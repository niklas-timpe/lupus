-- Built-in tool registry and shared helpers (output truncation, path
-- resolution). Individual tools live in their own modules and are plain
-- tool tables (see lupus/agent.lua for the contract).

local fs = require("lupus.util.fs")

local tools = {}

tools.MAX_BYTES = 50 * 1024
tools.MAX_LINES = 2000

--- Truncate long tool output. mode "head" keeps the beginning (default),
--- "tail" keeps the end (bash output: the end usually matters).
--- Returns the text plus a note when something was cut.
function tools.truncate(s, mode, max_bytes, max_lines)
	max_bytes = max_bytes or tools.MAX_BYTES
	max_lines = max_lines or tools.MAX_LINES
	mode = mode or "head"

	local total_bytes = #s
	local lines = {}
	for line in (s .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	-- Trailing newline produces one empty phantom line; drop it.
	if lines[#lines] == "" then
		lines[#lines] = nil
	end
	local total_lines = #lines

	if total_bytes <= max_bytes and total_lines <= max_lines then
		return s, nil
	end

	local keep = {}
	local kept_bytes = 0
	if mode == "tail" then
		for i = total_lines, 1, -1 do
			local cost = #lines[i] + 1
			if #keep >= max_lines or kept_bytes + cost > max_bytes then
				break
			end
			table.insert(keep, 1, lines[i])
			kept_bytes = kept_bytes + cost
		end
	else
		for i = 1, total_lines do
			local cost = #lines[i] + 1
			if #keep >= max_lines or kept_bytes + cost > max_bytes then
				break
			end
			keep[#keep + 1] = lines[i]
			kept_bytes = kept_bytes + cost
		end
	end

	local cut = total_lines - #keep
	local note = ("[truncated: showing %d of %d lines (%s)]"):format(
		#keep,
		total_lines,
		mode == "tail" and "end of output" or "start of output"
	)
	local body = table.concat(keep, "\n")
	if mode == "tail" then
		return note .. "\n" .. body, note
	end
	return body .. "\n" .. note, note
end

--- Resolve a (possibly relative, possibly ~) path against the tool cwd.
function tools.resolve(path, ctx)
	return fs.absolute(path, ctx.cwd)
end

--- All built-in tools, in registration order. read/bash/edit/write are the
--- default active set; grep/find/ls exist for read-only workflows.
function tools.builtin()
	return {
		(require("lupus.tools.read")),
		(require("lupus.tools.bash")),
		(require("lupus.tools.edit")),
		(require("lupus.tools.write")),
		(require("lupus.tools.grep")),
		(require("lupus.tools.find")),
		(require("lupus.tools.ls")),
	}
end

--- The default active set for coding sessions.
function tools.default_names()
	return { "read", "bash", "edit", "write", "grep", "find", "ls" }
end

return tools
