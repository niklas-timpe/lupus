-- Live streaming smoke test (needs a provider API key in the environment):
--   luajit examples/ai_demo.lua [model] "prompt"

package.path = "./?.lua;./?/init.lua;" .. package.path
local home = os.getenv("HOME")
if home then
  package.path = package.path .. ";" .. home .. "/.luarocks/share/lua/5.1/?.lua;"
    .. home .. "/.luarocks/share/lua/5.1/?/init.lua"
  package.cpath = package.cpath .. ";" .. home .. "/.luarocks/lib/lua/5.1/?.so"
end

local loop = require("lupus.loop")
local ai = require("lupus.ai")
local models = require("lupus.ai.models")

local model_query, prompt
if arg[2] then
  model_query, prompt = arg[1], arg[2]
else
  prompt = arg[1] or "Say hello in five words."
end

local model = model_query and models.get(model_query) or models.default()
if not model then
  io.stderr:write("no model available — set ANTHROPIC_API_KEY or OPENAI_API_KEY\n")
  os.exit(1)
end
io.write(("model: %s/%s\n\n"):format(model.provider, model.id))

local ok, err = loop.run(function()
  local stream = ai.stream(model, {
    system_prompt = "You are terse.",
    messages = { ai.types.user(prompt) },
  }, {
    api_key = models.api_key(model),
  })
  for ev in stream:events() do
    if ev.type == "text_delta" then
      io.write(ev.delta)
      io.flush()
    elseif ev.type == "thinking_delta" then
      io.write("\27[2m" .. ev.delta .. "\27[0m")
      io.flush()
    end
  end
  local msg = stream:result()
  io.write("\n\n")
  if msg.stop_reason == "error" or msg.stop_reason == "aborted" then
    io.write("error: " .. tostring(msg.error_message) .. "\n")
  else
    io.write(("[%s · %d in / %d out · $%.5f]\n"):format(
      msg.stop_reason, msg.usage.input, msg.usage.output, msg.usage.cost.total))
  end
end)
if not ok then
  io.stderr:write("failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
