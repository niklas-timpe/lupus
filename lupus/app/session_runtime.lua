-- Session runtime: the frontend-agnostic core that every mode (interactive
-- TUI, print) drives. It owns the agent, the persisted session, model
-- selection, and a single event stream that fans out agent events plus
-- runtime-level ones:
--
--   ...all agent events...
--   model_changed { model }
--   session_named { name }
--
-- Extensions hook in here too, so every frontend gets them for free.

local agent_mod = require("lupus.agent")
local models = require("lupus.ai.models")
local session_mod = require("lupus.session")
local prompt_mod = require("lupus.prompt")
local tools_mod = require("lupus.tools")
local config_mod = require("lupus.config")
local events_mod = require("lupus.ext.events")
local fs = require("lupus.util.fs")
local log = require("lupus.util.log")

local Runtime = {}
Runtime.__index = Runtime

local runtime_mod = { Runtime = Runtime }

--- opts (from CLI): model, session ("new"|"continue"|"resume"|"none"),
--- session_path (explicit file), system_prompt_file, no_context_files.
function runtime_mod.new(opts)
	opts = opts or {}
	local cwd = opts.cwd or fs.cwd()
	local cfg = config_mod.load(cwd)
	models.load(cfg.settings)

	local self = setmetatable({
		cwd = cwd,
		config = cfg,
		opts = opts,
		listeners = {},
		editor_history = {},
		hub = events_mod.new(),
		host = nil, -- extension host, built in load_extensions
	}, Runtime)

	-- Session
	if opts.session == "none" then
		self.session = session_mod.in_memory(cwd)
	elseif opts.session_path then
		self.session = assert(session_mod.open(opts.session_path))
	elseif opts.session == "continue" then
		self.session = session_mod.continue_recent(cwd, cfg.dirs.data) or session_mod.create(cwd, cfg.dirs.data)
	else
		self.session = session_mod.create(cwd, cfg.dirs.data)
	end

	-- Model: CLI > session > settings > first available.
	local model
	if opts.model then
		model = models.get(opts.model)
		if not model then
			error(("unknown model: %s (try --list-models)"):format(opts.model), 0)
		end
	end
	model = model
		or (self.session:model_id() and models.get(self.session:model_id()))
		or (cfg.settings.default_model and models.get(cfg.settings.default_model))
		or models.default(cfg.settings)
		-- No key anywhere: start anyway on the first registered model. The
		-- frontend notices the missing key and offers /login.
		or models.list()[1]
	if not model then
		error("no models registered — check providers/models in settings.json", 0)
	end
	self.model = model

	-- System prompt
	local custom
	if opts.system_prompt_file then
		custom = assert(fs.read_file(opts.system_prompt_file))
	end
	self.system_prompt = prompt_mod.build({
		cwd = cwd,
		config_dir = cfg.dirs.config,
		custom = custom,
		no_context_files = opts.no_context_files,
	})

	-- Agent, with extension hooks wired into the tool pipeline.
	self.agent = agent_mod.Agent.new({
		model = model,
		system_prompt = self.system_prompt,
		tools = tools_mod.builtin(),
		cwd = cwd,
		thinking = cfg.settings.thinking or "off",
		api_key = function(m)
			return models.api_key(m, cfg.settings)
		end,
		hooks = {
			before_tool = function(tc, args)
				return self.hub:veto("tool_call", {
					id = tc.id,
					tool_name = tc.name,
					arguments = args,
				})
			end,
			after_tool = function(tc, result_msg)
				local replaced = self.hub:transform("tool_result", result_msg, {
					id = tc.id,
					tool_name = tc.name,
				})
				return replaced
			end,
		},
	})
	self.agent.messages = self.session:messages()

	-- Persistence + fan-out (frontend listeners and the extension hub).
	self.agent:subscribe(function(ev)
		if ev.type == "message_end" then
			self.session:append_message(ev.message)
		end
		self:emit(ev)
		self.hub:notify(ev.type, ev)
	end)

	return self
end

--- Load extensions. Called by the frontend once its UI (if any) exists.
--- ui: { notify, set_status, select, confirm, input } or nil (print mode).
--- yields (trust dialog)
function Runtime:load_extensions(ui)
	local commands = self.commands
	if not commands then
		commands = require("lupus.commands").new()
		self.commands = commands
	end
	self.host = {
		hub = self.hub,
		runtime = self,
		ui = ui,
		commands = commands,
		flags = {},
		shortcuts = {},
	}
	local loaded = require("lupus.ext.loader").load_all(self.host, {
		cli_paths = self.opts.extensions,
		no_discovery = self.opts.no_extensions,
	})
	self.hub:notify("session_start", { session_id = self.session.id, loaded = loaded })
	return loaded
end

function Runtime:shutdown()
	self.hub:notify("session_shutdown", {})
end

-- ---------------------------------------------------------------------------

