-- The agent runtime: drives the prompt → LLM → tool-execution loop and
-- emits events that frontends and extensions subscribe to.
--
-- Events (all carry `type`):
--   agent_start / agent_end { messages }
--   turn_start / turn_end { message, tool_results }
--   message_start { message } / message_update { message, event } /
--   message_end { message }
--   tool_start { id, name, args, tool } / tool_update { id, name, partial } /
--   tool_end { id, name, result_message }
--
-- Listeners run inside the agent's task, in subscription order, and may
-- yield (extension dialogs pause the agent — deliberately).
--
-- Tools are plain tables:
--   { name, label, description, parameters = <schema node>,
--     execute = function(args, ctx) -> string | { content, details? },
--     render_call?, render_result?, hidden? }
-- execute raises on failure; the loop turns that into an error tool result
-- the model sees. ctx = { cwd, tool_call_id, aborted = fn() -> bool,
-- on_update = fn(partial_text) }.

local loop = require("lupus.loop")
local ai = require("lupus.ai")
local types = require("lupus.ai.types")
local schema = require("lupus.schema")
local log = require("lupus.util.log")

local Agent = {}
Agent.__index = Agent

local agent_mod = { Agent = Agent }

--- opts: model, system_prompt, tools (array), cwd, api_key (string or
--- fn(model)), thinking, max_tokens, hooks = { before_tool, after_tool,
--- transform_context, before_turn }.
function Agent.new(opts)
  local self = setmetatable({
    model = assert(opts.model, "Agent.new requires a model"),
    system_prompt = opts.system_prompt or "",
    cwd = opts.cwd or ".",
    api_key = opts.api_key,
    thinking = opts.thinking or "off",
    max_tokens = opts.max_tokens,
    hooks = opts.hooks or {},
    messages = {},
    listeners = {},
    steering = {},
    follow_ups = {},
    is_running = false,
    streaming_message = nil,
    current_stream = nil,
    abort_flag = { aborted = false },
    run_task = nil,
    tools = {},
    tools_by_name = {},
  }, Agent)
  self:set_tools(opts.tools or {})
  return self
end

function Agent:set_tools(tools)
  self.tools = tools
  self.tools_by_name = {}
  for _, tool in ipairs(tools) do
    self.tools_by_name[tool.name] = tool
  end
end

