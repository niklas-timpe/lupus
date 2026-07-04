local session_mod = require("lupus.session")
local config = require("lupus.config")
local prompt = require("lupus.prompt")
local fs = require("lupus.util.fs")
local types = require("lupus.ai.types")

local tmp

describe("session", function()
  before_each(function()
    tmp = "/tmp/lupus-test-" .. tostring(math.random(1e8))
    fs.mkdirp(tmp)
  end)

  after_each(function()
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  it("round-trips a conversation through the file", function()
    local sess = session_mod.create("/some/project", tmp)
    sess:append_message(types.user("hello"))
    local assistant = {
      role = "assistant",
      content = { { type = "text", text = "hi!" } },
      model = "m1", provider = "p1",
      usage = types.usage(),
      stop_reason = "stop", timestamp = os.time(),
    }
    sess:append_message(assistant)
    sess:append_model("claude-sonnet-4-5")

    local loaded = session_mod.open(sess.path)
    assert.is_not_nil(loaded)
    assert.equals(sess.id, loaded.id)
    assert.equals("/some/project", loaded.cwd)
    local msgs = loaded:messages()
    assert.equals(2, #msgs)
    assert.equals("hello", msgs[1].content)
    assert.equals("hi!", msgs[2].content[1].text)
    assert.equals("claude-sonnet-4-5", loaded:model_id())
  end)

  it("lists sessions newest-first with previews", function()
    local s1 = session_mod.create("/proj", tmp)
    s1:append_message(types.user("first session prompt"))
    os.execute("sleep 1")
    local s2 = session_mod.create("/proj", tmp)
    s2:append_message(types.user("second session prompt"))

    local list = session_mod.list("/proj", tmp)
    assert.equals(2, #list)
    assert.matches("second session", list[1].preview)
    assert.matches("first session", list[2].preview)

    local recent = session_mod.continue_recent("/proj", tmp)
    assert.equals(s2.id, recent.id)
  end)

  it("keeps in-memory sessions off disk", function()
    local sess = session_mod.in_memory("/proj")
    sess:append_message(types.user("secret"))
    assert.is_nil(sess.path)
    assert.equals(1, #sess:messages())
    assert.equals(0, #session_mod.list("/proj", tmp))
  end)

  it("stores and restores session names", function()
    local sess = session_mod.create("/proj", tmp)
    sess:set_name("my refactor")
    local loaded = session_mod.open(sess.path)
    assert.equals("my refactor", loaded.name)
  end)

  it("rejects non-session files", function()
    fs.write_file(tmp .. "/junk.jsonl", "not json\n")
    local sess, err = session_mod.open(tmp .. "/junk.jsonl")
    assert.is_nil(sess)
    assert.matches("not a lupus session", err)
  end)
end)

describe("config", function()
  it("deep-merges project over global settings", function()
    local merged = config.deep_merge(
      { thinking = "low", providers = { a = { base_url = "x" } }, keep = 1 },
      { thinking = "high", providers = { b = { base_url = "y" } } }
    )
    assert.equals("high", merged.thinking)
    assert.equals(1, merged.keep)
    assert.equals("x", merged.providers.a.base_url)
    assert.equals("y", merged.providers.b.base_url)
  end)

  it("replaces arrays instead of merging them", function()
    local merged = config.deep_merge({ list = { 1, 2, 3 } }, { list = { 9 } })
    assert.same({ 9 }, merged.list)
  end)
end)

describe("prompt", function()
  before_each(function()
    tmp = "/tmp/lupus-test-" .. tostring(math.random(1e8))
    fs.mkdirp(tmp .. "/sub/deep")
  end)

  after_each(function()
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  it("collects context files from ancestors, root first", function()
    fs.write_file(tmp .. "/AGENTS.md", "root rules")
    fs.write_file(tmp .. "/sub/deep/AGENTS.md", "deep rules")
    local files = prompt.context_files(tmp .. "/sub/deep")
    -- Only files under tmp matter for the assertion (the real / walk may
    -- find files above tmp on a dev machine).
    local found = {}
    for _, f in ipairs(files) do
      if f.path:find(tmp, 1, true) then found[#found + 1] = f end
    end
    assert.equals(2, #found)
    assert.matches("root rules", found[1].content)
    assert.matches("deep rules", found[2].content)
  end)

  it("builds a prompt with context and environment", function()
    fs.write_file(tmp .. "/AGENTS.md", "USE TABS")
    local p = prompt.build({ cwd = tmp })
    assert.matches("You are lupus", p)
    assert.matches("USE TABS", p)
    assert.matches("<project_context>", p)
    assert.matches("Working directory: " .. tmp:gsub("%-", "%%-"), p)
  end)

  it("supports custom and appended prompts", function()
    local p = prompt.build({ cwd = tmp, custom = "CUSTOM BASE", append = "EXTRA", no_context_files = true })
    assert.matches("^CUSTOM BASE", p)
    assert.matches("EXTRA", p)
    assert.is_nil(p:find("You are lupus", 1, true))
  end)
end)
