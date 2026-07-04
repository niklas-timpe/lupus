package.path = "./tests/?.lua;" .. package.path
local loop = require("lupus.loop")
local agent_mod = require("lupus.agent")
local schema = require("lupus.schema")
local fake = require("helpers.fake_provider")

fake.install()

local echo_tool = {
  name = "echo",
  label = "Echo",
  description = "Echo back the input",
  parameters = schema.object{
    value = schema.string{ desc = "Value to echo", required = true },
  },
  execute = function(args)
    return "echo: " .. args.value
  end,
}

local boom_tool = {
  name = "boom",
  label = "Boom",
  description = "Always fails",
  parameters = schema.object{},
  execute = function()
    error("kaboom")
  end,
}

local function run_agent(scripts, opts)
  opts = opts or {}
  local model = fake.model(scripts)
  local agent = agent_mod.Agent.new{
    model = model,
    system_prompt = "test",
    tools = opts.tools or { echo_tool, boom_tool },
    cwd = "/tmp",
    hooks = opts.hooks,
  }
  local events = {}
  agent:subscribe(function(ev)
    events[#events + 1] = ev
    if opts.on_event then opts.on_event(agent, ev) end
  end)
  loop.run(function()
    agent:prompt(opts.prompt or "go")
    agent:wait_idle()
  end)
  return agent, events, model
end

local function event_types(events)
  local out = {}
  for _, ev in ipairs(events) do out[#out + 1] = ev.type end
  return out
end

describe("agent", function()
  it("runs a simple text turn", function()
    local agent, events = run_agent({ { { text = "hello!" }, stop = "stop" } })
    assert.same({
      "agent_start", "turn_start",
      "message_start", "message_end",       -- user message
      "message_start",                      -- assistant
      "message_update", "message_update", "message_update", -- text start/delta/end
      "message_end",
      "turn_end", "agent_end",
    }, event_types(events))
    assert.equals(2, #agent.messages)
    assert.equals("user", agent.messages[1].role)
    assert.equals("hello!", agent.messages[2].content[1].text)
    assert.is_false(agent.is_running)
  end)

  it("executes tool calls and feeds results back", function()
    local agent, events, model = run_agent({
      { { text = "let me check" }, { tool = { id = "t1", name = "echo", args = { value = "hi" } } }, stop = "tool_use" },
      { { text = "done" }, stop = "stop" },
    })
    -- transcript: user, assistant(tool), tool_result, assistant(text)
    assert.equals(4, #agent.messages)
    local result = agent.messages[3]
    assert.equals("tool_result", result.role)
    assert.equals("t1", result.tool_call_id)
    assert.is_false(result.is_error)
    assert.equals("echo: hi", result.content[1].text)
    -- The second LLM call saw the tool result.
    local second_ctx = model.calls[2].context
    assert.equals("tool_result", second_ctx.messages[3].role)
    -- Events include the tool lifecycle.
    local has_tool_start, has_tool_end = false, false
    for _, ev in ipairs(events) do
      if ev.type == "tool_start" then has_tool_start = true end
      if ev.type == "tool_end" then has_tool_end = true end
    end
    assert.is_true(has_tool_start and has_tool_end)
  end)

  it("turns invalid arguments into error results", function()
    local agent = run_agent({
      { { tool = { id = "t1", name = "echo", args = { wrong = 1 } } }, stop = "tool_use" },
      { { text = "recovered" }, stop = "stop" },
    })
    local result = agent.messages[3]
    assert.is_true(result.is_error)
    assert.matches("Invalid arguments", result.content[1].text)
  end)

  it("handles unknown tools", function()
    local agent = run_agent({
      { { tool = { id = "t1", name = "nope", args = {} } }, stop = "tool_use" },
      { { text = "ok" }, stop = "stop" },
    })
    assert.matches("Unknown tool", agent.messages[3].content[1].text)
    assert.is_true(agent.messages[3].is_error)
  end)

  it("converts tool exceptions into error results", function()
    local agent = run_agent({
      { { tool = { id = "t1", name = "boom", args = {} } }, stop = "tool_use" },
      { { text = "ok" }, stop = "stop" },
    })
    assert.is_true(agent.messages[3].is_error)
    assert.matches("kaboom", agent.messages[3].content[1].text)
  end)

  it("lets before_tool hooks block execution", function()
    local agent = run_agent({
      { { tool = { id = "t1", name = "echo", args = { value = "x" } } }, stop = "tool_use" },
      { { text = "ok" }, stop = "stop" },
    }, {
      hooks = {
        before_tool = function(tc)
          if tc.name == "echo" then return { block = true, reason = "policy" } end
        end,
      },
    })
    assert.is_true(agent.messages[3].is_error)
    assert.matches("blocked", agent.messages[3].content[1].text)
    assert.matches("policy", agent.messages[3].content[1].text)
  end)

  it("injects steering messages after the current turn", function()
    local agent = run_agent({
      { { text = "first answer" }, stop = "stop" },
      { { text = "steered answer" }, stop = "stop" },
    }, {
      on_event = function(a, ev)
        if ev.type == "message_update" and #a.steering == 0 and not a._steered then
          a._steered = true
          a:steer("also do this")
        end
      end,
    })
    -- user, assistant, steered user, assistant
    assert.equals(4, #agent.messages)
    assert.equals("also do this", agent.messages[3].content)
    assert.equals("steered answer", agent.messages[4].content[1].text)
  end)

  it("delivers follow-ups after the agent would stop", function()
    local agent = run_agent({
      { { text = "a1" }, stop = "stop" },
      { { text = "a2" }, stop = "stop" },
    }, {
      on_event = function(a, ev)
        if ev.type == "turn_start" and not a._fu then
          a._fu = true
          a:follow_up("follow up")
        end
      end,
    })
    assert.equals(4, #agent.messages)
    assert.equals("follow up", agent.messages[3].content)
  end)

  it("stops after an aborted stream", function()
    local agent, events = run_agent({
      { { text = "part" }, { fail = "aborted by user", stop = "aborted" } },
    })
    assert.equals("aborted", agent.messages[2].stop_reason)
    assert.equals("agent_end", events[#events].type)
    assert.is_false(agent.is_running)
  end)

  it("stops turns once abort is requested", function()
    local agent = run_agent({
      { { tool = { id = "t1", name = "echo", args = { value = "x" } } }, stop = "tool_use" },
      { { text = "should not be reached" }, stop = "stop" },
    }, {
      on_event = function(a, ev)
        if ev.type == "tool_start" then a:abort() end
      end,
    })
    -- user, assistant(tool), tool_result — no second assistant turn
    assert.equals(3, #agent.messages)
  end)

  it("tracks usage on the assistant message", function()
    local agent = run_agent({ { { text = "hi" }, stop = "stop" } })
    local usage = agent.messages[2].usage
    assert.equals(10, usage.input)
    assert.equals(5, usage.output)
    assert.is_true(usage.cost.total > 0)
  end)
end)
