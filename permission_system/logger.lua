-- Audit/debug JSONL logging. Ported from logging.ts, minus its async
-- write-queue: pi needed one because Node's fs.appendFile is async;
-- lupus.util.fs.append_file is a synchronous libuv call (nothing in
-- fs.lua yields — see its docstring), so each write just happens inline.
--
-- Two streams share one file, same as pi: "review" entries are always
-- written (the audit trail of what the permission system did); "debug"
-- entries are gated by the extension config's `debug` flag.

local fs = require("lupus.util.fs")
local json = require("lupus.util.json")
local lupus_config = require("lupus.config")
local state = require("permission_system.state")

local logger = {}

local ENV_PATH_KEY = "LUPUS_PERMISSION_SYSTEM_LOG_PATH"

function logger.default_path()
	local override = os.getenv(ENV_PATH_KEY)
	if override and override ~= "" then
		return override
	end
	return fs.join(lupus_config.dirs().state, state.EXTENSION_ID, "log.jsonl")
end

local function write_line(path, stream, event, details)
	fs.mkdirp(fs.dirname(path))
	local entry = { timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"), extension = state.EXTENSION_ID, stream = stream, event = event }
	for k, v in pairs(details or {}) do
		entry[k] = v
	end
	local ok, line = pcall(json.encode, entry)
	if not ok then
		return -- logging must never crash permission handling
	end
	fs.append_file(path, line .. "\n")
end

--- opts: { get_config = fn() -> extension_config, path? }
function logger.new(opts)
	opts = opts or {}
	local path = opts.path or logger.default_path()
	local get_config = assert(opts.get_config, "logger.new requires get_config")

	return {
		debug = function(event, details)
			if not get_config().debug then
				return
			end
			write_line(path, "debug", event, details)
		end,
		review = function(event, details)
			write_line(path, "review", event, details)
		end,
	}
end

return logger
