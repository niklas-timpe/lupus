-- Configuration: XDG-style directories plus settings loaded from the global
-- file and deep-merged with per-project overrides.
--
--   ~/.config/lupus/settings.json      global settings
--   <project>/.lupus/settings.json     project overrides (win on conflict)
--
-- Settings keys (all optional):
--   default_model      model id or fuzzy query
--   thinking           "off" | "minimal" | "low" | "medium" | "high"
--   providers          { name = { base_url, api, env, api_key } }
--   models             { { id, provider, ... } }  (see lupus.ai.models)
--   api_keys           { provider = key }         (prefer env vars!)
--   max_history        editor prompt history size

local fs = require("lupus.util.fs")
local json = require("lupus.util.json")

local config = {}

local function xdg(env_var, fallback)
	local v = os.getenv(env_var)
	if v and v ~= "" then
		return v
	end
	return fs.home() .. fallback
end

function config.dirs()
	return {
		config = xdg("XDG_CONFIG_HOME", "/.config") .. "/lupus",
		state = xdg("XDG_STATE_HOME", "/.local/state") .. "/lupus",
		data = xdg("XDG_DATA_HOME", "/.local/share") .. "/lupus",
	}
end

--- Recursive merge: `over` wins; nested tables merge, arrays replace.
local function deep_merge(base, over)
	local out = {}
	for k, v in pairs(base) do
		out[k] = v
	end
	for k, v in pairs(over) do
		if type(v) == "table" and type(out[k]) == "table" and #v == 0 and #out[k] == 0 then
			out[k] = deep_merge(out[k], v)
		else
			out[k] = v
		end
	end
	return out
end

config.deep_merge = deep_merge

local function read_json(path)
	if not fs.is_file(path) then
		return {}
	end
	local data = fs.read_file(path)
	if not data then
		return {}
	end
	local parsed, err = json.decode(data)
	if type(parsed) ~= "table" then
		io.stderr:write(("lupus: ignoring malformed %s: %s\n"):format(path, tostring(err)))
		return {}
	end
	return parsed
end

--- Update the global settings file in place: read, apply `updater(settings)`,
--- write back. Creates the file (and config dir) when missing. Returns the
--- path written, or nil + error.
function config.update_global(updater)
	local dirs = config.dirs()
	local path = dirs.config .. "/settings.json"
	local settings = read_json(path)
	updater(settings)
	local ok, err = fs.mkdirp(dirs.config)
	if not ok then
		return nil, tostring(err)
	end
	ok, err = fs.write_file(path, json.encode(settings) .. "\n")
	if not ok then
		return nil, tostring(err)
	end
	return path
end

--- Load merged settings + directory paths for a working directory.
function config.load(cwd)
	cwd = cwd or fs.cwd()
	local dirs = config.dirs()
	local global = read_json(dirs.config .. "/settings.json")
	local project_dir = fs.join(cwd, ".lupus")
	local project = read_json(project_dir .. "/settings.json")
	return {
		cwd = cwd,
		dirs = dirs,
		project_dir = project_dir,
		settings = deep_merge(global, project),
	}
end

return config
