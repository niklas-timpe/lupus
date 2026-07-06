-- A small JSONC parser for permission configs, with ONE property that
-- `cjson` cannot give us: object key insertion order is preserved.
--
-- Why this exists (see llm.md §5.3): last-match-wins wildcard resolution
-- depends on declaration order *within* a single JSON object —
--   { "*": "deny", "git *": "ask", "git status": "allow" }
-- must resolve "git status" to "allow" because it's declared last. A hash
-- table (what cjson decodes objects into) has no such order. So permission
-- configs get their own hand-rolled recursive-descent parser that tags each
-- decoded object with an ordered key list, alongside comment/trailing-comma
-- support (the "C" in JSONC). Every other JSON payload in lupus keeps using
-- `lupus.util.json` (cjson) — this parser is scoped to permission configs
-- only.
--
-- Decoded shape:
--   object -> a Lua table with string keys holding the values, PLUS
--             `__keys` (array of key strings, first-occurrence order;
--             a repeated key keeps its original position, last value wins
--             per JSON/JS semantics) and `__is_object = true`.
--   array  -> a plain Lua sequence (1-based), values in order.
--   string/number/boolean -> plain Lua values.
--   null   -> the jsonc.null sentinel.

local jsonc = {}

jsonc.null = setmetatable({}, { __tostring = function() return "null" end })

function jsonc.is_null(v)
	return v == jsonc.null
end

--- Ordered iteration helper: for _, k, v in jsonc.pairs(obj) do ... end
function jsonc.pairs(obj)
	local keys = obj.__keys or {}
	local i = 0
	return function()
		i = i + 1
		local k = keys[i]
		if k == nil then
			return nil
		end
		return k, obj[k]
	end
end

-- ---------------------------------------------------------------------------
-- Parser

