-- Selectable list with optional type-to-filter. Used for the model picker,
-- session picker, and extension dialogs.
--
--   Select.new{
--     items = { { label = "gpt", desc = "OpenAI", value = ... }, ... },
--     on_select = function(item) end,
--     on_cancel = function() end,
--     title = "Pick a model",        -- optional
--     filterable = true,             -- optional type-to-filter
--     max_visible = 8,
--   }

local text = require("lupus.tui.text")
local utf8 = require("lupus.util.utf8")

local Select = {}
Select.__index = Select

function Select.new(opts)
  local self = setmetatable({
    items = opts.items or {},
    on_select = opts.on_select,
    on_cancel = opts.on_cancel,
    title = opts.title,
    filterable = opts.filterable or false,
    max_visible = opts.max_visible or 8,
    selected = 1,
    filter = "",
    focused = false,
  }, Select)
  return self
end

function Select:visible_items()
  if self.filter == "" then return self.items end
  local needle = self.filter:lower()
  local out = {}
  for _, item in ipairs(self.items) do
    local hay = (item.label .. " " .. (item.desc or "")):lower()
    if hay:find(needle, 1, true) then out[#out + 1] = item end
  end
  return out
end

function Select:handle_input(ev)
  if ev.type ~= "key" then return end
  local items = self:visible_items()
  if ev.name == "up" or ev.name == "ctrl+p" then
    self.selected = self.selected > 1 and self.selected - 1 or #items
  elseif ev.name == "down" or ev.name == "ctrl+n" then
    self.selected = self.selected < #items and self.selected + 1 or 1
  elseif ev.name == "enter" or ev.name == "tab" then
    local item = items[self.selected]
    if item and self.on_select then self.on_select(item) end
  elseif ev.name == "escape" then
    if self.on_cancel then self.on_cancel() end
  elseif self.filterable and ev.name == "backspace" then
    if self.filter ~= "" then
      local off = utf8.offset(self.filter, -1)
      self.filter = self.filter:sub(1, (off or 1) - 1)
      self.selected = 1
    end
  elseif self.filterable and ev.char then
    self.filter = self.filter .. ev.char
    self.selected = 1
  end
end

function Select:render(width)
  local lines = {}
  if self.title then
    lines[#lines + 1] = text.style.bold(text.truncate(self.title, width))
  end
  if self.filterable then
    local prompt = "filter: " .. self.filter
    lines[#lines + 1] = text.style.gray(text.truncate(prompt, width))
  end
  local items = self:visible_items()
  if self.selected > #items then self.selected = math.max(1, #items) end
  if #items == 0 then
    lines[#lines + 1] = text.style.dim("  (no matches)")
    return lines
  end

  -- Window centered on the selection.
  local visible = math.min(self.max_visible, #items)
  local top = math.max(1, math.min(self.selected - math.floor(visible / 2), #items - visible + 1))

  local label_w = 0
  for _, item in ipairs(items) do
    label_w = math.max(label_w, text.visible_width(item.label))
  end
  label_w = math.min(label_w, width - 6)

  for i = top, top + visible - 1 do
    local item = items[i]
    local marker = i == self.selected and "→ " or "  "
    local label = text.pad(text.truncate(item.label, label_w), label_w)
    local line = marker .. label
    if item.desc and item.desc ~= "" then
      line = line .. "  " .. text.style.gray(item.desc)
    end
    line = text.truncate(line, width)
    if i == self.selected then line = text.style.bold(line) end
    lines[#lines + 1] = line
  end
  if #items > visible then
    lines[#lines + 1] = text.style.dim(("  %d/%d"):format(self.selected, #items))
  end
  return lines
end

return Select
