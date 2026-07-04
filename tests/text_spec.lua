local t = require("lupus.tui.text")

describe("tui.text", function()
  describe("visible_width", function()
    it("measures ASCII", function()
      assert.equals(5, t.visible_width("hello"))
      assert.equals(0, t.visible_width(""))
    end)

    it("ignores ANSI sequences", function()
      assert.equals(5, t.visible_width("\27[1;31mhello\27[0m"))
      assert.equals(2, t.visible_width("\27]8;;http://x\7ok\27]8;;\7"))
    end)

    it("counts CJK as double width", function()
      assert.equals(4, t.visible_width("日本"))
      assert.equals(7, t.visible_width("a日b本c"))
    end)

    it("counts emoji as double width", function()
      assert.equals(2, t.visible_width("🚀"))
    end)

    it("counts combining marks as zero width", function()
      assert.equals(1, t.visible_width("e\204\129")) -- e + U+0301
    end)
  end)

  describe("wrap", function()
    it("returns short text unchanged", function()
      assert.same({ "hello" }, t.wrap("hello", 10))
    end)

    it("wraps on word boundaries", function()
      assert.same({ "the quick", "brown fox" }, t.wrap("the quick brown fox", 10))
    end)

    it("hard-breaks overlong words", function()
      assert.same({ "abcde", "fghij", "k" }, t.wrap("abcdefghijk", 5))
    end)

    it("preserves explicit newlines", function()
      assert.same({ "a", "b" }, t.wrap("a\nb", 10))
      assert.same({ "a", "", "b" }, t.wrap("a\n\nb", 10))
    end)

    it("carries ANSI styles across wrapped lines", function()
      local lines = t.wrap("\27[31mred red red\27[0m", 7)
      assert.equals(2, #lines)
      assert.matches("^\27%[31m", lines[2])
    end)

    it("does not split wide chars across the boundary", function()
      local lines = t.wrap("日本語テスト", 5)
      for _, line in ipairs(lines) do
        assert.is_true(t.visible_width(line) <= 5)
      end
    end)

    it("handles empty string", function()
      assert.same({ "" }, t.wrap("", 10))
    end)
  end)

  describe("truncate", function()
    it("leaves short strings alone", function()
      assert.equals("abc", t.truncate("abc", 10))
    end)

    it("truncates with ellipsis at exact width", function()
      local out = t.truncate("abcdefghij", 5)
      assert.equals(5, t.visible_width(out))
      assert.equals("abcd…", out)
    end)

    it("closes ANSI styles after truncation", function()
      local out = t.truncate("\27[31mabcdefghij\27[0m", 5)
      assert.matches("\27%[0m$", out)
      assert.equals(5, t.visible_width(out))
    end)
  end)

  describe("pad / strip_ansi / split_lines", function()
    it("pads to width", function()
      assert.equals("ab   ", t.pad("ab", 5))
      assert.equals(5, t.visible_width(t.pad("日本", 5)))
    end)

    it("strips ansi", function()
      assert.equals("hi", t.strip_ansi("\27[1mhi\27[0m"))
    end)

    it("splits lines tolerating CRLF", function()
      assert.same({ "a", "b", "" }, t.split_lines("a\r\nb\n"))
    end)
  end)
end)
