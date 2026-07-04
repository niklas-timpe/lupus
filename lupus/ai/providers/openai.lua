-- OpenAI Chat Completions adapter (api = "openai-completions"). Because the
-- base URL comes from the model, this one adapter also serves OpenRouter,
-- Groq, Ollama, and any other compatible server.

local http = require("lupus.ai.http")
local sse = require("lupus.ai.sse")
local builder_mod = require("lupus.ai.builder")
local json = require("lupus.util.json")

local adapter = {}

local FINISH_REASONS = {
  stop = "stop", length = "length", tool_calls = "tool_use",
  content_filter = "error",
}

-- ---------------------------------------------------------------------------
-- Context -> wire format

local function convert_messages(context)
  local out = json.array({})
  if context.system_prompt and context.system_prompt ~= "" then
    out[#out + 1] = { role = "system", content = context.system_prompt }
  end
  for _, msg in ipairs(context.messages) do
    if msg.role == "user" then
      local content = msg.content
      if type(content) == "table" then
        local parts = {}
        for _, block in ipairs(content) do
          if block.type == "text" then parts[#parts + 1] = block.text end
        end
        content = table.concat(parts, "\n")
      end
      out[#out + 1] = { role = "user", content = content }
    elseif msg.role == "assistant" then
      local entry = { role = "assistant" }
      local text_parts = {}
      local tool_calls = json.array({})
      for _, block in ipairs(msg.content) do
        if block.type == "text" then
          text_parts[#text_parts + 1] = block.text
        elseif block.type == "tool_call" then
          tool_calls[#tool_calls + 1] = {
            id = block.id,
            type = "function",
            ["function"] = {
              name = block.name,
              arguments = json.encode(block.arguments),
            },
          }
        end
        -- thinking blocks don't round-trip on this API
      end
      if #text_parts > 0 then entry.content = table.concat(text_parts, "\n") end
      if #tool_calls > 0 then entry.tool_calls = tool_calls end
      if entry.content or entry.tool_calls then
        out[#out + 1] = entry
      end
    elseif msg.role == "tool_result" then
      local parts = {}
      for _, block in ipairs(msg.content) do
        if block.type == "text" then parts[#parts + 1] = block.text end
      end
      out[#out + 1] = {
        role = "tool",
        tool_call_id = msg.tool_call_id,
        content = table.concat(parts, "\n"),
      }
    end
  end
  return out
end

local function build_payload(model, context, opts)
  local payload = {
    model = model.id,
    stream = true,
    stream_options = { include_usage = true },
    messages = convert_messages(context),
  }
  local max_tokens = opts.max_tokens or model.max_tokens
  if model.provider == "openai" then
    payload.max_completion_tokens = max_tokens
  else
    payload.max_tokens = max_tokens
  end
  if context.tools and #context.tools > 0 then
    local tools = json.array({})
    for _, tool in ipairs(context.tools) do
      tools[#tools + 1] = {
        type = "function",
        ["function"] = {
          name = tool.name,
          description = tool.description,
          parameters = tool.parameters,
        },
      }
    end
    payload.tools = tools
  end
  local thinking = opts.thinking
  if thinking and thinking ~= "off" and model.reasoning and model.provider == "openai" then
    payload.reasoning_effort = (thinking == "minimal") and "low" or thinking
  end
  if opts.temperature then payload.temperature = opts.temperature end
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

--- yields
function adapter.stream(model, context, opts, emit, ctrl)
  local b = builder_mod.new(model, emit)

  local payload = build_payload(model, context, opts)
  local headers = { ["content-type"] = "application/json" }
  if opts.api_key and opts.api_key ~= "" then
    headers["authorization"] = "Bearer " .. opts.api_key
  end
  local resp, err = http.request{
    url = model.base_url .. "/chat/completions",
    method = "POST",
    headers = headers,
    body = json.encode(payload),
  }
  if not resp then
    b:start()
    b:fail(err)
    return
  end
  ctrl.on_abort = function() resp:close() end

  if resp.status < 200 or resp.status >= 300 then
    local body = resp:read_all()
    b:start()
    b:fail(("API error %d: %s"):format(resp.status, provider_error(body)))
    return
  end

  b:start()
  local parser = sse.new()
  local stop_reason = "stop"
  local current_tool_index = nil
  local done = false

  while true do
    local chunk = resp:read()
    if not chunk then break end
    if ctrl.aborted then
      resp:close()
      b:fail("aborted by user", "aborted")
      return
    end
    for _, event in ipairs(parser:feed(chunk)) do
      if event.data == "[DONE]" then
        done = true
        goto next_event
      end
      do
        local data = json.decode(event.data)
        if type(data) ~= "table" then goto next_event end

        if type(data.usage) == "table" then
          local u = data.usage
          local details = type(u.prompt_tokens_details) == "table" and u.prompt_tokens_details or {}
          local cached = details.cached_tokens or 0
          b:set_usage{
            input = math.max(0, (u.prompt_tokens or 0) - cached),
            output = u.completion_tokens or 0,
            cache_read = cached,
          }
        end

        local choice = type(data.choices) == "table" and data.choices[1]
        if choice then
          local delta = type(choice.delta) == "table" and choice.delta or {}
          local reasoning = delta.reasoning_content or delta.reasoning
          if type(reasoning) == "string" then
            b:thinking_delta(reasoning)
          end
          if type(delta.content) == "string" then
            b:text_delta(delta.content)
          end
          if type(delta.tool_calls) == "table" then
            for _, tc in ipairs(delta.tool_calls) do
              local idx = tc.index or 0
              if idx ~= current_tool_index then
                current_tool_index = idx
                local fn = type(tc["function"]) == "table" and tc["function"] or {}
                b:tool_start(tc.id or ("call_" .. idx), fn.name or "")
              end
              local fn = type(tc["function"]) == "table" and tc["function"] or {}
              if type(fn.arguments) == "string" then
                b:tool_delta(fn.arguments)
              end
            end
          end
          if choice.finish_reason and choice.finish_reason ~= json.null then
            stop_reason = FINISH_REASONS[choice.finish_reason] or "stop"
          end
        end
      end
      ::next_event::
    end
    if done then break end
  end

  if not b.finished then
    if done then
      b:finish(stop_reason)
    elseif ctrl.aborted then
      b:fail("aborted by user", "aborted")
    else
      b:fail("stream ended unexpectedly")
    end
  end
end

adapter._convert_messages = convert_messages
adapter._build_payload = build_payload

return adapter
