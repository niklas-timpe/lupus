-- M.setup(api): the extension factory. Wires session_start,
-- before_agent_start, and the tool_call veto; owns the manager, the
-- session approval store, the extension's own config, and the logger.
--
-- Ported from pi-permission-system's index.ts tool_call/before_agent_start
-- handlers (llm.md §2-4), trimmed to what has a lupus equivalent:
-- no tool-registration check (lupus's agent already rejects unknown tool
-- names before the veto fires), no skill-read gating, no subagent
-- forwarding, no decision-dedup cache (lupus executes tools sequentially,
-- so the duplicate-concurrent-prompt race pi guards against can't happen
-- here).

local fs = require("lupus.util.fs")
local lupus_config = require("lupus.config")

local state = require("permission_system.state")
local common = require("permission_system.common")
local manager_mod = require("permission_system.manager")
local approval = require("permission_system.approval")
local prompts = require("permission_system.prompts")
local dialog = require("permission_system.dialog")
local config_mod = require("permission_system.config")
local logger_mod = require("permission_system.logger")
local yolo = require("permission_system.yolo")

local M = {}

local ENV_POLICY_CONFIG_KEY = "LUPUS_PERMISSIONS_CONFIG"

--- Subject string session approvals key on: the same "resource" each
--- check dispatch used (bash -> command, mcp -> target, path tool ->
--- normalized path), so "Allow Always" persists at the right grain.
local function get_subject(tool_name, input, cwd, result)
	if tool_name == "bash" then
		return result.command or ""
	end
	if result.source == "mcp" or tool_name == "mcp" then
		return result.target or tool_name
	end
	if state.BUILT_IN_TOOLS[tool_name] then
		return manager_mod.get_path_resource_from_input(input, cwd) or tool_name
	end
	return tool_name
end

local function unavailable_reason(tool_name, result)
	if tool_name == "bash" then
		return ("Running bash command '%s' requires approval, but no interactive UI is available."):format(
			result.command or ""
		)
	end
	if tool_name == "mcp" then
		return "Using tool 'mcp' requires approval, but no interactive UI is available."
	end
	return ("Using tool '%s' requires approval, but no interactive UI is available."):format(tool_name)
end

