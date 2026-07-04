-- A scriptable in-process provider for agent tests. Each model carries a
-- queue of scripted responses; every stream call pops one and replays it
-- through the shared builder, exactly like a real adapter would.

local builder_mod = require("lupus.ai.builder")
local json = require("lupus.util.json")
local ai = require("lupus.ai")

local M = {}

function M.install()
  ai.register_api("fake", {
    stream = function(model, context, opts, emit, ctrl)
      model.calls = model.calls or {}
      model.calls[#model.calls + 1] = { context = context, opts = opts }
      local script = table.remove(model.script, 1)
        or { { text = "(script exhausted)" }, stop = "stop" }
      local b = builder_mod.new(model, emit)
      b:start()
      for _, step in ipairs(script) do
        if ctrl.aborted then
          b:fail("aborted by user", "aborted")
          return
        end
        if step.text then b:text_delta(step.text) end
        if step.thinking then b:thinking_delta(step.thinking) end
        if step.tool then
          b:tool_start(step.tool.id or "call_1", step.tool.name)
          b:tool_delta(json.encode(step.tool.args or {}))
        end
        if step.fail then
          b:fail(step.fail, step.stop or "error")
          return
        end
      end
      b:set_usage{ input = 10, output = 5 }
      b:finish(script.stop or "stop")
    end,
  })
end

--- model whose responses follow `scripts` (array of scripts; a script is an
--- array of steps plus a `stop` reason).
function M.model(scripts)
  return {
    id = "fake-model", name = "Fake", provider = "fake", api = "fake",
    base_url = "", reasoning = true, context_window = 100000, max_tokens = 4096,
    cost = { input = 1, output = 2, cache_read = 0, cache_write = 0 },
    script = scripts or {},
  }
end

return M
