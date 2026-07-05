-- The subset of the Lua 5.3 utf8 library lupus uses, for LuaJIT (5.1).
-- Same semantics as the stock library for valid input; invalid bytes make
-- codepoint() raise, mirroring 5.3 (callers pcall where it matters).

local byte, char, concat = string.byte, string.char, table.concat
local floor = math.floor

local utf8 = {}

utf8.charpattern = "[%z\1-\127\194-\244][\128-\191]*"

local function is_cont(b)
	return b ~= nil and b >= 0x80 and b < 0xC0
end

--- Decode the codepoint starting at byte i. Returns cp, length or nil.
local function decode(s, i)
	local b = byte(s, i)
	if not b then
		return nil
	end
	if b < 0x80 then
		return b, 1
	end
	local len, cp
	if b >= 0xF0 then
		len, cp = 4, b - 0xF0
	elseif b >= 0xE0 then
		len, cp = 3, b - 0xE0
	elseif b >= 0xC0 then
		len, cp = 2, b - 0xC0
	else
		return nil
	end
	for k = 1, len - 1 do
		local c = byte(s, i + k)
		if not is_cont(c) then
			return nil
		end
		cp = cp * 64 + (c - 0x80)
	end
	return cp, len
end

function utf8.char(...)
	local out = {}
	for k = 1, select("#", ...) do
		local cp = select(k, ...)
		if cp < 0x80 then
			out[#out + 1] = char(cp)
		elseif cp < 0x800 then
			out[#out + 1] = char(0xC0 + floor(cp / 64), 0x80 + cp % 64)
		elseif cp < 0x10000 then
			out[#out + 1] = char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
		else
			out[#out + 1] = char(
				0xF0 + floor(cp / 262144),
				0x80 + floor(cp / 4096) % 64,
				0x80 + floor(cp / 64) % 64,
				0x80 + cp % 64
			)
		end
	end
	return concat(out)
end

--- Codepoint at byte position i (default 1). Raises on invalid UTF-8.
function utf8.codepoint(s, i)
	i = i or 1
	local cp = decode(s, i)
	if not cp then
		error("invalid UTF-8 code", 2)
	end
	return cp
end

--- Byte offset of the n-th codepoint from position i (Lua 5.3 semantics
--- for n > 0, n < 0, and n = 0).
function utf8.offset(s, n, i)
	local len = #s
	i = i or (n >= 0 and 1 or len + 1)
	if n == 0 then
		while i > 1 and is_cont(byte(s, i)) do
			i = i - 1
		end
		return i
	end
	if n > 0 then
		n = n - 1
		while n > 0 and i <= len do
			i = i + 1
			while is_cont(byte(s, i)) do
				i = i + 1
			end
			n = n - 1
		end
		if n > 0 or i > len + 1 then
			return nil
		end
		return i
	end
	while n < 0 and i > 1 do
		i = i - 1
		while i > 1 and is_cont(byte(s, i)) do
			i = i - 1
		end
		n = n + 1
	end
	if n < 0 then
		return nil
	end
	return i
end

--- Iterator over (byte position, codepoint). Raises on invalid UTF-8.
function utf8.codes(s)
	local i = 1
	return function()
		if i > #s then
			return nil
		end
		local cp, len = decode(s, i)
		if not cp then
			error("invalid UTF-8 code", 2)
		end
		local pos = i
		i = i + len
		return pos, cp
	end
end

--- Number of codepoints, or nil + position of the first invalid byte.
function utf8.len(s, i, j)
	i, j = i or 1, j or #s
	local n = 0
	while i <= j do
		local cp, len = decode(s, i)
		if not cp then
			return nil, i
		end
		n = n + 1
		i = i + len
	end
	return n
end

return utf8
