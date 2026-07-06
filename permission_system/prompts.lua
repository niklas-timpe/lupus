-- Human-readable prompt/deny-reason formatters. Ported from pi's
-- permission-prompts.ts, rewritten against lupus's tool argument shapes
-- (snake_case; a single old_string/new_string edit, not pi's
-- oldText/newText/edits list; no file_path alias — lupus tools only ever
-- send `path`, kept as a fallback for parity with pi's getPromptPath).
--
-- Omitted vs. pi: formatMissingToolNameReason / formatUnknownToolReason
-- (lupus's agent rejects a missing/unregistered tool name before the veto
-- ever fires — see llm.md §4 — so these have no call site) and the
-- skill-path prompts (lupus has no skill-file gating to prompt about).

local common = require("permission_system.common")
local json = require("lupus.util.json")

local prompts = {}

local TOOL_INPUT_PREVIEW_MAX_LENGTH = 200
local TOOL_TEXT_SUMMARY_MAX_LENGTH = 80

local function truncate_inline_text(value, max_length)
	if #value > max_length then
		return value:sub(1, max_length) .. "\226\128\166" -- "…"
	end
	return value
end

local function sanitize_inline_text(value, max_length)
	max_length = max_length or TOOL_TEXT_SUMMARY_MAX_LENGTH
	local normalized = value:gsub("%s+", " "):match("^%s*(.-)%s*$")
	if normalized == "" then
		return "empty text"
	end
	return truncate_inline_text(normalized, max_length)
end

local function count_text_lines(value)
	if not value or value == "" then
		return 0
	end
	local stripped = value:sub(-1) == "\n" and value:sub(1, -2) or value
	local n = 1
	for _ in stripped:gmatch("\n") do
		n = n + 1
	end
	return n
end

local function format_count(value, singular, plural)
	return ("%d %s"):format(value, value == 1 and singular or plural)
end

local function get_prompt_path(input)
	return common.get_non_empty_string(input.path) or common.get_non_empty_string(input.file_path)
end

-- ---------------------------------------------------------------------------
-- Per-tool input previews (what "requested tool 'X' <preview>" fills in)

local function format_read_input(input)
	local parts = {}
	local path = get_prompt_path(input)
	if path then
		parts[#parts + 1] = ("path '%s'"):format(path)
	end
	if type(input.offset) == "number" then
		parts[#parts + 1] = ("offset %d"):format(input.offset)
	end
	if type(input.limit) == "number" then
		parts[#parts + 1] = ("limit %d"):format(input.limit)
	end
	return #parts > 0 and ("for " .. table.concat(parts, ", ")) or ""
end

local function format_write_input(input)
	local path = get_prompt_path(input)
	local content = type(input.content) == "string" and input.content or ""
	local summary = ("(%s, %s)"):format(
		format_count(count_text_lines(content), "line", "lines"),
		format_count(#content, "character", "characters")
	)
	return path and ("for '" .. path .. "' " .. summary) or summary
end

local function format_edit_input(input)
	local path = get_prompt_path(input)
	if type(input.old_string) == "string" and type(input.new_string) == "string" then
		local summary = ("replaces %s with %s"):format(
			format_count(count_text_lines(input.old_string), "line", "lines"),
			format_count(count_text_lines(input.new_string), "line", "lines")
		)
		if input.replace_all then
			summary = summary .. ", all occurrences"
		end
		return path and ("for '" .. path .. "' (" .. summary .. ")") or ("(" .. summary .. ")")
	end
	return "with edit input"
end

local function format_search_input(tool_name, input)
	local parts = {}
	local path = get_prompt_path(input)
	local pattern = common.get_non_empty_string(input.pattern)
	if pattern then
		parts[#parts + 1] = ("pattern '%s'"):format(sanitize_inline_text(pattern))
	end
	if path then
		parts[#parts + 1] = ("path '%s'"):format(path)
	elseif tool_name == "find" or tool_name == "grep" or tool_name == "ls" then
		parts[#parts + 1] = "current working directory"
	end
	return #parts > 0 and ("for " .. table.concat(parts, ", ")) or ""
end

local function serialize_tool_input_preview(input)
	local ok, serialized = pcall(json.encode, input)
	if not ok or not serialized or serialized == "{}" or serialized == "null" then
		return ""
	end
	return (serialized:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function format_json_input(input)
	local inline = serialize_tool_input_preview(input)
	if inline == "" then
		return ""
	end
	return "with input " .. truncate_inline_text(inline, TOOL_INPUT_PREVIEW_MAX_LENGTH)
end

--- Preview text for "requested tool '<name>' <this>." (bash is handled
--- separately by its callers via result.command, never through here).
function prompts.format_tool_input_for_prompt(tool_name, input)
	local record = common.to_record(input)
	if tool_name == "edit" then
		return format_edit_input(record)
	elseif tool_name == "write" then
		return format_write_input(record)
	elseif tool_name == "read" then
		return format_read_input(record)
	elseif tool_name == "find" or tool_name == "grep" or tool_name == "ls" then
		return format_search_input(tool_name, record)
	end
	return format_json_input(input)
end

-- ---------------------------------------------------------------------------
-- Subject / hard-stop framing

--- lupus has no agent router (agent_name is always nil in practice); kept
--- parametric for parity with pi's layering model.
function prompts.format_agent_subject(agent_name)
	return agent_name and ("Agent '" .. agent_name .. "'") or "Current agent"
end

local function format_permission_hard_stop_hint(result)
	if (result.source == "mcp" or result.tool_name == "mcp") and result.target then
		return "Hard stop: this MCP permission denial is policy-enforced. Do not retry this target, "
			.. "do not run discovery/investigation to bypass it, and report the block to the user."
	end
	return "Hard stop: this permission denial is policy-enforced. Do not retry or investigate bypasses; "
		.. "report the block to the user."
end

-- ---------------------------------------------------------------------------
-- Deny / ask / user-denied prompts (main dispatch)

function prompts.format_deny_reason(result, agent_name)
	local parts = {}
	if agent_name then
		parts[#parts + 1] = ("Agent '%s'"):format(agent_name)
	end
	if (result.source == "mcp" or result.tool_name == "mcp") and result.target then
		parts[#parts + 1] = ("is not permitted to run MCP target '%s'"):format(result.target)
	else
		parts[#parts + 1] = ("is not permitted to run '%s'"):format(result.tool_name)
	end
	if result.command then
		parts[#parts + 1] = ("command '%s'"):format(result.command)
	end
	if result.matched_pattern then
		parts[#parts + 1] = ("(matched '%s')"):format(result.matched_pattern)
	end
	return table.concat(parts, " ") .. ". " .. format_permission_hard_stop_hint(result)
end

function prompts.format_user_denied_reason(result, denial_reason)
	local base
	if (result.source == "mcp" or result.tool_name == "mcp") and result.target then
		base = ("User denied MCP target '%s'."):format(result.target)
	elseif result.tool_name == "bash" and result.command then
		base = ("User denied bash command '%s'."):format(result.command)
	else
		base = ("User denied tool '%s'."):format(result.tool_name)
	end
	local suffix = denial_reason and (" Reason: " .. denial_reason .. ".") or ""
	return base .. suffix .. " " .. format_permission_hard_stop_hint(result)
end

function prompts.format_ask_prompt(result, agent_name, input)
	local subject = prompts.format_agent_subject(agent_name)

	if result.tool_name == "bash" then
		local pattern_info = result.matched_pattern and (" (matched '" .. result.matched_pattern .. "')") or ""
		return ("%s requested bash command '%s'%s. Allow this command?"):format(
			subject,
			result.command or "",
			pattern_info
		)
	end

	if (result.source == "mcp" or result.tool_name == "mcp") and result.target then
		local pattern_info = result.matched_pattern and (" (matched '" .. result.matched_pattern .. "')") or ""
		return ("%s requested MCP target '%s'%s. Allow this call?"):format(subject, result.target, pattern_info)
	end

	local pattern_info = result.matched_pattern and (" (matched '" .. result.matched_pattern .. "')") or ""
	local input_preview = prompts.format_tool_input_for_prompt(result.tool_name, input)
	local input_suffix = input_preview ~= "" and (" " .. input_preview) or ""
	return ("%s requested tool '%s'%s%s. Allow this call?"):format(subject, result.tool_name, pattern_info, input_suffix)
end

--- Kept for forward compatibility if an extension registers a "skill"
--- tool; lupus itself has no skill loader (see llm.md §4).
function prompts.format_skill_ask_prompt(skill_name, agent_name)
	return ("%s requested skill '%s'. Allow loading this skill?"):format(prompts.format_agent_subject(agent_name), skill_name)
end

-- ---------------------------------------------------------------------------
-- external_directory (fires before the main check for path tools whose
-- resolved path falls outside cwd)

local function format_external_directory_hard_stop_hint()
	return "Hard stop: this external directory permission denial is policy-enforced. Do not retry this path, "
		.. "do not attempt a filesystem bypass, and report the block to the user."
end

function prompts.format_external_directory_ask_prompt(tool_name, path_value, cwd, agent_name)
	return ("%s requested tool '%s' for path '%s' outside working directory '%s'. Allow this external directory access?"):format(
		prompts.format_agent_subject(agent_name),
		tool_name,
		path_value,
		cwd
	)
end

function prompts.format_external_directory_deny_reason(tool_name, path_value, cwd, agent_name)
	return ("%s is not permitted to run tool '%s' for path '%s' outside working directory '%s'. %s"):format(
		prompts.format_agent_subject(agent_name),
		tool_name,
		path_value,
		cwd,
		format_external_directory_hard_stop_hint()
	)
end

function prompts.format_external_directory_user_denied_reason(tool_name, path_value, denial_reason)
	local suffix = denial_reason and (" Reason: " .. denial_reason .. ".") or ""
	return ("User denied external directory access for tool '%s' path '%s'.%s %s"):format(
		tool_name,
		path_value,
		suffix,
		format_external_directory_hard_stop_hint()
	)
end

return prompts
