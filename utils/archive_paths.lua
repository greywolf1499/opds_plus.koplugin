-- Checks the entry names and kinds of an update archive before anything is extracted from it.
-- libarchive only checks the destination we pass it, not an entry's own name, so a crafted zip could
-- otherwise write outside the staging folder. Pure Lua, no KOReader modules.

local ArchivePaths = {}

ArchivePaths.MAX_ENTRIES = 2000
ArchivePaths.MAX_TOTAL_SIZE = 64 * 1024 * 1024
ArchivePaths.MAX_PATH_LENGTH = 1024
ArchivePaths.MAX_COMPONENT_LENGTH = 255
ArchivePaths.MAX_DEPTH = 16

--- Reads the name of an archive entry that must sit inside a single top-level folder
-- @param name string The entry name as the archive gives it, such as "opds_plus.koplugin/main.lua"
-- @param prefix string The top-level folder every entry must be in
-- @return string|nil The name inside the top-level folder ("" for the folder itself), nil when refused
-- @return string|nil Why the name is refused
function ArchivePaths.entryPath(name, prefix)
	if type(name) ~= "string" or name == "" then
		return nil, "empty entry name"
	end
	if #name > ArchivePaths.MAX_PATH_LENGTH then
		return nil, "entry name too long"
	end
	if name:find("%z") or name:find("%c") then
		return nil, "control character in entry name"
	end
	if name:find("\\", 1, true) then
		return nil, "backslash in entry name: " .. name
	end
	if name:sub(1, 1) == "/" then
		return nil, "absolute entry name: " .. name
	end
	-- A folder entry ends with one slash
	local trimmed = name:gsub("/$", "")
	local components = {}
	for component in (trimmed .. "/"):gmatch("([^/]*)/") do
		if component == "" or component == "." or component == ".." then
			return nil, "unsafe entry name: " .. name
		end
		if #component > ArchivePaths.MAX_COMPONENT_LENGTH then
			return nil, "entry name too long"
		end
		components[#components + 1] = component
	end
	if #components > ArchivePaths.MAX_DEPTH then
		return nil, "entry nested too deep: " .. name
	end
	if components[1] ~= prefix then
		return nil, "entry outside " .. tostring(prefix) .. "/: " .. name
	end
	return table.concat(components, "/", 2)
end

--- Checks every entry of an archive
-- @param entries table List of { path = string, mode = string, size = number|cdata }, as ffi/archiver
--   Reader:iterate() yields them
-- @param prefix string The top-level folder every entry must be in
-- @param limits table|nil { max_entries, max_total_size } to override the defaults
-- @return table|nil List of { path, rel, mode, size } in archive order, nil when refused
-- @return number|string The total size of the files, or why the archive is refused
function ArchivePaths.validate(entries, prefix, limits)
	limits = limits or {}
	local max_entries = limits.max_entries or ArchivePaths.MAX_ENTRIES
	local max_total = limits.max_total_size or ArchivePaths.MAX_TOTAL_SIZE
	if type(entries) ~= "table" or #entries == 0 then
		return nil, "empty archive"
	end
	if #entries > max_entries then
		return nil, "too many entries in archive"
	end

	local checked, seen, files = {}, {}, {}
	local total, file_count = 0, 0
	for _, entry in ipairs(entries) do
		if entry.mode ~= "file" and entry.mode ~= "directory" then
			return nil, "not a file or folder: " .. tostring(entry.path) .. " (" .. tostring(entry.mode) .. ")"
		end
		local rel, err = ArchivePaths.entryPath(entry.path, prefix)
		if not rel then
			return nil, err
		end
		if entry.mode == "file" and rel == "" then
			return nil, "top-level entry is a file: " .. entry.path
		end
		-- Names that differ only by case collide on FAT and exFAT
		local key = rel:lower()
		if seen[key] then
			if seen[key] ~= entry.mode or entry.mode == "file" then
				return nil, "duplicate entry: " .. entry.path
			end
		end
		seen[key] = entry.mode
		local size = 0
		if entry.mode == "file" then
			size = tonumber(entry.size) or -1
			if size < 0 then
				return nil, "bad size for " .. entry.path
			end
			files[key] = true
			file_count = file_count + 1
			total = total + size
			if total > max_total then
				return nil, "archive too large when extracted"
			end
		end
		checked[#checked + 1] = { path = entry.path, rel = rel, mode = entry.mode, size = size }
	end

	-- A file can't also be the folder of another entry
	for key in pairs(seen) do
		local parent = key:match("^(.*)/[^/]*$")
		while parent do
			if files[parent] then
				return nil, "file used as a folder: " .. parent
			end
			parent = parent:match("^(.*)/[^/]*$")
		end
	end

	if file_count == 0 then
		return nil, "no files in archive"
	end
	return checked, total
end

return ArchivePaths
