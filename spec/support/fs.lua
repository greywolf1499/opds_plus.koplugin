-- Filesystem helpers for specs: temp dirs, small file I/O and a symlink-safe recursive delete.
--
-- Containment: every fixture lives in a directory created by fs.tmpdir() as /tmp/opds_plus_test_<random>.
-- fs.write, fs.mkdirs and fs.remove_tree refuse any path outside those registered roots, and
-- fs.install_guards() (called by spec/helper.lua) makes the live os.remove, os.rename and lfs.rmdir do
-- the same, so neither a broken spec nor a broken plugin helper can touch the rest of the disk.
local lfs = require("lfs")

local fs = {}

local TMP_PREFIX = "/tmp/opds_plus_test_"
local ROOT_PATTERN = "^/tmp/opds_plus_test_%x+$"

local live = {
	remove = os.remove,
	rename = os.rename,
	rmdir = lfs.rmdir,
}

-- Registered fixture roots, in creation order.
local temp_dirs = {}

local function random_suffix()
	local urandom = assert(io.open("/dev/urandom", "rb"))
	local bytes = urandom:read(8)
	urandom:close()
	return (bytes:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

local function split(path)
	local parts = {}
	for component in path:gmatch("[^/]+") do
		parts[#parts + 1] = component
	end
	return parts
end

-- The registered root that `path` is (or is inside of), or nil. A relative path is resolved against the
-- working directory, as the system would. Rejects ".." components and paths whose parent components
-- are symlinks (they could point anywhere). The last component may be a symlink: deleting a link never
-- follows it.
function fs.owning_root(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	if path:sub(1, 1) ~= "/" then
		path = lfs.currentdir() .. "/" .. path
	end
	local parts = {}
	for _, component in ipairs(split(path)) do
		if component ~= "." then
			parts[#parts + 1] = component
		end
	end
	for _, component in ipairs(parts) do
		if component == "." or component == ".." then
			return nil
		end
	end
	local normalized = "/" .. table.concat(parts, "/")
	for _, root in ipairs(temp_dirs) do
		if normalized == root or normalized:sub(1, #root + 1) == root .. "/" then
			if lfs.symlinkattributes(root, "mode") ~= "directory" then
				return nil
			end
			local current = root
			local rest = split(normalized:sub(#root + 1))
			for i = 1, #rest - 1 do
				current = current .. "/" .. rest[i]
				local mode = lfs.symlinkattributes(current, "mode")
				if mode == "link" then
					return nil
				end
			end
			return root
		end
	end
	return nil
end

local function assert_contained(path, action)
	if not fs.owning_root(path) then
		error(("refusing to %s outside a spec temp dir: %s"):format(action, tostring(path)), 3)
	end
end

function fs.exists(path)
	return lfs.symlinkattributes(path, "mode") ~= nil
end

function fs.mkdirs(path)
	assert_contained(path, "create directories")
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
	assert_contained(path, "write")
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

-- Deletes a tree inside a registered temp dir. Symlinks are removed, never followed, so a fixture that
-- links to a real directory can't make a cleanup (or a test of one) delete anything outside it.
function fs.remove_tree(path)
	assert_contained(path, "delete")
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
		live.rmdir(path)
	else
		live.remove(path)
	end
end

-- Creates an empty, unique /tmp/opds_plus_test_<random> directory that fs.cleanup() removes. mkdir is
-- atomic and fails on an existing name, so a pre-planted directory or link is never adopted.
function fs.tmpdir()
	for _ = 1, 16 do
		local path = TMP_PREFIX .. random_suffix()
		assert(path:match(ROOT_PATTERN))
		if lfs.mkdir(path) and lfs.symlinkattributes(path, "mode") == "directory" then
			temp_dirs[#temp_dirs + 1] = path
			return path
		end
	end
	error("could not create a spec temp dir under " .. TMP_PREFIX)
end

function fs.cleanup()
	for i = #temp_dirs, 1, -1 do
		local root = temp_dirs[i]
		if root:match(ROOT_PATTERN) then
			fs.remove_tree(root)
		end
	end
	temp_dirs = {}
end

-- Replaces the live os.remove, os.rename and lfs.rmdir with versions that raise for any path outside
-- a registered temp dir (for os.rename, both ends). Specs that need deletion to fail or to reach other
-- paths must use fakes instead (see spec/unit/file_utils_spec.lua).
function fs.install_guards()
	if os.remove ~= live.remove then
		return
	end
	---@diagnostic disable-next-line: duplicate-set-field
	os.remove = function(path) -- luacheck: ignore 122
		assert_contained(path, "os.remove")
		return live.remove(path)
	end
	---@diagnostic disable-next-line: duplicate-set-field
	os.rename = function(from, to) -- luacheck: ignore 122
		assert_contained(from, "os.rename from")
		assert_contained(to, "os.rename to")
		return live.rename(from, to)
	end
	lfs.rmdir = function(path)
		assert_contained(path, "lfs.rmdir")
		return live.rmdir(path)
	end
end

return fs
