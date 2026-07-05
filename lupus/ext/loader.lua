-- Extension discovery and loading.
--
-- An extension is a Lua file returning `function(api) ... end`. Load order:
--   1. <config>/lupus/extensions/*.lua        (global, always trusted)
--   2. <project>/.lupus/extensions/*.lua      (trust-gated, asked once)
--   3. paths given with -e on the command line (always loaded)
--
-- Extensions run unsandboxed, with the full privileges of the lupus
-- process — treat project extensions like any other code you'd execute.
-- Trust decisions are stored per project directory in
-- <state>/lupus/trust.json.
--
-- A broken extension never takes the session down: chunk errors, factory
-- errors, and handler errors are reported and skipped.

local fs = require("lupus.util.fs")
local json = require("lupus.util.json")
local api_mod = require("lupus.ext.api")
local log = require("lupus.util.log")

local loader = {}

local function trust_path(state_dir)
	return fs.join(state_dir, "trust.json")
end

local function read_trust(state_dir)
	local data = fs.read_file(trust_path(state_dir))
	if not data then
		return {}
	end
	local parsed = json.decode(data)
	return type(parsed) == "table" and parsed or {}
end

local function write_trust(state_dir, trust)
	fs.mkdirp(state_dir)
	fs.write_file(trust_path(state_dir), json.encode(trust))
end

local function lua_files(dir)
	local out = {}
	for _, name in ipairs(fs.list_dir(dir)) do
		if name:match("%.lua$") then
			out[#out + 1] = fs.join(dir, name)
		end
	end
	return out
end

--- Resolve whether project-local extensions may load. Asks once via
--- ui.confirm when interactive; skips (with a note) in print mode. yields
local function project_trusted(host, cwd, state_dir, report)
	local trust = read_trust(state_dir)
	local decision = trust[cwd]
	if decision ~= nil then
		return decision
	end
	if not host.ui then
		report(
			(
				"skipping untrusted project extensions in %s/.lupus/extensions "
				.. "(run interactively once to trust this project)"
			):format(cwd)
		)
		return false
	end
	local answer = host.ui.confirm({
		title = ("Load project extensions from %s/.lupus/extensions? " .. "They run with your full user permissions."):format(
			cwd
		),
	})
	trust[cwd] = answer and true or false
	write_trust(state_dir, trust)
	return trust[cwd]
end

local function load_one(host, path, report)
	local chunk, err = loadfile(path)
	if not chunk then
		report(("extension %s failed to parse: %s"):format(path, tostring(err)))
		return false
	end
	local ok, factory = pcall(chunk)
	if not ok then
		report(("extension %s crashed on load: %s"):format(path, tostring(factory)))
		return false
	end
	if type(factory) ~= "function" then
		report(("extension %s must return function(api)"):format(path))
		return false
	end
	local api = api_mod.build(host, path)
	local run_ok, run_err = pcall(factory, api)
	if not run_ok then
		report(("extension %s failed during setup: %s"):format(path, tostring(run_err)))
		return false
	end
	log.info("loaded extension %s", path)
	return true
end

--- Discover and load extensions into `host`.
--- opts: { cli_paths = {...}, no_discovery = bool }.
--- Returns the list of successfully loaded paths. yields (trust dialog)
function loader.load_all(host, opts)
	opts = opts or {}
	local runtime = host.runtime
	local cfg = runtime.config
	local loaded = {}

	local function report(message)
		if host.ui then
			host.ui.notify(message, "warning")
		else
			io.stderr:write("lupus: " .. message .. "\n")
		end
		log.warn("%s", message)
	end

	local candidates = {}
	if not opts.no_discovery then
		for _, path in ipairs(lua_files(fs.join(cfg.dirs.config, "extensions"))) do
			candidates[#candidates + 1] = path
		end
		local project_ext_dir = fs.join(runtime.project_dir or cfg.project_dir, "extensions")
		local project_files = lua_files(project_ext_dir)
		if #project_files > 0 and project_trusted(host, runtime.cwd, cfg.dirs.state, report) then
			for _, path in ipairs(project_files) do
				candidates[#candidates + 1] = path
			end
		end
	end
	for _, path in ipairs(opts.cli_paths or {}) do
		candidates[#candidates + 1] = fs.absolute(path, runtime.cwd)
	end

	for _, path in ipairs(candidates) do
		if load_one(host, path, report) then
			loaded[#loaded + 1] = path
		end
	end
	return loaded
end

return loader
