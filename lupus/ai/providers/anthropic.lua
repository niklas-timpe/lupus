-- Anthropic Messages API adapter (api = "anthropic-messages").
-- Translates the unified context to the /v1/messages wire format and the
-- SSE response back into unified builder events.

local http = require("lupus.ai.http")
local sse = require("lupus.ai.sse")
local builder_mod = require("lupus.ai.builder")
local types = require("lupus.ai.types")
local json = require("lupus.util.json")

local adapter = {}

local THINKING_BUDGETS = { minimal = 1024, low = 4096, medium = 10000, high = 24576 }

local STOP_REASONS = {
	end_turn = "stop",
	stop_sequence = "stop",
	max_tokens = "length",
	tool_use = "tool_use",
	refusal = "error",
}

-- ---------------------------------------------------------------------------
-- Context -> wire format

local function convert_blocks(blocks)
	local out = json.array({})
	for _, block in ipairs(blocks) do
		if block.type == "text" then
			out[#out + 1] = { type = "text", text = block.text }
		elseif block.type == "thinking" then
			if block.signature and block.signature ~= "" then
				out[#out + 1] = { type = "thinking", thinking = block.thinking, signature = block.signature }
			end
		-- Unsigned thinking can't round-trip; drop it.
		elseif block.type == "tool_call" then
			out[#out + 1] = {
				type = "tool_use",
				id = block.id,
				name = block.name,
				input = next(block.arguments) and block.arguments or json.decode("{}"),
			}
		end
	end
	return out
end

local function convert_messages(messages)
	local out = json.array({})
	local pending_results = nil

	local function flush_results()
		if pending_results then
			out[#out + 1] = { role = "user", content = pending_results }
			pending_results = nil
		end
	end

	for _, msg in ipairs(messages) do
		if msg.role == "tool_result" then
			-- Consecutive tool results share one user turn.
			pending_results = pending_results or json.array({})
			local content = json.array({})
			for _, block in ipairs(msg.content) do
				if block.type == "text" then
					content[#content + 1] = { type = "text", text = block.text }
				end
			end
			if #content == 0 then
				content[#content + 1] = { type = "text", text = "" }
			end
			pending_results[#pending_results + 1] = {
				type = "tool_result",
				tool_use_id = msg.tool_call_id,
				content = content,
				is_error = msg.is_error or false,
			}
		elseif msg.role == "user" then
			flush_results()
			local content
			if type(msg.content) == "string" then
				content = json.array({ { type = "text", text = msg.content } })
			else
				content = convert_blocks(msg.content)
			end
			out[#out + 1] = { role = "user", content = content }
		elseif msg.role == "assistant" then
			flush_results()
			local content = convert_blocks(msg.content)
			if #content > 0 then
				out[#out + 1] = { role = "assistant", content = content }
			end
		end
	end
	flush_results()

	-- Prompt caching: mark the last content block of the last message.
	local last = out[#out]
	if last and type(last.content) == "table" and #last.content > 0 then
		last.content[#last.content].cache_control = { type = "ephemeral" }
	end
	return out
end

local function build_payload(model, context, opts)
	local payload = {
		model = model.id,
		max_tokens = opts.max_tokens or model.max_tokens,
		stream = true,
		messages = convert_messages(context.messages),
	}
	if context.system_prompt and context.system_prompt ~= "" then
		payload.system = json.array({
			{ type = "text", text = context.system_prompt, cache_control = { type = "ephemeral" } },
		})
	end
	if context.tools and #context.tools > 0 then
		local tools = json.array({})
		for _, tool in ipairs(context.tools) do
			tools[#tools + 1] = {
				name = tool.name,
				description = tool.description,
				input_schema = tool.parameters,
			}
		end
		payload.tools = tools
	end
	local thinking = opts.thinking
	if thinking and thinking ~= "off" and model.reasoning then
		local budget = THINKING_BUDGETS[thinking] or THINKING_BUDGETS.medium
		if budget < payload.max_tokens then
			payload.thinking = { type = "enabled", budget_tokens = budget }
		end
	end
	if opts.temperature then
		payload.temperature = opts.temperature
	end
	return payload
end

-- ---------------------------------------------------------------------------

local function provider_error(body)
	local parsed = json.decode(body)
	if type(parsed) == "table" and type(parsed.error) == "table" and parsed.error.message then
		return parsed.error.message
	end
	return body ~= "" and body:sub(1, 500) or "empty error response"
end

--- Run one streaming request. Emits builder events via `emit`; failures
--- become error events, never raises. yields
function adapter.stream(model, context, opts, emit, ctrl)
	local b = builder_mod.new(model, emit)

	local payload = build_payload(model, context, opts)
	local resp, err = http.request({
		url = model.base_url .. "/v1/messages",
		method = "POST",
		headers = {
			["content-type"] = "application/json",
			["x-api-key"] = opts.api_key or "",
			["anthropic-version"] = "2023-06-01",
		},
		body = json.encode(payload),
	})
	if not resp then
		b:start()
		b:fail(err)
		return
	end
	ctrl.on_abort = function()
		resp:close()
	end

	if resp.status < 200 or resp.status >= 300 then
		local body = resp:read_all()
		b:start()
		b:fail(("API error %d: %s"):format(resp.status, provider_error(body)))
		return
	end

	b:start()
	local parser = sse.new()
	local stop_reason = "stop"

	while true do
		local chunk = resp:read()
		if not chunk then
			break
		end
		if ctrl.aborted then
			resp:close()
			b:fail("aborted by user", "aborted")
			return
		end
		for _, event in ipairs(parser:feed(chunk)) do
			local data = json.decode(event.data)
			if type(data) ~= "table" then
				goto next_event
			end
			local kind = data.type or event.event

			if kind == "message_start" then
				local u = data.message and data.message.usage or {}
				b:set_usage({
					input = u.input_tokens,
					output = u.output_tokens,
					cache_read = u.cache_read_input_tokens,
					cache_write = u.cache_creation_input_tokens,
				})
			elseif kind == "content_block_start" then
				local cb = data.content_block or {}
				if cb.type == "tool_use" then
					b:tool_start(cb.id, cb.name)
				end
			-- text/thinking blocks open lazily on their first delta.
			elseif kind == "content_block_delta" then
				local delta = data.delta or {}
				if delta.type == "text_delta" then
					b:text_delta(delta.text or "")
				elseif delta.type == "thinking_delta" then
					b:thinking_delta(delta.thinking or "")
				elseif delta.type == "input_json_delta" then
					b:tool_delta(delta.partial_json or "")
				elseif delta.type == "signature_delta" then
					b:thinking_signature(delta.signature or "")
				end
			elseif kind == "content_block_stop" then
				b:close_block()
			elseif kind == "message_delta" then
				if data.delta and data.delta.stop_reason then
					stop_reason = STOP_REASONS[data.delta.stop_reason] or "stop"
				end
				if data.usage and data.usage.output_tokens then
					b:set_usage({ output = data.usage.output_tokens })
				end
			elseif kind == "message_stop" then
				b:finish(stop_reason)
			elseif kind == "error" then
				local msg = type(data.error) == "table" and data.error.message or event.data
				b:fail("API stream error: " .. tostring(msg))
				resp:close()
				return
			end
			::next_event::
		end
	end

	if not b.finished then
		if ctrl.aborted then
			b:fail("aborted by user", "aborted")
		else
			b:fail("stream ended unexpectedly")
		end
	end
end

adapter._convert_messages = convert_messages -- exposed for tests
adapter._build_payload = build_payload

return adapter
