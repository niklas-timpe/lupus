-- Child processes for the event loop, on top of uv.spawn. libuv owns the
-- fork/exec dance, pipe plumbing, and child reaping; this module adapts the
-- result to the task model.
--
--   local proc = process.spawn{ argv = {"ls", "-la"}, cwd = ?, env = ?,
--                               stdin = "pipe"|nil, pgroup = true|nil }
--   proc.stdout, proc.stderr      -- loop readers: proc.stdout:read() yields
--   proc.stdin                    -- uv pipe for loop.write (when stdin="pipe")
--   proc:wait() -> exit_code            -- yields (127+signal for kills)
--   proc:kill(sig) / proc:terminate()   -- terminate: TERM, 2s grace, KILL
--   proc:close_stdin()
--
-- `env` entries are additive on top of the inherited environment, matching
-- setenv-in-the-child semantics. `pgroup = true` detaches the child into its
-- own process group so kill/terminate reach grandchildren too.

local uv = require("luv")
local loop = require("lupus.loop.core")
local log = require("lupus.util.log")

local process = {}

local procs = {} -- pid -> proc (until exited)

local Proc = {}
Proc.__index = Proc

local function merged_env(extra)
	if not extra then
		return nil
	end
	local env = {}
	for k, v in pairs(uv.os_environ()) do
		if extra[k] == nil then
			env[#env + 1] = k .. "=" .. v
		end
	end
	for k, v in pairs(extra) do
		env[#env + 1] = k .. "=" .. tostring(v)
	end
	return env
end

--- A proc that never ran (exec failed synchronously). Mirrors the shape of
--- a real proc: exit code 127, the error readable from stderr.
local function failed_proc(message)
	local fake_reader = function(msg)
		local given = false
		return {
			read = function()
				if given or not msg then
					return nil
				end
				given = true
				return msg
			end,
			close = function() end,
		}
	end
	return setmetatable({
		pid = -1,
		pgroup = false,
		stdin = nil,
		stdout = fake_reader(nil),
		stderr = fake_reader("lupus: exec failed: " .. message .. "\n"),
		exit_code = 127,
		exit_kind = "exited",
		waiters = {},
	}, Proc)
end

--- Spawn a child. argv[1] is resolved via PATH. Never yields; a missing
--- executable reports exit code 127 with the error on stderr, like a shell.
function process.spawn(opts)
	local argv = assert(opts.argv, "process.spawn requires argv")
	assert(#argv > 0, "argv must not be empty")

	local stdin_pipe = opts.stdin == "pipe" and uv.new_pipe(false) or nil
	local stdout_pipe = uv.new_pipe(false)
	local stderr_pipe = uv.new_pipe(false)

	local args = {}
	for i = 2, #argv do
		args[i - 1] = argv[i]
	end

	local proc
	local handle, pid = uv.spawn(argv[1], {
		args = args,
		stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
		cwd = opts.cwd,
		env = merged_env(opts.env),
		detached = opts.pgroup or false,
		hide = true,
	}, function(code, signal)
		procs[proc.pid] = nil
		proc.exit_code = signal ~= 0 and 127 + signal or code
		proc.exit_kind = signal ~= 0 and "killed" or "exited"
		if proc.kill_timer then
			proc.kill_timer:cancel()
			proc.kill_timer = nil
		end
		if proc.handle and not proc.handle:is_closing() then
			proc.handle:close()
		end
		proc.handle = nil
		for _, task in ipairs(proc.waiters) do
			loop._wake(task, true)
		end
		proc.waiters = {}
	end)

	if not handle then
		for _, p in ipairs({ stdin_pipe, stdout_pipe, stderr_pipe }) do
			if p then
				p:close()
			end
		end
		log.debug("spawn failed: %s (%s)", argv[1], tostring(pid))
		return failed_proc(tostring(argv[1]) .. " (" .. tostring(pid) .. ")")
	end

	proc = setmetatable({
		pid = pid,
		handle = handle,
		pgroup = opts.pgroup or false,
		stdin = stdin_pipe,
		stdout = loop.reader(stdout_pipe),
		stderr = loop.reader(stderr_pipe),
		exit_code = nil,
		waiters = {},
	}, Proc)
	procs[pid] = proc
	log.debug("spawned pid %d: %s", pid, table.concat(argv, " "))
	return proc
end

--- Wait for exit. Returns the exit code (killed children report
--- 127 + signal number). yields
function Proc:wait()
	if self.exit_code == nil then
		local me = loop.current_task()
		self.waiters[#self.waiters + 1] = me
		loop._park(function()
			for i, t in ipairs(self.waiters) do
				if t == me then
					table.remove(self.waiters, i)
					break
				end
			end
		end)
	end
	return self.exit_code
end

function Proc:is_running()
	return self.exit_code == nil
end

--- Send a signal (default "sigterm"; accepts uv signal names or numbers).
--- Signals the whole process group when the child was spawned with
--- pgroup = true, so grandchildren die too.
function Proc:kill(sig)
	if self.exit_code ~= nil then
		return
	end
	sig = sig or "sigterm"
	if self.pgroup and self.pid > 0 then
		uv.kill(-self.pid, sig)
	elseif self.handle then
		self.handle:kill(sig)
	end
end

--- Graceful stop: SIGTERM now, SIGKILL after 2 seconds if still alive.
function Proc:terminate()
	if self.exit_code ~= nil then
		return
	end
	self:kill("sigterm")
	if not self.kill_timer then
		self.kill_timer = loop.timer(2000, function()
			self.kill_timer = nil
			self:kill("sigkill")
		end)
	end
end

--- Close the write end of the child's stdin (signals EOF to the child).
function Proc:close_stdin()
	if self.stdin then
		local pipe = self.stdin
		self.stdin = nil
		if not pipe:is_closing() then
			pipe:shutdown(function()
				if not pipe:is_closing() then
					pipe:close()
				end
			end)
		end
	end
end

--- Close remaining parent-side pipes. Call after the streams are drained.
function Proc:close()
	self:close_stdin()
	if self.stdout then
		self.stdout:close()
	end
	if self.stderr then
		self.stderr:close()
	end
end

--- Kill every child lupus still tracks (used on shutdown).
function process.kill_all()
	for _, proc in pairs(procs) do
		proc:kill("sigkill")
	end
end

return process
