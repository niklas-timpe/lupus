-- File logger. stdout/stderr belong to the TUI, so diagnostics go to a file
-- (default: ~/.local/state/lupus/lupus.log, override with LUPUS_LOG).
-- Disabled until log.setup() is called unless LUPUS_LOG is set.

local log = {}

local file = nil
local level_order = { debug = 1, info = 2, warn = 3, error = 4 }
local min_level = "info"

local function open_path(path)
	local dir = path:match("^(.*)/[^/]+$")
	if dir then
		require("lupus.util.fs").mkdirp(dir)
	end
	file = io.open(path, "a")
end

function log.setup(opts)
	opts = opts or {}
	min_level = opts.level or min_level
	if opts.path then
		open_path(opts.path)
	end
end

local function write(level, fmt, ...)
	if not file then
		local env = os.getenv("LUPUS_LOG")
		if env and env ~= "" then
			open_path(env)
		else
			return
		end
		if not file then
			return
		end
	end
	if level_order[level] < level_order[min_level] then
		return
	end
	local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	file:write(("%s %-5s %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), level, msg))
	file:flush()
end

function log.debug(...)
	write("debug", ...)
end
function log.info(...)
	write("info", ...)
end
function log.warn(...)
	write("warn", ...)
end
function log.error(...)
	write("error", ...)
end

return log
