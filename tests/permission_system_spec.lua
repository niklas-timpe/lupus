-- Core logic: jsonc ordering, wildcard matching, session approvals, and
-- the manager's checkPermission/getToolPermission dispatch (trusted-floor
-- rule, resource-qualified path rules, bash/mcp targets). See llm.md for
-- the design log this ports from (pi-permission-system).

local fs = require("lupus.util.fs")
local jsonc = require("permission_system.jsonc")
local wildcard = require("permission_system.wildcard")
local approval = require("permission_system.approval")
local manager_mod = require("permission_system.manager")

-- ---------------------------------------------------------------------------

describe("permission_system.jsonc", function()
	it("preserves object key declaration order", function()
		local v = jsonc.parse('{"a":1,"b":2,"a":3}')
		assert.same({ "a", "b" }, v.__keys)
		assert.equals(3, v.a) -- last value wins, position stays put
	end)

	it("supports // and /* */ comments and trailing commas", function()
		local v, err = jsonc.parse([[
      {
        // a comment
        "x": 1, /* inline */
        "y": 2,
      }
    ]])
		assert.is_nil(err)
		assert.equals(1, v.x)
		assert.equals(2, v.y)
	end)

	it("returns a line/column error on malformed input", function()
		local v, err = jsonc.parse("{ bad")
		assert.is_nil(v)
		assert.equals(1, err.line)
	end)

	it("strips a leading BOM", function()
		local v = jsonc.parse("\239\187\191{\"a\":1}")
		assert.equals(1, v.a)
	end)
end)

-- ---------------------------------------------------------------------------

describe("permission_system.wildcard", function()
	local function compiled(entries)
		return wildcard.compile_entries(entries)
	end

	it("last-match-wins within a compiled list", function()
		local c = compiled({
			{ pattern = "*", value = "deny" },
			{ pattern = "git *", value = "ask" },
			{ pattern = "git status", value = "allow" },
		})
		assert.equals("allow", wildcard.find_match(c, "git status").value)
		assert.equals("ask", wildcard.find_match(c, "git push").value)
		assert.equals("deny", wildcard.find_match(c, "ls -la").value)
	end)

	it("a trailing ' *' pattern also matches the bare prefix", function()
		local c = compiled({ { pattern = "git *", value = "ask" } })
		assert.equals("ask", wildcard.find_match(c, "git").value)
		assert.equals("ask", wildcard.find_match(c, "git status").value)
		assert.is_nil(wildcard.find_match(c, "gitx"))
	end)

	it("? matches exactly one character", function()
		local c = compiled({ { pattern = "a?c", value = "allow" } })
		assert.equals("allow", wildcard.find_match(c, "abc").value)
		assert.is_nil(wildcard.find_match(c, "ac"))
		assert.is_nil(wildcard.find_match(c, "abbc"))
	end)

	it("patterns over 500 characters never match", function()
		local c = compiled({ { pattern = ("a"):rep(501), value = "allow" } })
		assert.is_nil(wildcard.find_match(c, ("a"):rep(501)))
	end)

	it("find_match_for_names tries each candidate name in turn", function()
		local c = compiled({ { pattern = "read:/tmp/*", value = "allow" } })
		local m = wildcard.find_match_for_names(c, { "read:/other/path", "read" })
		assert.is_nil(m) -- neither candidate matches "read:/tmp/*"
		local m2 = wildcard.find_match_for_names(c, { "read:/tmp/x", "read" })
		assert.equals("allow", m2.value)
	end)
end)

-- ---------------------------------------------------------------------------

describe("permission_system.approval", function()
	it("evaluate_permission requires both tool and pattern to match, last wins", function()
		local rules = {
			{ tool = "bash", pattern = "*", action = "ask" },
			{ tool = "bash", pattern = "git *", action = "allow" },
		}
		assert.equals("allow", approval.evaluate_permission("bash", "git push", rules).action)
		assert.equals("ask", approval.evaluate_permission("bash", "rm -rf /", rules).action)
		assert.equals("ask", approval.evaluate_permission("write", "git push", rules).action) -- tool doesn't match
	end)

	it("session store only ever grants allow, never overrides deny", function()
		local store = approval.new_store()
		assert.is_false(store:has_session_approval("bash", "git push"))
		store:approve_always("bash", "git push")
		assert.is_true(store:has_session_approval("bash", "git push"))
		assert.is_false(store:has_session_approval("bash", "rm -rf /"))

		local overlaid = approval.apply_pattern_state(store, "bash", "git push", { state = "ask", source = "bash" })
		assert.equals("allow", overlaid.state)
		assert.equals("session_approval", overlaid.source)

		local still_denied = approval.apply_pattern_state(store, "bash", "git push", { state = "deny", source = "bash" })
		assert.equals("deny", still_denied.state)
	end)
end)

