package.path = "./tests/?.lua;" .. package.path
local loop = require("lupus.loop")
local events_mod = require("lupus.ext.events")
local loader = require("lupus.ext.loader")
local runtime_mod = require("lupus.app.session_runtime")
local fs = require("lupus.util.fs")
local fake = require("helpers.fake_provider")

fake.install()

local function setenv(k, v)
	local uv = require("luv")
	if v == nil then
		uv.os_unsetenv(k)
	else
		uv.os_setenv(k, v)
	end
end

-- ---------------------------------------------------------------------------

describe("ext.events hub", function()
	it("notify runs handlers in order and isolates errors", function()
		local hub = events_mod.new()
		local order = {}
		hub:on("agent_start", function()
			order[#order + 1] = "a"
		end)
		hub:on("agent_start", function()
			error("boom")
		end)
		hub:on("agent_start", function()
			order[#order + 1] = "b"
		end)
		hub:notify("agent_start", {})
		assert.same({ "a", "b" }, order)
	end)

	it("veto short-circuits on the first block", function()
		local hub = events_mod.new()
		local calls = 0
		hub:on("tool_call", function()
			calls = calls + 1
		end)
		hub:on("tool_call", function()
			calls = calls + 1
			return { block = true, reason = "no" }
		end)
		hub:on("tool_call", function()
			calls = calls + 1
		end)
		local verdict = hub:veto("tool_call", {})
		assert.equals(2, calls)
		assert.equals("no", verdict.reason)
	end)

	it("transform chains values and supports handled", function()
		local hub = events_mod.new()
		hub:on("user_input", function(v)
			return v .. "!"
		end)
		hub:on("user_input", function()
			return nil
		end) -- unchanged
		hub:on("user_input", function(v)
			return v .. "?"
		end)
		local out, handled = hub:transform("user_input", "hi", {})
		assert.equals("hi!?", out)
		assert.is_false(handled)

		hub:on("user_input", function()
			return { handled = true }
		end)
		local _, handled2 = hub:transform("user_input", "hi", {})
		assert.is_true(handled2)
	end)

	it("collect gathers table results", function()
		local hub = events_mod.new()
		hub:on("before_agent_start", function()
			return { system_prompt_append = "A" }
		end)
		hub:on("before_agent_start", function()
			return nil
		end)
		hub:on("before_agent_start", function()
			return { inject_message = "B" }
		end)
		local out = hub:collect("before_agent_start", {})
		assert.equals(2, #out)
	end)

	it("rejects unknown event names", function()
		local hub = events_mod.new()
		assert.has_error(function()
			hub:on("no_such_event", function() end)
		end)
	end)
end)

-- ---------------------------------------------------------------------------
-- Runtime integration: real runtime + fake provider + temp dirs.

local tmp

local function make_runtime(opts)
	opts = opts or {}
	-- Point all XDG dirs into the sandbox.
	local env = {
		XDG_CONFIG_HOME = tmp .. "/cfg",
		XDG_DATA_HOME = tmp .. "/data",
		XDG_STATE_HOME = tmp .. "/state",
	}
	local old = {}
	for k, v in pairs(env) do
		old[k] = os.getenv(k)
		setenv(k, v)
	end

	-- Config that resolves to the fake provider.
	fs.mkdirp(tmp .. "/cfg/lupus")
	fs.write_file(
		tmp .. "/cfg/lupus/settings.json",
		'{"providers":{"fake":{"api":"fake"}},'
			.. '"models":[{"id":"fake-model","provider":"fake","api":"fake"}],'
			.. '"default_model":"fake-model"}'
	)

	local rt = runtime_mod.new({
		cwd = opts.cwd or (tmp .. "/proj"),
		session = "none",
		extensions = opts.extensions,
		no_extensions = opts.no_extensions,
	})
	rt.model.script = opts.scripts or {}

	for k, v in pairs(old) do
		setenv(k, v)
	end
	return rt
end

describe("ext loader + runtime integration", function()
	before_each(function()
		tmp = "/tmp/lupus-ext-" .. tostring(math.random(1e8))
		fs.mkdirp(tmp .. "/proj")
	end)

	after_each(function()
		os.execute("rm -rf '" .. tmp .. "'")
	end)

	it("loads global extensions and fires session_start", function()
		fs.mkdirp(tmp .. "/cfg/lupus/extensions")
		fs.write_file(
			tmp .. "/cfg/lupus/extensions/probe.lua",
			[[
      return function(api)
        _G.__probe_started = false
        api.on("session_start", function() _G.__probe_started = true end)
      end
    ]]
		)
		local rt = make_runtime()
		loop.run(function()
			local loaded = rt:load_extensions(nil)
			assert.equals(1, #loaded)
		end)
		assert.is_true(_G.__probe_started)
		_G.__probe_started = nil
	end)

	it("skips untrusted project extensions in headless mode", function()
		fs.mkdirp(tmp .. "/proj/.lupus/extensions")
		fs.write_file(tmp .. "/proj/.lupus/extensions/evil.lua", "return function(api) _G.__evil = true end")
		local rt = make_runtime()
		loop.run(function()
			local loaded = rt:load_extensions(nil)
			assert.equals(0, #loaded)
		end)
		assert.is_nil(_G.__evil)
	end)

	it("loads project extensions when trusted via the ui dialog", function()
		fs.mkdirp(tmp .. "/proj/.lupus/extensions")
		fs.write_file(tmp .. "/proj/.lupus/extensions/ok.lua", "return function(api) _G.__proj_loaded = true end")
		local rt = make_runtime()
		local asked = 0
		local ui = {
			notify = function() end,
			confirm = function()
				asked = asked + 1
				return true
			end,
		}
		loop.run(function()
			assert.equals(1, #rt:load_extensions(ui))
		end)
		assert.equals(1, asked)
		assert.is_true(_G.__proj_loaded)
		_G.__proj_loaded = nil

		-- Decision is cached: a second load does not ask again.
		local rt2 = make_runtime()
		loop.run(function()
			assert.equals(1, #rt2:load_extensions(ui))
		end)
		assert.equals(1, asked)
		_G.__proj_loaded = nil
	end)

	it("api.has_ui reflects whether a UI is attached", function()
		fs.mkdirp(tmp .. "/cfg/lupus/extensions")
		fs.write_file(
			tmp .. "/cfg/lupus/extensions/hasui.lua",
			[[
      return function(api) _G.__has_ui_seen = api.has_ui end
    ]]
		)
		local rt = make_runtime()
		loop.run(function()
			rt:load_extensions(nil)
		end)
		assert.is_false(_G.__has_ui_seen)
		_G.__has_ui_seen = nil

		local rt2 = make_runtime()
		local ui = { notify = function() end }
		loop.run(function()
			rt2:load_extensions(ui)
		end)
		assert.is_true(_G.__has_ui_seen)
		_G.__has_ui_seen = nil
	end)

	it("survives malformed extensions", function()
		fs.mkdirp(tmp .. "/cfg/lupus/extensions")
		fs.write_file(tmp .. "/cfg/lupus/extensions/broken.lua", "this is not lua ((")
		fs.write_file(tmp .. "/cfg/lupus/extensions/wrong.lua", "return 42")
		fs.write_file(tmp .. "/cfg/lupus/extensions/good.lua", "return function() end")
		local rt = make_runtime()
		loop.run(function()
			local loaded = rt:load_extensions(nil)
			assert.equals(1, #loaded)
			assert.matches("good", loaded[1])
		end)
	end)

	it("extension tools are callable by the agent", function()
		fs.mkdirp(tmp .. "/cfg/lupus/extensions")
		fs.write_file(
			tmp .. "/cfg/lupus/extensions/mytool.lua",
			[[
      local schema = require("lupus.schema")
      return function(api)
        api.register_tool{
          name = "shout",
          description = "Uppercase text",
          parameters = schema.object{
            value = schema.string{ required = true },
          },
          execute = function(args) return args.value:upper() end,
        }
      end
    ]]
		)
		local rt = make_runtime({
			scripts = {
				{ { tool = { id = "t1", name = "shout", args = { value = "quiet" } } }, stop = "tool_use" },
				{ { text = "done" }, stop = "stop" },
			},
		})
		loop.run(function()
			rt:load_extensions(nil)
			rt:send("go")
			rt.agent:wait_idle()
		end)
		local result = rt.agent.messages[3]
		assert.equals("tool_result", result.role)
		assert.equals("QUIET", result.content[1].text)
	end)

	it("tool_call veto blocks built-in tools", function()
		fs.mkdirp(tmp .. "/cfg/lupus/extensions")
		fs.write_file(
			tmp .. "/cfg/lupus/extensions/guard.lua",
			[[
      return function(api)
        api.on("tool_call", function(ev)
          if ev.tool_name == "bash" then
            return { block = true, reason = "guarded" }
          end
        end)
      end
    ]]
		)
		local rt = make_runtime({
			scripts = {
				{ { tool = { id = "t1", name = "bash", args = { command = "echo hi" } } }, stop = "tool_use" },
				{ { text = "ok" }, stop = "stop" },
			},
		})
		loop.run(function()
			rt:load_extensions(nil)
			rt:send("go")
			rt.agent:wait_idle()
		end)
		local result = rt.agent.messages[3]
		assert.is_true(result.is_error)
		assert.matches("guarded", result.content[1].text)
	end)

	it("user_input transform and before_agent_start apply", function()
		fs.mkdirp(tmp .. "/cfg/lupus/extensions")
		fs.write_file(
			tmp .. "/cfg/lupus/extensions/shape.lua",
			[[
      return function(api)
        api.on("user_input", function(text) return text .. " [shaped]" end)
        api.on("before_agent_start", function()
          return { system_prompt_append = "EXTENSION RULES" }
        end)
      end
    ]]
		)
		local rt = make_runtime({
			scripts = { { { text = "hi" }, stop = "stop" } },
		})
		loop.run(function()
			rt:load_extensions(nil)
			rt:send("hello")
			rt.agent:wait_idle()
		end)
		assert.equals("hello [shaped]", rt.agent.messages[1].content)
		assert.matches("EXTENSION RULES", rt.agent.system_prompt)
		-- The fake provider saw the appended system prompt.
		assert.matches("EXTENSION RULES", rt.model.calls[1].context.system_prompt)
	end)

	it("before_agent_start hidden_tools filters the model's tool list", function()
		fs.mkdirp(tmp .. "/cfg/lupus/extensions")
		fs.write_file(
			tmp .. "/cfg/lupus/extensions/hide.lua",
			[[
      return function(api)
        api.on("before_agent_start", function()
          return { hidden_tools = { "bash" } }
        end)
      end
    ]]
		)
		local rt = make_runtime({
			scripts = { { { text = "hi" }, stop = "stop" } },
		})
		loop.run(function()
			rt:load_extensions(nil)
			rt:send("hello")
			rt.agent:wait_idle()
		end)
		local names = {}
		for _, tool in ipairs(rt.model.calls[1].context.tools) do
			names[tool.name] = true
		end
		assert.is_nil(names["bash"])
		assert.is_true(names["read"])
	end)

	it("cli extension paths load without discovery", function()
		fs.write_file(tmp .. "/standalone.lua", "return function(api) _G.__cli_ext = true end")
		local rt = make_runtime({
			extensions = { tmp .. "/standalone.lua" },
			no_extensions = true,
		})
		loop.run(function()
			assert.equals(1, #rt:load_extensions(nil))
		end)
		assert.is_true(_G.__cli_ext)
		_G.__cli_ext = nil
	end)
end)
