# lupus

An extensible AI coding agent for your terminal, written in Lua.

lupus streams responses from Anthropic and OpenAI-compatible APIs, executes
tools (read / bash / edit / write / grep / find / ls) in an agentic loop,
renders inline in your terminal — no alternate screen, your scrollback stays
yours — and persists every conversation as plain JSONL. Extensions are
ordinary Lua files.

```
┌──────────────────────────────────────────────────┐
│ lupus  anthropic/claude-sonnet-4-5  ·  ~/project │
│                                                  │
│ you                                              │
│ fix the failing test in utils_spec               │
│                                                  │
│ claude-sonnet-4-5                                │
│ ✓ Read tests/utils_spec.lua                      │
│ ✓ Bash busted tests/utils_spec.lua               │
│ The assertion expected the old date format. I    │
│ updated the fixture and the test passes now.     │
│                                                  │
│ ──────────────────────────────────────────────── │
│ > ask lupus anything  ·  /help for commands      │
│ ──────────────────────────────────────────────── │
└──────────────────────────────────────────────────┘
```

## Requirements

- **LuaJIT 2.1, available as `luajit` on PATH** — `bin/lupus` uses
  `#!/usr/bin/env luajit`. lupus targets Lua 5.1 plus LuaJIT extensions
  (`ffi`, `bit`).
