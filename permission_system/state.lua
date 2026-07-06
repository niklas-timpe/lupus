-- Shared constants for the permission system. No behavior lives here —
-- just the vocabulary every other module agrees on.

local state = {}

state.EXTENSION_ID = "permission-system"

--- "allow" | "deny" | "ask"
state.PermissionState = {
	ALLOW = "allow",
	DENY = "deny",
	ASK = "ask",
}

--- lupus's built-in tools — same names pi uses, different argument casing.
state.BUILT_IN_TOOLS = {
	bash = true,
	read = true,
	write = true,
	edit = true,
	grep = true,
	find = true,
	ls = true,
}

--- Same set, ordered — for anything that needs deterministic iteration
--- (the /permissions summary, the before_agent_start hidden-tools scan).
state.BUILT_IN_TOOL_NAMES = { "bash", "read", "write", "edit", "grep", "find", "ls" }

--- Built-in tools whose input carries a filesystem `path` field, so their
--- permission check is resource-qualified ("read:/abs/path/*").
state.PATH_TOOLS = {
	read = true,
	write = true,
	edit = true,
	grep = true,
	find = true,
	ls = true,
}

state.SPECIAL_KEYS = {
	external_directory = true,
	doom_loop = true,
}

--- Record-level permission categories (each a map of pattern -> state).
state.CATEGORIES = { "tools", "bash", "mcp", "skills", "special" }

--- Default-policy categories (a single state per category, no patterns).
state.POLICY_CATEGORIES = { "tools", "bash", "mcp", "skills", "special" }

state.DEFAULT_POLICY = {
	tools = "ask",
	bash = "ask",
	mcp = "ask",
	skills = "ask",
	special = "ask",
}

--- MCP tool names that get a baseline "allow" when no explicit mcp rule
--- matches but *some* mcp rule in the merged config says "allow" (or the
--- mcp default policy is "allow"). Forward-compatible: lupus ships no mcp
--- tool by default, but an extension can register one using these names.
state.MCP_BASELINE_TARGETS = {
	mcp_status = true,
	mcp_list = true,
	mcp_search = true,
	mcp_describe = true,
	mcp_connect = true,
}

return state
