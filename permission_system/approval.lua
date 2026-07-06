-- Session-scoped "Allow Always" approvals: an in-memory, allow-only rule
-- list layered on top of the config-derived check result. Never persisted
-- to disk, never overrides a "deny" (see docstring on apply_pattern_state).

local common = require("permission_system.common")
local wildcard = require("permission_system.wildcard")

local approval = {}

--- rule = { tool = <glob>, pattern = <glob>, action = <PermissionState> }
--- (action is always "allow" for rules this module produces, but
--- evaluate_permission accepts any PermissionState so config-derived rules
--- can be threaded through the same last-match-wins evaluator.)

local function is_rule(value)
	return type(value) == "table"
		and type(value.tool) == "string"
		and type(value.pattern) == "string"
		and common.is_permission_state(value.action)
end

--- Last-match-wins over `rulesets` (each an array of rules, checked in the
--- order given — later rulesets can override earlier ones), matching a
--- rule only when BOTH its tool glob and its pattern glob match.
function approval.evaluate_permission(tool, command, ...)
	local rules = {}
	for _, ruleset in ipairs({ ... }) do
		if type(ruleset) == "table" then
			for _, rule in ipairs(ruleset) do
				if is_rule(rule) then
					rules[#rules + 1] = rule
				end
			end
		end
	end

	local normalized_tool = wildcard.normalize_name(tool)
	local normalized_command = wildcard.normalize_name(command)

	for i = #rules, 1, -1 do
		local rule = rules[i]
		if wildcard.compile(rule.tool, rule.action).match(normalized_tool) then
			if wildcard.compile(rule.pattern, rule.action).match(normalized_command) then
				return { action = rule.action, matched_pattern = rule.pattern, matched_tool = rule.tool }
			end
		end
	end

	return { action = "ask" }
end

-- ---------------------------------------------------------------------------

local SessionApprovalStore = {}
SessionApprovalStore.__index = SessionApprovalStore

function approval.new_store()
	return setmetatable({ rules = {} }, SessionApprovalStore)
end

function SessionApprovalStore:approve_always(tool, pattern)
	local normalized_tool = common.get_non_empty_string(tool)
	local normalized_pattern = common.get_non_empty_string(pattern)
	if not normalized_tool or not normalized_pattern then
		return
	end
	self.rules[#self.rules + 1] = { tool = normalized_tool, pattern = normalized_pattern, action = "allow" }
end

SessionApprovalStore.approve_once = SessionApprovalStore.approve_always

function SessionApprovalStore:has_session_approval(tool, command)
	return self:evaluate(tool, command).state == "allow"
end

--- Returns { state = "allow"|"ask", matched_pattern? }. Never "deny" — a
--- session approval only ever adds "allow"; anything else falls back to
--- "ask" so the caller's own config-derived result decides.
function SessionApprovalStore:evaluate(tool, command)
	local result = approval.evaluate_permission(tool, command, self.rules)
	if result.action == "allow" then
		return { state = "allow", matched_pattern = result.matchedPattern or result.matched_pattern }
	end
	return { state = "ask" }
end

function SessionApprovalStore:get_rules()
	local out = {}
	for i, rule in ipairs(self.rules) do
		out[i] = { tool = rule.tool, pattern = rule.pattern, action = rule.action }
	end
	return out
end

function SessionApprovalStore:clear()
	self.rules = {}
end

--- Overlay a session approval on top of a config-derived check result. If
--- the config result is already "deny", it's returned unchanged — a
--- session approval can never relax a deny. Otherwise, if a "subject"
--- (bash command / mcp target / normalized path / bare tool name — the
--- caller decides what's meaningful per tool) has an "Allow Always" rule,
--- that wins over "ask".
function approval.apply_pattern_state(store, tool_name, subject, result)
	if result.state == "deny" then
		return result
	end
	local evaluation = store:evaluate(tool_name, subject)
	if evaluation.state == "allow" then
		local overlaid = {}
		for k, v in pairs(result) do
			overlaid[k] = v
		end
		overlaid.state = "allow"
		overlaid.source = "session_approval"
		overlaid.matched_pattern = evaluation.matched_pattern
		return overlaid
	end
	return result
end

return approval
