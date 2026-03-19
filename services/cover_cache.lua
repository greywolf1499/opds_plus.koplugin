local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")

local CoverCache = {}

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/opds_plus/covers"

local function ensureDir(path)
	if lfs.attributes(path, "mode") == "directory" then
		return true
	end

	local current = ""
	for part in path:gmatch("[^/]+") do
		current = current == "" and ("/" .. part) or (current .. "/" .. part)
		if lfs.attributes(current, "mode") ~= "directory" then
			local ok = lfs.mkdir(current)
			if not ok then
				return false
			end
		end
	end
	return true
end

local function hashUrl(url)
	local h1 = 5381
	local h2 = 2166136261

	for i = 1, #url do
		local b = string.byte(url, i)
		h1 = bit.tobit(bit.bxor((h1 * 33), b))
		h2 = bit.tobit((h2 * 16777619) + b)
	end

	return bit.tohex(h1) .. bit.tohex(h2)
end

local function cachePath(url)
	return CACHE_DIR .. "/" .. hashUrl(url) .. ".img"
end

local function readFile(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

local function writeFile(path, content)
	local f = io.open(path, "wb")
	if not f then
		return false
	end
	f:write(content)
	f:close()
	return true
end

local function listCacheFiles()
	local files = {}
	local total = 0

	if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
		return files, total
	end

	for name in lfs.dir(CACHE_DIR) do
		if name ~= "." and name ~= ".." and name:sub(-4) == ".img" then
			local path = CACHE_DIR .. "/" .. name
			local attr = lfs.attributes(path)
			if attr and attr.mode == "file" then
				local size = attr.size or 0
				table.insert(files, {
					path = path,
					size = size,
					mtime = attr.modification or 0,
				})
				total = total + size
			end
		end
	end

	return files, total
end

local function pruneToMaxBytes(max_bytes)
	if not max_bytes or max_bytes <= 0 then
		return
	end

	local files, total = listCacheFiles()
	if total <= max_bytes then
		return
	end

	table.sort(files, function(a, b)
		return a.mtime < b.mtime
	end)

	for _, file in ipairs(files) do
		if total <= max_bytes then
			break
		end

		os.remove(file.path)
		total = total - file.size
	end
end

function CoverCache.get(url, ttl_seconds)
	local path = cachePath(url)
	local attr = lfs.attributes(path)
	if not attr or attr.mode ~= "file" then
		return nil
	end

	local content = readFile(path)
	if not content or content == "" then
		return nil
	end

	local age = os.time() - (attr.modification or 0)
	return {
		content = content,
		stale = ttl_seconds and age > ttl_seconds or false,
		age_seconds = age,
	}
end

function CoverCache.put(url, content, max_bytes)
	if not content or content == "" then
		return false
	end

	if not ensureDir(CACHE_DIR) then
		return false
	end

	local ok = writeFile(cachePath(url), content)
	if ok and max_bytes and max_bytes > 0 then
		pruneToMaxBytes(max_bytes)
	end
	return ok
end

function CoverCache.clear()
	if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
		return
	end

	for name in lfs.dir(CACHE_DIR) do
		if name ~= "." and name ~= ".." and name:sub(-4) == ".img" then
			os.remove(CACHE_DIR .. "/" .. name)
		end
	end
end

return CoverCache