function M.setup(api)
	local cwd = api.cwd
	local dirs = lupus_config.dirs()
	local global_config_path = common.get_non_empty_string(os.getenv(ENV_POLICY_CONFIG_KEY))
		or fs.join(dirs.config, "permissions.jsonc")
	local project_config_path = fs.join(cwd, ".lupus", "permissions.jsonc")

	-- Declared before use so the closures below close over this exact
	-- variable cell: reassigning `ext_config` later (session_start, /permissions
	-- reload/yolo/debug) is immediately visible to them — no extra
	-- indirection needed.
	config_mod.ensure()
	local ext_config, load_warning = config_mod.load()

	local log = logger_mod.new({ get_config = function()
		return ext_config
	end })

	local function notify_warning(message)
		api.notify("permission-system: " .. message, "warning")
		log.debug("config.load_warning", { message = message })
	end

	local manager = manager_mod.new({
		global_config_path = global_config_path,
		project_config_path = project_config_path,
		on_warning = notify_warning,
	})

	local store = approval.new_store()

	if load_warning then
		notify_warning(load_warning)
	end

	local function set_yolo_status()
		api.set_status(yolo.is_enabled(ext_config) and "YOLO" or nil)
	end
	set_yolo_status()

	-- ------------------------------------------------------------- lifecycle

	api.on("session_start", function()
		store:clear()
		local reloaded, warning = config_mod.load()
		ext_config = reloaded
		if warning then
			notify_warning(warning)
		end
		set_yolo_status()
	end)

	-- ---------------------------------------------------------- system prompt

	api.on("before_agent_start", function()
		if not ext_config.enabled then
			return
		end

		local hidden, denied, asking = {}, {}, {}
		for _, name in ipairs(state.BUILT_IN_TOOL_NAMES) do
			local base = { tool_name = name, state = manager:get_tool_permission(name), source = "tool" }
			local overlaid = approval.apply_pattern_state(store, name, name, base)
			if overlaid.state == "deny" then
				hidden[#hidden + 1] = name
				denied[#denied + 1] = name
			elseif overlaid.state == "ask" then
				asking[#asking + 1] = name
			end
		end

		local append = nil
		if #denied > 0 or #asking > 0 then
			local lines = { "Permission policy in effect:" }
			if #denied > 0 then
				lines[#lines + 1] = "- Denied tools, do not attempt: " .. table.concat(denied, ", ")
			end
			if #asking > 0 then
				lines[#lines + 1] = "- Tools that require approval before use: " .. table.concat(asking, ", ")
			end
			append = table.concat(lines, "\n")
		end

		return { hidden_tools = hidden, system_prompt_append = append }
	end)

	-- ------------------------------------------------------------ tool_call

	api.on("tool_call", function(ev)
		if not ext_config.enabled then
			return
		end

		local tool_name = ev.tool_name
		local input = ev.arguments or {}

		-- external_directory: fires before the main check, only for path
		-- tools whose resolved path falls outside cwd.
		if state.PATH_TOOLS[tool_name] then
			local path_value = common.get_non_empty_string(common.to_record(input).path)
			if path_value then
				local normalized_path = common.normalize_path_for_comparison(path_value, cwd)
				local normalized_cwd = common.normalize_path_for_comparison(cwd, cwd)
				if
					normalized_path ~= ""
					and normalized_cwd ~= ""
					and not common.is_path_within_directory(normalized_path, normalized_cwd)
				then
					local ext_check = manager:check_permission("external_directory", { path = path_value, cwd = cwd }, cwd)
					if ext_check.state == "ask" then
						ext_check = approval.apply_pattern_state(store, "external_directory", normalized_path, ext_check)
					end

					if ext_check.state == "deny" then
						log.review(
							"permission_request.blocked",
							{ tool_name = tool_name, path = normalized_path, resolution = "policy_denied" }
						)
						return {
							block = true,
							reason = prompts.format_external_directory_deny_reason(tool_name, normalized_path, cwd),
						}
					end

					if ext_check.state == "ask" then
						if not yolo.can_resolve_ask(api.has_ui, ext_config) then
							log.review(
								"permission_request.blocked",
								{ tool_name = tool_name, path = normalized_path, resolution = "confirmation_unavailable" }
							)
							return {
								block = true,
								reason = ("Accessing '%s' outside the working directory requires approval, but no interactive UI is available."):format(
									normalized_path
								),
							}
						end

						local decision
						if yolo.should_auto_approve("ask", ext_config) then
							decision = { approved = true, state = "approved" }
							log.review("permission_request.auto_approved", { tool_name = tool_name, path = normalized_path })
						else
							log.review("permission_request.waiting", { tool_name = tool_name, path = normalized_path })
							local message = prompts.format_external_directory_ask_prompt(tool_name, normalized_path, cwd)
							decision = dialog.request_decision(api, "Permission Required", message)
							log.review(
								decision.approved and "permission_request.approved" or "permission_request.denied",
								{ tool_name = tool_name, path = normalized_path, resolution = decision.state }
							)
						end

						if not decision.approved then
							return {
								block = true,
								reason = prompts.format_external_directory_user_denied_reason(
									tool_name,
									normalized_path,
									decision.denial_reason
								),
							}
						end
						if decision.state == "always" then
							store:approve_always("external_directory", normalized_path)
						end
					end
					-- allow falls through to the main check below
				end
			end
		end

		local result = manager:check_permission(tool_name, input, cwd)
		local subject = get_subject(tool_name, input, cwd, result)
		result = approval.apply_pattern_state(store, tool_name, subject, result)

		if result.state == "deny" then
			log.review("permission_request.blocked", {
				tool_name = tool_name,
				command = result.command,
				target = result.target,
				matched_pattern = result.matched_pattern,
				resolution = "policy_denied",
			})
			return { block = true, reason = prompts.format_deny_reason(result) }
		end

		if result.state == "ask" then
			if not yolo.can_resolve_ask(api.has_ui, ext_config) then
				log.review("permission_request.blocked", {
					tool_name = tool_name,
					command = result.command,
					target = result.target,
					resolution = "confirmation_unavailable",
				})
				return { block = true, reason = unavailable_reason(tool_name, result) }
			end

			local decision
			if yolo.should_auto_approve("ask", ext_config) then
				decision = { approved = true, state = "approved" }
				log.review("permission_request.auto_approved", { tool_name = tool_name, command = result.command, target = result.target })
			else
				log.review("permission_request.waiting", { tool_name = tool_name, command = result.command, target = result.target })
				local message = prompts.format_ask_prompt(result, nil, input)
				decision = dialog.request_decision(api, "Permission Required", message)
				log.review(
					decision.approved and "permission_request.approved" or "permission_request.denied",
					{ tool_name = tool_name, command = result.command, target = result.target, resolution = decision.state }
				)
			end

			if not decision.approved then
				return { block = true, reason = prompts.format_user_denied_reason(result, decision.denial_reason) }
			end
			if decision.state == "always" then
				store:approve_always(tool_name, subject)
			end
		end

		-- allow (or an approved ask) => nil verdict => tool runs.
	end)

	-- -------------------------------------------------------------- command

	api.register_command({
		name = "permissions",
		description = "Show or change permission-system settings (yolo/debug mode, config paths)",
		run = function(ctx, args)
			args = args or ""
			local sub, rest = args:match("^(%S*)%s*(.*)$")
			sub = sub ~= "" and sub or "show"

			if sub == "show" then
				local lines = {
					("permission-system: %s, yolo=%s, debug=%s"):format(
						ext_config.enabled and "enabled" or "disabled",
						tostring(ext_config.yolo_mode),
						tostring(ext_config.debug)
					),
				}
				for _, name in ipairs(state.BUILT_IN_TOOL_NAMES) do
					lines[#lines + 1] = ("  %s: %s"):format(name, manager:get_tool_permission(name))
				end
				ctx.notify(table.concat(lines, "\n"))
			elseif sub == "yolo" or sub == "debug" then
				local want = rest:match("^(%S*)")
				local key = sub == "yolo" and "yolo_mode" or "debug"
				local new_value
				if want == "on" then
					new_value = true
				elseif want == "off" then
					new_value = false
				else
					new_value = not ext_config[key]
				end
				ext_config[key] = new_value
				local ok, err = config_mod.save({ debug = ext_config.debug, yolo_mode = ext_config.yolo_mode })
				if sub == "yolo" then
					set_yolo_status()
				end
				ctx.notify(
					("permission-system: %s %s%s"):format(sub, new_value and "ON" or "OFF", ok and "" or (" (not persisted: " .. tostring(err) .. ")"))
				)
			elseif sub == "reload" then
				local reloaded, warning = config_mod.load()
				ext_config = reloaded
				store:clear()
				set_yolo_status()
				ctx.notify(
					("permission-system: reloaded config%s, cleared session approvals"):format(
						warning and (" (warning: " .. warning .. ")") or ""
					)
				)
			elseif sub == "path" then
				ctx.notify(
					table.concat({
						"permission-system:",
						"  policy (global): " .. global_config_path,
						"  policy (project): " .. project_config_path,
						"  extension config: " .. config_mod.default_path(),
						"  log: " .. logger_mod.default_path(),
					}, "\n")
				)
			else
				ctx.notify("usage: /permissions [show|yolo [on|off]|debug [on|off]|reload|path]")
			end
		end,
	})
end

return M
