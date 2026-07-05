-- Multi-line input editor with soft wrapping, UTF-8 aware cursor movement,
-- prompt history, and a reverse-video fake cursor.
--
-- State is three values: lines (array of strings, no newlines), cursor.line,
-- and cursor.col (byte offset within the line: 0 = before the first byte).
-- Everything else is derived at render time.
--
-- Keys: enter submits, alt+enter / ctrl+j insert a newline, arrows/home/end
-- navigate (up/down move across *visual* rows), ctrl+a/e line start/end,
-- ctrl+w delete word back, ctrl+u/k kill to line start/end, up/down at the
-- first/last row browse history.

local text = require("lupus.tui.text")

local Editor = {}
Editor.__index = Editor

--- opts: on_submit = fn(text), on_change = fn(), placeholder = string,
---       max_visible = rows before scrolling (default 6), history_limit.
function Editor.new(opts)
	opts = opts or {}
	return setmetatable({
		lines = { "" },
		cursor = { line = 1, col = 0 },
		on_submit = opts.on_submit,
		on_change = opts.on_change,
		placeholder = opts.placeholder or "",
		max_visible = opts.max_visible or 6,
		history = {},
		history_limit = opts.history_limit or 100,
		history_pos = nil, -- nil = editing a fresh draft
		draft = nil,
		focused = false,
		scroll = 0, -- visual rows scrolled off above
	}, Editor)
end

-- ---------------------------------------------------------------------------
-- Content accessors

function Editor:get_text()
	return table.concat(self.lines, "\n")
end

function Editor:set_text(s)
	self.lines = text.split_lines(s)
	self.cursor.line = #self.lines
	self.cursor.col = #self.lines[#self.lines]
	self:changed()
end

function Editor:clear()
	self.lines = { "" }
	self.cursor.line = 1
	self.cursor.col = 0
	self.history_pos = nil
	self.draft = nil
	self.scroll = 0
	self:changed()
end

function Editor:is_empty()
	return #self.lines == 1 and self.lines[1] == ""
end

function Editor:changed()
	if self.on_change then
		self.on_change()
	end
end

