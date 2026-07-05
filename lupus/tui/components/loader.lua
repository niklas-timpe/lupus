-- Animated spinner line: "⠋ Thinking… (3s · esc to interrupt)"

local loop = require("lupus.loop")
local text = require("lupus.tui.text")

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local Loader = {}
Loader.__index = Loader

function Loader.new(tui, opts)
	opts = opts or {}
	return setmetatable({
		tui = tui,
		message = opts.message or "Working…",
		hint = opts.hint,
		frame = 1,
		started_at = nil,
		timer = nil,
	}, Loader)
end

function Loader:set_message(message)
	self.message = message
end

function Loader:start()
	if self.timer then
		return
	end
	self.started_at = loop.now_ms()
	self.timer = loop.interval(80, function()
		self.frame = self.frame % #FRAMES + 1
		self.tui:request_render()
	end)
end

function Loader:stop()
	if self.timer then
		self.timer:cancel()
		self.timer = nil
	end
end

function Loader:render(width)
	if not self.timer then
		return {}
	end
	local secs = math.floor((loop.now_ms() - self.started_at) / 1000)
	local line = text.style.cyan(FRAMES[self.frame])
		.. " "
		.. self.message
		.. text.style.gray((" (%ds%s)"):format(secs, self.hint and (" · " .. self.hint) or ""))
	return { text.truncate(line, width) }
end

return Loader
