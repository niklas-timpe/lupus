-- Wildcard pattern compilation and matching.
--
-- pi's wildcard-matcher.ts compiles each glob to a JS regex (`*`->`.*`,
-- `?`->`.`) plus one non-standard extension: a pattern ending in " *" (a
-- literal trailing space then star, e.g. "git *") also matches the bare
-- prefix with no trailing space ("git"), via `escaped.endsWith(" .*")` ->
-- rewritten to `( .*)?`.
--
-- That rewrite doesn't survive translation to Lua patterns: Lua's `?`
-- quantifier only applies to the single preceding character class, never
-- to a parenthesized group — `(...)?`is not a thing in Lua patterns (its
-- parens are capture-only). Rather than fight that, this compiles each
-- glob into a small closure that walks the glob directly (classic iterative
-- fnmatch-style matching: `*` = any run of chars, `?` = any one char,
-- everything else literal, full-string anchored, case-sensitive) and
-- special-cases the " *" trailing-space extension as a second, explicit
-- check. Same observable behavior as pi's regex, no Lua-pattern
-- contortions.

local common = require("permission_system.common")

local wildcard = {}

local MAX_PATTERN_LENGTH = 500

--- Anchored glob match: '*' = any run of characters (incl. none),
--- '?' = exactly one character, everything else literal.
local function glob_match(glob, name)
	local gi, gn = 1, #glob
	local ni, nn = 1, #name
	local star_gi, star_ni = nil, nil

	while ni <= nn do
		local gc = gi <= gn and glob:sub(gi, gi) or nil
		if gc and (gc == "?" or gc == name:sub(ni, ni)) then
			gi = gi + 1
			ni = ni + 1
		elseif gc == "*" then
			star_gi, star_ni = gi, ni
			gi = gi + 1
		elseif star_gi then
			gi = star_gi + 1
			star_ni = star_ni + 1
			ni = star_ni
		else
			return false
		end
	end

	while gi <= gn and glob:sub(gi, gi) == "*" do
		gi = gi + 1
	end
	return gi > gn
end

--- Compile one pattern -> value entry into a matcher closure.
--- `value` is opaque (permission state, or a {state,layer,trusted} record
--- for manager.lua's layered patterns) — this module never inspects it.
function wildcard.compile(pattern, value)
	if #pattern > MAX_PATTERN_LENGTH then
		return {
			pattern = pattern,
			value = value,
			match = function()
				return false
			end,
		}
	end

	local glob = pattern:gsub("\\", "/")
	local trailing_space_star = glob:sub(-2) == " *"
	local bare_prefix = trailing_space_star and glob:sub(1, -3) or nil

	return {
		pattern = pattern,
		value = value,
		match = function(name)
			if glob_match(glob, name) then
				return true
			end
			return trailing_space_star and name == bare_prefix or false
		end,
	}
end

--- Compile an ordered list of { pattern = , value = } into matchers,
--- preserving order (order is what makes last-match-wins meaningful).
function wildcard.compile_entries(entries)
	local out = {}
	for _, entry in ipairs(entries) do
		out[#out + 1] = wildcard.compile(entry.pattern, entry.value)
	end
	return out
end

--- Names are normalized the same way patterns are (backslash -> forward
--- slash) before matching. Exposed so callers that invoke a compiled
--- entry's `match` directly (bypassing find_match), such as
--- approval.lua's rule-by-rule evaluation, stay consistent.
function wildcard.normalize_name(name)
	return (name:gsub("\\", "/"))
end

--- Scan compiled patterns last -> first (last-declared wins) and return the
--- first match against `name`, or nil.
function wildcard.find_match(compiled, name)
	local normalized_name = wildcard.normalize_name(name)
	for i = #compiled, 1, -1 do
		local entry = compiled[i]
		if entry.match(normalized_name) then
			return { value = entry.value, matched_pattern = entry.pattern, matched_name = name }
		end
	end
	return nil
end

--- Try each candidate name (in order) against the compiled list, returning
--- the first match found. Used where a check has several equally-valid
--- target strings (e.g. "read:/abs/path" then bare "read").
function wildcard.find_match_for_names(compiled, names)
	return common.find_first_match_for_names(names, function(name)
		return wildcard.find_match(compiled, name)
	end)
end

return wildcard
