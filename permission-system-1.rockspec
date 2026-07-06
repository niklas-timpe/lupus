package = "permission-system"
version = "1"
source = {
  url = "git+https://github.com/niklas-timpe/lupus.git",
}
description = {
  summary = "Layered allow/deny/ask permission gate for lupus tool calls",
  detailed = [[
    Port of pi-permission-system (https://github.com/MasuRii/pi-permission-system)
    for the lupus AI coding agent: JSONC policy config (global + per-project,
    trusted-floor merge), wildcard command/path rules, an external-directory
    gate, session "Allow Always" approvals, and an interactive approval
    dialog. Ships as a standalone package (sibling of lupus/, not part of
    lupus core) plus a thin loader extension.
  ]],
  homepage = "https://github.com/niklas-timpe/lupus",
  license = "MIT",
}
dependencies = {
  "lua == 5.1", -- LuaJIT
  "luv >= 1.45",
  "lua-cjson >= 2.1",
}
build = {
  type = "builtin",
  modules = {
    ["permission_system"] = "permission_system/init.lua",
    ["permission_system.state"] = "permission_system/state.lua",
    ["permission_system.common"] = "permission_system/common.lua",
    ["permission_system.jsonc"] = "permission_system/jsonc.lua",
    ["permission_system.wildcard"] = "permission_system/wildcard.lua",
    ["permission_system.approval"] = "permission_system/approval.lua",
    ["permission_system.manager"] = "permission_system/manager.lua",
    ["permission_system.prompts"] = "permission_system/prompts.lua",
    ["permission_system.dialog"] = "permission_system/dialog.lua",
    ["permission_system.config"] = "permission_system/config.lua",
    ["permission_system.logger"] = "permission_system/logger.lua",
    ["permission_system.yolo"] = "permission_system/yolo.lua",
  },
}
