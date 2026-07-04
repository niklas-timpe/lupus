-- System prompt assembly: identity + tool guidance + project context files
-- (AGENTS.md discovered from the global config dir and every ancestor of
-- the working directory) + date and cwd.

local fs = require("lupus.util.fs")

local prompt = {}

local BASE = [[
You are lupus, an expert coding agent working in the user's terminal.

You take action using tools: read files before editing them, run commands to
verify your changes, and keep going until the task is done or you are blocked
on information only the user has. Prefer editing existing files over
rewriting them. Never invent file contents — read them.

Guidelines:
- Be concise. Answer directly, without preamble.
- Show file paths clearly when referring to code.
- When a command or edit fails, read the error and fix the cause.
- Make the smallest change that solves the problem.]]

local CONTEXT_FILE_NAMES = { "AGENTS.md", "AGENTS.MD", "CLAUDE.md" }

local function find_context_file(dir)
  for _, name in ipairs(CONTEXT_FILE_NAMES) do
    local path = fs.join(dir, name)
    if fs.is_file(path) then
      local content = fs.read_file(path)
      if content and content ~= "" then
        return { path = path, content = content }
      end
    end
  end
  return nil
end

--- Context files: global (config dir) first, then ancestors root → cwd.
function prompt.context_files(cwd, config_dir)
  local files = {}
  if config_dir then
    local global = find_context_file(config_dir)
    if global then files[#files + 1] = global end
  end
  local ancestors = {}
  local dir = cwd
  while dir and dir ~= "/" and dir ~= "" do
    ancestors[#ancestors + 1] = dir
    dir = dir:match("^(.*)/[^/]+$")
  end
  for i = #ancestors, 1, -1 do
    local found = find_context_file(ancestors[i])
    if found then files[#files + 1] = found end
  end
  return files
end

--- Build the system prompt.
--- opts: cwd, config_dir, custom (replaces BASE), append (extra sections),
---       no_context_files.
function prompt.build(opts)
  opts = opts or {}
  local cwd = opts.cwd or fs.cwd()
  local parts = { opts.custom or BASE }

  if opts.append and opts.append ~= "" then
    parts[#parts + 1] = opts.append
  end

  if not opts.no_context_files then
    local files = prompt.context_files(cwd, opts.config_dir)
    if #files > 0 then
      local sections = { "<project_context>" }
      for _, f in ipairs(files) do
        sections[#sections + 1] = ('<instructions path="%s">\n%s\n</instructions>'):format(f.path, f.content)
      end
      sections[#sections + 1] = "</project_context>"
      parts[#parts + 1] = table.concat(sections, "\n")
    end
  end

  parts[#parts + 1] = ("Current date: %s\nWorking directory: %s"):format(os.date("%Y-%m-%d"), cwd)
  return table.concat(parts, "\n\n")
end

return prompt
