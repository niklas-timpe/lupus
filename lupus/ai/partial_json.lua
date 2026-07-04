-- Best-effort parsing of incomplete JSON. Tool-call arguments stream as raw
-- JSON fragments; this lets the UI show them while they grow. The final,
-- authoritative parse always happens on the complete string, so returning
-- nil here (when the fragment is too mangled) is fine.

local json = require("lupus.util.json")

local partial_json = {}

--- Scan `s`, tracking structure, and return a completed copy — or nil.
local function complete(s)
  local stack = {}          -- open frames: { close = "}"|"]", state = ... }
  -- object states: "start" (expect key or }), "colon" (expect :),
  --                "value" (expect value), "after" (expect , or })
  -- array states:  "start" (expect value or ]), "after" (expect , or ])
  local in_string = false
  local escape = false
  local string_start = nil  -- byte index of the opening quote
  local token_start = nil   -- start of a bare literal (number/true/...)
  local cut = nil           -- truncate everything from this index on

  local function top()
    return stack[#stack]
  end

  local function value_done()
    local frame = top()
    if frame then frame.state = "after" end
  end

  local i = 1
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    if in_string then
      if escape then
        escape = false
      elseif ch == "\\" then
        escape = true
      elseif ch == '"' then
        in_string = false
        local frame = top()
        if frame and frame.close == "}" and frame.state == "start" then
          frame.state = "colon" -- that string was a key
        else
          value_done()
        end
        string_start = nil
      end
    elseif token_start then
      if ch:match("[%w%.%+%-]") then
        -- still inside the literal
      else
        token_start = nil
        value_done()
        i = i - 1 -- reprocess this char as structure
      end
    elseif ch == '"' then
      in_string = true
      string_start = i
    elseif ch == "{" then
      stack[#stack + 1] = { close = "}", state = "start" }
    elseif ch == "[" then
      stack[#stack + 1] = { close = "]", state = "start" }
    elseif ch == "}" or ch == "]" then
      table.remove(stack)
      value_done()
    elseif ch == ":" then
      local frame = top()
      if frame then frame.state = "value" end
    elseif ch == "," then
      local frame = top()
      if frame then
        frame.state = frame.close == "}" and "start" or "start"
      end
    elseif ch:match("[%w%.%+%-]") then
      token_start = i
    end
    i = i + 1
  end

  local out = s

  if in_string then
    local frame = top()
    if frame and frame.close == "}" and frame.state == "start" then
      -- Partial key: drop it entirely.
      out = out:sub(1, string_start - 1)
    else
      if escape then out = out:sub(1, -2) end
      -- Unfinished \uXXXX escape: drop the fragment.
      out = out:gsub("\\u%x?%x?%x?$", "")
      out = out .. '"'
      value_done()
    end
  elseif token_start then
    local token = s:sub(token_start)
    local completed_literal = nil
    for _, lit in ipairs({ "true", "false", "null" }) do
      if lit:sub(1, #token) == token then completed_literal = lit break end
    end
    if completed_literal then
      out = out:sub(1, token_start - 1) .. completed_literal
      value_done()
    elseif token:match("^%-?%d+%.?%d*$") and token:match("%d") then
      -- Trim a trailing dot so "12." parses.
      out = out:gsub("%.$", "")
      value_done()
    else
      -- Unfinishable literal (e.g. "-", "1e"): drop it.
      out = out:sub(1, token_start - 1)
    end
  end

  -- Structural fixups at the (possibly truncated) tail.
  out = out:gsub("%s+$", "")
  out = out:gsub(",$", "")
  local frame = top()
  if frame and frame.state == "value" then
    out = out .. "null"
  elseif frame and frame.state == "colon" then
    out = out .. ":null"
  end

  for idx = #stack, 1, -1 do
    out = out .. stack[idx].close
  end
  return out
end

--- Parse a possibly-incomplete JSON string. Returns a value or nil.
function partial_json.parse(s)
  if s == "" then return nil end
  local v = json.decode(s)
  if v ~= nil then return v end
  local ok, completed = pcall(complete, s)
  if not ok or not completed or completed == "" then return nil end
  return (json.decode(completed))
end

return partial_json
