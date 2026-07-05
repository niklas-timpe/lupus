-- Cooperative event loop: a coroutine scheduler driven by libuv (via luv).
--
-- Everything in lupus that can block — reading the tty, streaming an HTTP
-- response through curl, waiting on a bash tool, sleeping for a spinner
-- frame — runs inside a "task" (a coroutine managed here) and yields to this
-- scheduler instead of blocking the process. libuv supplies timers, signals,
-- stream I/O, and child processes; this module supplies the task model on
-- top: uv callbacks never run user coroutines directly, they only mark tasks
-- ready, and the scheduler resumes them between uv iterations.
--
--   loop.run(main)                 run the scheduler until all tasks finish
--   loop.spawn(fn, ...) -> task    start a task; task:cancel(), task:join()
--   loop.sleep(ms)                                              -- yields
--   loop.reader(uv_stream) -> r    r:read([timeout_ms]) -> chunk |
--                                    nil on EOF | nil, "timeout" -- yields
--   loop.read(r [, timeout_ms])    alias for r:read(timeout_ms)
--   loop.write(uv_stream, data) -> true | nil, err              -- yields
--   loop.timer(ms, fn) / loop.interval(ms, fn) -> handle:cancel()
--   loop.on_signal("SIGWINCH", fn) -> unregister function
--
-- Signal handlers and timer callbacks run in scheduler context and must not
-- yield; spawn a task from them for anything blocking.
--
-- The task/timer/reader/scheduler primitives live in lupus.loop.core: that
-- keeps this module's own dependents (lupus.loop.process, lupus.loop.channel)
-- from having to require this whole module back, which would be a require()
-- cycle Lua can't unwind. This module just adds signal handling (which never
-- touches scheduler state) and attaches lupus.loop.process.

local core = require("lupus.loop.core")
local uv = require("luv")
local log = require("lupus.util.log")

local loop = core

-- ---------------------------------------------------------------------------
-- Signals. One uv signal watcher per signal name; handlers run in scheduler
-- context (uv callback) and must not yield.

local signal_handlers = {} -- signame -> array of fns
local signal_watchers = {} -- signame -> uv_signal_t

function loop.on_signal(signame, fn)
	local handlers = signal_handlers[signame]
	if not handlers then
		handlers = {}
		signal_handlers[signame] = handlers
	end
	handlers[#handlers + 1] = fn
	if not signal_watchers[signame] then
		local watcher = uv.new_signal()
		local ok, err = pcall(function()
			watcher:start(signame:lower(), function()
				for _, h in ipairs(signal_handlers[signame] or {}) do
					local hok, herr = pcall(h)
					if not hok then
						log.error("signal handler (%s) failed: %s", signame, tostring(herr))
					end
				end
			end)
		end)
		if not ok then
			watcher:close()
			error("unknown signal: " .. tostring(signame) .. " (" .. tostring(err) .. ")")
		end
		signal_watchers[signame] = watcher
	end
	return function()
		for i, h in ipairs(handlers) do
			if h == fn then
				table.remove(handlers, i)
				break
			end
		end
	end
end

loop.process = require("lupus.loop.process")

return loop
