-- edit: exact string replacement in a file. The old string must match
-- exactly and unambiguously (or pass replace_all).

local s = require("lupus.schema")
local fs = require("lupus.util.fs")
local tools = require("lupus.tools")

local function count_plain(haystack, needle)
  local count = 0
  local pos = 1
  while true do
    local at = haystack:find(needle, pos, true)
    if not at then return count end
    count = count + 1
    pos = at + #needle
  end
end

local function replace_plain(haystack, needle, replacement, all)
  local out = {}
  local pos = 1
  while true do
    local at = haystack:find(needle, pos, true)
    if not at then
      out[#out + 1] = haystack:sub(pos)
      break
    end
    out[#out + 1] = haystack:sub(pos, at - 1)
    out[#out + 1] = replacement
    pos = at + #needle
    if not all then
      out[#out + 1] = haystack:sub(pos)
      break
    end
  end
  return table.concat(out)
end

return {
  name = "edit",
  label = "Edit",
  description = "Replace an exact string in a file. old_string must appear "
    .. "exactly once (include surrounding lines to disambiguate), or set "
    .. "replace_all to change every occurrence.",
  parameters = s.object{
    path = s.string{ desc = "File to modify", required = true },
    old_string = s.string{ desc = "Exact text to replace", required = true },
    new_string = s.string{ desc = "Replacement text", required = true },
    replace_all = s.boolean{ desc = "Replace every occurrence (default false)" },
  },

  execute = function(args, ctx)
    local path = tools.resolve(args.path, ctx)
    local data, err = fs.read_file(path)
    if not data then
      error(("cannot read %s: %s"):format(args.path, tostring(err)))
    end
    if args.old_string == args.new_string then
      error("old_string and new_string are identical")
    end
    local n = count_plain(data, args.old_string)
    if n == 0 then
      error(("old_string not found in %s — read the file again and match the current content exactly"):format(args.path))
    end
    if n > 1 and not args.replace_all then
      error(("old_string appears %d times in %s — add surrounding context to make it unique, or set replace_all"):format(n, args.path))
    end
    local updated = replace_plain(data, args.old_string, args.new_string, args.replace_all)
    assert(fs.write_file(path, updated))
    local replaced = args.replace_all and n or 1
    return {
      content = ("Replaced %d occurrence%s in %s"):format(replaced, replaced == 1 and "" or "s", args.path),
      details = { replacements = replaced },
    }
  end,

  render_call = function(args)
    return args.path or "?"
  end,
}
