-- SGR interpreter: turns one ANSI-styled line into runs of plain text with
-- a structured style, the boundary between the string-based component world
-- (lupus/tui/text.lua styling) and whatever draws the screen. Pure module —
-- no ncurses here — so components and tests never touch the C library.
--
--   sgr.parse_line("\27[1mhi\27[0m there")
--     -> { { text = "hi", width = 2, style = { bold = true } },
--          { text = " there", width = 6, style = {} } }
--
-- style fields: bold, dim, italic, underline, reverse (booleans) and
-- fg = 0..15 (ANSI color index; 8..15 are the bright variants) or nil for
-- the terminal default.

local text = require("lupus.tui.text")

local sgr = {}

local function copy_style(st)
	return {
		bold = st.bold,
		dim = st.dim,
		italic = st.italic,
		underline = st.underline,
		reverse = st.reverse,
		fg = st.fg,
	}
end

local function apply_code(st, code)
	if code == 0 then
		st.bold, st.dim, st.italic, st.underline, st.reverse, st.fg = nil, nil, nil, nil, nil, nil
	elseif code == 1 then
		st.bold = true
	elseif code == 2 then
		st.dim = true
	elseif code == 3 then
		st.italic = true
	elseif code == 4 then
		st.underline = true
	elseif code == 7 then
		st.reverse = true
	elseif code == 22 then
		st.bold, st.dim = nil, nil
	elseif code == 23 then
		st.italic = nil
	elseif code == 24 then
		st.underline = nil
	elseif code == 27 then
		st.reverse = nil
	elseif code >= 30 and code <= 37 then
		st.fg = code - 30
	elseif code == 39 then
		st.fg = nil
	elseif code >= 90 and code <= 97 then
		st.fg = code - 90 + 8
	end
	-- Backgrounds and the 38/48 extended forms are not produced by
	-- lupus/tui/text.lua; anything unrecognized is ignored.
end

--- Parse a styled line into runs. Non-SGR escape sequences are dropped.
function sgr.parse_line(line)
	local runs = {}
	local st = {}
	local parts = {}
	local width = 0

	local function flush()
		if #parts == 0 then
			return
		end
		runs[#runs + 1] = { text = table.concat(parts), width = width, style = copy_style(st) }
		parts = {}
		width = 0
	end

	for _, cell in ipairs(text.cells(line)) do
		if cell.ansi then
			local params = cell.s:match("^\27%[([%d;]*)m$")
			if params then
				flush()
				if params == "" then
					apply_code(st, 0)
				else
					for chunk in params:gmatch("[^;]+") do
						apply_code(st, tonumber(chunk) or -1)
					end
				end
			end
		else
			parts[#parts + 1] = cell.s
			width = width + cell.w
		end
	end
	flush()
	return runs
end

return sgr
