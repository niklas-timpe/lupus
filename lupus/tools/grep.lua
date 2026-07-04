-- grep: search file contents (system grep, recursive, .git skipped).

local s = require("lupus.schema")
local loop = require("lupus.loop")
local tools = require("lupus.tools")

return {
  name = "grep",
  label = "Grep",
  description = "Search file contents recursively with grep (basic regular "
    .. "expressions). Returns matching lines as path:line:text.",
  parameters = s.object{
    pattern = s.string{ desc = "Pattern to search for (grep BRE syntax)", required = true },
    path = s.string{ desc = "File or directory to search (default: working directory)" },
    ignore_case = s.boolean{ desc = "Case-insensitive search" },
  },

  execute = function(args, ctx)
    local target = tools.resolve(args.path or ".", ctx)
    local argv = { "grep", "-rn", "-I", "--exclude-dir=.git", "--exclude-dir=node_modules" }
    if args.ignore_case then argv[#argv + 1] = "-i" end
    argv[#argv + 1] = "-e"
    argv[#argv + 1] = args.pattern
    argv[#argv + 1] = target

    local proc = loop.process.spawn{ argv = argv, cwd = ctx.cwd }
    local chunks = {}
    while true do
      local chunk = loop.read(proc.stdout)
      if not chunk then break end
      chunks[#chunks + 1] = chunk
      if ctx.aborted() then proc:terminate() end
    end
    local stderr = ""
    while true do
      local chunk = loop.read(proc.stderr)
      if not chunk then break end
      stderr = stderr .. chunk
    end
    local code = proc:wait()
    proc:close()

    if code == 1 then return "No matches found" end
    if code > 1 then
      error("grep failed: " .. stderr:gsub("%s+$", ""))
    end
    return (tools.truncate(table.concat(chunks):gsub("%s+$", ""), "head"))
  end,

  render_call = function(args)
    return args.pattern .. (args.path and (" in " .. args.path) or "")
  end,
}
