-- Keyless startup and /login plumbing: model fallback, set_api_key
-- persistence, and post-extension model re-resolution.

package.path = "./tests/?.lua;" .. package.path
local runtime_mod = require("lupus.app.session_runtime")
local models = require("lupus.ai.models")
local config = require("lupus.config")
local fs = require("lupus.util.fs")
local json = require("lupus.util.json")
local uv = require("luv")

local KEY_VARS = {
  "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY",
  "GROQ_API_KEY", "EDENAI_API_KEY",
}

local function setenv(k, v)
  if v == nil then uv.os_unsetenv(k) else uv.os_setenv(k, v) end
end

describe("keyless startup and login", function()
  local tmp, saved_env

  before_each(function()
    -- hrtime, not math.random: LuaJIT's unseeded PRNG repeats across runs,
    -- and a reused sandbox leaks the previous run's settings.json.
    tmp = "/tmp/lupus-login-" .. tostring(uv.hrtime())
    fs.mkdirp(tmp .. "/proj")
    saved_env = {}
    for _, k in ipairs(KEY_VARS) do
      saved_env[k] = os.getenv(k)
      setenv(k, nil)
    end
    for k, v in pairs({
      XDG_CONFIG_HOME = tmp .. "/cfg",
      XDG_DATA_HOME = tmp .. "/data",
      XDG_STATE_HOME = tmp .. "/state",
    }) do
      saved_env[k] = os.getenv(k)
      setenv(k, v)
    end
  end)

  after_each(function()
    for k, v in pairs(saved_env) do setenv(k, v) end
    models.load({}) -- reset the registry for other specs
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  local function make_runtime()
    return runtime_mod.new{ cwd = tmp .. "/proj", session = "none", no_extensions = true }
  end

  it("starts without any API key on a fallback model", function()
    local rt = make_runtime()
    assert.is_not_nil(rt.model)
    assert.equals(models.list()[1].id, rt.model.id)
    assert.is_false(rt:model_available())
  end)

  it("set_api_key makes the model usable and persists the key", function()
    local rt = make_runtime()
    local path = assert(rt:set_api_key("anthropic", "sk-test-123"))
    assert.is_true(rt:model_available())

    local saved = json.decode(fs.read_file(path))
    assert.equals("sk-test-123", saved.api_keys.anthropic)

    -- A fresh config load (new session) sees the key too.
    local cfg = config.load(tmp .. "/proj")
    assert.equals("sk-test-123", cfg.settings.api_keys.anthropic)
  end)

  it("reresolve_model picks up models registered after startup", function()
    fs.mkdirp(tmp .. "/cfg/lupus")
    fs.write_file(tmp .. "/cfg/lupus/settings.json",
      '{"default_model":"late/some-model"}')
    local rt = make_runtime()
    -- default_model is unknown at construction: fallback wins.
    assert.is_not.equals("some-model", rt.model.id)

    -- An "extension" registers the provider and model, then the frontend
    -- re-resolves.
    rt.config.settings.providers = { late = { base_url = "http://x", api_key = "k" } }
    rt.config.settings.models = { { id = "some-model", provider = "late" } }
    models.load(rt.config.settings)
    rt:reresolve_model()

    assert.equals("some-model", rt.model.id)
    assert.equals("late", rt.model.provider)
    assert.is_true(rt:model_available())
  end)

  it("set_model persists default_model only when asked", function()
    local rt = make_runtime()
    local other = models.list()[2]

    rt:set_model(other)
    local cfg = config.load(tmp .. "/proj")
    assert.is_nil(cfg.settings.default_model)

    rt:set_model(other, { persist = true })
    cfg = config.load(tmp .. "/proj")
    assert.equals(other.provider .. "/" .. other.id, cfg.settings.default_model)
  end)

  it("models.providers lists providers sorted by name", function()
    models.load({})
    local list = models.providers()
    assert.is_true(#list >= 5)
    for i = 2, #list do
      assert.is_true(list[i - 1].name < list[i].name)
    end
  end)
end)
