-- Prompt/deny-reason formatters (lupus tool argument shapes) and the
-- dialog's prompt-compaction helper.

local prompts = require("permission_system.prompts")
local dialog = require("permission_system.dialog")

describe("permission_system.prompts", function()
	it("formats a bash ask prompt with the matched pattern", function()
		local msg = prompts.format_ask_prompt({
			tool_name = "bash",
			command = "git push",
			matched_pattern = "git *",
		})
		assert.matches("bash command 'git push'", msg, 1, true)
		assert.matches("matched 'git %*'", msg)
	end)

	it("formats a read/write/edit tool preview using lupus's field names", function()
		local read_msg = prompts.format_ask_prompt({ tool_name = "read" }, nil, { path = "a.txt", offset = 10 })
		assert.matches("path 'a.txt'", read_msg, 1, true)
		assert.matches("offset 10", read_msg, 1, true)

		local write_msg = prompts.format_ask_prompt({ tool_name = "write" }, nil, { path = "a.txt", content = "hi\nthere" })
		assert.matches("2 lines", write_msg, 1, true)

		local edit_msg = prompts.format_ask_prompt(
			{ tool_name = "edit" },
			nil,
			{ path = "a.txt", old_string = "x", new_string = "y\nz", replace_all = true }
		)
		assert.matches("all occurrences", edit_msg, 1, true)
	end)

	it("deny reason includes a hard-stop hint", function()
		local reason = prompts.format_deny_reason({ tool_name = "bash", command = "rm -rf /", matched_pattern = "rm *" })
		assert.matches("Hard stop", reason, 1, true)
		assert.matches("matched 'rm %*'", reason)
	end)

	it("user-denied reason includes the given reason", function()
		local reason = prompts.format_user_denied_reason({ tool_name = "write" }, "not today")
		assert.matches("User denied tool 'write'", reason, 1, true)
		assert.matches("Reason: not today", reason, 1, true)
	end)

	it("mcp results are framed as MCP targets, not raw tool names", function()
		local msg = prompts.format_ask_prompt({ tool_name = "mcp", source = "mcp", target = "server_tool" })
		assert.matches("MCP target 'server_tool'", msg, 1, true)
	end)

	it("external_directory prompts name both the path and the cwd", function()
		local msg = prompts.format_external_directory_ask_prompt("read", "/outside/x", "/project")
		assert.matches("/outside/x", msg, 1, true)
		assert.matches("/project", msg, 1, true)
	end)
end)

describe("permission_system.dialog", function()
	it("passes short prompts through unchanged", function()
		assert.equals("short prompt", dialog.compact_prompt("short prompt"))
	end)

	it("compacts an oversized prompt with a notice", function()
		local huge = ("x"):rep(3000)
		local out = dialog.compact_prompt(huge)
		assert.is_true(#out <= 2200)
		assert.matches("Permission prompt compacted", out, 1, true)
	end)
end)
