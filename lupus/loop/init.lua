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

require("lupus.util.compat")
local uv = require("luv")
local log = require("lupus.util.log")

local loop = {}

loop.uv = uv

-- ---------------------------------------------------------------------------
-- Scheduler state (module-level; persists across loop.run calls only for
-- signal registrations, everything else is reset by run()).

local state = {
  ready = {},          -- FIFO of { task = t, args = {...} }
  alive = 0,           -- count of non-dead tasks
  current = nil,       -- task being resumed right now
  running = false,
  signal_handlers = {},-- signame -> array of fns
  signal_watchers = {},-- signame -> uv_signal_t
}

function loop.now_ms()
  return uv.now()
end

-- ---------------------------------------------------------------------------
-- Tasks

local Task = {}
Task.__index = Task

local function new_task(fn, ...)
  local args = table.pack(...)
  local task = setmetatable({
    status = "ready",  -- ready | running | waiting | dead
    joiners = {},
    results = nil,     -- table.pack(pcall-style ok, ...) once dead
    cancelled = false,
    cleanup = nil,     -- called on cancel to detach from wait lists
  }, Task)
  task.co = coroutine.create(function()
    return fn(table.unpack(args, 1, args.n))
  end)
  return task
end

local function push_ready(task, ...)
  task.status = "ready"
  state.ready[#state.ready + 1] = { task = task, args = table.pack(...) }
end

--- Wake a waiting task. First resume value false means "cancelled"; the
--- park point raises. Ignored unless the task is actually waiting.
local function wake(task, ok, ...)
  if task.status ~= "waiting" then return end
  push_ready(task, ok, ...)
end

--- Park the current task until someone wakes it. `cleanup` detaches the
--- task from whatever wait list it joined, and runs if it gets cancelled.
local function park(cleanup)
  local task = state.current
  assert(task, "park() outside of a task")
  task.status = "waiting"
  task.cleanup = cleanup
  local res = table.pack(coroutine.yield())
  task.cleanup = nil
  if not res[1] then
    error(res[2] or "cancelled", 0)
  end
  return table.unpack(res, 2, res.n)
end

loop._park = park
loop._wake = wake

function loop.current_task()
  return state.current
end

function loop.spawn(fn, ...)
  local task = new_task(fn, ...)
  state.alive = state.alive + 1
  push_ready(task, true)
  return task
end

local function finish_task(task, ok, ...)
  task.status = "dead"
  task.results = table.pack(ok, ...)
  state.alive = state.alive - 1
  if not ok and not task.cancelled and #task.joiners == 0 then
    log.error("task error: %s", tostring((...)))
  end
  for _, joiner in ipairs(task.joiners) do
    wake(joiner, true)
  end
  task.joiners = {}
end

--- Cancel a task: it resumes with an error("cancelled") at its current (or
--- next) yield point. Cancelling a dead task is a no-op.
function Task:cancel()
  if self.status == "dead" then return end
  self.cancelled = true
  if self.status == "waiting" then
    if self.cleanup then self.cleanup() end
    wake(self, false, "cancelled")
  end
  -- If ready/running, the cancellation flag is honored at the next resume
  -- (see dispatch) or the next park.
end

--- Wait for a task to finish. Returns like pcall: ok, results...
--- A cancelled task yields false, "cancelled".
function Task:join()
  if self.status ~= "dead" then
    local me = state.current
    self.joiners[#self.joiners + 1] = me
    park(function()
      for i, j in ipairs(self.joiners) do
        if j == me then table.remove(self.joiners, i) break end
      end
    end)
  end
  return table.unpack(self.results, 1, self.results.n)
end

function Task:is_done()
  return self.status == "dead"
end

-- ---------------------------------------------------------------------------
-- Timers

local Timer = {}
Timer.__index = Timer

function Timer:cancel()
  if self.dead then return end
  self.dead = true
  if self.handle then
    self.handle:stop()
    self.handle:close()
    self.handle = nil
  end
end

--- One-shot timer; fn runs in scheduler context (must not yield).
function loop.timer(ms, fn)
  local entry = setmetatable({}, Timer)
  entry.handle = uv.new_timer()
  entry.handle:start(ms, 0, function()
    entry:cancel()
    local ok, err = pcall(fn)
    if not ok then log.error("timer callback failed: %s", tostring(err)) end
  end)
  return entry
end

--- Repeating timer.
function loop.interval(ms, fn)
  local entry = setmetatable({}, Timer)
  entry.handle = uv.new_timer()
  entry.handle:start(ms, ms, function()
    local ok, err = pcall(fn)
    if not ok then log.error("timer callback failed: %s", tostring(err)) end
  end)
  return entry
end

-- yields
function loop.sleep(ms)
  local task = state.current
  local entry = setmetatable({}, Timer)
  entry.handle = uv.new_timer()
  entry.handle:start(ms, 0, function()
    entry:cancel()
    wake(task, true)
  end)
  park(function() entry:cancel() end)
end

-- ---------------------------------------------------------------------------
-- Stream reading. A Reader wraps a uv stream (pipe, tty) and buffers chunks
-- from read_start so tasks can pull them one at a time. Reading pauses when
-- the buffer is far ahead of the consumer (backpressure) and resumes as the
-- consumer catches up.

local Reader = {}
Reader.__index = Reader

local HIGH_WATER = 256 * 1024

function loop.reader(stream)
  return setmetatable({
    stream = stream,
    chunks = {},
    first = 1,
    last = 0,
    buffered = 0,
    eof = false,
    err = nil,
    waiter = nil,
    reading = false,
    closed = false,
  }, Reader)
end

local function reader_start(self)
  if self.reading or self.eof or self.closed then return end
  self.reading = true
  self.stream:read_start(function(err, chunk)
    if err then
      self.err = err
      self.eof = true
    elseif chunk == nil then
      self.eof = true
    else
      self.last = self.last + 1
      self.chunks[self.last] = chunk
      self.buffered = self.buffered + #chunk
      if self.buffered >= HIGH_WATER then
        self.reading = false
        self.stream:read_stop()
      end
    end
    if self.waiter then
      local t = self.waiter
      self.waiter = nil
      wake(t, true)
    end
  end)
end

local function reader_pop(self)
  local c = self.chunks[self.first]
  if c == nil then return nil end
  self.chunks[self.first] = nil
  self.first = self.first + 1
  self.buffered = self.buffered - #c
  if not self.reading and self.buffered < HIGH_WATER then
    reader_start(self)
  end
  return c
end

--- Next chunk. Returns a non-empty string; nil, err on stream error; plain
--- nil at EOF; nil, "timeout" when timeout_ms elapses first. yields
function Reader:read(timeout_ms)
  local c = reader_pop(self)
  if c then return c end
  if self.eof then return nil, self.err end
  reader_start(self)
  assert(not self.waiter, "reader already has a waiting task")
  self.waiter = state.current

  local timed_out = false
  local timer
  if timeout_ms then
    timer = loop.timer(timeout_ms, function()
      timed_out = true
      if self.waiter then
        local t = self.waiter
        self.waiter = nil
        wake(t, true)
      end
    end)
  end
  local ok = pcall(park, function() self.waiter = nil end)
  if timer then timer:cancel() end
  if not ok then error("cancelled", 0) end
  if timed_out then return nil, "timeout" end
  c = reader_pop(self)
  if c then return c end
  return nil, self.err
end

--- Stop reading and close the underlying stream. Safe to call twice.
function Reader:close()
  if self.closed then return end
  self.closed = true
  self.eof = true
  if not self.stream:is_closing() then
    self.stream:read_stop()
    self.stream:close()
  end
  if self.waiter then
    local t = self.waiter
    self.waiter = nil
    wake(t, true)
  end
end

--- loop.read(reader [, timeout_ms]): alias so call sites read naturally.
function loop.read(reader, timeout_ms)
  return reader:read(timeout_ms)
end

--- Write all of `data` to a uv stream. Returns true or nil, err. yields
function loop.write(stream, data)
  -- `slot` detaches the task on cancel so a late write callback can't wake
  -- it at some unrelated park point.
  local slot = { task = state.current }
  local finished, werr = false, nil
  local ok, err = pcall(function()
    stream:write(data, function(cb_err)
      finished = true
      werr = cb_err
      if slot.task then
        local t = slot.task
        slot.task = nil
        wake(t, true)
      end
    end)
  end)
  if not ok then return nil, tostring(err) end
  if not finished then
    park(function() slot.task = nil end)
  end
  if werr then return nil, tostring(werr) end
  return true
end

-- ---------------------------------------------------------------------------
-- Signals. One uv signal watcher per signal name; handlers run in scheduler
-- context (uv callback) and must not yield.

function loop.on_signal(signame, fn)
  local handlers = state.signal_handlers[signame]
  if not handlers then
    handlers = {}
    state.signal_handlers[signame] = handlers
  end
  handlers[#handlers + 1] = fn
  if not state.signal_watchers[signame] then
    local watcher = uv.new_signal()
    local ok, err = pcall(function()
      watcher:start(signame:lower(), function()
        for _, h in ipairs(state.signal_handlers[signame] or {}) do
          local hok, herr = pcall(h)
          if not hok then log.error("signal handler (%s) failed: %s", signame, tostring(herr)) end
        end
      end)
    end)
    if not ok then
      watcher:close()
      error("unknown signal: " .. tostring(signame) .. " (" .. tostring(err) .. ")")
    end
    state.signal_watchers[signame] = watcher
  end
  return function()
    for i, h in ipairs(handlers) do
      if h == fn then table.remove(handlers, i) break end
    end
  end
end

-- ---------------------------------------------------------------------------
-- The scheduler

local function dispatch(item)
  local task = item.task
  if task.status == "dead" then return end
  local args = item.args
  if task.cancelled and args[1] == true then
    args = table.pack(false, "cancelled")
  end
  task.status = "running"
  local previous = state.current
  state.current = task
  local res = table.pack(coroutine.resume(task.co, table.unpack(args, 1, args.n)))
  state.current = previous
  if coroutine.status(task.co) == "dead" then
    if res[1] then
      finish_task(task, true, table.unpack(res, 2, res.n))
    else
      local err = res[2]
      if task.cancelled and err == "cancelled" then
        finish_task(task, false, "cancelled")
      else
        finish_task(task, false, debug.traceback(task.co, tostring(err)))
      end
    end
  end
  -- Otherwise the task yielded: park() already set status = "waiting".
end

local function drain_ready()
  while #state.ready > 0 do
    local batch = state.ready
    state.ready = {}
    for _, item in ipairs(batch) do
      dispatch(item)
    end
  end
end

--- Run the scheduler with `fn` as the main task. Returns the main task's
--- results (pcall style: ok, ...). Reentrant calls are an error.
function loop.run(fn, ...)
  assert(not state.running, "loop.run is not reentrant")
  state.running = true
  state.ready = {}
  state.alive = 0

  local main = loop.spawn(fn, ...)
  local ok, err = pcall(function()
    while true do
      drain_ready()
      if state.alive == 0 then break end
      -- All tasks are parked; let libuv wait for whatever wakes one (timer,
      -- stream, signal, child exit). If libuv has nothing pending either,
      -- nothing can ever wake them.
      local active = uv.run("once")
      if not active and #state.ready == 0 then
        error("event loop deadlock: tasks are parked with nothing to wake them")
      end
    end
  end)
  state.running = false
  if not ok then error(err, 0) end
  return table.unpack(main.results, 1, main.results.n)
end

-- Lazy accessor so `loop.process.spawn{...}` works without a hard require
-- cycle (process.lua requires this module back).
setmetatable(loop, {
  __index = function(_, k)
    if k == "process" then
      local p = require("lupus.loop.process")
      rawset(loop, "process", p)
      return p
    end
    return nil
  end,
})

return loop
