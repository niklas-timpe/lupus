package = "lupus"
version = "dev-1"
source = {
  url = "git+https://github.com/niklas-timpe/lupus.git",
}
description = {
  summary = "A terminal AI coding agent in Lua",
  detailed = [[
    Lupus is an interactive, extensible AI coding agent for the terminal.
    It streams responses from Anthropic and OpenAI-compatible APIs, executes
    tools (read/bash/edit/write/grep/find/ls), persists sessions as JSONL,
    and is extensible with plain Lua extension files.
  ]],
  homepage = "https://github.com/niklas-timpe/lupus",
  license = "MIT",
}
dependencies = {
  "lua == 5.1", -- LuaJIT
  "luv >= 1.45",
  "lua-cjson >= 2.1",
}
-- Also requires at runtime (not luarocks-managed): LuaJIT itself, and
-- ncurses (the wide build, libncursesw 6.x) loaded via the LuaJIT FFI.
build = {
  type = "builtin",
  modules = {
    ["lupus.agent"] = "lupus/agent.lua",
    ["lupus.ai.builder"] = "lupus/ai/builder.lua",
    ["lupus.ai.http"] = "lupus/ai/http.lua",
    ["lupus.ai"] = "lupus/ai/init.lua",
    ["lupus.ai.models"] = "lupus/ai/models.lua",
    ["lupus.ai.partial_json"] = "lupus/ai/partial_json.lua",
    ["lupus.ai.providers.anthropic"] = "lupus/ai/providers/anthropic.lua",
    ["lupus.ai.providers.openai"] = "lupus/ai/providers/openai.lua",
    ["lupus.ai.sse"] = "lupus/ai/sse.lua",
    ["lupus.ai.types"] = "lupus/ai/types.lua",
    ["lupus.app"] = "lupus/app/init.lua",
    ["lupus.app.interactive"] = "lupus/app/interactive.lua",
    ["lupus.app.print_mode"] = "lupus/app/print_mode.lua",
    ["lupus.app.session_runtime"] = "lupus/app/session_runtime.lua",
    ["lupus.cli"] = "lupus/cli.lua",
    ["lupus.commands"] = "lupus/commands.lua",
    ["lupus.config"] = "lupus/config.lua",
    ["lupus.ext.api"] = "lupus/ext/api.lua",
    ["lupus.ext.events"] = "lupus/ext/events.lua",
    ["lupus.ext.loader"] = "lupus/ext/loader.lua",
    ["lupus.loop.channel"] = "lupus/loop/channel.lua",
    ["lupus.loop"] = "lupus/loop/init.lua",
    ["lupus.loop.process"] = "lupus/loop/process.lua",
    ["lupus.prompt"] = "lupus/prompt.lua",
    ["lupus.schema"] = "lupus/schema.lua",
    ["lupus.session"] = "lupus/session.lua",
    ["lupus.tools.bash"] = "lupus/tools/bash.lua",
    ["lupus.tools.edit"] = "lupus/tools/edit.lua",
    ["lupus.tools.find"] = "lupus/tools/find.lua",
    ["lupus.tools.grep"] = "lupus/tools/grep.lua",
    ["lupus.tools"] = "lupus/tools/init.lua",
    ["lupus.tools.ls"] = "lupus/tools/ls.lua",
    ["lupus.tools.read"] = "lupus/tools/read.lua",
    ["lupus.tools.write"] = "lupus/tools/write.lua",
    ["lupus.tui.components.editor"] = "lupus/tui/components/editor.lua",
    ["lupus.tui.components.loader"] = "lupus/tui/components/loader.lua",
    ["lupus.tui.components.markdown"] = "lupus/tui/components/markdown.lua",
    ["lupus.tui.components.select"] = "lupus/tui/components/select.lua",
    ["lupus.tui.components.spacer"] = "lupus/tui/components/spacer.lua",
    ["lupus.tui.components.text"] = "lupus/tui/components/text.lua",
    ["lupus.tui"] = "lupus/tui/init.lua",
    ["lupus.tui.input"] = "lupus/tui/input.lua",
    ["lupus.tui.ncurses"] = "lupus/tui/ncurses.lua",
    ["lupus.tui.screen"] = "lupus/tui/screen.lua",
    ["lupus.tui.sgr"] = "lupus/tui/sgr.lua",
    ["lupus.tui.text"] = "lupus/tui/text.lua",
    ["lupus.util.compat"] = "lupus/util/compat.lua",
    ["lupus.util.fs"] = "lupus/util/fs.lua",
    ["lupus.util.json"] = "lupus/util/json.lua",
    ["lupus.util.log"] = "lupus/util/log.lua",
    ["lupus.util.utf8"] = "lupus/util/utf8.lua",
  },
  install = {
    bin = { lupus = "bin/lupus" },
  },
}
