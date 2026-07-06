-- Yolo-mode predicates. Ported from yolo-mode.ts; the runtime globalThis
-- API (yolo-mode-api.ts) is pi-specific plumbing for its Zellij modal and
-- has no lupus equivalent — /permissions yolo [on|off] calls config.save
-- directly instead (see init.lua).

local yolo = {}

function yolo.is_enabled(extension_config)
	return extension_config.yolo_mode == true
end

function yolo.should_auto_approve(permission_state, extension_config)
	return permission_state == "ask" and yolo.is_enabled(extension_config)
end

--- Whether an "ask" can be resolved at all: needs either an interactive
--- UI to prompt with, or yolo mode to auto-approve. lupus has no
--- subagents (pi's other way to resolve an ask), so this is simpler than
--- canResolveAskPermissionRequest.
function yolo.can_resolve_ask(has_ui, extension_config)
	return has_ui or yolo.is_enabled(extension_config)
end

return yolo
