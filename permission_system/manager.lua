-- PermissionManager: the brain. Loads global (trusted) + project (untrusted)
-- permission configs, compiles per-category wildcard pattern lists in
-- declaration order, and resolves checkPermission/getToolPermission with
-- the trusted-floor rule: an untrusted layer may tighten (add "deny") but
-- can never relax a trusted "deny".
--
-- Ported from pi-permission-system's permission-manager.ts. lupus has only
-- two layers (no per-agent frontmatter, no agent router — see llm.md §4),
-- but the trusted-floor algorithm is identical; it degrades gracefully to
-- 2 layers instead of 4.

local uv = require("luv")
local fs = require("lupus.util.fs")
local common = require("permission_system.common")
local jsonc = require("permission_system.jsonc")
local wildcard = require("permission_system.wildcard")
local state = require("permission_system.state")

local manager = {}

-- ---------------------------------------------------------------------------
-- Raw config normalization

local function normalize_policy(value, fill_defaults)
	local record = common.to_record(value)
	local out = {}
	for _, category in ipairs(state.POLICY_CATEGORIES) do
		local v = record[category]
		if common.is_permission_state(v) then
			out[category] = v
		elseif fill_defaults then
			out[category] = state.DEFAULT_POLICY[category]
		end
	end
	return out
end

--- Ordered { {pattern=, state=}, ... } from a jsonc object, valid entries
--- only (declaration order preserved — this is what last-match-wins needs).
local function normalize_permission_entries(value)
	local obj = common.to_record(value)
	local out = {}
	for _, key in ipairs(obj.__keys or {}) do
		local v = obj[key]
		if common.is_permission_state(v) then
			out[#out + 1] = { pattern = key, state = v }
		end
	end
	return out
end

local function upsert_entry(entries, pattern, new_state)
	for _, entry in ipairs(entries) do
		if entry.pattern == pattern then
			entry.state = new_state
			return
		end
	end
	entries[#entries + 1] = { pattern = pattern, state = new_state }
end

--- One layer's raw jsonc object -> { default_policy, tools, bash, mcp,
--- skills, special }. `fill_policy_defaults` is true only for the global
--- layer: global's default policy always has all 5 categories (falling
--- back to "ask"); project's stays partial so unset categories fall
--- through to global instead of shadowing it with "ask".
local function normalize_raw_permission(raw, fill_policy_defaults)
	local record = common.to_record(raw)
	local normalized = {
		default_policy = normalize_policy(record.defaultPolicy, fill_policy_defaults),
		tools = normalize_permission_entries(record.tools),
		bash = normalize_permission_entries(record.bash),
		mcp = normalize_permission_entries(record.mcp),
		skills = normalize_permission_entries(record.skills),
		special = normalize_permission_entries(record.special),
	}

	-- Top-level shorthand: a scalar "read": "allow" at the config root
	-- folds into `tools`; "doom_loop"/"external_directory" fold into
	-- `special`. Preserves root declaration order via upsert (update in
	-- place if the nested category object already declared the same key,
	-- else append).
	for _, key in ipairs(record.__keys or {}) do
		local value = record[key]
		if common.is_permission_state(value) then
			if state.BUILT_IN_TOOLS[key] then
				upsert_entry(normalized.tools, key, value)
			elseif state.SPECIAL_KEYS[key] then
				upsert_entry(normalized.special, key, value)
			end
		end
	end

	return normalized
end

-- ---------------------------------------------------------------------------
-- MCP target construction (forward-compatible: lupus ships no mcp tool by
-- default, but an extension-registered one feeds `input` with the same
-- {tool, server, connect, describe, search} shape and gets the same rules).

local function parse_qualified_mcp_tool_name(value)
	local trimmed = value:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil, nil
	end
	local colon = trimmed:find(":", 1, true)
	if not colon or colon <= 1 or colon >= #trimmed then
		return nil, nil
	end
	local server = trimmed:sub(1, colon - 1):match("^%s*(.-)%s*$")
	local tool = trimmed:sub(colon + 1):match("^%s*(.-)%s*$")
	if server == "" or tool == "" then
		return nil, nil
	end
	return server, tool
