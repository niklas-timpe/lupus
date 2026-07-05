-- A fake drawing surface for renderer tests: implements the surface
-- contract from lupus/tui/screen.lua by recording puts into a plain grid of
-- strings. ASCII-oriented (byte position == column), which is all the
-- renderer tests need.

local M = {}

local Surface = {}
Surface.__index = Surface

function M.new(cols, rows)
	return setmetatable({
		cols = cols,
		rows = rows,
		grid = {},
		puts = {}, -- log of { y, x, text, style } for style assertions
		frames = 0,
		invalidated = 0,
	}, Surface)
end

function Surface:size()
	return self.cols, self.rows
end

function Surface:begin_frame()
	self.grid = {}
	self.puts = {}
end

function Surface:put(y, x, str, style)
	self.puts[#self.puts + 1] = { y = y, x = x, text = str, style = style }
	local row = self.grid[y] or ""
	if #row < x - 1 then
		row = row .. (" "):rep(x - 1 - #row)
	end
	self.grid[y] = row .. str
end

function Surface:end_frame()
	self.frames = self.frames + 1
end

function Surface:invalidate()
	self.invalidated = self.invalidated + 1
end

--- Row y as a string ("" when empty).
function Surface:row(y)
	return self.grid[y] or ""
end

--- Non-empty rows in order (for content assertions).
function Surface:visible()
	local out = {}
	for y = 1, self.rows do
		local row = self.grid[y]
		if row and row ~= "" then
			out[#out + 1] = row
		end
	end
	return out
end

return M