-- ---------------------------------------------------------------------------

describe("permission_system.manager", function()
	local tmp

	before_each(function()
		tmp = "/tmp/lupus-permsys-test-" .. tostring(math.random(1e9))
		fs.mkdirp(tmp)
	end)

	after_each(function()
		os.execute("rm -rf " .. tmp)
	end)

	local function write(path, content)
		fs.mkdirp(fs.dirname(path))
		fs.write_file(path, content)
	end

	it("falls back to ask when no config file exists", function()
		local m = manager_mod.new({ global_config_path = tmp .. "/missing.jsonc" })
		local r = m:check_permission("bash", { command = "ls" }, tmp)
		assert.equals("ask", r.state)
	end)

	it("resolves bash command patterns with last-match-wins", function()
		write(
			tmp .. "/g.jsonc",
			[[{ "bash": { "*": "deny", "git *": "ask", "git status": "allow" } }]]
		)
		local m = manager_mod.new({ global_config_path = tmp .. "/g.jsonc" })
		assert.equals("allow", m:check_permission("bash", { command = "git status" }, tmp).state)
		assert.equals("ask", m:check_permission("bash", { command = "git push" }, tmp).state)
		assert.equals("deny", m:check_permission("bash", { command = "rm -rf /" }, tmp).state)
	end)

	it("resource-qualifies path tool rules (read:/abs/path/*)", function()
		write(
			tmp .. "/g.jsonc",
			([[{ "tools": { "read": "allow", "read:%s/secret/*": "deny" } }]]):format(tmp)
		)
		local m = manager_mod.new({ global_config_path = tmp .. "/g.jsonc" })
		assert.equals("allow", m:check_permission("read", { path = "plain.txt" }, tmp).state)
		local denied = m:check_permission("read", { path = "secret/x.txt" }, tmp)
		assert.equals("deny", denied.state)
		assert.equals("read:" .. tmp .. "/secret/x.txt", denied.target)
	end)

	it("an untrusted project layer can tighten but never relax a trusted deny", function()
		write(tmp .. "/g.jsonc", [[{ "bash": { "rm -rf *": "deny" } }]])
		write(tmp .. "/p.jsonc", [[{ "bash": { "rm -rf *": "allow" } }]])
		local m = manager_mod.new({ global_config_path = tmp .. "/g.jsonc", project_config_path = tmp .. "/p.jsonc" })
		assert.equals("deny", m:check_permission("bash", { command = "rm -rf /" }, tmp).state)
	end)

	it("an untrusted project layer CAN tighten a trusted allow", function()
		write(tmp .. "/g.jsonc", [[{ "bash": { "git push": "allow" } }]])
		write(tmp .. "/p.jsonc", [[{ "bash": { "git push": "deny" } }]])
		local m = manager_mod.new({ global_config_path = tmp .. "/g.jsonc", project_config_path = tmp .. "/p.jsonc" })
		assert.equals("deny", m:check_permission("bash", { command = "git push" }, tmp).state)
	end)

	it("top-level scalar shorthand folds into tools/special", function()
		write(tmp .. "/g.jsonc", [[{ "read": "allow", "doom_loop": "deny" }]])
		local m = manager_mod.new({ global_config_path = tmp .. "/g.jsonc" })
		assert.equals("allow", m:get_tool_permission("read"))
		assert.equals("deny", m:check_permission("doom_loop", {}, tmp).state)
	end)

	it("get_tool_permission is tool-level only, ignoring command rules", function()
		write(tmp .. "/g.jsonc", [[{ "bash": { "git status": "allow" }, "defaultPolicy": { "bash": "deny" } }]])
		local m = manager_mod.new({ global_config_path = tmp .. "/g.jsonc" })
		assert.equals("deny", m:get_tool_permission("bash"))
	end)

	it("warns and falls back to ask on malformed config, without crashing", function()
		write(tmp .. "/bad.jsonc", "{ oops")
		local warnings = {}
		local m = manager_mod.new({
			global_config_path = tmp .. "/bad.jsonc",
			on_warning = function(msg)
				warnings[#warnings + 1] = msg
			end,
		})
		assert.equals("ask", m:check_permission("bash", { command = "ls" }, tmp).state)
		assert.equals(1, #warnings)
	end)

	it("mcp targets fall back to a baseline allow only when some mcp rule allows", function()
		write(tmp .. "/g.jsonc", [[{ "mcp": { "my_server_tool": "allow" } }]])
		local m = manager_mod.new({ global_config_path = tmp .. "/g.jsonc" })
		local r = m:check_permission("mcp", {}, tmp) -- no tool/server/connect/etc → "mcp_status" baseline target
		assert.equals("allow", r.state)
		assert.equals("mcp_status", r.target)
	end)
end)
