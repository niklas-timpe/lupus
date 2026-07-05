-- The `api` object handed to each extension factory. Extensions are plain
-- Lua files returning `function(api) ... end`; everything they can do goes
-- through here.
--
-- `host` is shared across all extensions of a session:
--   { hub, runtime, ui?, commands, flags, shortcuts }
-- ui is nil in print mode: dialogs raise, notify falls back to stderr.

local loop = require("lupus.loop")
local models = require("lupus.ai.models")
local log = require("lupus.util.log")

local api_mod = {}

local function ui_required(host, what)
	if not host.ui then
		error(what .. " needs an interactive session (print mode has no UI)", 3)
	end
	return host.ui
end

function api_mod.build(host, source_path)
	local api = {}

	api.cwd = host.runtime.cwd
	api.config = host.runtime.config.settings
	api.session_id = host.runtime.session.id
	api.source = source_path

	-- ---------------------------------------------------------------- events
	function api.on(name, handler)
		assert(type(handler) == "function", "api.on: handler must be a function")
		host.hub:on(name, handler)
	end

	-- ---------------------------------------------------------- registration
	function api.register_tool(def)
		assert(
			type(def) == "table" and def.name and def.execute and def.parameters,
			"register_tool needs { name, description, parameters, execute }"
		)
		def.label = def.label or def.name
		def.description = def.description or ""
		local tools = host.runtime.agent.tools
		for i, t in ipairs(tools) do
			if t.name == def.name then -- same name overrides (built-ins included)
				table.remove(tools, i)
				break
			end
		end
		tools[#tools + 1] = def
		host.runtime.agent:set_tools(tools)
		log.info("extension %s registered tool %s", source_path, def.name)
	end

	function api.register_command(def)
		assert(type(def) == "table" and def.name and def.run, "register_command needs { name, run }")
		def.description = def.description or ("from " .. source_path)
		host.commands:register(def)
	end

	function api.register_shortcut(def)
		assert(type(def) == "table" and def.key and def.run, "register_shortcut needs { key, run }")
		host.shortcuts[#host.shortcuts + 1] = def
	end

	function api.register_flag(name, default)
		if host.flags[name] == nil then
			host.flags[name] = default
		end
	end

	function api.get_flag(name)
		return host.flags[name]
	end

	function api.set_flag(name, value)
		host.flags[name] = value
	end

	-- --------------------------------------------------------------- actions
	--- Send text to the agent: new run when idle, steering when busy.
	function api.send_message(text)
		return host.runtime:send(text)
	end

	function api.abort()
		host.runtime:abort()
	end

	--- Switch model by id/fuzzy query. Returns true on success.
	function api.set_model(query)
		local m = models.get(query)
		if not m or not models.available(m, host.runtime.config.settings) then
			return false
		end
		host.runtime:set_model(m)
		return true
	end

	--- Add a note to the transcript display (not sent to the model).
	function api.append_entry(text)
		if host.ui then
			host.ui.notify(text)
		else
			io.stderr:write("[ext] " .. text .. "\n")
		end
	end

	-- ------------------------------------------------------------------- ui
	function api.notify(text, level)
		if host.ui then
			host.ui.notify(text, level)
		else
			io.stderr:write("[ext:" .. (level or "info") .. "] " .. text .. "\n")
		end
	end

	function api.set_status(text)
		if host.ui and host.ui.set_status then
			host.ui.set_status(text)
		end
	end

	--- opts: { title, options = { {label=, value=, desc=?} | "string", ... } }
	--- Returns the chosen value (or the string), nil on cancel. yields
	function api.select(opts)
		return ui_required(host, "api.select").select(opts)
	end

	--- opts: { title }. Returns bool. yields
	function api.confirm(opts)
		return ui_required(host, "api.confirm").confirm(opts)
	end

	--- opts: { title, placeholder? }. Returns text or nil. yields
	function api.input(opts)
		return ui_required(host, "api.input").input(opts)
	end

	-- ----------------------------------------------------------------- exec
	--- Run a command. argv is an array; opts: { cwd?, timeout? (secs) }.
	--- Returns { stdout, stderr, code }. yields
	function api.exec(argv, opts)
		opts = opts or {}
		local proc = loop.process.spawn({
			argv = argv,
			cwd = opts.cwd or host.runtime.cwd,
			pgroup = true,
		})
		local timer
		if opts.timeout then
			timer = loop.timer(opts.timeout * 1000, function()
				proc:terminate()
			end)
		end
		local out, err_out = {}, {}
		local t1 = loop.spawn(function()
			while true do
				local chunk = loop.read(proc.stdout)
				if not chunk then
					return
				end
				out[#out + 1] = chunk
			end
		end)
		local t2 = loop.spawn(function()
			while true do
				local chunk = loop.read(proc.stderr)
				if not chunk then
					return
				end
				err_out[#err_out + 1] = chunk
			end
		end)
		local code = proc:wait()
		t1:join()
		t2:join()
		if timer then
			timer:cancel()
		end
		proc:close()
		return { stdout = table.concat(out), stderr = table.concat(err_out), code = code }
	end

	return api
end

return api_mod
