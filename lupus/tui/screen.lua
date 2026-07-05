-- The real-terminal surface: ncurses lifecycle plus the drawing interface
-- the renderer targets. Swapping this file (or passing another surface to
-- TUI.new) changes how frames reach the screen without touching components,
-- the renderer, or input.
--
-- Surface contract (what lupus/tui/init.lua calls):
--   surface:size() -> cols, rows
--   surface:begin_frame()               erase the back buffer
--   surface:put(row, col, str, style)   draw plain text with an sgr-style table
--   surface:end_frame()                 present the frame
--   surface:invalidate()                force the next present to repaint fully
-- and, for real terminals only (the renderer checks before calling):
--   surface:start() / surface:stop() / surface:resize() / surface:write_raw(s)
--
-- ncurses owns terminal modes (raw, noecho), the alternate screen, and
-- frame diffing; input bytes are read elsewhere (lupus/tui/input.lua via a
-- uv tty reader) — none of the ncurses input machinery is used.

local nc = require("lupus.tui.ncurses")
local bit = require("bit")
local uv = require("luv")

local C = nc.C
local bor = bit.bor

local Screen = {}
Screen.__index = Screen

local screen_mod = { Screen = Screen }

function screen_mod.new()
	return setmetatable({
		win = nil, -- stdscr once started
		started = false,
		pairs_by_fg = {}, -- fg color index -> pair number
		next_pair = 1,
		has_color = false,
	}, Screen)
end

-- ---------------------------------------------------------------------------
-- Lifecycle

function Screen:start()
	if self.started then
		return
	end
	nc.init_locale()
	self.win = C.initscr()
	assert(self.win ~= nil, "initscr failed")
	C.raw() -- byte-at-a-time input, no signal keys, no flow control
	C.noecho()
	C.curs_set(0)
	C.leaveok(self.win, true)
	C.scrollok(self.win, false)
	if C.has_colors() then
		C.start_color()
		-- Colored text on the terminal's default background.
		self.has_color = C.use_default_colors() == 0
	end
	self.started = true
end

function Screen:stop()
	if not self.started then
		return
	end
	self.started = false
	C.endwin()
end

--- Restore the terminal after a crash; safe to call in any state.
function screen_mod.restore()
	if not C.isendwin() then
		C.endwin()
	end
end

--- Escape sequences ncurses doesn't manage (bracketed paste). Bypasses the
--- virtual screen and goes straight to the terminal.
function Screen:write_raw(s)
	io.stdout:write(s)
	io.stdout:flush()
end

--- Called on SIGWINCH: learn the new size and let ncurses reallocate.
function Screen:resize()
	if not self.tty_out then
		self.tty_out = uv.new_tty(1, false)
	end
	local w, h = self.tty_out:get_winsize()
	if w and w > 0 and h > 0 then
		C.resizeterm(h, w)
	end
end

function Screen:size()
	if not self.win then
		return 80, 24
	end
	return C.getmaxx(self.win), C.getmaxy(self.win)
end

-- ---------------------------------------------------------------------------
-- Drawing

--- ncurses attribute for an sgr style table, allocating color pairs (fg on
--- default background) on first use.
function Screen:attr_for(style)
	local a = 0
	if style.bold then
		a = bor(a, nc.A.BOLD)
	end
	if style.dim then
		a = bor(a, nc.A.DIM)
	end
	if style.italic then
		a = bor(a, nc.A.ITALIC)
	end
	if style.underline then
		a = bor(a, nc.A.UNDERLINE)
	end
	if style.reverse then
		a = bor(a, nc.A.REVERSE)
	end
	local fg = style.fg
	if fg and self.has_color then
		if fg >= 8 then
			-- Bright variants: real color 8..15 where the terminal has 16 colors,
			-- bold + base color otherwise.
			a = bor(a, nc.A.BOLD)
			fg = fg - 8
		end
		local pair = self.pairs_by_fg[fg]
		if not pair then
			pair = self.next_pair
			self.next_pair = pair + 1
			C.init_pair(pair, fg, -1)
			self.pairs_by_fg[fg] = pair
		end
		a = bor(a, nc.color_pair(pair))
	end
	return a
end

function Screen:begin_frame()
	C.werase(self.win)
end

--- row/col are 1-based; str is plain UTF-8 (no escape sequences).
function Screen:put(row, col, str, style)
	C.wattrset(self.win, style and self:attr_for(style) or 0)
	C.wmove(self.win, row - 1, col - 1)
	C.waddnstr(self.win, str, #str)
end

function Screen:end_frame()
	C.wattrset(self.win, 0)
	C.wnoutrefresh(self.win)
	C.doupdate()
end

function Screen:invalidate()
	if self.win then
		C.clearok(self.win, true)
	end
end

return screen_mod
