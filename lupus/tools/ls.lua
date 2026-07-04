-- ls: list a directory (directories first, "/" suffixed).

local s = require("lupus.schema")
local fs = require("lupus.util.fs")
local tools = require("lupus.tools")

return {
  name = "ls",
  label = "List",
  description = "List the entries of a directory. Directories carry a "
    .. "trailing slash.",
  parameters = s.object{
    path = s.string{ desc = "Directory to list (default: working directory)" },
  },

  execute = function(args, ctx)
    local target = tools.resolve(args.path or ".", ctx)
    if not fs.is_dir(target) then
      error(("%s is not a directory"):format(args.path or "."))
    end
    local dirs, files = {}, {}
    for _, name in ipairs(fs.list_dir(target)) do
      if fs.is_dir(fs.join(target, name)) then
        dirs[#dirs + 1] = name .. "/"
      else
        files[#files + 1] = name
      end
    end
    local out = {}
    for _, d in ipairs(dirs) do out[#out + 1] = d end
    for _, f in ipairs(files) do out[#out + 1] = f end
    if #out == 0 then return "(empty directory)" end
    return (tools.truncate(table.concat(out, "\n"), "head"))
  end,

  render_call = function(args)
    return args.path or "."
  end,
}