function Runtime:subscribe(fn)
	self.listeners[#self.listeners + 1] = fn
	return function()
		for i, f in ipairs(self.listeners) do
			if f == fn then
				table.remove(self.listeners, i)
				return
			end
		end
	end
end

function Runtime:emit(ev)
	for _, fn in ipairs(self.listeners) do
		local ok, err = pcall(fn, ev)
		if not ok then
			log.error("runtime listener failed (%s): %s", ev.type, tostring(err))
		end
	end
end

--- Send user input: starts a run when idle, steers when busy. Extensions
--- get a shot first (user_input transform); on a fresh run they can extend
--- the system prompt, inject context, and hide tools from the model's tool
--- list for the run (before_agent_start: { system_prompt_append?,
--- inject_message?, hidden_tools? = {name, ...} }). Recomputed every fresh
--- run, so a hide/append lasts only as long as the condition that produced
--- it holds true.
function Runtime:send(text)
	local transformed, handled = self.hub:transform("user_input", text, {
		running = self.agent.is_running,
	})
	if handled then
		return "handled"
	end
	text = transformed

	if self.agent.is_running then
		self.agent:steer(text)
		return "steered"
	end

	local contributions = self.hub:collect("before_agent_start", {})
	local appends = {}
	local hidden_tools = nil
	for _, c in ipairs(contributions) do
		if c.system_prompt_append then
			appends[#appends + 1] = c.system_prompt_append
		end
		if c.inject_message then
			local injected = require("lupus.ai.types").user(c.inject_message)
			self.agent.messages[#self.agent.messages + 1] = injected
			self.session:append_message(injected)
		end
		if c.hidden_tools then
			hidden_tools = hidden_tools or {}
			for _, name in ipairs(c.hidden_tools) do
				hidden_tools[name] = true
			end
		end
	end
	self.agent.system_prompt = self.system_prompt
	if #appends > 0 then
		self.agent.system_prompt = self.system_prompt .. "\n\n" .. table.concat(appends, "\n\n")
	end
	self.agent.hidden_tools = hidden_tools

	self.agent:prompt(text)
	return "started"
end

function Runtime:abort()
	self.agent:abort()
end

function Runtime:is_running()
	return self.agent.is_running
end

--- True when the current model has a usable API key (or needs none).
function Runtime:model_available()
	return models.available(self.model, self.config.settings)
end

--- Re-run model resolution (CLI > session > default_model) against the
--- current registry. Extensions can register providers and models after the
--- constructor resolved the model; called by frontends once they're loaded,
--- so a persisted choice like "edenai/…" wins over the builtin fallback.
function Runtime:reresolve_model()
	local wanted = self.opts.model or self.session:model_id() or self.config.settings.default_model
	if not wanted then
		return
	end
	local m = models.get(wanted)
	if m and m ~= self.model then
		self:set_model(m)
	end
end

--- Store an API key for a provider: persists to the global settings file
--- and applies to the running session immediately (the agent resolves keys
--- through config.settings on every request).
function Runtime:set_api_key(provider, key)
	local keys = self.config.settings.api_keys
	if not keys then
		keys = {}
		self.config.settings.api_keys = keys
	end
	keys[provider] = key
	return config_mod.update_global(function(settings)
		settings.api_keys = settings.api_keys or {}
		settings.api_keys[provider] = key
	end)
end

--- opts.persist: remember this choice as default_model in the global
--- settings (used for explicit user switches, not automatic resolution).
function Runtime:set_model(model, opts)
	self.model = model
	self.agent.model = model
	self.session:append_model(model.id)
	if opts and opts.persist then
		local key = model.provider .. "/" .. model.id
		if self.config.settings.default_model ~= key then
			self.config.settings.default_model = key
			config_mod.update_global(function(s)
				s.default_model = key
			end)
		end
	end
	self:emit({ type = "model_changed", model = model })
end

function Runtime:set_thinking(level)
	self.agent.thinking = level
end

function Runtime:name_session(name)
	self.session:set_name(name)
	self:emit({ type = "session_named", name = name })
end

--- Replace the current session with a fresh one (same config/model).
function Runtime:new_session()
	if self.opts.session == "none" then
		self.session = session_mod.in_memory(self.cwd)
	else
		self.session = session_mod.create(self.cwd, self.config.dirs.data)
	end
	self.agent.messages = {}
	self.session:append_model(self.model.id)
end

--- Rough context usage estimate (chars/4) against the model window.
function Runtime:context_usage()
	local chars = #self.system_prompt
	for _, msg in ipairs(self.agent.messages) do
		local c = msg.content
		if type(c) == "string" then
			chars = chars + #c
		elseif type(c) == "table" then
			for _, block in ipairs(c) do
				chars = chars + #(block.text or block.thinking or "")
				if block.arguments then
					chars = chars + 64
				end
			end
		end
	end
	local tokens = math.floor(chars / 4)
	return {
		tokens = tokens,
		window = self.model.context_window,
		percent = math.min(100, math.floor(tokens * 100 / self.model.context_window)),
	}
end

--- Total cost of the current transcript.
function Runtime:total_cost()
	local total = 0
	for _, msg in ipairs(self.agent.messages) do
		if msg.role == "assistant" and msg.usage and msg.usage.cost then
			total = total + (msg.usage.cost.total or 0)
		end
	end
	return total
end

return runtime_mod
