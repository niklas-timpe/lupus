-- Lua 5.1 / LuaJIT compatibility shims. lupus targets LuaJIT (Lua 5.1 plus
-- LuaJIT extensions); the few 5.2+ stdlib functions we rely on are filled in
-- here. Require this before anything that uses table.pack/table.unpack.

if not table.pack then
	function table.pack(...)
		return { n = select("#", ...), ... }
	end
end

if not table.unpack then
	table.unpack = unpack
end

return true
