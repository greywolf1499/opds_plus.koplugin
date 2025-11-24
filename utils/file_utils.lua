-- File utility functions for OPDS operations
-- Handles filename manipulation and validation

local util = require("util")

local FileUtils = {}

--- Add file extension if missing
-- @param filename string Original filename
-- @param filetype string Desired file extension (without dot)
-- @return string Filename with extension
function FileUtils.ensureExtension(filename, filetype)
	if not filename or not filetype then return filename end

	local current_suffix = util.getFileNameSuffix(filename)
	if not current_suffix then
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
