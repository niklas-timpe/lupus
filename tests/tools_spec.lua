local loop = require("lupus.loop")
local fs = require("lupus.util.fs")
local tools = require("lupus.tools")

local tmp

local function tool(name)
	for _, t in ipairs(tools.builtin()) do
		if t.name == name then
			return t
		end
	end
	error("no such tool: " .. name)
end

local function ctx(overrides)
	local c = {
		cwd = tmp,
		tool_call_id = "t1",
		aborted = function()
			return false
		end,
	}
	for k, v in pairs(overrides or {}) do
		c[k] = v
	end
	return c
end

--- Run a tool inside the event loop, pcall-style.
local function run_tool(name, args, c)
	local ok, res
	loop.run(function()
		ok, res = pcall(tool(name).execute, args, c or ctx())
	end)
	return ok, res
end

describe("built-in tools", function()
	before_each(function()
		tmp = "/tmp/lupus-test-" .. tostring(math.random(1e8))
		fs.mkdirp(tmp)
	end)

	after_each(function()
		os.execute("rm -rf '" .. tmp .. "'")
	end)

	describe("read", function()
		it("reads a file", function()
			fs.write_file(tmp .. "/a.txt", "line1\nline2\nline3")
			local ok, out = run_tool("read", { path = "a.txt" })
			assert.is_true(ok)
			assert.equals("line1\nline2\nline3", out)
		end)

		it("supports offset and limit", function()
			fs.write_file(tmp .. "/a.txt", "l1\nl2\nl3\nl4")
			local ok, out = run_tool("read", { path = "a.txt", offset = 2, limit = 2 })
			assert.is_true(ok)
			assert.matches("^l2\nl3\n%[lines 2%-3 of 4%]$", out)
		end)

		it("errors on missing files and directories", function()
			local ok, err = run_tool("read", { path = "missing.txt" })
			assert.is_false(ok)
			assert.matches("cannot read", err)
			local ok2, err2 = run_tool("read", { path = "." })
			assert.is_false(ok2)
			assert.matches("directory", err2)
		end)

		it("rejects binary files", function()
			fs.write_file(tmp .. "/bin", "abc\0def")
			local ok, err = run_tool("read", { path = "bin" })
			assert.is_false(ok)
			assert.matches("binary", err)
		end)
	end)

	describe("write", function()
		it("creates files with parent directories", function()
			local ok, res = run_tool("write", { path = "sub/dir/new.txt", content = "hello\nworld" })
			assert.is_true(ok)
			assert.matches("Created", res.content)
			assert.equals("hello\nworld", fs.read_file(tmp .. "/sub/dir/new.txt"))
		end)

		it("reports updates of existing files", function()
			fs.write_file(tmp .. "/x.txt", "old")
			local ok, res = run_tool("write", { path = "x.txt", content = "new" })
			assert.is_true(ok)
			assert.matches("Updated", res.content)
		end)
	end)

	describe("edit", function()
		it("replaces a unique string", function()
			fs.write_file(tmp .. "/e.txt", "aaa\nbbb\nccc")
			local ok, res = run_tool("edit", { path = "e.txt", old_string = "bbb", new_string = "BBB" })
			assert.is_true(ok)
			assert.equals("aaa\nBBB\nccc", fs.read_file(tmp .. "/e.txt"))
			assert.equals(1, res.details.replacements)
		end)

		it("treats old_string literally (no patterns)", function()
			fs.write_file(tmp .. "/e.txt", "a%d+b")
			local ok = run_tool("edit", { path = "e.txt", old_string = "a%d+b", new_string = "X" })
			assert.is_true(ok)
			assert.equals("X", fs.read_file(tmp .. "/e.txt"))
		end)

		it("rejects ambiguous matches without replace_all", function()
			fs.write_file(tmp .. "/e.txt", "dup\ndup")
			local ok, err = run_tool("edit", { path = "e.txt", old_string = "dup", new_string = "x" })
			assert.is_false(ok)
			assert.matches("2 times", err)
			local ok2 = run_tool("edit", { path = "e.txt", old_string = "dup", new_string = "x", replace_all = true })
			assert.is_true(ok2)
			assert.equals("x\nx", fs.read_file(tmp .. "/e.txt"))
		end)

		it("errors when old_string is missing", function()
			fs.write_file(tmp .. "/e.txt", "content")
			local ok, err = run_tool("edit", { path = "e.txt", old_string = "nope", new_string = "x" })
			assert.is_false(ok)
			assert.matches("not found", err)
		end)
	end)

	describe("bash", function()
		it("runs commands in the working directory", function()
			local ok, res = run_tool("bash", { command = "echo hello && pwd" })
			assert.is_true(ok)
			assert.matches("hello", res.content)
			assert.matches(tmp:gsub("%-", "%%-"), res.content)
			assert.equals(0, res.details.exit_code)
		end)

		it("captures stderr and nonzero exits as error results", function()
			local ok, res = run_tool("bash", { command = "echo oops >&2; exit 3" })
			assert.is_true(ok) -- not an exception: an error *result*
			assert.is_true(res.is_error)
			assert.matches("oops", res.content)
			assert.matches("exit code 3", res.content)
		end)

		it("times out long commands", function()
			local ok, err = run_tool("bash", { command = "sleep 10", timeout = 1 })
			assert.is_false(ok)
			assert.matches("timed out", err)
		end)

		it("aborts when requested", function()
			local aborted = false
			local c = ctx({
				aborted = function()
					return aborted
				end,
			})
			local ok, err
			loop.run(function()
				loop.timer(100, function()
					aborted = true
				end)
				ok, err = pcall(tool("bash").execute, { command = "sleep 10" }, c)
			end)
			assert.is_false(ok)
			assert.matches("aborted", err)
		end)
	end)

	describe("ls", function()
		it("lists directories first with slashes", function()
			fs.mkdirp(tmp .. "/zdir")
			fs.write_file(tmp .. "/afile", "x")
			local ok, out = run_tool("ls", {})
			assert.is_true(ok)
			assert.equals("zdir/\nafile", out)
		end)
	end)

	describe("grep", function()
		it("finds matches with path:line prefix", function()
			fs.write_file(tmp .. "/g.txt", "alpha\nbeta\ngamma")
			local ok, out = run_tool("grep", { pattern = "beta" })
			assert.is_true(ok)
			assert.matches("g%.txt:2:beta", out)
		end)

		it("reports no matches cleanly", function()
			fs.write_file(tmp .. "/g.txt", "alpha")
			local ok, out = run_tool("grep", { pattern = "zzz" })
			assert.is_true(ok)
			assert.equals("No matches found", out)
		end)
	end)

	describe("find", function()
		it("finds files by glob, skipping .git", function()
			fs.mkdirp(tmp .. "/src")
			fs.mkdirp(tmp .. "/.git")
			fs.write_file(tmp .. "/src/a.lua", "")
			fs.write_file(tmp .. "/.git/b.lua", "")
			local ok, out = run_tool("find", { pattern = "*.lua" })
			assert.is_true(ok)
			assert.matches("src/a%.lua", out)
			assert.is_nil(out:find(".git/b.lua", 1, true))
		end)
	end)

	describe("truncate helper", function()
		it("keeps the tail for bash-style output", function()
			local long = {}
			for i = 1, 3000 do
				long[i] = "line " .. i
			end
			local out = tools.truncate(table.concat(long, "\n"), "tail")
			assert.matches("^%[truncated", out)
			assert.matches("line 3000$", out)
			assert.is_nil(out:find("line 1\n", 1, true))
		end)

		it("keeps the head for file reads", function()
			local long = {}
			for i = 1, 3000 do
				long[i] = "line " .. i
			end
			local out = tools.truncate(table.concat(long, "\n"), "head")
			assert.matches("^line 1\n", out)
			assert.matches("%[truncated[^\n]*%]$", out)
		end)

		it("leaves short output alone", function()
			local out, note = tools.truncate("short", "head")
			assert.equals("short", out)
			assert.is_nil(note)
		end)
	end)
end)
