-- Small, dependency-free helpers shared across the permission system.
-- Ported from pi-permission-system's common.ts; the agent-frontmatter /
-- YAML helpers are omitted (lupus has no agent-frontmatter layer — see
-- llm.md §4).

local fs = require("lupus.util.fs")
local state = require("permission_system.state")

local common = {}

--- Coerce a value to a plain record table, or {} for anything else
--- (nil, arrays, scalars). Mirrors pi's toRecord.
function common.to_record(value)
	if type(value) ~= "table" then
		return {}
	end
	-- Reject array-ish tables (json arrays decode with integer keys 1..n).
	if value[1] ~= nil then
		return {}
	end
	return value
end

--- Trim a string and return it, or nil if not a non-empty string.
function common.get_non_empty_string(value)
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = value:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil
	end
	return trimmed
end

--- Semantically get_non_empty_string; kept as a named alias for call-site
--- readability where the value represents an agent name. lupus has no
--- agent router, so this is always nil in practice — kept for parity with
--- pi's layering model and in case lupus grows named agents later.
common.normalize_agent_name = common.get_non_empty_string

function common.is_permission_state(value)
	return value == state.PermissionState.ALLOW or value == state.PermissionState.DENY or value == state.PermissionState.ASK
end

--- Normalize a list of names (trim + drop empty) and return the first
--- match `match_single` produces, or nil.
function common.find_first_match_for_names(names, match_single)
	for _, name in ipairs(names) do
		local trimmed = name:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			local match = match_single(trimmed)
			if match then
				return match
			end
		end
	end
	return nil
end

--- Resolve a path argument to an absolute, normalized path. Strips a
--- surrounding pair of quotes (models occasionally over-quote arguments).
function common.normalize_path_for_comparison(path_value, cwd)
	local trimmed = path_value:match("^%s*(.-)%s*$")
	trimmed = trimmed:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
	if trimmed == "" then
		return ""
	end
	return fs.absolute(trimmed, cwd)
end

--- Absolute path, forward-slashed, trailing slash stripped (except root).
--- This is the string permission patterns like "read:/abs/path/*" match
--- against.
function common.normalize_path_resource_for_permission(path_value, cwd)
	local normalized = common.normalize_path_for_comparison(path_value, cwd):gsub("\\", "/")
	if normalized == "" then
		return ""
	end
	if normalized:match("^/+$") then
		return "/"
	end
	return (normalized:gsub("/+$", ""))
end

--- True if `path_value` is `directory` or a descendant of it. Both must
--- already be normalized (see above).
function common.is_path_within_directory(path_value, directory)
	if path_value == "" or directory == "" then
		return false
	end
	if path_value == directory then
		return true
	end
	local prefix = directory:sub(-1) == "/" and directory or (directory .. "/")
	return path_value:sub(1, #prefix) == prefix
end

function common.normalize_line_endings(text)
	return (text:gsub("\r\n", "\n"))
end

return common
