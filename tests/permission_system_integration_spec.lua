-- End-to-end sanity check: load the REAL thin-loader extension
-- (examples/extensions/permission_system.lua) through lupus's actual
-- ext.loader + ext.api + session_runtime pipeline (no hand-mocked api
-- object, unlike the manual smoke tests during development) and drive a
-- scripted bash tool call through the real agent loop to confirm the veto
-- fires exactly like it would in a real session.

local loop = require("lupus.loop")
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

local EXTENSION_PATH = fs.absolute("examples/extensions/permission_system.lua", fs.cwd())

local tmp

-- Unlike tests/ext_spec.lua's make_runtime, XDG_* must stay pointed at the
-- sandbox for the whole test body, not just during construction:
-- session_runtime captures cfg.dirs once at construction (fine either
-- way), but permission_system resolves lupus.config.dirs() lazily inside
-- M.setup, which runs later during load_extensions — exactly like a real
-- process, where the env var is set once for its whole lifetime. So
-- before_each/after_each own the env var lifecycle here, not make_runtime.
local function make_runtime(opts)
	opts = opts or {}
	fs.mkdirp(tmp .. "/cfg/lupus")
	fs.write_file(
		tmp .. "/cfg/lupus/settings.json",
		'{"providers":{"fake":{"api":"fake"}},'
			.. '"models":[{"id":"fake-model","provider":"fake","api":"fake"}],'
			.. '"default_model":"fake-model"}'
	)
	if opts.global_permissions then
		fs.write_file(tmp .. "/cfg/lupus/permissions.jsonc", opts.global_permissions)
	end

	local rt = runtime_mod.new({
		cwd = opts.cwd or (tmp .. "/proj"),
		session = "none",
		extensions = { EXTENSION_PATH },
	})
	rt.model.script = opts.scripts or {}
	return rt
end

describe("permission_system loaded as a real lupus extension", function()
	local old_env

	before_each(function()
		tmp = "/tmp/lupus-permsys-integration-" .. tostring(math.random(1e8))
		fs.mkdirp(tmp .. "/proj")
		old_env = {}
		for _, k in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME" }) do
			old_env[k] = os.getenv(k)
		end
		setenv("XDG_CONFIG_HOME", tmp .. "/cfg")
		setenv("XDG_DATA_HOME", tmp .. "/data")
		setenv("XDG_STATE_HOME", tmp .. "/state")
	end)

	after_each(function()
		for k, v in pairs(old_env) do
			setenv(k, v)
		end
		os.execute("rm -rf '" .. tmp .. "'")
	end)

	it("loads via the ext loader and registers the /permissions command", function()
		local rt = make_runtime()
		loop.run(function()
			local loaded = rt:load_extensions(nil)
			assert.equals(1, #loaded)
		end)
		assert.is_not_nil(rt.commands:get("permissions"))
	end)

	it("blocks a denied bash command through the real tool_call veto", function()
		local rt = make_runtime({
			global_permissions = '{ "bash": { "*": "deny" } }',
			scripts = {
				{ { tool = { id = "t1", name = "bash", args = { command = "rm -rf /" } } }, stop = "tool_use" },
				{ { text = "ok" }, stop = "stop" },
			},
		})
		loop.run(function()
			rt:load_extensions(nil) -- print mode: no UI, "deny" blocks outright
			rt:send("go")
			rt.agent:wait_idle()
		end)
		local result = rt.agent.messages[3]
		assert.is_true(result.is_error)
		assert.matches("not permitted to run", result.content[1].text, 1, true)
	end)

	it("lets an allowed bash command run", function()
		local rt = make_runtime({
			global_permissions = '{ "bash": { "*": "deny", "echo *": "allow" } }',
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
		assert.is_false(result.is_error)
	end)

	it("without a UI, an 'ask' state blocks with a no-UI reason instead of hanging", function()
		local rt = make_runtime({
			global_permissions = '{ "bash": { "*": "ask" } }',
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
		assert.matches("no interactive UI is available", result.content[1].text, 1, true)
	end)

	it("hides a fully-denied tool from the model's tool list via before_agent_start", function()
		local rt = make_runtime({
			global_permissions = '{ "tools": { "write": "deny" } }',
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
		assert.is_nil(names["write"])
		assert.is_true(names["read"])
	end)
end)
