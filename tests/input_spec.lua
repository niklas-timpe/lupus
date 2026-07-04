local input = require("lupus.tui.input")

local function names(events)
  local out = {}
  for _, ev in ipairs(events) do
    out[#out + 1] = ev.type == "paste" and ("paste:" .. ev.text) or ev.name
  end
  return out
end

describe("tui.input", function()
  it("parses printable chars with char field", function()
    local events, rest = input.parse("ab")
    assert.same({ "a", "b" }, names(events))
    assert.equals("a", events[1].char)
    assert.equals("", rest)
  end)

  it("parses UTF-8 chars", function()
    local events = input.parse("é日")
    assert.same({ "é", "日" }, names(events))
  end)

  it("parses control keys", function()
    local events = input.parse("\3\13\9\127\21")
    assert.same({ "ctrl+c", "enter", "tab", "backspace", "ctrl+u" }, names(events))
  end)

  it("parses arrow and navigation CSI sequences", function()
    local events = input.parse("\27[A\27[B\27[C\27[D\27[H\27[F\27[3~\27[5~\27[Z")
    assert.same({ "up", "down", "left", "right", "home", "end", "delete", "pageup", "shift+tab" },
      { events[1].name, events[2].name, events[4].name, events[3].name, events[5].name,
        events[6].name, events[7].name, events[8].name, events[9].name })
  end)

  it("parses modified keys", function()
    local events = input.parse("\27[1;5A\27[1;2C\27[3;3~")
    assert.same({ "ctrl+up", "shift+right", "alt+delete" }, names(events))
  end)

  it("parses SS3 sequences", function()
    local events = input.parse("\27OA\27OH")
    assert.same({ "up", "home" }, names(events))
  end)

  it("parses alt+key", function()
    local events = input.parse("\27f\27\13\27\127")
    assert.same({ "alt+f", "alt+enter", "alt+backspace" }, names(events))
  end)

  it("reports a lone ESC as pending", function()
    local events, rest, pending = input.parse("\27")
    assert.same({}, events)
    assert.equals("\27", rest)
    assert.equals("seq", pending)
  end)

  it("flushes a pending ESC as the escape key", function()
    local events, rest = input.flush_partial("\27")
    assert.same({ "escape" }, names(events))
    assert.equals("", rest)
  end)

  it("holds an incomplete CSI sequence", function()
    local events, rest, pending = input.parse("a\27[1;5")
    assert.same({ "a" }, names(events))
    assert.equals("\27[1;5", rest)
    assert.equals("seq", pending)
    local more = input.parse(rest .. "D")
    assert.same({ "ctrl+left" }, names(more))
  end)

  it("parses bracketed paste", function()
    local events = input.parse("\27[200~hello\nworld\27[201~x")
    assert.same({ "paste:hello\nworld", "x" }, names(events))
  end)

  it("holds an unterminated paste", function()
    local events, rest, pending = input.parse("\27[200~partial data")
    assert.same({}, events)
    assert.equals("paste", pending)
    assert.equals("\27[200~partial data", rest)
  end)

  it("holds a split UTF-8 char", function()
    local bytes = "日"
    local events, rest, pending = input.parse(bytes:sub(1, 2))
    assert.same({}, events)
    assert.equals("seq", pending)
    assert.equals(bytes:sub(1, 2), rest)
  end)

  it("swallows OSC terminal responses", function()
    local events = input.parse("\27]11;rgb:1111/2222/3333\7a")
    assert.same({ "a" }, names(events))
  end)
end)
