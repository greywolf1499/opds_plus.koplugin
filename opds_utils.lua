-- OPDS utility functions
-- Extracted from opdsbrowserplus.lua for reusability

local util = require("util")
local url = require("socket.url")
local logger = require("logger")

local OPDSUtils = {}

-- Build a catalog entry for the root menu
-- @param server table Server configuration object
-- @return table Formatted catalog entry
function OPDSUtils.buildRootEntry(server)
	local icons = ""
	if server.username then
		icons = "\u{f2c0}" -- Lock icon for authenticated catalogs
	end
	if server.sync then
		icons = "\u{f46a} " .. icons -- Sync icon
	end
	return {
		text       = server.title,
		mandatory  = icons,
		url        = server.url,
		username   = server.username,
		password   = server.password,
		raw_names  = server.raw_names,
		searchable = server.url and server.url:match("%%s") and true or false,
		sync       = server.sync,
	}
end

-- Build an absolute URL from a base URL and relative href
-- @param base_url string Base URL
-- @param href string Relative or absolute URL
-- @return string Absolute URL
function OPDSUtils.buildAbsoluteUrl(base_url, href)
	return url.absolute(base_url, href)
end

-- Extract filename from URL, handling query parameters
-- @param item_url string URL to extract filename from
-- @return string Extracted filename
function OPDSUtils.extractFilenameFromUrl(item_url)
	return item_url:gsub(".*/", ""):gsub("?.*", "")
end

-- Parse filename from Content-Disposition header
-- @param disposition string Content-Disposition header value
-- @return string|nil Extracted filename or nil
function OPDSUtils.parseContentDisposition(disposition)
	if not disposition then return nil end

	-- Try quoted filename first: filename="example.epub"
	local filename = disposition:match('filename="([^"]+)"')
	if filename then return filename end

	-- Try unquoted filename: filename=example.epub
	filename = disposition:match('filename=([^;]+)')
	return filename
end

-- Add file extension if missing
-- @param filename string Original filename
-- @param filetype string Desired file extension (without dot)
-- @return string Filename with extension
function OPDSUtils.ensureFileExtension(filename, filetype)
	if not filename or not filetype then return filename end

	local current_suffix = util.getFileNameSuffix(filename)
	if not current_suffix then
		filename = filename .. "." .. filetype:lower()
	end

	return filename
end

-- Determine if a URL is searchable (contains %s placeholder)
-- @param catalog_url string URL to check
-- @return boolean True if URL contains search placeholder
function OPDSUtils.isSearchableUrl(catalog_url)
	return catalog_url and catalog_url:match("%%s") and true or false
end

-- Create a search URL by replacing search terms placeholder
-- @param template string URL template with {searchTerms} or %s
-- @param search_query string Search query (already URL encoded)
-- @return string Search URL with query inserted
function OPDSUtils.buildSearchUrl(template, search_query)
	if not template or not search_query then return nil end

	-- Handle both {searchTerms} and %s patterns
	local search_url = template:gsub("{searchTerms}", search_query)
	search_url = search_url:gsub("%%s", search_query)

	return search_url
end

-- Extract count and last_read from PSE stream link attributes
-- @param link table Link object with PSE attributes
-- @return number|nil, number|nil count, last_read values
function OPDSUtils.extractPSEStreamInfo(link)
	local count, last_read

	for k, v in pairs(link) do
		if k:sub(-6) == ":count" then
			count = tonumber(v)
		elseif k:sub(-9) == ":lastRead" then
			last_read = tonumber(v)
		end
	end

	return count, (last_read and last_read > 0 and last_read or nil)
end

-- Parse title from entry (handles both string and table formats)
-- @param entry_title string|table Title from OPDS entry
-- @param default string Default value if parsing fails
-- @return string Parsed title
function OPDSUtils.parseEntryTitle(entry_title, default)
	default = default or "Unknown"

	if type(entry_title) == "string" then
		return entry_title
	elseif type(entry_title) == "table" then
		if type(entry_title.type) == "string" and entry_title.div ~= "" then
			return entry_title.div
		end
	end

	return default
end

-- Parse author from entry (handles various formats)
-- @param entry_author table Author information from OPDS entry
-- @param default string Default value if parsing fails
-- @return string|nil Parsed author name or nil
function OPDSUtils.parseEntryAuthor(entry_author, _default)
	_default = _default or "Unknown Author"

	if type(entry_author) ~= "table" or not entry_author.name then
		return nil
	end

	local author = entry_author.name

	if type(author) == "table" then
		if #author > 0 then
			author = table.concat(author, ", ")
		else
			return nil
		end
	end

	return author
end

-- Check if a link should be treated as a catalog navigation link
-- @param link table Link object from OPDS feed
-- @param catalog_type string Expected catalog MIME type pattern
-- @return boolean True if link is a navigation link
function OPDSUtils.isCatalogNavigationLink(link, catalog_type)
	if not link.type or not link.type:find(catalog_type) then
		return false
	end

	-- Check if rel is not set or is a subsection/sort type
	return not link.rel
		or link.rel == "subsection"
		or link.rel == "http://opds-spec.org/subsection"
		or link.rel == "http://opds-spec.org/sort/popular"
		or link.rel == "http://opds-spec.org/sort/new"
end

-- Check if a link should be treated as an acquisition link
-- @param link table Link object from OPDS feed
-- @param acquisition_pattern string Pattern to match acquisition rel
-- @return boolean True if link is an acquisition link
function OPDSUtils.isAcquisitionLink(link, acquisition_pattern)
	return link.rel and link.rel:match(acquisition_pattern)
end

-- Log debug message if debug mode is enabled
-- @param manager table Plugin manager with settings
-- @param ... any Arguments to log
function OPDSUtils.debugLog(manager, ...)
	if manager and manager.settings and manager.settings.debug_mode then
		logger.dbg("OPDS+ Utils:", ...)
	end
end

return OPDSUtils
