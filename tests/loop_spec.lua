local loop = require("lupus.loop")
local channel = require("lupus.loop.channel")
local uv = require("luv")

--- A connected uv pipe pair (read side, write side) for stream tests.
local function pipe_pair()
	local fds = uv.pipe({ nonblock = true }, { nonblock = true })
	local r = uv.new_pipe(false)
	r:open(fds.read)
	local w = uv.new_pipe(false)
	w:open(fds.write)
	return r, w
end

describe("loop", function()
	it("runs a main task to completion and returns its results", function()
		local ok, a, b = loop.run(function()
			return 1, "two"
		end)
		assert.is_true(ok)
		assert.equals(1, a)
		assert.equals("two", b)
	end)

	it("propagates main task errors as ok=false", function()
		local ok, err = loop.run(function()
			error("boom")
		end)
		assert.is_false(ok)
		assert.matches("boom", err)
	end)

	it("spawns tasks and joins them", function()
		local ok, sum = loop.run(function()
			local t1 = loop.spawn(function()
				return 10
			end)
			local t2 = loop.spawn(function()
				loop.sleep(5)
				return 20
			end)
			local _, a = t1:join()
			local _, b = t2:join()
			return a + b
		end)
		assert.is_true(ok)
		assert.equals(30, sum)
	end)

	it("sleep respects ordering", function()
		local order = {}
		loop.run(function()
			local t1 = loop.spawn(function()
				loop.sleep(30)
				order[#order + 1] = "slow"
			end)
			local t2 = loop.spawn(function()
				loop.sleep(5)
				order[#order + 1] = "fast"
			end)
			t1:join()
			t2:join()
		end)
		assert.same({ "fast", "slow" }, order)
	end)

	it("cancels a sleeping task", function()
		local finished = false
		local ok = loop.run(function()
			local t = loop.spawn(function()
				loop.sleep(60000)
				finished = true
			end)
			loop.sleep(5)
			t:cancel()
			local jok, jerr = t:join()
			assert.is_false(jok)
			assert.equals("cancelled", jerr)
		end)
		assert.is_true(ok)
		assert.is_false(finished)
	end)

	it("timer callbacks fire, intervals repeat, cancel stops them", function()
		local ticks = 0
		loop.run(function()
			local h = loop.interval(5, function()
				ticks = ticks + 1
			end)
			loop.sleep(28)
			h:cancel()
			local at_cancel = ticks
			loop.sleep(20)
			assert.equals(at_cancel, ticks)
		end)
		assert.is_true(ticks >= 3)
	end)

	it("reads and writes across a pipe", function()
		local ok = loop.run(function()
			local r, w = pipe_pair()
			local reader = loop.reader(r)
			local writer = loop.spawn(function()
				loop.write(w, ("x"):rep(200000)) -- larger than the pipe buffer
				w:close()
			end)
			local total = 0
			while true do
				local chunk = reader:read()
				if not chunk then
					break
				end
				total = total + #chunk
			end
			reader:close()
			writer:join()
			assert.equals(200000, total)
		end)
		assert.is_true(ok)
	end)

	it("reader read times out", function()
		local ok = loop.run(function()
			local r, w = pipe_pair()
			local reader = loop.reader(r)
			local res, err = reader:read(10)
			assert.is_nil(res)
			assert.equals("timeout", err)
			reader:close()
			w:close()
		end)
		assert.is_true(ok)
	end)
end)

describe("channel", function()
	it("passes values between tasks in order", function()
		local got = {}
		loop.run(function()
			local ch = channel.new()
			loop.spawn(function()
				for i = 1, 5 do
					ch:send(i)
				end
				ch:close()
			end)
			for v in ch:iter() do
				got[#got + 1] = v
			end
		end)
		assert.same({ 1, 2, 3, 4, 5 }, got)
	end)

	it("recv blocks until a value arrives", function()
		loop.run(function()
			local ch = channel.new()
			loop.spawn(function()
				loop.sleep(10)
				ch:send("late")
			end)
			assert.equals("late", ch:recv())
		end)
	end)

	it("bounded channels apply backpressure", function()
		local sent = {}
		loop.run(function()
			local ch = channel.new(2)
			loop.spawn(function()
				for i = 1, 4 do
					ch:send(i)
					sent[#sent + 1] = i
				end
				ch:close()
			end)
			loop.sleep(10)
			-- Producer should be stuck after filling capacity 2.
			assert.equals(2, #sent)
			for _ in ch:iter() do
				loop.sleep(1)
			end
			assert.equals(4, #sent)
		end)
	end)

	it("close wakes blocked receivers", function()
		loop.run(function()
			local ch = channel.new()
			loop.spawn(function()
				loop.sleep(5)
				ch:close()
			end)
			local v, err = ch:recv()
			assert.is_nil(v)
			assert.equals("closed", err)
		end)
	end)
end)

describe("process", function()
	it("captures stdout and exit code", function()
		loop.run(function()
			local proc = loop.process.spawn({ argv = { "sh", "-c", "printf hello; exit 3" } })
			local out = {}
			while true do
				local chunk = proc.stdout:read()
				if not chunk then
					break
				end
				out[#out + 1] = chunk
			end
			local code = proc:wait()
			proc:close()
			assert.equals("hello", table.concat(out))
			assert.equals(3, code)
		end)
	end)

	it("feeds stdin through a pipe", function()
		loop.run(function()
			local proc = loop.process.spawn({ argv = { "cat" }, stdin = "pipe" })
			loop.write(proc.stdin, "echo me")
			proc:close_stdin()
			local out = proc.stdout:read()
			assert.equals("echo me", out)
			assert.equals(0, proc:wait())
			proc:close()
		end)
	end)

	it("kill terminates a long-running child", function()
		loop.run(function()
			local proc = loop.process.spawn({ argv = { "sleep", "30" } })
			loop.sleep(10)
			proc:kill()
			local code = proc:wait()
			proc:close()
			assert.is_true(code > 127) -- 127 + SIGTERM
		end)
	end)

	it("reports a missing executable as exit 127", function()
		loop.run(function()
			local proc = loop.process.spawn({ argv = { "definitely-not-a-binary-xyz" } })
			local code = proc:wait()
			local err = proc.stderr:read() or ""
			proc:close()
			assert.equals(127, code)
			assert.matches("exec failed", err)
		end)
	end)

	it("respects cwd", function()
		loop.run(function()
			local proc = loop.process.spawn({ argv = { "pwd" }, cwd = "/tmp" })
			local out = proc.stdout:read() or ""
			proc:wait()
			proc:close()
			assert.matches("/tmp", out)
		end)
	end)
end)
