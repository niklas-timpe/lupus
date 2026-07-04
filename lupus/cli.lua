-- Command-line entry: argument parsing and mode dispatch.

local VERSION = "0.1.0"

local cli = {}

local USAGE = [[
lupus - a terminal AI coding agent

Usage:
  lupus [options] [prompt]

Options:
  -p, --print            Non-interactive: run one prompt, print the reply, exit
  -m, --model <id>       Model to use (see `lupus --list-models`)
  -c, --continue         Continue the most recent session in this directory
  -r, --resume           Pick a session to resume
      --no-session       Don't persist this conversation
  -e, --extension <path> Load an extension file (repeatable)
      --no-extensions    Skip extension discovery (-e still loads)
      --list-models      List available models and exit
      --system-prompt <file>  Replace the built-in system prompt
  -v, --version          Print version and exit
  -h, --help             Show this help

Environment:
  ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY ... provider keys
                         (no key? lupus starts anyway — use /login)
  LUPUS_LOG              Path for the debug log file
]]

--- Parse argv into an options table. Returns opts or nil, error.
function cli.parse(argv)
  local opts = {
    mode = "interactive",
    extensions = {},
    prompt_parts = {},
    session = "new",
  }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local function next_value(flag)
      i = i + 1
      local v = argv[i]
      if not v then error(("%s requires a value"):format(flag), 0) end
      return v
    end
    if a == "-h" or a == "--help" then
      opts.help = true
    elseif a == "-v" or a == "--version" then
      opts.version = true
    elseif a == "-p" or a == "--print" then
      opts.mode = "print"
    elseif a == "-m" or a == "--model" then
      opts.model = next_value(a)
    elseif a == "-c" or a == "--continue" then
      opts.session = "continue"
    elseif a == "-r" or a == "--resume" then
      opts.session = "resume"
    elseif a == "--no-session" then
      opts.session = "none"
    elseif a == "-e" or a == "--extension" then
      opts.extensions[#opts.extensions + 1] = next_value(a)
    elseif a == "--no-extensions" then
      opts.no_extensions = true
    elseif a == "--list-models" then
      opts.list_models = true
    elseif a == "--system-prompt" then
      opts.system_prompt_file = next_value(a)
    elseif a == "--" then
      for j = i + 1, #argv do opts.prompt_parts[#opts.prompt_parts + 1] = argv[j] end
      i = #argv
    elseif a:sub(1, 1) == "-" and #a > 1 then
      error(("unknown option: %s (see --help)"):format(a), 0)
    else
      opts.prompt_parts[#opts.prompt_parts + 1] = a
    end
    i = i + 1
  end
  opts.prompt = #opts.prompt_parts > 0 and table.concat(opts.prompt_parts, " ") or nil
  return opts
end

function cli.main(argv)
  local ok, opts = pcall(cli.parse, argv or {})
  if not ok then
    io.stderr:write("lupus: " .. tostring(opts) .. "\n")
    return 2
  end
  if opts.help then
    io.write(USAGE)
    return 0
  end
  if opts.version then
    io.write("lupus " .. VERSION .. "\n")
    return 0
  end

  local app = require("lupus.app")
  return app.run(opts)
end

cli.VERSION = VERSION

return cli
