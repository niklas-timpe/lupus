-- Channels: the producer/consumer bridge between tasks. Event streams (LLM
-- responses, agent events) are a producer task sending into a channel and a
-- consumer iterating it.
--
--   local ch = channel.new()        -- unbounded (or channel.new(capacity))
--   ch:send(v)                      -- yields while a bounded channel is full
--   ch:recv() -> v | nil, "closed"  -- yields while empty
--   ch:close()                      -- recv drains the buffer, then "closed"
--   for v in ch:iter() do ... end

local loop = require("lupus.loop")

local channel = {}

local Channel = {}
Channel.__index = Channel

function channel.new(capacity)
	return setmetatable({
		buf = {},
		first = 1,
		last = 0,
		capacity = capacity,
		closed = false,
		recv_waiters = {},
		send_waiters = {},
	}, Channel)
end

local function remove_waiter(list, task)
	for i, t in ipairs(list) do
		if t == task then
			table.remove(list, i)
			return
		end
	end
end

local function wake_one(list)
	local task = table.remove(list, 1)
	if task then
		loop._wake(task, true)
	end
end

function Channel:size()
	return self.last - self.first + 1
end

-- yields when the channel is bounded and full
function Channel:send(v)
	assert(v ~= nil, "cannot send nil on a channel")
	while self.capacity and not self.closed and self:size() >= self.capacity do
		local me = loop.current_task()
		self.send_waiters[#self.send_waiters + 1] = me
		loop._park(function()
			remove_waiter(self.send_waiters, me)
		end)
	end
	if self.closed then
		return nil, "closed"
	end
	self.last = self.last + 1
	self.buf[self.last] = v
	wake_one(self.recv_waiters)
	return true
end

-- yields when empty; returns value, or nil, "closed" once drained
function Channel:recv()
	while true do
		if self:size() > 0 then
			local v = self.buf[self.first]
			self.buf[self.first] = nil
			self.first = self.first + 1
			wake_one(self.send_waiters)
			return v
		end
		if self.closed then
			return nil, "closed"
		end
		local me = loop.current_task()
		self.recv_waiters[#self.recv_waiters + 1] = me
		loop._park(function()
			remove_waiter(self.recv_waiters, me)
		end)
	end
end

--- Non-blocking receive: value, or nil, "empty" | "closed".
function Channel:try_recv()
	if self:size() > 0 then
		local v = self.buf[self.first]
		self.buf[self.first] = nil
		self.first = self.first + 1
		wake_one(self.send_waiters)
		return v
	end
	return nil, self.closed and "closed" or "empty"
end

function Channel:close()
	if self.closed then
		return
	end
	self.closed = true
	while #self.recv_waiters > 0 do
		wake_one(self.recv_waiters)
	end
	while #self.send_waiters > 0 do
		wake_one(self.send_waiters)
	end
end

function Channel:is_closed()
	return self.closed
end

--- Iterator draining the channel until closed: for v in ch:iter() do end
function Channel:iter()
	return function()
		return (self:recv())
	end
end

return channel
