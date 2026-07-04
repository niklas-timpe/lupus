-- JSON boundary for the whole project. All wire payloads and session files
-- go through these helpers; never require("cjson") elsewhere. This keeps the
-- two classic Lua/JSON pitfalls in one place:
--   * null:  cjson decodes JSON null to a lightuserdata sentinel. We re-export
--            it as json.null so callers can test and produce it explicitly.
--   * empty arrays: an empty Lua table encodes as {} by default. json.array()
--            tags a table so it always encodes as a JSON array.

local cjson = require("cjson.safe")

local json = {}

json.null = cjson.null

local array_mt = { __name = "json.array" }
if cjson.array_mt then array_mt = cjson.array_mt end

--- Tag a table so it encodes as a JSON array even when empty.
function json.array(t)
  return setmetatable(t or {}, array_mt)
end

function json.is_null(v)
  return v == cjson.null
end

--- Encode a Lua value to a JSON string. Errors on unencodable input.
function json.encode(value)
  local s, err = cjson.encode(value)
  if not s then error("json encode failed: " .. tostring(err), 2) end
  return s
end

--- Decode JSON. Returns value, or nil + error message.
function json.decode(s)
  return cjson.decode(s)
end

--- Decode JSON, raising on failure (for internal data we produced ourselves).
function json.decode_or_error(s)
  local v, err = cjson.decode(s)
  if v == nil and err then error("json decode failed: " .. tostring(err), 2) end
  return v
end

return json
