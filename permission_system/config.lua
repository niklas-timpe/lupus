-- The extension's OWN settings (enabled / debug / yolo_mode) — distinct
-- from the permission POLICY files manager.lua reads. Ported from
-- extension-config.ts, minus the parts that don't apply here:
-- forwardedPromptTimeoutSeconds (subagent-forwarding only, omitted per
-- llm.md §4) and symlink-aware write-target resolution (lupus's state
-- dir is never expected to be a hand-maintained symlink farm the way
-- pi's per-extension config directory can be).
--
-- Save() still preserves unknown keys and does an atomic tmp+rename
-- write, and still refuses to clobber a file that fails to parse (so a
-- hand-edited custom key never gets silently destroyed) — those are the
-- two properties worth keeping from the original. It does NOT preserve
-- key order on save: jsonc.lua only parses, it doesn't serialize, and
-- writing our own order-preserving encoder for a config file has at most
-- three known keys isn't worth it (see manager.lua for where ordering
-- actually matters — the permission policy, never this file).

local fs = require("lupus.util.fs")
local lupus_config = require("lupus.config")
local json = require("lupus.util.json")
local jsonc = require("permission_system.jsonc")
local common = require("permission_system.common")
local state = require("permission_system.state")

local config = {}

config.DEFAULTS = { enabled = true, debug = false, yolo_mode = false }

local ENV_PATH_KEY = "LUPUS_PERMISSION_SYSTEM_CONFIG_PATH"

--- MANAGED_KEYS are the only fields config.save() ever (over)writes;
--- "enabled" and any custom keys a user adds by hand are read but never
--- rewritten by us.
local MANAGED_KEYS = { debug = true, yolo_mode = true }

function config.default_path()
	local override = os.getenv(ENV_PATH_KEY)
	if override and override ~= "" then
		return override
	end
	return fs.join(lupus_config.dirs().state, state.EXTENSION_ID, "config.json")
end

function config.normalize(raw)
	local record = common.to_record(raw)
	return {
		enabled = record.enabled ~= false,
		debug = record.debug == true,
		yolo_mode = record.yolo_mode == true,
	}
end

--- Returns normalized_config, warning_or_nil. A missing file is silent
--- (first-run default); a malformed one warns and falls back to defaults.
function config.load(path)
	path = path or config.default_path()
	if not fs.is_file(path) then
		return config.normalize(nil), nil
	end
	local text = fs.read_file(path)
	if not text then
		return config.normalize(nil), nil
	end
	local value, err = jsonc.parse(text)
	if not value then
		return config.normalize(nil),
			jsonc.format_load_warning(path, err, "permission-system config", "using default extension config")
	end
	return config.normalize(value), nil
end

--- Create the config file with defaults if it doesn't exist yet, so it's
--- discoverable/hand-editable. Returns true if it created the file.
function config.ensure(path)
	path = path or config.default_path()
	if fs.is_file(path) then
		return false
	end
	fs.mkdirp(fs.dirname(path))
	fs.write_file(path, json.encode(config.DEFAULTS) .. "\n")
	return true
end

--- Merge `updates` (only "debug"/"yolo_mode" keys are honored) into the
--- existing file, preserving any other keys already there, and write it
--- back atomically. Returns true, or false + error message.
function config.save(updates, path)
	path = path or config.default_path()

	local merged = {}
	if fs.is_file(path) then
		local text = fs.read_file(path) or ""
		local existing, err = jsonc.parse(text)
		if not existing then
			return false,
				("refusing to save permission-system config at '%s': existing file is corrupt (%s)"):format(
					path,
					err and err.message or "parse error"
				)
		end
		for _, key in ipairs(existing.__keys or {}) do
			if key ~= "__proto__" and key ~= "constructor" and key ~= "prototype" then
				merged[key] = existing[key]
			end
		end
	end

	for key, value in pairs(updates) do
		if MANAGED_KEYS[key] then
			merged[key] = value
		end
	end

	fs.mkdirp(fs.dirname(path))
	local tmp_path = path .. ".tmp"
	local ok, err = fs.write_file(tmp_path, json.encode(merged) .. "\n")
	if not ok then
		return false, tostring(err)
	end
	local renamed, rename_err = os.rename(tmp_path, path)
	if not renamed then
		return false, tostring(rename_err)
	end
	return true
end

return config