function Editor:add_history(entry)
	if entry == "" then
		return
	end
	if self.history[#self.history] == entry then
		return
	end
	self.history[#self.history + 1] = entry
	if #self.history > self.history_limit then
		table.remove(self.history, 1)
	end
end

-- ---------------------------------------------------------------------------
-- UTF-8 helpers: cursor cols are byte offsets, movement is by codepoint.

local function prev_offset(line, col)
	-- Byte offset of the start of the codepoint before position col.
	if col <= 0 then
		return nil
	end
	local i = col
	while i > 1 do
		local b = line:byte(i)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		i = i - 1
	end
	return i - 1
end

local function next_offset(line, col)
	if col >= #line then
		return nil
	end
	local i = col + 1
	local b = line:byte(i)
	local len = 1
	if b >= 0xF0 then
		len = 4
	elseif b >= 0xE0 then
		len = 3
	elseif b >= 0xC0 then
		len = 2
	end
	return math.min(col + len, #line)
end

-- ---------------------------------------------------------------------------
-- Editing operations

function Editor:insert(s)
	-- Normalize: CRLF -> LF, tabs -> two spaces, strip other control chars.
	s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "  ")
	s = s:gsub("[\1-\8\11\12\14-\31\127]", "")
	local parts = text.split_lines(s)
	local line = self.lines[self.cursor.line]
	local before = line:sub(1, self.cursor.col)
	local after = line:sub(self.cursor.col + 1)
	if #parts == 1 then
		self.lines[self.cursor.line] = before .. parts[1] .. after
		self.cursor.col = #before + #parts[1]
	else
		self.lines[self.cursor.line] = before .. parts[1]
		for i = 2, #parts do
			table.insert(self.lines, self.cursor.line + i - 1, parts[i])
		end
		local last_idx = self.cursor.line + #parts - 1
		self.cursor.col = #self.lines[last_idx]
		self.lines[last_idx] = self.lines[last_idx] .. after
		self.cursor.line = last_idx
	end
	self:changed()
end

function Editor:backspace()
	local cur = self.cursor
	local line = self.lines[cur.line]
	if cur.col > 0 then
		local prev = prev_offset(line, cur.col)
		self.lines[cur.line] = line:sub(1, prev) .. line:sub(cur.col + 1)
		cur.col = prev
	elseif cur.line > 1 then
		local above = self.lines[cur.line - 1]
		cur.col = #above
		self.lines[cur.line - 1] = above .. line
		table.remove(self.lines, cur.line)
		cur.line = cur.line - 1
	end
	self:changed()
end

function Editor:delete_forward()
	local cur = self.cursor
	local line = self.lines[cur.line]
	if cur.col < #line then
		local nxt = next_offset(line, cur.col)
		self.lines[cur.line] = line:sub(1, cur.col) .. line:sub(nxt + 1)
	elseif cur.line < #self.lines then
		self.lines[cur.line] = line .. self.lines[cur.line + 1]
		table.remove(self.lines, cur.line + 1)
	end
	self:changed()
end

function Editor:delete_word_back()
	local cur = self.cursor
	local line = self.lines[cur.line]
	if cur.col == 0 then
		self:backspace()
		return
	end
	local head = line:sub(1, cur.col)
	-- Trailing spaces, then the word before them.
	local target = head:gsub("[^%s]*%s*$", "")
	self.lines[cur.line] = target .. line:sub(cur.col + 1)
	cur.col = #target
	self:changed()
end

function Editor:kill_to_start()
	local cur = self.cursor
	self.lines[cur.line] = self.lines[cur.line]:sub(cur.col + 1)
	cur.col = 0
	self:changed()
end

function Editor:kill_to_end()
	local cur = self.cursor
	self.lines[cur.line] = self.lines[cur.line]:sub(1, cur.col)
	self:changed()
end

-- ---------------------------------------------------------------------------
-- Visual layout: wrap logical lines into rows of at most `width` columns,
-- remembering the byte range each row covers. Cursor math rides on this.

local function wrap_line(line, width)
	local rows = {}
	local cells = text.cells(line)
	local start_byte = 0 -- bytes before the row's first char
	local byte = 0
	local col = 0
	local row_cells = {}
	local break_cell = nil -- index in row_cells after which we can break

	local function flush(next_start)
		local parts = {}
		for _, c in ipairs(row_cells) do
			parts[#parts + 1] = c.s
		end
		rows[#rows + 1] = { s = table.concat(parts), start_byte = start_byte, end_byte = next_start }
		start_byte = next_start
		row_cells = {}
		col = 0
		break_cell = nil
	end

	for _, cell in ipairs(cells) do
		if col + cell.w > width and #row_cells > 0 then
			if break_cell and break_cell < #row_cells then
				-- Word wrap: keep tail for the next row.
				local tail = {}
				for i = break_cell + 1, #row_cells do
					tail[#tail + 1] = row_cells[i]
				end
				for i = #row_cells, break_cell + 1, -1 do
					row_cells[i] = nil
				end
				local tail_bytes = 0
				for _, c in ipairs(tail) do
					tail_bytes = tail_bytes + #c.s
				end
				flush(byte - tail_bytes)
				for _, c in ipairs(tail) do
					row_cells[#row_cells + 1] = c
					col = col + c.w
				end
			else
				flush(byte)
			end
		end
		row_cells[#row_cells + 1] = cell
		byte = byte + #cell.s
		col = col + cell.w
		if cell.s == " " then
			break_cell = #row_cells
		end
	end
	flush(byte)
	return rows
end

--- Build all visual rows: { s, line, start_byte, end_byte }.
function Editor:layout(width)
	local rows = {}
	for idx, line in ipairs(self.lines) do
		for _, row in ipairs(wrap_line(line, width)) do
			row.line = idx
			rows[#rows + 1] = row
		end
	end
	return rows
end

--- Index (into rows) of the row containing the cursor.
local function cursor_row(rows, cur)
	for i, row in ipairs(rows) do
		if row.line == cur.line and cur.col >= row.start_byte and cur.col < row.end_byte then
			return i
		end
	end
	-- Cursor at the very end of a logical line: last row of that line.
	for i = #rows, 1, -1 do
		if rows[i].line == cur.line then
			return i
		end
	end
	return #rows
end

local function col_in_row(row, cur_col)
	local s = row.s:sub(1, cur_col - row.start_byte)
	return text.visible_width(s)
end

--- Move cursor to `target_vcol` columns into rows[idx].
local function place_in_row(self, row, target_vcol)
	local col = 0
	local byte = row.start_byte
	for _, cell in ipairs(text.cells(row.s)) do
		if col + cell.w > target_vcol then
			break
		end
		col = col + cell.w
		byte = byte + #cell.s
	end
	self.cursor.line = row.line
	self.cursor.col = byte
end

function Editor:move_vertical(delta, width)
	local rows = self:layout(width)
	local idx = cursor_row(rows, self.cursor)
	local target = idx + delta
	if target < 1 or target > #rows then
		return false
	end
	local vcol = col_in_row(rows[idx], self.cursor.col)
	place_in_row(self, rows[target], vcol)
	return true
end

-- ---------------------------------------------------------------------------
-- History

function Editor:history_prev()
	if #self.history == 0 then
		return
	end
	if self.history_pos == nil then
		self.draft = self:get_text()
		self.history_pos = #self.history
	elseif self.history_pos > 1 then
		self.history_pos = self.history_pos - 1
	else
		return
	end
	self:set_text(self.history[self.history_pos])
end

function Editor:history_next()
	if self.history_pos == nil then
		return
	end
	if self.history_pos < #self.history then
		self.history_pos = self.history_pos + 1
		local entry = self.history[self.history_pos]
		self:set_text(entry)
	else
		self.history_pos = nil
		self:set_text(self.draft or "")
		self.draft = nil
	end
end

-- ---------------------------------------------------------------------------
-- Input

function Editor:submit()
	local content = self:get_text():gsub("^%s+", ""):gsub("%s+$", "")
	if content == "" then
		return
	end
	self:add_history(content)
	self:clear()
	if self.on_submit then
		self.on_submit(content)
	end
end

--- Returns true when the event was consumed; unknown keys fall through to
--- the TUI's viewport defaults.
function Editor:handle_input(ev, width)
	width = width or self.last_width or 78
	if ev.type == "paste" then
		self:insert(ev.text)
		return true
	end
	if ev.type ~= "key" then
		return false
	end
	local name = ev.name
	local cur = self.cursor

	if ev.char then
		self:insert(ev.char)
	elseif name == "enter" then
		self:submit()
	elseif name == "alt+enter" or name == "ctrl+j" then
		self:insert("\n")
	elseif name == "backspace" or name == "ctrl+h" then
		self:backspace()
	elseif name == "delete" or name == "ctrl+d" then
		self:delete_forward()
	elseif name == "left" or name == "ctrl+b" then
		local prev = prev_offset(self.lines[cur.line], cur.col)
		if prev then
			cur.col = prev
		elseif cur.line > 1 then
			cur.line = cur.line - 1
			cur.col = #self.lines[cur.line]
		end
	elseif name == "right" or name == "ctrl+f" then
		local nxt = next_offset(self.lines[cur.line], cur.col)
		if nxt then
			cur.col = nxt
		elseif cur.line < #self.lines then
			cur.line = cur.line + 1
			cur.col = 0
		end
	elseif name == "up" then
		if not self:move_vertical(-1, width) then
			self:history_prev()
		end
	elseif name == "down" then
		if not self:move_vertical(1, width) then
			self:history_next()
		end
	elseif name == "home" or name == "ctrl+a" then
		cur.col = 0
	elseif name == "end" or name == "ctrl+e" then
		cur.col = #self.lines[cur.line]
	elseif name == "ctrl+w" or name == "alt+backspace" then
		self:delete_word_back()
	elseif name == "ctrl+u" then
		self:kill_to_start()
	elseif name == "ctrl+k" then
		self:kill_to_end()
	else
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Rendering

local CURSOR_OPEN = "\27[7m"

local function render_cursor_cell(row_text, byte_in_row)
	-- Reverse-video the char at byte_in_row (or a space at end of row).
	local head = row_text:sub(1, byte_in_row)
	local rest = row_text:sub(byte_in_row + 1)
	if rest == "" then
		return head .. CURSOR_OPEN .. " " .. text.RESET
	end
	local cells = text.cells(rest)
	local first = cells[1] and cells[1].s or " "
	return head .. CURSOR_OPEN .. first .. text.RESET .. rest:sub(#first + 1)
end

function Editor:render(width)
	self.last_width = width
	local content_width = width - 2 -- "> " prefix on the first row
	if content_width < 4 then
		content_width = 4
	end

	local border = text.style.dim(("─"):rep(width))
	local lines = { border }

	if self:is_empty() and not self.focused then
		lines[#lines + 1] = "> " .. text.style.dim(self.placeholder)
		lines[#lines + 1] = border
		return lines
	end

	local rows = self:layout(content_width)
	local cur_idx = cursor_row(rows, self.cursor)

	-- Placeholder with cursor when empty and focused.
	if self:is_empty() then
		lines[#lines + 1] = "> " .. CURSOR_OPEN .. " " .. text.RESET .. text.style.dim(self.placeholder)
		lines[#lines + 1] = border
		return lines
	end

	-- Scroll window over visual rows, keeping the cursor visible.
	local visible = self.max_visible
	if cur_idx <= self.scroll then
		self.scroll = cur_idx - 1
	elseif cur_idx > self.scroll + visible then
		self.scroll = cur_idx - visible
	end
	if self.scroll > math.max(0, #rows - visible) then
		self.scroll = math.max(0, #rows - visible)
	end

	local top = self.scroll + 1
	local bottom = math.min(#rows, self.scroll + visible)
	for i = top, bottom do
		local row = rows[i]
		local body = row.s
		if i == cur_idx and self.focused then
			body = render_cursor_cell(body, self.cursor.col - row.start_byte)
		end
		local prefix = (i == 1) and "> " or "  "
		lines[#lines + 1] = prefix .. body
	end

	local bottom_border = border
	if #rows > visible then
		local info = (" %d-%d/%d "):format(top, bottom, #rows)
		bottom_border = text.style.dim("─── " .. info .. ("─"):rep(math.max(0, width - 5 - #info)))
	end
	lines[#lines + 1] = bottom_border
	return lines
end

return Editor
