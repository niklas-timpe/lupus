-- Permission gate for tool calls: allow/deny/ask policy from JSONC config
-- files (global + per-project), wildcard command/path rules, an
-- external-directory gate, and an interactive approval dialog. Port of
-- pi-permission-system (https://github.com/MasuRii/pi-permission-system)
-- for lupus — see permission_system/ (sibling package, not lupus core)
-- and llm.md for the full design log.
--
-- Drop into ~/.config/lupus/extensions/, or load explicitly:
--   lupus -e examples/extensions/permission_system.lua
--
-- Config files (JSONC — comments and trailing commas OK):
--   ~/.config/lupus/permissions.jsonc   (trusted; can't be relaxed by the project)
--   <project>/.lupus/permissions.jsonc  (untrusted; can tighten, never relax)
-- See permission_system/permissions.example.jsonc for the schema.
--
-- Commands: /permissions [show|yolo [on|off]|debug [on|off]|reload|path]

return function(api)
	require("permission_system").setup(api)
end