function Agent:subscribe(fn)
  self.listeners[#self.listeners + 1] = fn
  return function()
    for i, f in ipairs(self.listeners) do
      if f == fn then table.remove(self.listeners, i) return end
    end
  end
end

-- May yield (listeners can block on dialogs).
function Agent:emit(type_, extra)
  local ev = extra or {}
  ev.type = type_
  for _, fn in ipairs(self.listeners) do
    local ok, err = pcall(fn, ev)
    if not ok then log.error("agent listener failed (%s): %s", type_, tostring(err)) end
  end
end

-- ---------------------------------------------------------------------------
-- Driving

local function to_user_message(m)
  if type(m) == "string" then return types.user(m) end
  return m
end

--- Queue a message to be injected after the current assistant turn.
function Agent:steer(message)
  self.steering[#self.steering + 1] = to_user_message(message)
end

--- Queue a message delivered only once the agent would otherwise stop.
function Agent:follow_up(message)
  self.follow_ups[#self.follow_ups + 1] = to_user_message(message)
end

function Agent:abort()
  if not self.is_running then return end
  self.abort_flag.aborted = true
  if self.current_stream then self.current_stream:abort() end
end

--- Wait until the current run (if any) finishes. yields
function Agent:wait_idle()
  if self.run_task then self.run_task:join() end
end

--- Start a run with a user prompt (string or message). Errors if already
--- running. The run happens in its own task; subscribe for events.
function Agent:prompt(message)
  assert(not self.is_running, "agent is already running")
  local msg = to_user_message(message)
  self.is_running = true
  self.abort_flag = { aborted = false }
  self.run_task = loop.spawn(function()
    local ok, err = pcall(self.run, self, { msg })
    self.is_running = false
    self.streaming_message = nil
    self.current_stream = nil
    if not ok then
      log.error("agent run crashed: %s", tostring(err))
      self:emit("agent_end", { messages = {}, error = tostring(err) })
    end
  end)
  return self.run_task
end

-- ---------------------------------------------------------------------------
-- The loop

local function drain(queue)
  local out = {}
  for i, m in ipairs(queue) do out[i] = m end
  for i = #queue, 1, -1 do queue[i] = nil end
  return out
end

function Agent:run(pending)
  local new_messages = {}
  self:emit("agent_start")

  while true do
    -- Turn loop: keep going while there are tool calls or injected input.
    while true do
      self:emit("turn_start")

      for _, msg in ipairs(pending) do
        self.messages[#self.messages + 1] = msg
        new_messages[#new_messages + 1] = msg
        self:emit("message_start", { message = msg })
        self:emit("message_end", { message = msg })
      end
      pending = {}

      local assistant = self:stream_assistant()
      new_messages[#new_messages + 1] = assistant

      if assistant.stop_reason == "error" or assistant.stop_reason == "aborted" then
        self:emit("turn_end", { message = assistant, tool_results = {} })
        self:emit("agent_end", { messages = new_messages })
        return
      end

      local tool_calls = types.tool_calls(assistant)
      local results = {}
      if #tool_calls > 0 then
        results = self:execute_tools(tool_calls)
        for _, r in ipairs(results) do
          new_messages[#new_messages + 1] = r
        end
      end
      self:emit("turn_end", { message = assistant, tool_results = results })

      if self.abort_flag.aborted then
        self:emit("agent_end", { messages = new_messages })
        return
      end

      pending = drain(self.steering)
      if #tool_calls == 0 and #pending == 0 then break end
    end

    pending = drain(self.follow_ups)
    if #pending == 0 then break end
  end

  self:emit("agent_end", { messages = new_messages })
end

-- ---------------------------------------------------------------------------
-- LLM step

--- Tools in wire form (JSON schema), cached per tool table.
function Agent:wire_tools()
  local out = {}
  for _, tool in ipairs(self.tools) do
    if not tool._wire_schema then
      tool._wire_schema = schema.to_json_schema(tool.parameters)
    end
    out[#out + 1] = {
      name = tool.name,
      description = tool.description,
      parameters = tool._wire_schema,
    }
  end
  return out
end

function Agent:resolve_api_key()
  if type(self.api_key) == "function" then return self.api_key(self.model) end
  return self.api_key
end

function Agent:stream_assistant()
  local messages = self.messages
  if self.hooks.transform_context then
    local ok, transformed = pcall(self.hooks.transform_context, messages)
    if ok and transformed then messages = transformed end
  end

  local context = {
    system_prompt = self.system_prompt,
    messages = messages,
    tools = self:wire_tools(),
  }

  local stream = ai.stream(self.model, context, {
    api_key = self:resolve_api_key(),
    thinking = self.thinking,
    max_tokens = self.max_tokens,
  })
  self.current_stream = stream

  local started = false
  for ev in stream:events() do
    if not started then
      started = true
      self.streaming_message = ev.partial
      self:emit("message_start", { message = ev.partial })
    end
    if ev.type ~= "start" and ev.type ~= "done" and ev.type ~= "error" then
      self.streaming_message = ev.partial
      self:emit("message_update", { message = ev.partial, event = ev })
    end
  end

  local final = stream:result()
  self.current_stream = nil
  self.streaming_message = nil
  self.messages[#self.messages + 1] = final
  self:emit("message_end", { message = final })
  return final
end

-- ---------------------------------------------------------------------------
-- Tool execution (sequential: file mutations stay ordered and the UI reads
-- top to bottom; parallelism can be added per-tool later without breaking
-- the tool contract).

local function error_result(tc, message)
  return types.tool_result(tc.id, tc.name,
    { types.text_block(message) }, true)
end

local function normalize_result(tc, raw)
  if type(raw) == "string" then
    return types.tool_result(tc.id, tc.name, { types.text_block(raw) }, false)
  end
  if type(raw) ~= "table" then
    return types.tool_result(tc.id, tc.name, { types.text_block(tostring(raw or "")) }, false)
  end
  local content = raw.content
  if type(content) == "string" then
    content = { types.text_block(content) }
  elseif type(content) ~= "table" then
    content = { types.text_block("") }
  end
  return types.tool_result(tc.id, tc.name, content, raw.is_error or false, raw.details)
end

function Agent:execute_tools(tool_calls)
  local results = {}
  for _, tc in ipairs(tool_calls) do
    local result_msg

    if self.abort_flag.aborted then
      result_msg = error_result(tc, "Operation aborted by user")
    else
      result_msg = self:execute_one(tc)
    end

    results[#results + 1] = result_msg
    self.messages[#self.messages + 1] = result_msg
    self:emit("message_start", { message = result_msg })
    self:emit("message_end", { message = result_msg })
  end
  return results
end

function Agent:execute_one(tc)
  local tool = self.tools_by_name[tc.name]
  if not tool then
    return error_result(tc, ("Unknown tool: %s"):format(tc.name))
  end

  local ok_args, args = schema.validate(tool.parameters, tc.arguments)
  if not ok_args then
    return error_result(tc, ("Invalid arguments for %s: %s"):format(tc.name, args))
  end

  if self.hooks.before_tool then
    local hook_ok, verdict = pcall(self.hooks.before_tool, tc, args)
    if hook_ok and type(verdict) == "table" and verdict.block then
      return error_result(tc, "Tool execution blocked: " .. (verdict.reason or "no reason given"))
    end
  end

  self:emit("tool_start", { id = tc.id, name = tc.name, args = args, tool = tool })

  local ctx = {
    cwd = self.cwd,
    tool_call_id = tc.id,
    aborted = function() return self.abort_flag.aborted end,
    on_update = function(partial)
      self:emit("tool_update", { id = tc.id, name = tc.name, partial = partial })
    end,
  }

  local ok, raw = pcall(tool.execute, args, ctx)
  local result_msg
  if ok then
    result_msg = normalize_result(tc, raw)
  else
    result_msg = error_result(tc, tostring(raw))
  end

  if self.hooks.after_tool then
    local hook_ok, replacement = pcall(self.hooks.after_tool, tc, result_msg)
    if hook_ok and type(replacement) == "table" and replacement.role == "tool_result" then
      result_msg = replacement
    end
  end

  self:emit("tool_end", { id = tc.id, name = tc.name, result_message = result_msg })
  return result_msg
end

return agent_mod