end

local function push_mcp_tool_targets(raw_reference, server_hint, push)
	local qualified_server, qualified_tool = parse_qualified_mcp_tool_name(raw_reference)
	local resolved_server = server_hint or qualified_server
	local resolved_tool = qualified_tool or raw_reference

	if resolved_server then
		push(resolved_server .. "_" .. resolved_tool)
		push(resolved_server .. ":" .. resolved_tool)
		push(resolved_server)
	end
	push(resolved_tool)
	push(raw_reference)
end

local function create_mcp_permission_targets(input)
	local record = common.to_record(input)
	local tool = common.get_non_empty_string(record.tool)
	local server = common.get_non_empty_string(record.server)
	local connect = common.get_non_empty_string(record.connect)
	local describe = common.get_non_empty_string(record.describe)
	local search = common.get_non_empty_string(record.search)

	local targets, seen = {}, {}
	local function push(value)
		if value and value ~= "" and not seen[value] then
			seen[value] = true
			targets[#targets + 1] = value
		end
	end

	if tool then
		push_mcp_tool_targets(tool, server, push)
		push("mcp_call")
		return targets
	end
	if connect then
		push("mcp_connect_" .. connect)
		push(connect)
		push("mcp_connect")
		return targets
	end
	if describe then
		push_mcp_tool_targets(describe, server, push)
		push("mcp_describe")
		return targets
	end
	if search then
		if server then
			push("mcp_server_" .. server)
			push(server)
		end
		push(search)
		push("mcp_search")
		return targets
	end
	if server then
		push("mcp_server_" .. server)
		push(server)
		push("mcp_list")
		return targets
	end
	push("mcp_status")
	return targets
end

-- ---------------------------------------------------------------------------
-- Path resource targets ("read:/abs/path/*")

local function get_path_resource_from_input(input, cwd)
	local record = common.to_record(input)
	local path_value = common.get_non_empty_string(record.path) or common.get_non_empty_string(record.file_path)
	if not path_value then
		return nil
	end
	local effective_cwd = common.get_non_empty_string(record.cwd) or cwd
	local resource = common.normalize_path_resource_for_permission(path_value, effective_cwd)
	return resource ~= "" and resource or nil
end

local function create_action_resource_targets(action, input, cwd)
	local resource = get_path_resource_from_input(input, cwd)
	if resource then
		return { action .. ":" .. resource }
	end
	return {}
end

-- ---------------------------------------------------------------------------
-- Layered pattern resolution (trusted-floor rule)

--- Compile every layer's entries for one category into a single ordered
--- list (global's patterns first, then project's), each wrapped with its
--- layer name + trust so the trusted-floor check can find the latest
--- trusted match later.
local function compile_patterns_from_layers(category, layers)
	local entries = {}
	for _, layer in ipairs(layers) do
		for _, item in ipairs(layer[category] or {}) do
			entries[#entries + 1] = {
				pattern = item.pattern,
				value = { state = item.state, layer = layer.name, trusted = layer.trusted },
			}
		end
	end
	return wildcard.compile_entries(entries)
end

local function find_latest_trusted_match(patterns, name)
	local normalized_name = wildcard.normalize_name(name)
	for i = #patterns, 1, -1 do
		local entry = patterns[i]
		if entry.value.trusted and entry.match(normalized_name) then
			return { value = entry.value, matched_pattern = entry.pattern, matched_name = name }
		end
	end
	return nil
end

local function find_latest_trusted_match_for_names(patterns, names)
	for i = #patterns, 1, -1 do
		local entry = patterns[i]
		if entry.value.trusted then
			for _, name in ipairs(names) do
				if entry.match(wildcard.normalize_name(name)) then
					return { value = entry.value, matched_pattern = entry.pattern, matched_name = name }
				end
			end
		end
	end
	return nil
end

--- Last-match-wins, with the trusted floor: if the winning match is
--- untrusted and not "deny", but some trusted pattern also matches and
--- says "deny", the trusted "deny" wins instead.
local function find_compiled_permission_match(patterns, name)
	if #patterns == 0 then
		return nil
	end
	local match = wildcard.find_match(patterns, name)
	if not match then
		return nil
	end
	if match.value.state ~= "deny" and not match.value.trusted then
		local trusted_floor = find_latest_trusted_match(patterns, name)
		if trusted_floor and trusted_floor.value.state == "deny" then
			return trusted_floor
		end
	end
	return match
end

local function find_compiled_permission_match_for_names(patterns, names)
	return common.find_first_match_for_names(names, function(name)
		return find_compiled_permission_match(patterns, name)
	end)
end

--- Path/special-style dispatch: several candidate target strings (the
--- resource-qualified one first, the bare tool name second), but unlike
--- find_compiled_permission_match_for_names (which exhausts one name
--- against all patterns before trying the next), this scans patterns
--- last -> first and for EACH pattern tries every candidate name — so
--- whichever target a *later-declared* pattern happens to match wins,
--- regardless of which target string it was.
local function find_compiled_permission_match_by_pattern_order_for_names(patterns, names)
	if #patterns == 0 then
		return nil
	end
	local normalized_names = {}
	for _, name in ipairs(names) do
		local trimmed = name:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			normalized_names[#normalized_names + 1] = trimmed
		end
	end
	if #normalized_names == 0 then
		return nil
	end

	for i = #patterns, 1, -1 do
		local entry = patterns[i]
		for _, name in ipairs(normalized_names) do
			if entry.match(wildcard.normalize_name(name)) then
				if entry.value.state ~= "deny" and not entry.value.trusted then
					local trusted_floor = find_latest_trusted_match_for_names(patterns, normalized_names)
					if trusted_floor and trusted_floor.value.state == "deny" then
						return trusted_floor
					end
				end
				return { value = entry.value, matched_pattern = entry.pattern, matched_name = name }
			end
		end
	end
	return nil
end

--- Scalar (non-pattern) trusted-floor resolution, for default-policy
--- categories: walk layers in order, letting a trusted "deny" act as a
--- floor an untrusted non-deny can't beat.
local function resolve_layered_default(layers, category)
	local current, trusted_floor = nil, nil
	for _, layer in ipairs(layers) do
		local layer_state = layer.default_policy[category]
		if layer_state then
			local candidate = { state = layer_state, layer = layer.name, trusted = layer.trusted }
			if not candidate.trusted and candidate.state ~= "deny" and trusted_floor and trusted_floor.state == "deny" then
				current = trusted_floor
			else
				current = candidate
				if candidate.trusted then
					trusted_floor = candidate
				end
			end
		end
	end
	return current
end

local function default_state(layers, category)
	local resolved = resolve_layered_default(layers, category)
	return resolved and resolved.state or state.DEFAULT_POLICY[category]
end

local function compiled_category_has_allow(compiled_list)
	for _, entry in ipairs(compiled_list) do
		if entry.value.state == "allow" then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- File loading + caching (mtime-stamped, like pi's FileCacheEntry)

local function file_stamp(path)
	if not path then
		return "none"
	end
	local st = uv.fs_stat(path)
	if not st then
		return "missing"
	end
	return ("%d.%d"):format(st.mtime.sec, st.mtime.nsec)
end

local function load_raw_config(path, on_warning)
	if not path or not fs.is_file(path) then
		return nil
	end
	local text = fs.read_file(path)
	if not text then
		return nil
	end
	local value, err = jsonc.parse(text)
	if not value then
		if on_warning then
			on_warning(jsonc.format_load_warning(path, err, "permission config", "using ask fallback"))
		end
		return nil
	end
	return value
end

-- ---------------------------------------------------------------------------

local Manager = {}
Manager.__index = Manager

--- opts: { global_config_path, project_config_path?, on_warning? = fn(msg) }
function manager.new(opts)
	opts = opts or {}
	assert(opts.global_config_path, "manager.new requires global_config_path")
	return setmetatable({
		global_config_path = opts.global_config_path,
		project_config_path = opts.project_config_path,
		on_warning = opts.on_warning,
		_global_cache = nil,
		_project_cache = nil,
		_resolved_cache = nil,
	}, Manager)
end

function Manager:_load_global()
	local stamp = file_stamp(self.global_config_path)
	if self._global_cache and self._global_cache.stamp == stamp then
		return self._global_cache.value
	end
	local raw = load_raw_config(self.global_config_path, self.on_warning)
	local value = normalize_raw_permission(raw, true)
	self._global_cache = { stamp = stamp, value = value }
	return value
end

function Manager:_load_project()
	if not self.project_config_path then
		return normalize_raw_permission(nil, false)
	end
	local stamp = file_stamp(self.project_config_path)
	if self._project_cache and self._project_cache.stamp == stamp then
		return self._project_cache.value
	end
	local raw = load_raw_config(self.project_config_path, self.on_warning)
	local value = normalize_raw_permission(raw, false)
	self._project_cache = { stamp = stamp, value = value }
	return value
end

--- Cache key covering every file that affects resolution, so a resolved
--- (compiled) view is reused until either config file's mtime changes.
function Manager:get_policy_cache_stamp()
	return file_stamp(self.global_config_path) .. "|" .. file_stamp(self.project_config_path)
end

function Manager:_resolve()
	local stamp = self:get_policy_cache_stamp()
	if self._resolved_cache and self._resolved_cache.stamp == stamp then
		return self._resolved_cache.value
	end

	local global_cfg = self:_load_global()
	local project_cfg = self:_load_project()
	local layers = {
		{
			name = "global",
			trusted = true,
			default_policy = global_cfg.default_policy,
			tools = global_cfg.tools,
			bash = global_cfg.bash,
			mcp = global_cfg.mcp,
			skills = global_cfg.skills,
			special = global_cfg.special,
		},
		{
			name = "project",
			trusted = false,
			default_policy = project_cfg.default_policy,
			tools = project_cfg.tools,
			bash = project_cfg.bash,
			mcp = project_cfg.mcp,
			skills = project_cfg.skills,
			special = project_cfg.special,
		},
	}

	local compiled = {}
	for _, category in ipairs(state.CATEGORIES) do
		compiled[category] = compile_patterns_from_layers(category, layers)
	end

	local value = { layers = layers, compiled = compiled }
	self._resolved_cache = { stamp = stamp, value = value }
	return value
end

--- Tool-level permission only (no command/resource rules) — used for
--- deciding whether to hide a tool from the model's tool list.
function Manager:get_tool_permission(tool_name)
	local resolved = self:_resolve()
	local layers, compiled = resolved.layers, resolved.compiled
	local normalized = tool_name:match("^%s*(.-)%s*$")

	if state.SPECIAL_KEYS[normalized] then
		return default_state(layers, "special")
	end
	if normalized == "skill" then
		return default_state(layers, "skills")
	end

	local tool_match = find_compiled_permission_match(compiled.tools, normalized)
	if normalized == "bash" then
		return (tool_match and tool_match.value.state) or default_state(layers, "bash")
	end
	if normalized == "mcp" then
		return (tool_match and tool_match.value.state) or default_state(layers, "mcp")
	end
	return (tool_match and tool_match.value.state) or default_state(layers, "tools")
end

--- Full dispatch: resource/command-aware. `cwd` resolves relative paths
--- for path-bearing tools (lupus has one fixed session cwd; pass
--- api.cwd). Returns { tool_name, state, matched_pattern?, command?,
--- target?, source }.
function Manager:check_permission(tool_name, input, cwd)
	local resolved = self:_resolve()
	local layers, compiled = resolved.layers, resolved.compiled
	local normalized = tool_name:match("^%s*(.-)%s*$")
	local tool_match = find_compiled_permission_match(compiled.tools, normalized)

	if state.SPECIAL_KEYS[normalized] then
		local targets = create_action_resource_targets(normalized, input, cwd)
		targets[#targets + 1] = normalized
		local result = find_compiled_permission_match_by_pattern_order_for_names(compiled.special, targets)
		return {
			tool_name = tool_name,
			state = (result and result.value.state) or default_state(layers, "special"),
			matched_pattern = result and result.matched_pattern,
			target = result and result.matched_name,
			source = "special",
		}
	end

	if normalized == "skill" then
		local skill_name = common.to_record(input).name
		if type(skill_name) == "string" then
			local result = find_compiled_permission_match(compiled.skills, skill_name)
			return {
				tool_name = tool_name,
				state = (result and result.value.state) or default_state(layers, "skills"),
				matched_pattern = result and result.matched_pattern,
				source = "skill",
			}
		end
		return { tool_name = tool_name, state = default_state(layers, "skills"), source = "skill" }
	end

	if normalized == "bash" then
		local record = common.to_record(input)
		local command = type(record.command) == "string" and record.command or ""
		local result = find_compiled_permission_match(compiled.bash, command)
		return {
			tool_name = tool_name,
			state = (result and result.value.state) or (tool_match and tool_match.value.state) or default_state(
				layers,
				"bash"
			),
			command = command,
			matched_pattern = result and result.matched_pattern,
			source = "bash",
		}
	end

	if normalized == "mcp" then
		local mcp_targets = create_mcp_permission_targets(input)
		mcp_targets[#mcp_targets + 1] = "mcp"
		local fallback_target = mcp_targets[1] or "mcp"
		local default_mcp_state = default_state(layers, "mcp")

		local mcp_match = find_compiled_permission_match_for_names(compiled.mcp, mcp_targets)
		if mcp_match then
			return {
				tool_name = tool_name,
				state = mcp_match.value.state,
				matched_pattern = mcp_match.matched_pattern,
				target = mcp_match.matched_name,
				source = "mcp",
			}
		end

		if tool_match then
			return {
				tool_name = tool_name,
				state = tool_match.value.state,
				matched_pattern = tool_match.matched_pattern,
				target = fallback_target,
				source = "tool",
			}
		end

		local baseline_target = nil
		for _, target in ipairs(mcp_targets) do
			if state.MCP_BASELINE_TARGETS[target] then
				baseline_target = target
				break
			end
		end
		if baseline_target and (compiled_category_has_allow(compiled.mcp) or default_mcp_state == "allow") then
			return { tool_name = tool_name, state = "allow", target = baseline_target, source = "mcp" }
		end

		return { tool_name = tool_name, state = default_mcp_state, target = fallback_target, source = "default" }
	end

	if state.BUILT_IN_TOOLS[normalized] then
		local targets = create_action_resource_targets(normalized, input, cwd)
		targets[#targets + 1] = normalized
		local result = find_compiled_permission_match_by_pattern_order_for_names(compiled.tools, targets)
		return {
			tool_name = tool_name,
			state = (result and result.value.state) or default_state(layers, "tools"),
			matched_pattern = result and result.matched_pattern,
			target = result and result.matched_name,
			source = "tool",
		}
	end

	if tool_match then
		return { tool_name = tool_name, state = tool_match.value.state, matched_pattern = tool_match.matched_pattern, source = "tool" }
	end

	return { tool_name = tool_name, state = default_state(layers, "tools"), source = "default" }
end

manager.Manager = Manager
manager.get_path_resource_from_input = get_path_resource_from_input

return manager
