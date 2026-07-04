-- write: create or overwrite a file, creating parent directories.

local s = require("lupus.schema")
local fs = require("lupus.util.fs")
local tools = require("lupus.tools")

return {
  name = "write",
  label = "Write",
  description = "Write content to a file, replacing anything there. Parent "
    .. "directories are created. Prefer edit for changing existing files.",
  parameters = s.object{
    path = s.string{ desc = "File to write", required = true },
    content = s.string{ desc = "Full file content", required = true },
  },

  execute = function(args, ctx)
    local path = tools.resolve(args.path, ctx)
    local existed = fs.is_file(path)
    local dir = fs.dirname(path)
    if dir and dir ~= "" then
      assert(fs.mkdirp(dir))
    end
    assert(fs.write_file(path, args.content))
    local lines = select(2, args.content:gsub("\n", "")) + (args.content == "" and 0 or 1)
    return {
      content = ("%s %s (%d lines)"):format(existed and "Updated" or "Created", args.path, lines),
      details = { created = not existed, bytes = #args.content },
    }
  end,

  render_call = function(args)
    return args.path or "?"
  end,
}
