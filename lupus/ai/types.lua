-- Message and usage constructors for the unified LLM layer. Everything is a
-- plain table with a `role`/`type` discriminator; these helpers keep the
-- shapes consistent across providers, the agent, and session files.
--
-- Content blocks:
--   { type = "text", text = s }
--   { type = "thinking", thinking = s, signature = s? }
--   { type = "tool_call", id = s, name = s, arguments = {...} }
--
-- Messages:
--   { role = "user", content = string | {blocks}, timestamp }
--   { role = "assistant", content = {blocks}, model, provider, usage,
--     stop_reason = "stop"|"length"|"tool_use"|"error"|"aborted",
--     error_message?, timestamp }
--   { role = "tool_result", tool_call_id, tool_name, content = {blocks},
--     is_error, details?, timestamp }

local types = {}

function types.text_block(s)
	return { type = "text", text = s }
end

function types.thinking_block(s)
	return { type = "thinking", thinking = s }
end

function types.tool_call_block(id, name, arguments)
	return { type = "tool_call", id = id, name = name, arguments = arguments or {} }
end

function types.user(content)
	return { role = "user", content = content, timestamp = os.time() }
end

--- Fresh assistant message that a stream accumulates into.
function types.assistant_new(model)
	return {
		role = "assistant",
		content = {},
		model = model.id,
		provider = model.provider,
		usage = types.usage(),
		stop_reason = nil,
		timestamp = os.time(),
	}
end

--- Terminal assistant message for failures outside/after streaming.
function types.assistant_error(model, error_message, stop_reason)
	local msg = types.assistant_new(model)
	msg.stop_reason = stop_reason or "error"
	msg.error_message = error_message
	return msg
end

function types.tool_result(tool_call_id, tool_name, content, is_error, details)
	return {
		role = "tool_result",
		tool_call_id = tool_call_id,
		tool_name = tool_name,
		content = content,
		is_error = is_error or false,
		details = details,
		timestamp = os.time(),
	}
end

function types.usage()
	return {
		input = 0,
		output = 0,
		cache_read = 0,
		cache_write = 0,
		total_tokens = 0,
		cost = { input = 0, output = 0, cache_read = 0, cache_write = 0, total = 0 },
	}
end

--- Recompute usage.cost from a model's $/Mtok rates. Mutates and returns.
function types.calculate_cost(model, usage)
	local rates = model.cost or {}
	local M = 1e6
	local c = usage.cost
	c.input = (rates.input or 0) / M * usage.input
	c.output = (rates.output or 0) / M * usage.output
	c.cache_read = (rates.cache_read or 0) / M * usage.cache_read
	c.cache_write = (rates.cache_write or 0) / M * usage.cache_write
	c.total = c.input + c.output + c.cache_read + c.cache_write
	return usage
end

--- Concatenated text of a message's text blocks (or its plain string).
function types.message_text(msg)
	if type(msg.content) == "string" then
		return msg.content
	end
	local parts = {}
	for _, block in ipairs(msg.content or {}) do
		if block.type == "text" then
			parts[#parts + 1] = block.text
		end
	end
	return table.concat(parts, "\n")
end

--- Tool-call blocks of an assistant message.
function types.tool_calls(msg)
	local out = {}
	for _, block in ipairs(msg.content or {}) do
		if block.type == "tool_call" then
			out[#out + 1] = block
		end
	end
	return out
end

return types
