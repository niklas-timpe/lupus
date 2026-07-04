-- Non-interactive mode (-p): run one prompt, stream the reply to stdout,
-- report tool activity on stderr, exit non-zero on error. No TUI.

local loop = require("lupus.loop")

local print_mode = {}

function print_mode.run(runtime, opts)
  if not opts.prompt or opts.prompt == "" then
    -- Read the prompt from stdin when piped.
    opts.prompt = io.read("*a")
  end
  if not opts.prompt or opts.prompt:match("^%s*$") then
    io.stderr:write("lupus: no prompt provided\n")
    return 2
  end

  local exit_code = 0

  runtime:subscribe(function(ev)
    if ev.type == "message_update" then
      local ev2 = ev.event
      if ev2 and ev2.type == "text_delta" then
        io.write(ev2.delta)
        io.flush()
      end
    elseif ev.type == "tool_start" then
      io.stderr:write(("[tool] %s\n"):format(ev.name))
    elseif ev.type == "tool_end" then
      if ev.result_message.is_error then
        io.stderr:write(("[tool:%s] error\n"):format(ev.name))
      end
    elseif ev.type == "message_end" then
      local msg = ev.message
      if msg.role == "assistant"
        and (msg.stop_reason == "error" or msg.stop_reason == "aborted") then
        io.stderr:write("\nlupus: " .. tostring(msg.error_message or msg.stop_reason) .. "\n")
        exit_code = 1
      end
    end
  end)

  local run_ok, err = loop.run(function()
    runtime:load_extensions(nil) -- headless: dialogs unavailable
    -- Extensions may have registered the provider a persisted model needs.
    runtime:reresolve_model()
    if not runtime:model_available() then
      local prov = require("lupus.ai.models").provider_info(runtime.model.provider)
      local env_hint = prov and prov.env and (" (set " .. prov.env .. ")") or ""
      io.stderr:write(("lupus: no API key for %s/%s%s — run lupus interactively and use /login\n")
        :format(runtime.model.provider, runtime.model.id, env_hint))
      exit_code = 2
      runtime:shutdown()
      return
    end
    runtime:send(opts.prompt)
    runtime.agent:wait_idle()
    runtime:shutdown()
  end)
  if not run_ok then
    io.stderr:write("lupus: " .. tostring(err) .. "\n")
    return 1
  end

  io.write("\n")
  return exit_code
end

return print_mode
