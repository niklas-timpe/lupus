-- Keyboard input: reassembles escape sequences that arrive split across
-- reads and turns raw bytes into named key events.
--
-- Events:
--   { type = "key", name = "ctrl+c" | "up" | "enter" | "a" | ..., char = "a"|nil }
--   { type = "paste", text = "..." }              (bracketed paste)
--
-- Key names are canonical: modifiers in ctrl+alt+shift order, then the key.
-- `char` is set only for plain printable input (what an editor inserts).
--
-- input.parse is a pure function (easy to test); input.run_reader drives it
-- from a file descriptor inside the event loop, applying a short timeout to
-- disambiguate a lone ESC from the start of a sequence.

local loop = require("lupus.loop")
local band = require("bit").band

local input = {}

local ESC = 27

local PASTE_START = "\27[200~"
local PASTE_END = "\27[201~"

local ctrl_names = {
  [0] = "ctrl+space", [8] = "ctrl+h", [9] = "tab", [10] = "ctrl+j",
  [13] = "enter", [28] = "ctrl+\\", [29] = "ctrl+]", [30] = "ctrl+^",
  [31] = "ctrl+_", [127] = "backspace",
}

local csi_letter_keys = {
  A = "up", B = "down", C = "right", D = "left",
  H = "home", F = "end", Z = "shift+tab",
  P = "f1", Q = "f2", R = "f3", S = "f4",
}

local csi_tilde_keys = {
  [1] = "home", [2] = "insert", [3] = "delete", [4] = "end",
  [5] = "pageup", [6] = "pagedown", [7] = "home", [8] = "end",
  [11] = "f1", [12] = "f2", [13] = "f3", [14] = "f4", [15] = "f5",
  [17] = "f6", [18] = "f7", [19] = "f8", [20] = "f9", [21] = "f10",
  [23] = "f11", [24] = "f12",
}

