-- Static text block: wraps its content to the render width. The workhorse
-- for plain transcript entries and status lines.

local text_util = require("lupus.tui.text")

local Text = {}
Text.__index = Text

--- opts: style = fn(line) -> line (applied before wrapping),
---       padding_y = blank lines above/below.
function Text.new(content, opts)
  opts = opts or {}
  return setmetatable({
    content = content or "",
    style = opts.style,
    padding_y = opts.padding_y or 0,
    cache_key = nil,
    cache = nil,
  }, Text)
end

function Text:set_text(content)
  if content == self.content then return end
  self.content = content
  self.cache_key = nil
end

function Text:render(width)
  local key = width .. "\0" .. self.content
  if self.cache_key == key then return self.cache end
  local body = self.content
  if self.style then body = self.style(body) end
  local lines = {}
  for _ = 1, self.padding_y do lines[#lines + 1] = "" end
  if self.content ~= "" then
    for _, line in ipairs(text_util.wrap(body, width)) do
      lines[#lines + 1] = line
    end
  end
  for _ = 1, self.padding_y do lines[#lines + 1] = "" end
  self.cache_key = key
  self.cache = lines
  return lines
end

return Text
