-- File utility functions for OPDS operations
-- Handles filename manipulation and validation, and removing folders

local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local FileUtils = {}

--- Add file extension if missing, or if it is not one the reader can open
-- @param filename string Original filename
-- @param filetype string Desired file extension (without dot)
-- @param is_known function|nil Tells whether a suffix can be opened; without it only a missing one is replaced
-- @return string Filename with extension
function FileUtils.ensureExtension(filename, filetype, is_known)
	if not filename or not filetype then return filename end

	-- util.getFileNameSuffix returns "" for a name without a dot, never nil
	local current_suffix = util.getFileNameSuffix(filename)
	if current_suffix == "" or (is_known and not is_known(current_suffix)) then
		filename = filename .. "." .. filetype:lower()
	end

	return filename
end

--- Sanitize filename for safe filesystem usage
-- @param filename string Original filename
-- @param directory string Target directory path
-- @return string Safe filename
function FileUtils.sanitize(filename, directory)
	return util.getSafeFilename(filename, directory)
end

--- Fix UTF-8 encoding issues in filename
-- @param filename string Filename to fix
-- @param replacement string Character to replace invalid UTF-8 (default: "_")
-- @return string Fixed filename
function FileUtils.fixUtf8(filename, replacement)
	return util.fixUtf8(filename, replacement or "_")
end

--- Check a path before removing a tree from it
-- @param path any
-- @return string|nil The path without trailing slashes
-- @return string|nil Why the path is refused
local function checkTreePath(path)
	if type(path) ~= "string" or path == "" then
		return nil, "no path to remove"
	end
	if path:sub(1, 1) ~= "/" then
		return nil, "not an absolute path: " .. path
	end
	-- With a trailing slash the system looks through a link, at the folder it points to
	path = path:gsub("/+$", "")
	if path == "" then
		return nil, "refusing to remove the root folder"
	end
	for component in path:gmatch("[^/]+") do
		if component == "." or component == ".." then
			return nil, "refusing a path with . or .. in it: " .. path
		end
	end
	return path
end

--- Remove a file, a link or a folder with everything in it. A link is removed itself, never followed.
-- Keeps going after a failure, so as much as possible is removed.
-- @param path string An existing path, without trailing slashes
-- @return boolean|nil true when the path is gone
-- @return string|nil What could not be removed
local function removeEntry(path)
	local mode = lfs.symlinkattributes(path, "mode")
	if mode == nil then
		return true
	end
	if mode ~= "directory" then
		return os.remove(path)
	end

	local listed, names = pcall(function()
		local found = {}
		for name in lfs.dir(path) do
			if name ~= "." and name ~= ".." then
				found[#found + 1] = name
			end
		end
		return found
	end)
	if not listed then
		return nil, tostring(names)
	end

	local failure
	for _, name in ipairs(names) do
		local removed, err = removeEntry(path .. "/" .. name)
		if not removed and not failure then
			failure = err
		end
	end
	local removed, err = lfs.rmdir(path)
	if not removed and not failure then
		failure = path .. ": " .. tostring(err)
	end
	if failure then
		return nil, failure
	end
	return true
end

--- Remove a file or a folder with everything in it, without ever following a link: a link to a folder
-- (a development checkout, say) is removed and the folder it points to is left alone.
-- @param path string Absolute path, without . or .. in it. Anything else is refused
-- @return boolean|nil true when the path is gone, or was not there
-- @return string|nil Why the path was refused, or what could not be removed
function FileUtils.removeTree(path)
	local clean, refusal = checkTreePath(path)
	if not clean then
		return nil, refusal
	end
	return removeEntry(clean)
end

return FileUtils
