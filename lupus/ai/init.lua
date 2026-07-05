-- Unified LLM streaming API.
--
--   local stream = ai.stream(model, context, opts)
--   for ev in stream:events() do ... end       -- unified event protocol
--   local message = stream:result()            -- final assistant message
--   stream:abort()
--
--   local message = ai.complete(model, context, opts)  -- non-streaming use
--
-- context = { system_prompt?, messages = {...}, tools? } where each tool is
-- { name, description, parameters = <JSON-schema table> }.
-- opts = { api_key?, max_tokens?, temperature?, thinking? = "off"|"minimal"|
--          "low"|"medium"|"high" }.
--
-- Once a stream exists, failures are never raised: the terminal message has
-- stop_reason "error"/"aborted" and error_message set.

local loop = require("lupus.loop")
local channel = require("lupus.loop.channel")
local types = require("lupus.ai.types")
local log = require("lupus.util.log")

local ai = {}

ai.types = types

local adapters = {
	["anthropic-messages"] = function()
		return require("lupus.ai.providers.anthropic")
	end,
	["openai-completions"] = function()
		return require("lupus.ai.providers.openai")
	end,
}

--- Register a custom wire adapter (extensions can add providers).
function ai.register_api(name, adapter)
	adapters[name] = function()
		return adapter
	end
end

local Stream = {}
Stream.__index = Stream

--- Iterator over events; stops after the terminal done/error event.
function Stream:events()
	return function()
		return (self.ch:recv())
	end
end

--- Drain remaining events and return the final assistant message. yields
function Stream:result()
	while not self.final do
		local ev = self.ch:recv()
		if not ev then
			break
		end
	end
	return self.final
end

--- Abort the request: kills the transport; the stream terminates with a
--- stop_reason = "aborted" message.
function Stream:abort()
	self.ctrl.aborted = true
	if self.ctrl.on_abort then
		pcall(self.ctrl.on_abort)
	end
end

--- Start a streaming request. Must be called from inside the event loop.
function ai.stream(model, context, opts)
	opts = opts or {}
	local load_adapter = adapters[model.api]
	local self = setmetatable({
		ch = channel.new(),
		ctrl = { aborted = false, on_abort = nil },
		final = nil,
	}, Stream)

	self.task = loop.spawn(function()
		local function emit(ev)
			if ev.type == "done" or ev.type == "error" then
				self.final = ev.message
			end
			self.ch:send(ev)
		end
		if not load_adapter then
			local msg = types.assistant_error(model, "no adapter for api: " .. tostring(model.api))
			emit({ type = "start", partial = msg })
			emit({ type = "error", message = msg, partial = msg })
		else
			local adapter = load_adapter()
			local ok, err = pcall(adapter.stream, model, context, opts, emit, self.ctrl)
			if not ok and not self.final then
				log.error("adapter crashed: %s", tostring(err))
				local msg = types.assistant_error(model, "internal adapter error: " .. tostring(err))
				emit({ type = "error", message = msg, partial = msg })
			elseif not ok then
				log.error("adapter error after finish: %s", tostring(err))
			end
		end
		self.ch:close()
	end)
	return self
end

--- Blocking (yielding) completion: stream and return the final message.
function ai.complete(model, context, opts)
	return ai.stream(model, context, opts):result()
end

return ai
