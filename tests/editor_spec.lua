local Editor = require("lupus.tui.components.editor")
local utf8 = require("lupus.util.utf8")

local function key(name, char)
  return { type = "key", name = name, char = char }
end

local function type_text(ed, s)
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    ed:handle_input(key(ch, ch), 40)
  end
end

describe("tui editor", function()
  it("inserts typed characters", function()
    local ed = Editor.new()
    type_text(ed, "hello")
    assert.equals("hello", ed:get_text())
    assert.equals(5, ed.cursor.col)
  end)

  it("handles UTF-8 movement and deletion", function()
    local ed = Editor.new()
    type_text(ed, "aé日")
    ed:handle_input(key("left"), 40)
    ed:handle_input(key("backspace"), 40)
    assert.equals("a日", ed:get_text())
    ed:handle_input(key("right"), 40)
    ed:handle_input(key("backspace"), 40)
    assert.equals("a", ed:get_text())
  end)

  it("submits on enter and clears", function()
    local submitted
    local ed = Editor.new({ on_submit = function(s) submitted = s end })
    type_text(ed, " hi there ")
    ed:handle_input(key("enter"), 40)
    assert.equals("hi there", submitted)
    assert.equals("", ed:get_text())
  end)

  it("does not submit empty input", function()
    local submitted = false
    local ed = Editor.new({ on_submit = function() submitted = true end })
    ed:handle_input(key("enter"), 40)
    assert.is_false(submitted)
  end)

  it("inserts newlines with alt+enter and navigates lines", function()
    local ed = Editor.new()
    type_text(ed, "one")
    ed:handle_input(key("alt+enter"), 40)
    type_text(ed, "two")
    assert.equals("one\ntwo", ed:get_text())
    ed:handle_input(key("up"), 40)
    assert.equals(1, ed.cursor.line)
    assert.equals(3, ed.cursor.col)
    ed:handle_input(key("down"), 40)
    assert.equals(2, ed.cursor.line)
  end)

  it("merges lines on backspace at line start", function()
    local ed = Editor.new()
    ed:set_text("ab\ncd")
    ed.cursor.line = 2
    ed.cursor.col = 0
    ed:handle_input(key("backspace"), 40)
    assert.equals("abcd", ed:get_text())
    assert.equals(2, ed.cursor.col)
  end)

  it("kills to line start and end", function()
    local ed = Editor.new()
    type_text(ed, "abcdef")
    ed.cursor.col = 3
    ed:handle_input(key("ctrl+k"), 40)
    assert.equals("abc", ed:get_text())
    ed:handle_input(key("ctrl+u"), 40)
    assert.equals("", ed:get_text())
  end)

  it("deletes word backwards", function()
    local ed = Editor.new()
    type_text(ed, "foo bar baz")
    ed:handle_input(key("ctrl+w"), 40)
    assert.equals("foo bar ", ed:get_text())
    ed:handle_input(key("ctrl+w"), 40)
    assert.equals("foo ", ed:get_text())
  end)

  it("navigates history with up/down", function()
    local ed = Editor.new()
    ed:add_history("first")
    ed:add_history("second")
    ed:handle_input(key("up"), 40)
    assert.equals("second", ed:get_text())
    ed:handle_input(key("up"), 40)
    assert.equals("first", ed:get_text())
    ed:handle_input(key("down"), 40)
    assert.equals("second", ed:get_text())
    ed:handle_input(key("down"), 40)
    assert.equals("", ed:get_text())
  end)

  it("preserves the draft when browsing history", function()
    local ed = Editor.new()
    ed:add_history("old")
    type_text(ed, "draft")
    ed:handle_input(key("up"), 40)
    assert.equals("old", ed:get_text())
    ed:handle_input(key("down"), 40)
    assert.equals("draft", ed:get_text())
  end)

  it("inserts pastes with normalization", function()
    local ed = Editor.new()
    ed:handle_input({ type = "paste", text = "a\r\nb\tc" }, 40)
    assert.equals("a\nb  c", ed:get_text())
  end)

  it("moves across soft-wrapped rows", function()
    local ed = Editor.new()
    ed:set_text("aaaa bbbb cccc dddd")
    -- width 10 → rows like "aaaa bbbb ", "cccc dddd"
    ed.cursor.line = 1
    ed.cursor.col = 0
    ed:handle_input(key("down"), 10)
    assert.equals(1, ed.cursor.line)
    assert.is_true(ed.cursor.col > 0)
  end)

  it("renders with borders and cursor", function()
    local ed = Editor.new({ placeholder = "type here" })
    ed.focused = true
    local lines = ed:render(20)
    assert.equals(3, #lines) -- border, input row, border
    type_text(ed, "hi")
    lines = ed:render(20)
    assert.matches("hi", lines[2])
  end)
end)
