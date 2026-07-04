-- ANSI-aware text measurement and shaping. Every rendered line in the TUI
-- flows through these three: visible_width, wrap, truncate.
--
-- Width model ("wcwidth-lite"): ASCII printable = 1, East-Asian wide and
-- emoji = 2, combining marks / zero-width joiners = 0. Complex ZWJ emoji
-- clusters may be over-counted; the renderer rewrites whole lines, so a
-- mis-measured glyph causes transient misalignment, never corruption.

local utf8 = require("lupus.util.utf8")

local text = {}

local ESC = "\27"
text.RESET = ESC .. "[0m"

-- ---------------------------------------------------------------------------
-- Codepoint width

-- Sorted {first, last} ranges of zero-width codepoints (combining marks etc.)
local zero_ranges = {
  { 0x0300, 0x036F }, { 0x0483, 0x0489 }, { 0x0591, 0x05BD }, { 0x05BF, 0x05BF },
  { 0x05C1, 0x05C2 }, { 0x05C4, 0x05C5 }, { 0x05C7, 0x05C7 }, { 0x0610, 0x061A },
  { 0x064B, 0x065F }, { 0x0670, 0x0670 }, { 0x06D6, 0x06DC }, { 0x06DF, 0x06E4 },
  { 0x0711, 0x0711 }, { 0x0730, 0x074A }, { 0x07A6, 0x07B0 }, { 0x0816, 0x0819 },
  { 0x0900, 0x0902 }, { 0x093C, 0x093C }, { 0x0941, 0x0948 }, { 0x094D, 0x094D },
  { 0x0951, 0x0957 }, { 0x09BC, 0x09BC }, { 0x09C1, 0x09C4 }, { 0x09CD, 0x09CD },
  { 0x0B3C, 0x0B3C }, { 0x0E31, 0x0E31 }, { 0x0E34, 0x0E3A }, { 0x0E47, 0x0E4E },
  { 0x200B, 0x200F }, { 0x202A, 0x202E }, { 0x2060, 0x2064 }, { 0xFE00, 0xFE0F },
  { 0xFEFF, 0xFEFF }, { 0x1AB0, 0x1AFF }, { 0x1DC0, 0x1DFF }, { 0x20D0, 0x20FF },
  { 0xE0100, 0xE01EF },
}

-- Sorted {first, last} ranges of double-width codepoints.
local wide_ranges = {
  { 0x1100, 0x115F }, { 0x2329, 0x232A }, { 0x2E80, 0x303E }, { 0x3041, 0x33FF },
  { 0x3400, 0x4DBF }, { 0x4E00, 0x9FFF }, { 0xA000, 0xA4CF }, { 0xA960, 0xA97F },
  { 0xAC00, 0xD7A3 }, { 0xF900, 0xFAFF }, { 0xFE10, 0xFE19 }, { 0xFE30, 0xFE52 },
  { 0xFE54, 0xFE66 }, { 0xFE68, 0xFE6B }, { 0xFF00, 0xFF60 }, { 0xFFE0, 0xFFE6 },
  { 0x1F004, 0x1F004 }, { 0x1F0CF, 0x1F0CF }, { 0x1F18E, 0x1F18E }, { 0x1F191, 0x1F19A },
  { 0x1F200, 0x1F2FF }, { 0x1F300, 0x1F64F }, { 0x1F680, 0x1F6FF }, { 0x1F900, 0x1F9FF },
  { 0x1FA00, 0x1FAFF }, { 0x20000, 0x2FFFD }, { 0x30000, 0x3FFFD },
}

local function in_ranges(ranges, cp)
  local lo, hi = 1, #ranges
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r = ranges[mid]
    if cp < r[1] then
      hi = mid - 1
    elseif cp > r[2] then
      lo = mid + 1
    else
      return true
    end
  end
  return false
end

