-- Interactive TUI smoke test: an editor, a spinner, and a live list.
--   luajit examples/tui_demo.lua            interactive (q or ctrl+c quits)
--   luajit examples/tui_demo.lua --auto     scripted 2-second self-test

package.path = "./?.lua;./?/init.lua;" .. package.path
local home = os.getenv("HOME")
if home then
  package.path = package.path .. ";" .. home .. "/.luarocks/share/lua/5.1/?.lua;"
    .. home .. "/.luarocks/share/lua/5.1/?/init.lua"
  package.cpath = package.cpath .. ";" .. home .. "/.luarocks/lib/lua/5.1/?.so"
end

require("lupus.util.compat")
local loop = require("lupus.loop")
local tui_mod = require("lupus.tui")
local screen_mod = require("lupus.tui.screen")
local Text = require("lupus.tui.components.text")
local Markdown = require("lupus.tui.components.markdown")
local Editor = require("lupus.tui.components.editor")
local Loader = require("lupus.tui.components.loader")
local Spacer = require("lupus.tui.components.spacer")
local text = require("lupus.tui.text")

local auto = arg[1] == "--auto"

--- Restore the terminal whatever happens, then rethrow.
local function panic_guard(fn)
  local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
  if not ok then
    screen_mod.restore()
    io.stderr:write("\ncrashed:\n" .. tostring(err) .. "\n")
    os.exit(1)
  end
end

panic_guard(function()
  loop.run(function()
    local t = tui_mod.TUI.new()

    t:add(Markdown.new(table.concat({
      "# lupus TUI demo",
      "",
      "This exercises **markdown**, *styles*, `inline code`, and:",
      "",
      "- differential rendering",
      "- a live spinner",
      "- the multi-line editor (alt+enter for newlines)",
      "",
      "> Type something and press enter. Press **q** on an empty editor or ctrl+c to quit.",
    }, "\n")))
    t:add(Spacer.new(1))

    local echo = Text.new("", { style = text.style.green })
    t:add(echo)

    local loader = Loader.new(t, { message = "Spinning…", hint = "demo" })
    t:add(loader)
    t:add(Spacer.new(1))

    local editor = Editor.new({
      placeholder = "say something",
      on_submit = function(s)
        echo:set_text("you said: " .. s)
        t:request_render()
      end,
    })
    t:add(editor)
    t:set_focus(editor)

    local done = false
    t:add_key_listener(function(ev)
      if ev.type == "key" and (ev.name == "ctrl+c" or (ev.name == "q" and editor:is_empty())) then
        done = true
        return true
      end
      return false
    end)

    t:start()
    loader:start()

    if auto then
      loop.sleep(500)
      editor:handle_input({ type = "key", name = "h", char = "h" })
      editor:handle_input({ type = "key", name = "i", char = "i" })
      t:request_render()
      loop.sleep(300)
      editor:handle_input({ type = "key", name = "enter" })
      t:request_render()
      loop.sleep(1200)
      done = true
    end

    while not done do
      loop.sleep(50)
    end

    loader:stop()
    t:stop()
  end)
end)
