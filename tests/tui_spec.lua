package.path = "./tests/?.lua;" .. package.path
local surface_mod = require("helpers.surface")
local tui_mod = require("lupus.tui")
local Text = require("lupus.tui.components.text")
local text = require("lupus.tui.text")
local sgr = require("lupus.tui.sgr")

local function make_tui(cols, rows)
  local surface = surface_mod.new(cols, rows)
  local t = tui_mod.TUI.new({ surface = surface })
  t.running = true -- render directly in tests, no timers
  t.width, t.height = cols, rows
  return t, surface
end

local function key(name)
  return { type = "key", name = name }
end

describe("tui renderer", function()
  it("draws components top-aligned when content fits", function()
    local t, s = make_tui(40, 10)
    t:add(Text.new("hello"))
    t:add(Text.new("world"))
    t:render_frame()
    assert.equals("hello", s:row(1))
    assert.equals("world", s:row(2))
    assert.equals(1, s.frames)
  end)

  it("reflects component updates in the next frame", function()
    local t, s = make_tui(40, 10)
    local a = Text.new("aaa")
    local b = Text.new("bbb")
    t:add(a) t:add(b)
    t:render_frame()
    b:set_text("BBB")
    t:render_frame()
    assert.same({ "aaa", "BBB" }, s:visible())
  end)

  it("drops removed components from the frame", function()
    local t, s = make_tui(40, 10)
    local a = Text.new("one")
    local b = Text.new("two")
    t:add(a) t:add(b)
    t:render_frame()
    t:remove(b)
    t:render_frame()
    assert.same({ "one" }, s:visible())
  end)

  it("bottom-anchors when content exceeds the screen height", function()
    local t, s = make_tui(40, 4)
    for i = 1, 6 do
      t:add(Text.new("line " .. i))
    end
    t:render_frame()
    assert.same({ "line 3", "line 4", "line 5", "line 6" }, s:visible())
  end)

  it("pageup/pagedown scroll the viewport and clamp at the edges", function()
    local t, s = make_tui(40, 4)
    for i = 1, 6 do
      t:add(Text.new("line " .. i))
    end
    t:render_frame()

    t:dispatch(key("pageup"))
    t:render_frame()
    assert.equals("line 1", s:visible()[1])

    -- Another pageup cannot scroll past the top.
    t:dispatch(key("pageup"))
    t:render_frame()
    assert.equals("line 1", s:visible()[1])

    t:dispatch(key("pagedown"))
    t:render_frame()
    local vis = s:visible()
    assert.equals("line 6", vis[#vis])
  end)

  it("scrolls with pageup even while a component has focus", function()
    local t, s = make_tui(40, 4)
    for i = 1, 6 do
      t:add(Text.new("line " .. i))
    end
    local seen = {}
    t:set_focus({ handle_input = function(_, ev) seen[#seen + 1] = ev.name end })
    t:render_frame()

    t:dispatch(key("pageup"))
    t:render_frame()
    assert.equals("line 1", s:visible()[1])
    assert.same({}, seen) -- the focused component never saw the key
  end)

  it("scrolls with the mouse wheel", function()
    local t, s = make_tui(40, 4)
    for i = 1, 6 do
      t:add(Text.new("line " .. i))
    end
    t:set_focus({ handle_input = function() end })
    t:render_frame()

    t:dispatch({ type = "mouse", name = "wheelup" })
    t:render_frame()
    assert.equals("line 1", s:visible()[1])

    t:dispatch({ type = "mouse", name = "wheeldown" })
    t:render_frame()
    local vis = s:visible()
    assert.equals("line 6", vis[#vis])
  end)

  it("snaps back to the bottom when the focused component gets input", function()
    local t, s = make_tui(40, 4)
    for i = 1, 6 do
      t:add(Text.new("line " .. i))
    end
    t:set_focus({ handle_input = function() end })
    t:render_frame()

    t:dispatch(key("pageup"))
    t:render_frame()
    assert.equals("line 1", s:visible()[1])

    t:dispatch(key("a"))
    t:render_frame()
    local vis = s:visible()
    assert.equals("line 6", vis[#vis])
  end)

  it("wraps component text to the screen width", function()
    local t, s = make_tui(10, 6)
    t:add(Text.new("aaaa bbbb cccc"))
    t:render_frame()
    local vis = s:visible()
    assert.is_true(#vis >= 2)
    for _, l in ipairs(vis) do
      assert.is_true(#l <= 10)
    end
  end)

  it("clips lines wider than the screen", function()
    local t, s = make_tui(10, 4)
    t:add({ render = function() return { ("x"):rep(50) } end })
    t:render_frame()
    assert.is_true(#s:row(1) <= 10)
  end)

  it("hands styles to the surface as parsed runs", function()
    local t, s = make_tui(40, 4)
    t:add(Text.new(text.style.red("err") .. " plain"))
    t:render_frame()
    assert.equals("err", s.puts[1].text)
    assert.equals(1, s.puts[1].style.fg)
    assert.equals(" plain", s.puts[2].text)
    assert.is_nil(s.puts[2].style.fg)
  end)

  it("forced renders invalidate the surface", function()
    local t, s = make_tui(40, 4)
    t:add(Text.new("x"))
    t:request_render(true)
    t:render_frame()
    assert.equals(1, s.invalidated)
  end)
end)

describe("sgr", function()
  it("parses nested styles into runs", function()
    local runs = sgr.parse_line(text.style.bold("hi") .. " " .. text.style.gray("dim"))
    assert.equals("hi", runs[1].text)
    assert.is_true(runs[1].style.bold)
    assert.equals(" ", runs[2].text)
    assert.is_nil(runs[2].style.bold)
    assert.equals("dim", runs[3].text)
    assert.equals(8, runs[3].style.fg) -- bright black
  end)

  it("tracks run widths for wide characters", function()
    local runs = sgr.parse_line("日本")
    assert.equals(4, runs[1].width)
    assert.equals("日本", runs[1].text)
  end)

  it("resets styles on SGR 0", function()
    local runs = sgr.parse_line("\27[1;31mboth\27[0mnone")
    assert.is_true(runs[1].style.bold)
    assert.equals(1, runs[1].style.fg)
    assert.is_nil(runs[2].style.bold)
    assert.is_nil(runs[2].style.fg)
  end)
end)