--- Display width of a single codepoint.
function text.cp_width(cp)
  if cp < 0x20 or (cp >= 0x7F and cp < 0xA0) then return 0 end
  if cp < 0x300 then return 1 end
  if in_ranges(zero_ranges, cp) then return 0 end
  if in_ranges(wide_ranges, cp) then return 2 end
  return 1
end

-- ---------------------------------------------------------------------------
-- Cell parsing: split a string into ANSI sequences (width 0) and character
-- cells. Everything else builds on this.

local function ansi_end(s, i)
  -- s:byte(i) == 27. Returns the index of the last byte of the sequence.
  local nxt = s:byte(i + 1)
  if nxt == 0x5B then -- CSI: ESC [ params final(0x40-0x7E)
    local j = i + 2
    while j <= #s do
      local b = s:byte(j)
      if b >= 0x40 and b <= 0x7E then return j end
      j = j + 1
    end
    return #s
  elseif nxt == 0x5D then -- OSC: ESC ] ... BEL | ESC \
    local j = i + 2
    while j <= #s do
      local b = s:byte(j)
      if b == 0x07 then return j end
      if b == 0x1B and s:byte(j + 1) == 0x5C then return j + 1 end
      j = j + 1
    end
    return #s
  elseif nxt then
    return i + 1 -- two-byte escape (ESC c, ESC 7, ...)
  end
  return i
end

