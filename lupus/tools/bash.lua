-- bash: run a shell command in the working directory. Runs in its own
-- process group so aborting kills the whole pipeline, streams output as it
-- arrives, and keeps the tail when output is huge.

local s = require("lupus.schema")
local loop = require("lupus.loop")
local tools = require("lupus.tools")

local DEFAULT_TIMEOUT = 120

return {
  name = "bash",
  label = "Bash",
  description = "Execute a shell command (via sh -c) in the working directory. "
    .. "Returns combined stdout/stderr and the exit code. Long output is "
    .. "truncated to the last part. Default timeout: " .. DEFAULT_TIMEOUT .. "s.",
  parameters = s.object{
    command = s.string{ desc = "Shell command to execute", required = true },
    timeout = s.integer{ desc = "Timeout in seconds (default " .. DEFAULT_TIMEOUT .. ")" },
  },

  execute = function(args, ctx)
    local proc = loop.process.spawn{
      argv = { "sh", "-c", args.command },
      cwd = ctx.cwd,
      pgroup = true,
    }

    local timed_out = false
    local timer = loop.timer((args.timeout or DEFAULT_TIMEOUT) * 1000, function()
      timed_out = true
      proc:terminate()
    end)

    local chunks = {}
    local total = 0
    local function drain(fd)
      return loop.spawn(function()
        while true do
          local chunk = loop.read(fd)
          if not chunk then return end
          chunks[#chunks + 1] = chunk
          total = total + #chunk
          -- Keep memory bounded: drop from the front beyond 4x the limit.
          while total > 4 * tools.MAX_BYTES and #chunks > 1 do
            total = total - #chunks[1]
            table.remove(chunks, 1)
          end
          if ctx.on_update then
            ctx.on_update(chunks[#chunks])
          end
          if ctx.aborted() then
            proc:terminate()
          end
        end
      end)
    end

    -- Watch for aborts even when the command produces no output.
    local abort_watch = loop.interval(200, function()
      if ctx.aborted() then proc:terminate() end
    end)

    local out_task = drain(proc.stdout)
    local err_task = drain(proc.stderr)
    local code = proc:wait()
    out_task:join()
    err_task:join()
    timer:cancel()
    abort_watch:cancel()
    proc:close()

    local output = table.concat(chunks)
    output = output:gsub("%s+$", "")
    local body = tools.truncate(output, "tail")

    if ctx.aborted() then
      error("Command aborted by user" .. (body ~= "" and ("\nOutput so far:\n" .. body) or ""))
    end
    if timed_out then
      error(("Command timed out after %ds"):format(args.timeout or DEFAULT_TIMEOUT)
        .. (body ~= "" and ("\nOutput so far:\n" .. body) or ""))
    end

    if code ~= 0 then
      return {
        content = (body ~= "" and body .. "\n" or "") .. ("[exit code %d]"):format(code),
        is_error = true,
        details = { exit_code = code },
      }
    end
    return { content = body ~= "" and body or "(no output)", details = { exit_code = 0 } }
  end,

  render_call = function(args)
    return args.command or "?"
  end,
}
