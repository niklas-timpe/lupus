-- Small filesystem helpers on top of libuv's synchronous fs API. Paths are
-- plain strings; nothing here yields, so these are safe to call from
-- anywhere (the uv.fs_* calls run blocking when no callback is given).

local uv = require("luv")

local fs = {}

function fs.exists(path)
	return uv.fs_stat(path) ~= nil
end

function fs.is_dir(path)
	local st = uv.fs_stat(path)
	return st ~= nil and st.type == "directory"
end

function fs.is_file(path)
	local st = uv.fs_stat(path)
	return st ~= nil and st.type == "file"
end

--- File size in bytes, or nil if not a regular file.
function fs.size(path)
	local st = uv.fs_stat(path)
	return st and st.size or nil
end

function fs.read_file(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, err
	end
	local data = f:read("*a")
	f:close()
	return data
end

function fs.write_file(path, data)
	local f, err = io.open(path, "wb")
	if not f then
		return nil, err
	end
	local ok, werr = f:write(data)
	f:close()
	if not ok then
		return nil, werr
	end
	return true
end

function fs.append_file(path, data)
	local f, err = io.open(path, "ab")
	if not f then
		return nil, err
	end
	local ok, werr = f:write(data)
	f:close()
	if not ok then
		return nil, werr
	end
	return true
end

--- mkdir -p. Returns true or nil + error.
function fs.mkdirp(path)
	if fs.is_dir(path) then
		return true
	end
	local parent = fs.dirname(path)
	if parent ~= path and parent ~= "/" and parent ~= "." then
		local ok, err = fs.mkdirp(parent)
		if not ok then
			return nil, err
		end
	end
	local ok, err = uv.fs_mkdir(path, 493) -- 0755
	if not ok and not fs.is_dir(path) then
		return nil, err
	end
	return true
end

--- List directory entries (names only, no "." / ".."). Returns {} if unreadable.
function fs.list_dir(path)
	local iter = uv.fs_scandir(path)
	if not iter then
		return {}
	end
	local out = {}
	while true do
		local name = uv.fs_scandir_next(iter)
		if not name then
			break
		end
		out[#out + 1] = name
	end
	table.sort(out)
	return out
end

function fs.join(...)
	local parts = { ... }
	local path = table.concat(parts, "/")
	path = path:gsub("//+", "/")
	return path
end

--- dirname/basename with libgen semantics for the paths lupus produces.
function fs.dirname(path)
	if path == "" then
		return "."
	end
	path = path:gsub("/+$", "")
	if path == "" then
		return "/"
	end
	local dir = path:match("^(.*)/[^/]+$")
	if not dir then
		return path:sub(1, 1) == "/" and "/" or "."
	end
	if dir == "" then
		return "/"
	end
	return dir
end

function fs.basename(path)
	if path == "" then
		return "."
	end
	path = path:gsub("/+$", "")
	if path == "" then
		return "/"
	end
	return path:match("[^/]+$") or path
end

function fs.home()
	return os.getenv("HOME") or "/tmp"
end

function fs.cwd()
	return uv.cwd()
end

--- Expand a leading ~ to $HOME.
function fs.expand(path)
	if path:sub(1, 2) == "~/" then
		return fs.home() .. path:sub(2)
	elseif path == "~" then
		return fs.home()
	end
	return path
end

--- Make a relative path absolute against a base (default cwd). Normalizes
--- "." and ".." segments.
function fs.absolute(path, base)
	path = fs.expand(path)
	if path:sub(1, 1) ~= "/" then
		path = fs.join(base or fs.cwd(), path)
	end
	local parts = {}
	for seg in path:gmatch("[^/]+") do
		if seg == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif seg ~= "." then
			parts[#parts + 1] = seg
		end
	end
	return "/" .. table.concat(parts, "/")
end

return fs