--- Parse into cells: { s = bytes, w = width, ansi = bool }. Invalid UTF-8
--- bytes become width-1 cells so nothing ever crashes the renderer.
function text.cells(s)
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local b = s:byte(i)
    if b == 0x1B then
      local last = ansi_end(s, i)
      out[#out + 1] = { s = s:sub(i, last), w = 0, ansi = true }
      i = last + 1
    elseif b < 0x80 then
      out[#out + 1] = { s = s:sub(i, i), w = (b >= 0x20 and b ~= 0x7F) and 1 or 0 }
      i = i + 1
    else
      local ok, cp = pcall(utf8.codepoint, s, i)
      if ok and cp then
        local last = utf8.offset(s, 2, i)
        last = (last and last - 1) or n
        out[#out + 1] = { s = s:sub(i, last), w = text.cp_width(cp) }
        i = last + 1
      else
        out[#out + 1] = { s = s:sub(i, i), w = 1 }
        i = i + 1
      end
    end
  end
  return out
end

--- Visible column width of a string (ANSI sequences count as zero).
function text.visible_width(s)
  -- Fast path: pure printable ASCII.
  if not s:find("[^\32-\126]") then return #s end
  local w = 0
  for _, cell in ipairs(text.cells(s)) do
    w = w + cell.w
  end
  return w
end

--- Strip all ANSI escape sequences.
function text.strip_ansi(s)
  if not s:find(ESC, 1, true) then return s end
  local out = {}
  for _, cell in ipairs(text.cells(s)) do
    if not cell.ansi then out[#out + 1] = cell.s end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- SGR state tracking, so styles survive line wraps and truncation.

local function apply_sgr(active, params)
  -- params: the body of ESC[<...>m
  if params == "" or params == "0" then
    return {}
  end
  -- Track whole sequences; a reset clears. Splitting compound sequences
  -- like "1;31" is unnecessary for re-emission purposes.
  for chunk in params:gmatch("[^;]+") do
    if chunk == "0" then active = {} end
  end
  active[#active + 1] = ESC .. "[" .. params .. "m"
  return active
end

local function sgr_params(cell)
  return cell.ansi and cell.s:match("^\27%[([%d;]*)m$") or nil
end

-- ---------------------------------------------------------------------------

--- Word-wrap to `width` columns, preserving ANSI styling across breaks.
--- Returns an array of lines; "" input gives { "" }.
function text.wrap(s, width)
  if width <= 0 then return { s } end
  local out = {}
  for _, logical in ipairs(text.split_lines(s)) do
    local cells = text.cells(logical)
    local active = {}       -- SGR sequences in force
    local line = {}         -- cells of the current output line
    local col = 0
    local break_at = nil    -- index in `line` after which we may break
    local emitted = 0       -- lines produced for this logical line

    local function flush(next_active)
      emitted = emitted + 1
      local parts = {}
      for _, c in ipairs(line) do parts[#parts + 1] = c.s end
      out[#out + 1] = table.concat(parts)
      line = {}
      col = 0
      break_at = nil
      -- Re-open styles that are still active on the continuation line.
      for _, code in ipairs(next_active) do
        line[#line + 1] = { s = code, w = 0, ansi = true }
      end
    end

    for _, cell in ipairs(cells) do
      local params = sgr_params(cell)
      if params then
        active = apply_sgr(active, params)
        line[#line + 1] = cell
      elseif cell.ansi then
        line[#line + 1] = cell
      else
        if col + cell.w > width then
          if break_at and break_at < #line then
            -- Break at the last space: move the tail to the next line.
            local tail = {}
            for i = break_at + 1, #line do tail[#tail + 1] = line[i] end
            for i = #line, break_at + 1, -1 do line[i] = nil end
            -- Drop the trailing space we broke on.
            if #line > 0 and line[#line].s == " " then line[#line] = nil end
            local tail_col = 0
            for _, c in ipairs(tail) do tail_col = tail_col + c.w end
            flush(active)
            for _, c in ipairs(tail) do line[#line + 1] = c end
            col = tail_col
          else
            if #line > 0 and line[#line].s == " " then line[#line] = nil end
            flush(active)
          end
        end
        line[#line + 1] = cell
        col = col + cell.w
        if cell.s == " " then
          break_at = #line
        end
      end
    end
    -- Skip a final line holding only re-opened style codes.
    if col > 0 or emitted == 0 then flush(active) end
  end
  if #out == 0 then out = { "" } end
  return out
end

--- Truncate to at most `max` columns, appending `ellipsis` (default "…")
--- when something was cut. ANSI codes are preserved and styles closed.
function text.truncate(s, max, ellipsis)
  ellipsis = ellipsis or "…"
  if text.visible_width(s) <= max then return s end
  local ell_w = text.visible_width(ellipsis)
  local budget = max - ell_w
  if budget < 0 then budget = 0 end
  local out = {}
  local col = 0
  local styled = false
  for _, cell in ipairs(text.cells(s)) do
    if cell.ansi then
      out[#out + 1] = cell.s
      if sgr_params(cell) then styled = true end
    else
      if col + cell.w > budget then break end
      out[#out + 1] = cell.s
      col = col + cell.w
    end
  end
  out[#out + 1] = ellipsis
  if styled then out[#out + 1] = text.RESET end
  return table.concat(out)
end

--- Pad with trailing spaces to exactly `width` visible columns (longer
--- strings are returned unchanged).
function text.pad(s, width)
  local w = text.visible_width(s)
  if w >= width then return s end
  return s .. (" "):rep(width - w)
end

--- Split on \n (and tolerate \r\n). Always returns at least { "" }.
function text.split_lines(s)
  local lines = {}
  local pos = 1
  while true do
    local nl = s:find("\n", pos, true)
    if not nl then
      lines[#lines + 1] = s:sub(pos)
      break
    end
    local line = s:sub(pos, nl - 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    lines[#lines + 1] = line
    pos = nl + 1
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Style helpers used across components.

local function styler(open)
  local prefix = ESC .. "[" .. open .. "m"
  return function(s)
    return prefix .. s .. text.RESET
  end
end

text.style = {
  bold = styler("1"),
  dim = styler("2"),
  italic = styler("3"),
  underline = styler("4"),
  reverse = styler("7"),
  red = styler("31"),
  green = styler("32"),
  yellow = styler("33"),
  blue = styler("34"),
  magenta = styler("35"),
  cyan = styler("36"),
  gray = styler("90"),
}

return text
