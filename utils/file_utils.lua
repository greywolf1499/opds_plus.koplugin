-- File utility functions for OPDS operations
-- Handles filename manipulation and validation

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

return FileUtils
