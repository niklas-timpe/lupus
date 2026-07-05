-- Incremental Server-Sent-Events parser. Feed it raw bytes as they arrive;
-- it returns complete events and buffers the rest. Tolerates \r\n, events
-- split at any byte boundary, comment lines, and unknown fields.

local sse = {}

local Parser = {}
Parser.__index = Parser

function sse.new()
	return setmetatable({
		buf = "",
		event = nil, -- current event name
		data = {}, -- accumulated data lines
	}, Parser)
end

local function dispatch(self, out)
	if #self.data == 0 and not self.event then
		return
	end
	out[#out + 1] = {
		event = self.event or "message",
		data = table.concat(self.data, "\n"),
	}
	self.event = nil
	self.data = {}
end

--- Feed a chunk; returns an array of { event = name, data = string }.
function Parser:feed(chunk)
	self.buf = self.buf .. chunk
	local out = {}
	while true do
		local nl = self.buf:find("\n", 1, true)
		if not nl then
			break
		end
		local line = self.buf:sub(1, nl - 1)
		self.buf = self.buf:sub(nl + 1)
		if line:sub(-1) == "\r" then
			line = line:sub(1, -2)
		end

		if line == "" then
			dispatch(self, out)
		elseif line:sub(1, 1) == ":" then
		-- comment / keepalive
		else
			local field, value = line:match("^([^:]+):%s?(.*)$")
			if not field then
				field, value = line, ""
			end
			if field == "event" then
				self.event = value
			elseif field == "data" then
				self.data[#self.data + 1] = value
			end
			-- id / retry / unknown fields: ignored
		end
	end
	return out
end

--- End of stream: flush any dangling event (a missing trailing blank line).
function Parser:finish()
	local out = {}
	dispatch(self, out)
	return out
end

return sse
