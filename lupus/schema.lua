-- Schema DSL for tool parameters. One definition serves two purposes:
--   * runtime validation of the arguments a model sends for a tool call
--   * generation of the JSON Schema advertised to the provider API
--
-- Usage:
--   local s = require("lupus.schema")
--   local params = s.object{
--     path  = s.string{ desc = "File path", required = true },
--     limit = s.integer{ desc = "Max lines", default = 2000 },
--   }
--   local ok, args_or_err = s.validate(params, raw_args)
--   local json_schema = s.to_json_schema(params)
--
-- Validation is forgiving where models tend to be sloppy: JSON null counts
-- as absent, integers accept whole floats, and unknown keys pass through.

local json = require("lupus.util.json")

local schema = {}

local function node(kind, opts)
	opts = opts or {}
	return {
		kind = kind,
		desc = opts.desc,
		required = opts.required or false,
		default = opts.default,
		enum = opts.enum,
		items = opts.items,
		fields = opts.fields,
	}
end

function schema.string(opts)
	return node("string", opts)
end
function schema.number(opts)
	return node("number", opts)
end
function schema.integer(opts)
	return node("integer", opts)
end
function schema.boolean(opts)
	return node("boolean", opts)
end

--- s.enum({"a","b"}, {desc=...}) — string constrained to a fixed set.
function schema.enum(values, opts)
	opts = opts or {}
	opts.enum = values
	return node("string", opts)
end

--- s.array(item_schema, {desc=...})
function schema.array(items, opts)
	opts = opts or {}
	opts.items = items
	return node("array", opts)
end

--- s.object{ field = <schema>, ... } — field options live on the field schemas.
function schema.object(fields, opts)
	opts = opts or {}
	opts.fields = fields or {}
	return node("object", opts)
end

local validate_node

local function type_error(path, expected, got)
	local where = path == "" and "value" or ("field '%s'"):format(path)
	return ("%s: expected %s, got %s"):format(where, expected, got)
end

local function lua_typename(v)
	if json.is_null(v) then
		return "null"
	end
	local t = type(v)
	if t == "number" then
		return v % 1 == 0 and "integer" or "number"
	end
	return t
end

validate_node = function(spec, value, path)
	if value == nil or json.is_null(value) then
		if spec.default ~= nil then
			return true, spec.default
		end
		if spec.required then
			return false, ("missing required %s"):format(path == "" and "value" or "field '" .. path .. "'")
		end
		return true, nil
	end

	local kind = spec.kind
	if kind == "string" then
		if type(value) ~= "string" then
			return false, type_error(path, "string", lua_typename(value))
		end
		if spec.enum then
			for _, v in ipairs(spec.enum) do
				if v == value then
					return true, value
				end
			end
			return false,
				("field '%s': expected one of [%s], got %q"):format(path, table.concat(spec.enum, ", "), value)
		end
		return true, value
	elseif kind == "integer" then
		if type(value) ~= "number" then
			return false, type_error(path, "integer", lua_typename(value))
		end
		if value % 1 ~= 0 then
			return false, type_error(path, "integer", "number " .. tostring(value))
		end
		return true, value
	elseif kind == "number" then
		if type(value) ~= "number" then
			return false, type_error(path, "number", lua_typename(value))
		end
		return true, value
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return false, type_error(path, "boolean", lua_typename(value))
		end
		return true, value
	elseif kind == "array" then
		if type(value) ~= "table" then
			return false, type_error(path, "array", lua_typename(value))
		end
		local out = {}
		for i, item in ipairs(value) do
			local ok, res = validate_node(spec.items, item, ("%s[%d]"):format(path, i))
			if not ok then
				return false, res
			end
			out[i] = res
		end
		return true, out
	elseif kind == "object" then
		if type(value) ~= "table" then
			return false, type_error(path, "object", lua_typename(value))
		end
		local out = {}
		-- Unknown keys pass through untouched (models sometimes add extras).
		for k, v in pairs(value) do
			if not json.is_null(v) then
				out[k] = v
			end
		end
		for name, field in pairs(spec.fields) do
			local child_path = path == "" and name or (path .. "." .. name)
			local ok, res = validate_node(field, value[name], child_path)
			if not ok then
				return false, res
			end
			out[name] = res
		end
		return true, out
	end
	return false, "unknown schema kind: " .. tostring(kind)
end

--- Validate a value against a schema. Returns true, normalized_value
--- (defaults applied, integers coerced) or false, error_message.
function schema.validate(spec, value)
	return validate_node(spec, value, "")
end

local to_json_node

to_json_node = function(spec)
	local out = {}
	if spec.kind == "object" then
		out.type = "object"
		out.properties = {}
		local required = json.array({})
		local names = {}
		for name in pairs(spec.fields) do
			names[#names + 1] = name
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local field = spec.fields[name]
			out.properties[name] = to_json_node(field)
			if field.required then
				required[#required + 1] = name
			end
		end
		out.required = required
		out.additionalProperties = true
	elseif spec.kind == "array" then
		out.type = "array"
		out.items = to_json_node(spec.items)
	else
		out.type = spec.kind
		if spec.enum then
			out.enum = json.array(spec.enum)
		end
	end
	if spec.desc then
		out.description = spec.desc
	end
	if spec.default ~= nil then
		out.default = spec.default
	end
	return out
end

--- Produce a JSON-Schema table ready for json.encode.
function schema.to_json_schema(spec)
	return to_json_node(spec)
end

return schema
