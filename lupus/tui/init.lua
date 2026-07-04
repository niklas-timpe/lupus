-- The TUI: a component tree rendered full-screen through a surface (the
-- ncurses screen in production, a fake grid in tests).
--
-- Component contract (unchanged from the string renderer days):
--   component:render(width) -> array of ANSI-styled lines, ≤ width columns
--   component.handle_input(ev) (optional)  -- receives events when focused
--   component.focused (optional)           -- set by tui:set_focus
--
-- Each frame the tree is flattened into one array of styled lines; the
-- bottom-anchored tail that fits the screen is parsed into style runs
-- (lupus/tui/sgr.lua) and drawn onto the surface. ncurses diffs the frame
-- against the physical screen, so redrawing everything each frame is cheap.
-- pageup/pagedown and the mouse wheel scroll the view; input that reaches
-- the focused component snaps the view back to the bottom.
--
-- The layers, individually replaceable:
--   components  -> styled strings   (lupus/tui/components/*, text.lua)
--   this module -> frames of runs   (tree, focus, viewport, frame pacing)
--   sgr.lua     -> style tables     (pure ANSI parsing)
--   screen.lua  -> the terminal     (ncurses lifecycle and drawing)
--   input.lua   -> key events      (pure parser over a uv tty reader)

local loop = require("lupus.loop")
local text = require("lupus.tui.text")
local sgr = require("lupus.tui.sgr")
local input_mod = require("lupus.tui.input")
local log = require("lupus.util.log")

local TUI = {}
TUI.__index = TUI

local tui_module = { TUI = TUI }

local FRAME_MS = 16

local PASTE_ON = "\27[?2004h"
local PASTE_OFF = "\27[?2004l"

-- Button presses + SGR encoding: enough for wheel events, which is all the
-- input parser turns into events.
local MOUSE_ON = "\27[?1000;1006h"
local MOUSE_OFF = "\27[?1000;1006l"

local WHEEL_LINES = 3

--- opts.surface: a screen-like surface (defaults to the real ncurses
--- screen). opts.input_reader: a loop reader yielding key bytes (defaults
--- to a uv tty reader on stdin).
function TUI.new(opts)
  opts = opts or {}
  local self = setmetatable({
    surface = opts.surface or require("lupus.tui.screen").new(),
    input_reader = opts.input_reader,
    children = {},
    focus = nil,
    key_listeners = {},
    width = 0,
    height = 0,
    scroll = 0, -- lines scrolled up from the bottom of the content
    render_scheduled = false,
    last_render = 0,
    running = false,
  }, TUI)
  return self
end

-- ---------------------------------------------------------------------------
-- Component tree

function TUI:add(component, index)
  if index then
    table.insert(self.children, index, component)
  else
    self.children[#self.children + 1] = component
  end
  self:request_render()
  return component
end

function TUI:remove(component)
  for i, c in ipairs(self.children) do
    if c == component then
      table.remove(self.children, i)
      self:request_render()
      return
    end
  end
end

function TUI:clear_children()
  self.children = {}
  self:request_render()
end

function TUI:set_focus(component)
  if self.focus == component then return end
  if self.focus then self.focus.focused = false end
  self.focus = component
  if component then component.focused = true end
  self:request_render()
end

--- Global key listeners run before the focused component; return true to
--- consume the event. Returns an unregister function.
function TUI:add_key_listener(fn)
  self.key_listeners[#self.key_listeners + 1] = fn
  return function()
    for i, f in ipairs(self.key_listeners) do
      if f == fn then table.remove(self.key_listeners, i) return end
    end
  end
end

function TUI:scroll_by(lines)
  local target = self.scroll + lines
  self.scroll = target > 0 and target or 0 -- upper clamp happens at render
  self:request_render()
end

function TUI:dispatch(ev)
  for _, fn in ipairs(self.key_listeners) do
    local ok, consumed = pcall(fn, ev)
    if not ok then
      log.error("key listener failed: %s", tostring(consumed))
    elseif consumed then
      self:request_render()
      return
    end
  end
  -- Scroll input is claimed here, before the focused component: the editor
  -- always has focus, so it would otherwise shadow scrolling entirely.
  if ev.type == "mouse" then
    if ev.name == "wheelup" then
      self:scroll_by(WHEEL_LINES)
    elseif ev.name == "wheeldown" then
      self:scroll_by(-WHEEL_LINES)
    end
    return
  end
  if ev.type == "key" and (ev.name == "pageup" or ev.name == "pagedown") then
    local page = self.height > 2 and self.height - 2 or 1
    self:scroll_by(ev.name == "pageup" and page or -page)
    return
  end
  if self.focus and self.focus.handle_input then
    self.scroll = 0 -- typing while scrolled up snaps back to the editor
    local ok, err = pcall(self.focus.handle_input, self.focus, ev)
    if not ok then log.error("component input failed: %s", tostring(err)) end
    self:request_render()
  end
end

-- ---------------------------------------------------------------------------
-- Rendering

--- Coalesced render request: at most one frame per FRAME_MS.
function TUI:request_render(force)
  if force then self.force_next = true end
  if self.render_scheduled or not self.running then return end
  self.render_scheduled = true
  local elapsed = loop.now_ms() - self.last_render
  local delay = elapsed >= FRAME_MS and 0 or (FRAME_MS - elapsed)
  loop.timer(delay, function()
    self.render_scheduled = false
    self.last_render = loop.now_ms()
    local ok, err = pcall(self.render_frame, self)
    if not ok then log.error("render failed: %s", tostring(err)) end
  end)
end

local function collect_lines(self)
  local lines = {}
  for _, child in ipairs(self.children) do
    local ok, child_lines = pcall(child.render, child, self.width)
    if ok and child_lines then
      for _, line in ipairs(child_lines) do
        -- Defensive: a line wider than the screen would wrap inside
        -- ncurses and shift everything below it.
        if text.visible_width(line) > self.width then
          line = text.truncate(line, self.width, "")
        end
        lines[#lines + 1] = line
      end
    elseif not ok then
      log.error("component render failed: %s", tostring(child_lines))
    end
  end
  return lines
end

function TUI:render_frame()
  local cols, rows = self.surface:size()
  self.width, self.height = cols, rows

  if self.force_next then
    self.force_next = false
    if self.surface.invalidate then self.surface:invalidate() end
  end

  local lines = collect_lines(self)
  local total = #lines

  -- Bottom-anchored viewport: show the tail unless scrolled up.
  local max_scroll = total > rows and total - rows or 0
  if self.scroll > max_scroll then self.scroll = max_scroll end
  local bottom = total - self.scroll
  local top = bottom - rows + 1
  if top < 1 then top = 1 end

  self.surface:begin_frame()
  local y = 1
  for i = top, bottom do
    local x = 1
    for _, run in ipairs(sgr.parse_line(lines[i])) do
      if run.text ~= "" then
        self.surface:put(y, x, run.text, run.style)
        x = x + run.width
      end
    end
    y = y + 1
  end
  self.surface:end_frame()
end

-- ---------------------------------------------------------------------------
-- Lifecycle

--- Start the TUI: ncurses screen, bracketed paste, input task.
--- Call from inside loop.run. yields
function TUI:start(opts)
  opts = opts or {}
  self.running = true
  if not opts.headless then
    if self.surface.start then
      self.surface:start()
      self.surface:write_raw(PASTE_ON .. MOUSE_ON)
    end
    self.resize_unsub = loop.on_signal("SIGWINCH", function()
      if self.surface.resize then self.surface:resize() end
      self:request_render(true)
    end)
    if not self.input_reader then
      self.tty_in = loop.uv.new_tty(0, true)
      self.input_reader = loop.reader(self.tty_in)
    end
  end
  if self.input_reader then
    self.input_task = loop.spawn(function()
      input_mod.run_reader(self.input_reader, function(ev) self:dispatch(ev) end)
    end)
  end
  self:request_render()
end

--- Stop and restore the terminal (leaves the alternate screen; the shell
--- prompt returns as it was). Safe anywhere.
function TUI:stop()
  if not self.running then return end
  self.running = false
  if self.input_task then self.input_task:cancel() end
  if self.resize_unsub then self.resize_unsub() end
  if self.tty_in then
    self.input_reader:close()
    self.input_reader = nil
    self.tty_in = nil
  end
  if self.surface.stop then
    self.surface:write_raw(MOUSE_OFF .. PASTE_OFF)
    self.surface:stop()
  end
end

return tui_module