- **libuv via [luv](https://github.com/luvit/luv)** — the event loop
  (timers, signals, streams, child processes). `brew install luv` or
  `luarocks --lua-version 5.1 install luv`.
- **ncurses 6 (wide build, `libncursesw`)** — the TUI talks to it directly
  through the LuaJIT FFI, no wrapper rock. `brew install ncurses` on macOS
  (the ancient system 5.7 works as a fallback); on Linux it is almost
  certainly installed already.
- `curl` in PATH (all HTTPS goes through it — no TLS stack in-process)
- LuaRocks packages: `lua-cjson` (and `busted` to run the tests)

```sh
luarocks --lua-version 5.1 install lua-cjson
```

## Quickstart

```sh
export ANTHROPIC_API_KEY=sk-ant-…   # or OPENAI_API_KEY / OPENROUTER_API_KEY / GROQ_API_KEY
# No key in the environment? lupus still starts and offers /login, which
# stores the key in ~/.config/lupus/settings.json.

./bin/lupus                          # interactive session in the current directory
./bin/lupus "explain this codebase"  # interactive, with an opening prompt
./bin/lupus -p "write a .gitignore for Lua"   # non-interactive: print and exit
./bin/lupus -c                       # continue the most recent session here
./bin/lupus -r                       # pick a session to resume
./bin/lupus --list-models
```

Keys: `enter` send · `alt+enter` newline · `esc` interrupt the agent ·
`ctrl+c` twice quit · `up`/`down` prompt history.

Slash commands: `/help` `/login` `/model` `/thinking` `/new` `/name` `/cost`
`/clear` `/quit` — plus whatever extensions and prompt templates add.
`/model` remembers your choice across sessions; `/login` stores provider API
keys.

## Configuration

Settings are JSON, deep-merged: `~/.config/lupus/settings.json` (global) ←
`<project>/.lupus/settings.json` (overrides).

```json
{
  "default_model": "claude-sonnet-4-5",
  "thinking": "medium",
  "providers": {
    "myserver": { "base_url": "http://localhost:8080/v1" }
  },
  "models": [
    { "id": "qwen3:32b", "provider": "ollama" },
    { "id": "custom", "provider": "myserver", "context_window": 32768 }
  ]
}
```

- Built-in providers: `anthropic`, `openai`, `openrouter`, `groq`, `ollama`.
  Custom providers default to the OpenAI-compatible wire format, so most
  self-hosted servers just need a `base_url`.
- API keys come from environment variables (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, …) or an `api_keys` settings table (env vars preferred).
- Model costs/windows for custom models are optional (`cost` in $/Mtok).

Sessions are stored as JSONL under
`~/.local/share/lupus/sessions/<encoded-cwd>/`, one JSON object per line —
trivially greppable and diffable. `--no-session` keeps a conversation
off disk.

`AGENTS.md` (or `CLAUDE.md`) files are picked up from `~/.config/lupus/` and
every ancestor of the working directory, and injected into the system prompt.

## Extensions

An extension is a Lua file returning `function(api)`. Drop it into
`~/.config/lupus/extensions/` (global), `<project>/.lupus/extensions/`
(project — you're asked once whether to trust it), or load with
`-e path.lua`.

```lua
-- ~/.config/lupus/extensions/guard.lua
return function(api)
  -- Veto/inspect tool calls before they run.
  api.on("tool_call", function(ev)
    if ev.tool_name == "bash" and ev.arguments.command:match("rm %-rf") then
      return { block = true, reason = "not on my watch" }
    end
  end)

  -- Register a tool the model can call.
  local schema = require("lupus.schema")
  api.register_tool{
    name = "todo_scan",
    description = "List TODO comments in the project",
    parameters = schema.object{},
    execute = function(_, ctx)
      local res = api.exec({ "grep", "-rn", "TODO", "." }, { cwd = ctx.cwd })
      return res.stdout ~= "" and res.stdout or "no TODOs"
    end,
  }

  -- Slash commands, dialogs, status line…
  api.register_command{
    name = "todos",
    description = "Ask the agent to triage TODOs",
    run = function() api.send_message("Run todo_scan and triage the results.") end,
  }
end
```

**Events** — `api.on(name, handler)`:

| kind | events | handler contract |
|---|---|---|
| notify | `session_start` `session_shutdown` `agent_start` `agent_end` `turn_start` `turn_end` `message_start` `message_update` `message_end` `tool_start` `tool_update` `tool_end` `model_changed` | observe; return ignored |
| veto | `tool_call` | return `{ block = true, reason = "…" }` to stop the call; mutate `ev.arguments` to rewrite it |
| transform | `user_input`, `tool_result` | return a replacement value, `nil` for unchanged, `{ handled = true }` to swallow |
| collect | `before_agent_start` | return `{ system_prompt_append = "…", inject_message = "…" }` |

**API surface**: `register_tool` `register_command` `register_shortcut`
`register_flag`/`get_flag`/`set_flag` · `send_message` `abort` `set_model`
`append_entry` · `notify` `set_status` `select` `confirm` `input` (dialogs
suspend the calling coroutine until answered) · `exec` ·
`cwd` `config` `session_id`.

Prompt templates: markdown files in `~/.config/lupus/commands/` or
`.lupus/commands/` become `/name` commands; `$ARGUMENTS` is substituted.

> **Security**: extensions are plain Lua running with your full user
> permissions — no sandbox. Treat project-local extensions like any code you
> would execute, and only trust projects you'd run `make` in.

## Architecture

```
lupus/
├── loop/       coroutine scheduler driven by libuv (luv) — timers, signals,
│               streams, child processes, channels
├── tui/        full-screen terminal UI on ncurses (direct FFI bindings):
│               component tree → styled lines → SGR runs → curses window;
│               pure key parsing over a uv tty, ANSI-aware text shaping,
│               components (editor, markdown, …)
├── ai/         unified LLM API: curl-subprocess HTTP, incremental SSE +
│               partial-JSON parsing, anthropic-messages and
│               openai-completions adapters, model registry, cost tracking
├── agent.lua   the loop: prompt → stream → validate & execute tools →
│               repeat; steering/follow-up queues; abort
├── tools/      read bash edit write grep find ls (+ truncation policy)
├── ext/        extension hub (notify/veto/transform/collect), api, loader
├── app/        session_runtime (agent+persistence+extensions, frontend-
│               agnostic) → interactive TUI / print mode
├── session.lua JSONL persistence   config.lua  settings   prompt.lua  system prompt
└── cli.lua     argument parsing and dispatch
```

Everything blocking runs in coroutines scheduled over a single libuv loop —
streaming, keystrokes, spinners, and shell commands interleave without
threads; uv callbacks never run user code, they only mark tasks ready. A
streaming response is a coroutine writing into a channel.

The TUI is layered so each part swaps independently: components render
ANSI-styled strings (`tui/text.lua` helpers); `tui/init.lua` owns the tree,
focus, and bottom-anchored viewport; `tui/sgr.lua` parses styled lines into
plain-text runs with structured styles; `tui/screen.lua` maps runs to
ncurses attributes and windows (the only file that touches the C library,
via the `tui/ncurses.lua` FFI declarations); `tui/input.lua` turns raw tty
bytes into key events. Tests exercise the renderer against a fake surface —
no terminal required.

## Development

```sh
luarocks --lua-version 5.1 install busted
busted                           # run the test suite
luajit examples/tui_demo.lua     # TUI playground (no API key needed)
luajit examples/ai_demo.lua "hi" # live streaming smoke test (needs a key)
LUPUS_LOG=/tmp/lupus.log ./bin/lupus   # debug logging
```

## License

MIT