local function with_modifiers(mod, key)
  -- xterm modifier parameter: value - 1 is a bitmask.
  if not mod or mod <= 1 then return key end
  local bits = mod - 1
  local parts = {}
  if band(bits, 4) ~= 0 then parts[#parts + 1] = "ctrl" end
  if band(bits, 2) ~= 0 then parts[#parts + 1] = "alt" end
  if band(bits, 1) ~= 0 then parts[#parts + 1] = "shift" end
  parts[#parts + 1] = key
  return table.concat(parts, "+")
end

local function key_event(name, char)
  return { type = "key", name = name, char = char }
end

--- Parse one CSI sequence body (bytes between "ESC[" and including the
--- final byte). Returns an event or nil for sequences we ignore.
local function parse_csi(body)
  local final = body:sub(-1)
  local params = body:sub(1, -2)
  if final == "~" then
    local num, mod = params:match("^(%d+);(%d+)$")
    if not num then num = params:match("^(%d*)$") end
    local key = csi_tilde_keys[tonumber(num) or -1]
    if key then return key_event(with_modifiers(tonumber(mod), key)) end
    return nil
  end
  local key = csi_letter_keys[final]
  if not key then return nil end
  if final == "Z" then return key_event(key) end
  local _, mod = params:match("^(%d*);(%d+)$")
  return key_event(with_modifiers(tonumber(mod), key))
end

local function utf8_len_from_lead(b)
  if b < 0x80 then return 1
  elseif b >= 0xF0 then return 4
  elseif b >= 0xE0 then return 3
  elseif b >= 0xC0 then return 2
  end
  return 1 -- stray continuation byte: consume alone
end

--- Consume events from `buf`. Returns events, rest, pending where rest is
--- an incomplete tail ("" when fully consumed) and pending is "paste" |
--- "seq" | nil describing why parsing stopped.
function input.parse(buf)
  local events = {}
  local i = 1
  local n = #buf
  while i <= n do
    local b = buf:byte(i)
    if b == ESC then
      -- Bracketed paste?
      if buf:sub(i, i + #PASTE_START - 1) == PASTE_START then
        local stop = buf:find(PASTE_END, i + #PASTE_START, true)
        if not stop then
          return events, buf:sub(i), "paste"
        end
        local body = buf:sub(i + #PASTE_START, stop - 1)
        events[#events + 1] = { type = "paste", text = body }
        i = stop + #PASTE_END
      elseif PASTE_START:sub(1, n - i + 1) == buf:sub(i) then
        -- Buffer ends with a strict prefix of the paste-start marker.
        return events, buf:sub(i), "seq"
      elseif i == n then
        return events, buf:sub(i), "seq" -- lone ESC: wait / flush decides
      else
        local nxt = buf:byte(i + 1)
        if nxt == 0x5B then -- CSI
          local j = i + 2
          local fin = nil
          while j <= n do
            local c = buf:byte(j)
            if c >= 0x40 and c <= 0x7E then fin = j break end
            j = j + 1
          end
          if not fin then
            return events, buf:sub(i), "seq"
          end
          local ev = parse_csi(buf:sub(i + 2, fin))
          if ev then events[#events + 1] = ev end
          i = fin + 1
        elseif nxt == 0x5D then -- OSC (terminal response): swallow
          local j = i + 2
          local stop = nil
          while j <= n do
            local c = buf:byte(j)
            if c == 0x07 then stop = j break end
            if c == ESC and buf:byte(j + 1) == 0x5C then stop = j + 1 break end
            j = j + 1
          end
          if not stop then
            return events, buf:sub(i), "seq"
          end
          i = stop + 1
        elseif nxt == 0x4F then -- SS3
          if i + 2 > n then
            return events, buf:sub(i), "seq"
          end
          local key = csi_letter_keys[buf:sub(i + 2, i + 2)]
          if key then events[#events + 1] = key_event(key) end
          i = i + 3
        elseif nxt == ESC then
          events[#events + 1] = key_event("escape")
          i = i + 1
        else
          -- Alt + something
          if nxt == 13 then
            events[#events + 1] = key_event("alt+enter")
            i = i + 2
          elseif nxt == 127 then
            events[#events + 1] = key_event("alt+backspace")
            i = i + 2
          elseif nxt >= 0x20 and nxt ~= 0x7F then
            local len = utf8_len_from_lead(nxt)
            if i + 1 + len - 1 > n then
              return events, buf:sub(i), "seq"
            end
            events[#events + 1] = key_event("alt+" .. buf:sub(i + 1, i + len))
            i = i + 1 + len
          else
            -- ESC + control byte: emit escape, reprocess the control byte.
            events[#events + 1] = key_event("escape")
            i = i + 1
          end
        end
      end
    elseif b < 0x20 or b == 0x7F then
      local name = ctrl_names[b]
      if not name and b >= 1 and b <= 26 then
        name = "ctrl+" .. string.char(b + 96)
      end
      if name then events[#events + 1] = key_event(name) end
      i = i + 1
    else
      local len = utf8_len_from_lead(b)
      if i + len - 1 > n then
        return events, buf:sub(i), "seq" -- split UTF-8 char
      end
      local ch = buf:sub(i, i + len - 1)
      events[#events + 1] = key_event(ch, ch)
      i = i + len
    end
  end
  return events, "", nil
end

--- Flush an incomplete tail after a timeout: the leading ESC becomes an
--- escape key press and the remainder is reparsed.
function input.flush_partial(buf)
  if buf:byte(1) == ESC then
    local events, rest = input.parse(buf:sub(2))
    table.insert(events, 1, key_event("escape"))
    return events, rest
  end
  return {}, buf
end

--- Task body: pull chunks from a loop reader (reader:read([timeout_ms])),
--- emit events via on_event(ev). Returns on EOF. yields
function input.run_reader(reader, on_event)
  local buf = ""
  while true do
    local chunk = reader:read()
    if not chunk then return end
    buf = buf .. chunk
    while buf ~= "" do
      local events, rest, pending = input.parse(buf)
      buf = rest
      for _, ev in ipairs(events) do on_event(ev) end
      if buf == "" then break end
      if pending == "paste" then
        -- Mid-paste: wait as long as it takes.
        local more = reader:read()
        if not more then return end
        buf = buf .. more
      else
        -- Possibly a lone ESC: give the rest of the sequence 20ms to arrive.
        local more, why = reader:read(20)
        if more then
          buf = buf .. more
        elseif why == "timeout" then
          local flushed
          flushed, buf = input.flush_partial(buf)
          for _, ev in ipairs(flushed) do on_event(ev) end
        else
          return -- EOF
        end
      end
    end
  end
end

return input