local function new_cursor(text)
	-- Strip a leading UTF-8 BOM.
	if text:sub(1, 3) == "\239\187\191" then
		text = text:sub(4)
	end
	return { text = text, len = #text, pos = 1 }
end

local function line_col(text, pos)
	local before = text:sub(1, pos - 1)
	local line = 1
	local last_nl = 0
	for nl_pos in before:gmatch("()\n") do
		line = line + 1
		last_nl = nl_pos
	end
	return line, pos - last_nl
end

local function fail(cur, message)
	local line, col = line_col(cur.text, cur.pos)
	error({ jsonc_error = true, message = message, line = line, column = col }, 0)
end

local function peek(cur)
	if cur.pos > cur.len then
		return nil
	end
	return cur.text:sub(cur.pos, cur.pos)
end

--- Skip whitespace, //line and /* block */ comments.
local function skip_ws(cur)
	while cur.pos <= cur.len do
		local c = cur.text:sub(cur.pos, cur.pos)
		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			cur.pos = cur.pos + 1
		elseif c == "/" and cur.text:sub(cur.pos + 1, cur.pos + 1) == "/" then
			local nl = cur.text:find("\n", cur.pos + 2, true)
			cur.pos = nl and (nl + 1) or (cur.len + 1)
		elseif c == "/" and cur.text:sub(cur.pos + 1, cur.pos + 1) == "*" then
			local close = cur.text:find("*/", cur.pos + 2, true)
			if not close then
				fail(cur, "unterminated block comment")
			end
			cur.pos = close + 2
		else
			break
		end
	end
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function parse_string(cur)
	if peek(cur) ~= '"' then
		fail(cur, "expected string")
	end
	cur.pos = cur.pos + 1
	local out = {}
	while true do
		if cur.pos > cur.len then
			fail(cur, "unterminated string")
		end
		local c = cur.text:sub(cur.pos, cur.pos)
		if c == '"' then
			cur.pos = cur.pos + 1
			return table.concat(out)
		elseif c == "\\" then
			local esc = cur.text:sub(cur.pos + 1, cur.pos + 1)
			if esc == "u" then
				local hex = cur.text:sub(cur.pos + 2, cur.pos + 5)
				local code = tonumber(hex, 16)
				if not code or #hex ~= 4 then
					fail(cur, "invalid \\u escape")
				end
				if code < 0x80 then
					out[#out + 1] = string.char(code)
				elseif code < 0x800 then
					out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
				else
					out[#out + 1] = string.char(
						0xE0 + math.floor(code / 0x1000),
						0x80 + (math.floor(code / 0x40) % 0x40),
						0x80 + (code % 0x40)
					)
				end
				cur.pos = cur.pos + 6
			else
				local mapped = ESCAPES[esc]
				if not mapped then
					fail(cur, "invalid escape \\" .. tostring(esc))
				end
				out[#out + 1] = mapped
				cur.pos = cur.pos + 2
			end
		else
			out[#out + 1] = c
			cur.pos = cur.pos + 1
		end
	end
end

local function parse_number(cur)
	local rest = cur.text:sub(cur.pos)
	local num = rest:match("^%-?%d+%.?%d*[eE]?[+%-]?%d*")
	if not num or num == "" or num == "-" then
		fail(cur, "invalid number")
	end
	cur.pos = cur.pos + #num
	return tonumber(num)
end

local parse_value

local function parse_object(cur)
	cur.pos = cur.pos + 1 -- consume "{"
	local obj = { __is_object = true, __keys = {} }
	local seen = {}
	skip_ws(cur)
	if peek(cur) == "}" then
		cur.pos = cur.pos + 1
		return obj
	end
	while true do
		skip_ws(cur)
		if peek(cur) ~= '"' then
			fail(cur, "expected string key")
		end
		local key = parse_string(cur)
		skip_ws(cur)
		if peek(cur) ~= ":" then
			fail(cur, "expected ':' after key")
		end
		cur.pos = cur.pos + 1
		skip_ws(cur)
		local value = parse_value(cur)
		if not seen[key] then
			seen[key] = true
			obj.__keys[#obj.__keys + 1] = key
		end
		obj[key] = value
		skip_ws(cur)
		local c = peek(cur)
		if c == "," then
			cur.pos = cur.pos + 1
			skip_ws(cur)
			if peek(cur) == "}" then -- trailing comma
				cur.pos = cur.pos + 1
				return obj
			end
		elseif c == "}" then
			cur.pos = cur.pos + 1
			return obj
		else
			fail(cur, "expected ',' or '}'")
		end
	end
end

local function parse_array(cur)
	cur.pos = cur.pos + 1 -- consume "["
	local arr = {}
	skip_ws(cur)
	if peek(cur) == "]" then
		cur.pos = cur.pos + 1
		return arr
	end
	while true do
		skip_ws(cur)
		arr[#arr + 1] = parse_value(cur)
		skip_ws(cur)
		local c = peek(cur)
		if c == "," then
			cur.pos = cur.pos + 1
			skip_ws(cur)
			if peek(cur) == "]" then -- trailing comma
				cur.pos = cur.pos + 1
				return arr
			end
		elseif c == "]" then
			cur.pos = cur.pos + 1
			return arr
		else
			fail(cur, "expected ',' or ']'")
		end
	end
end

parse_value = function(cur)
	skip_ws(cur)
	local c = peek(cur)
	if c == nil then
		fail(cur, "unexpected end of input")
	elseif c == "{" then
		return parse_object(cur)
	elseif c == "[" then
		return parse_array(cur)
	elseif c == '"' then
		return parse_string(cur)
	elseif c == "t" and cur.text:sub(cur.pos, cur.pos + 3) == "true" then
		cur.pos = cur.pos + 4
		return true
	elseif c == "f" and cur.text:sub(cur.pos, cur.pos + 4) == "false" then
		cur.pos = cur.pos + 5
		return false
	elseif c == "n" and cur.text:sub(cur.pos, cur.pos + 3) == "null" then
		cur.pos = cur.pos + 4
		return jsonc.null
	elseif c == "-" or c:match("%d") then
		return parse_number(cur)
	else
		fail(cur, "unexpected character " .. c)
	end
end

--- Parse JSONC text. Returns value, nil on success or nil, err on failure.
--- err = { message, line, column }.
function jsonc.parse(text)
	local cur = new_cursor(text)
	local ok, result = pcall(function()
		local value = parse_value(cur)
		skip_ws(cur)
		if cur.pos <= cur.len then
			fail(cur, "trailing content after top-level value")
		end
		return value
	end)
	if ok then
		return result, nil
	end
	if type(result) == "table" and result.jsonc_error then
		return nil, { message = result.message, line = result.line, column = result.column }
	end
	error(result, 0) -- unexpected Lua error, don't swallow it
end

--- Format a load-warning string for a config file. `err` is either the
--- { message, line, column } shape from jsonc.parse, or a plain string.
function jsonc.format_load_warning(path, err, subject, fallback_message)
	subject = subject or "config"
	local base
	if type(err) == "table" and err.message then
		base = ("Failed to parse %s at '%s' (%s at line %d, column %d)"):format(
			subject,
			path,
			err.message,
			err.line,
			err.column
		)
	else
		base = ("Failed to load %s at '%s': %s"):format(subject, path, tostring(err))
	end
	if fallback_message then
		return base .. "; " .. fallback_message .. "."
	end
	return base
end

return jsonc
