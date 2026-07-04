-- read: return file contents, optionally a line range.

local s = require("lupus.schema")
local fs = require("lupus.util.fs")
local tools = require("lupus.tools")

return {
  name = "read",
  label = "Read",
  description = "Read a file. Returns the content, optionally starting at a "
    .. "1-based line offset with a line limit. Large files are truncated; "
    .. "use offset/limit to page through them.",
  parameters = s.object{
    path = s.string{ desc = "File path (absolute or relative to the working directory)", required = true },
    offset = s.integer{ desc = "1-based line number to start reading from" },
    limit = s.integer{ desc = "Maximum number of lines to return" },
  },

  execute = function(args, ctx)
    local path = tools.resolve(args.path, ctx)
    if fs.is_dir(path) then
      error(("%s is a directory (use ls)"):format(args.path))
    end
    local data, err = fs.read_file(path)
    if not data then
      error(("cannot read %s: %s"):format(args.path, tostring(err)))
    end
    if data:find("\0", 1, true) then
      error(("%s looks like a binary file (%d bytes)"):format(args.path, #data))
    end

    if args.offset or args.limit then
      local lines = {}
      for line in (data .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
      if lines[#lines] == "" then lines[#lines] = nil end
      local from = math.max(1, args.offset or 1)
      local to = args.limit and math.min(#lines, from + args.limit - 1) or #lines
      local slice = {}
      for i = from, to do slice[#slice + 1] = lines[i] end
      data = table.concat(slice, "\n")
      if to < #lines then
        data = data .. ("\n[lines %d-%d of %d]"):format(from, to, #lines)
      end
      return data
    end

    return (tools.truncate(data, "head"))
  end,

  render_call = function(args)
    local parts = { args.path or "?" }
    if args.offset then parts[#parts + 1] = ":" .. args.offset end
    return table.concat(parts)
  end,
}
