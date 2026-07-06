-- The 4-option approval dialog (Allow Once / Allow Always / Reject / Reject
-- with Reason), plus prompt compaction so an oversized tool-input preview
-- doesn't make the select dialog unusable. Ported from
-- permission-dialog.ts's requestPermissionDecisionFromUi +
-- compactPermissionPromptForSelect; the subagent-forwarding timeout path is
-- omitted (lupus has no subagents — see llm.md §4).

local common = require("permission_system.common")

local dialog = {}

local MAX_VISIBLE_LINES = 32
local MAX_VISIBLE_CHARACTERS = 2200

local OPTIONS = { "Allow Once", "Allow Always", "Reject", "Reject with Reason" }

local function rtrim(value)
	return (value:match("^(.-)%s*$"))
end

local function split_lines(value)
	local normalized = value:gsub("\r\n", "\n"):gsub("\r", "\n")
	local lines = {}
	for line in (normalized .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	return lines
end

local function format_compaction_notice(omitted_lines, omitted_characters)
	local parts = {}
	if omitted_lines > 0 then
		parts[#parts + 1] = ("%d %s"):format(omitted_lines, omitted_lines == 1 and "line" or "lines")
	end
	if omitted_characters > 0 then
		parts[#parts + 1] = ("%d %s"):format(omitted_characters, omitted_characters == 1 and "character" or "characters")
	end
	local summary = #parts > 0 and table.concat(parts, " and ") or "content"
	return "[Permission prompt compacted: omitted " .. summary .. " to keep the permission dialog usable.]"
end

--- Keep an oversized prompt within MAX_VISIBLE_LINES/MAX_VISIBLE_CHARACTERS
--- by keeping a prefix and appending a compaction notice, shrinking the
--- prefix until the notice + prefix fit.
function dialog.compact_prompt(value)
	local lines = split_lines(value)
	if #lines <= MAX_VISIBLE_LINES and #value <= MAX_VISIBLE_CHARACTERS then
		return value
	end

	local max_prefix_lines = math.max(1, MAX_VISIBLE_LINES - 1)
	local prefix_lines = {}
	for i = 1, math.min(max_prefix_lines, #lines) do
		prefix_lines[i] = lines[i]
	end
	local omitted_lines = math.max(0, #lines - #prefix_lines)
	local prefix = table.concat(prefix_lines, "\n")

	for _ = 1, 3 do
		local omitted_characters = math.max(0, #value - #prefix)
		local notice = format_compaction_notice(omitted_lines, omitted_characters)
		local trimmed = rtrim(prefix)
		local separator_length = trimmed ~= "" and 1 or 0
		local max_prefix_characters = math.max(0, MAX_VISIBLE_CHARACTERS - #notice - separator_length)

		if #prefix <= max_prefix_characters then
			return trimmed ~= "" and (trimmed .. "\n" .. notice) or notice
		end
		prefix = rtrim(prefix:sub(1, max_prefix_characters))
	end

	local omitted_characters = math.max(0, #value - #prefix)
	local notice = format_compaction_notice(omitted_lines, omitted_characters)
	local trimmed = rtrim(prefix)
	return trimmed ~= "" and (trimmed .. "\n" .. notice) or notice
end

--- Show the 4-option dialog. Returns { approved, state = "once"|"always"
--- |"reject", denial_reason? }. Yields (api.select/api.input pause the
--- agent's run task — see llm.md §5.6, safe under LuaJIT's yield-across-
--- pcall extension).
function dialog.request_decision(api, title, message)
	local combined = dialog.compact_prompt(title .. "\n" .. message)
	local choice = api.select({ title = combined, options = OPTIONS })

	if choice == "Allow Once" then
		return { approved = true, state = "once" }
	end
	if choice == "Allow Always" then
		return { approved = true, state = "always" }
	end
	if choice == "Reject with Reason" then
		local reason = api.input({
			title = combined .. "\nShare why this request was denied (optional).",
			placeholder = "Reason shown back to the agent",
		})
		reason = common.get_non_empty_string(reason)
		if reason then
			return { approved = false, state = "reject", denial_reason = reason }
		end
		return { approved = false, state = "reject" }
	end

	-- "Reject", or nil (esc/cancel) — both deny.
	return { approved = false, state = "reject" }
end

return dialog
