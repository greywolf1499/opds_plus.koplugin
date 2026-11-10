-- Filesystem helpers for specs: temp dirs, small file I/O and a symlink-safe recursive delete.
local lfs = require("lfs")

local fs = {}

function fs.exists(path)
	return lfs.symlinkattributes(path, "mode") ~= nil
end

function fs.mkdirs(path)
	local current = path:sub(1, 1) == "/" and "/" or ""
	for component in path:gmatch("[^/]+") do
		current = current .. component .. "/"
		if lfs.attributes(current, "mode") == nil then
			assert(lfs.mkdir(current))
		end
	end
	return path
end

function fs.write(path, content)
	local dir = path:match("^(.*)/[^/]*$")
	if dir and dir ~= "" then
		fs.mkdirs(dir)
	end
	local file = assert(io.open(path, "wb"))
	file:write(content or "")
	file:close()
	return path
end

function fs.read(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

-- Lists the entry names of a directory, sorted.
function fs.list(path)
	local names = {}
	for name in lfs.dir(path) do
		if name ~= "." and name ~= ".." then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

-- Deletes a tree. Symlinks are removed, never followed, so a fixture that links to a real directory
-- can't make a cleanup (or a test of one) delete anything outside the temp dir.
function fs.remove_tree(path)
	local mode = lfs.symlinkattributes(path, "mode")
	if mode == nil then
		return
	end
	if mode == "directory" then
		for name in lfs.dir(path) do
			if name ~= "." and name ~= ".." then
				fs.remove_tree(path .. "/" .. name)
			end
		end
		lfs.rmdir(path)
	else
		os.remove(path)
	end
end

local temp_dirs = {}

-- Creates an empty, unique directory that fs.cleanup() removes.
function fs.tmpdir()
	local path = os.tmpname()
	os.remove(path)
	assert(lfs.mkdir(path))
	temp_dirs[#temp_dirs + 1] = path
	return path
end

function fs.cleanup()
	for _, path in ipairs(temp_dirs) do
		fs.remove_tree(path)
	end
	temp_dirs = {}
end

return fs
