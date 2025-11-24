-- URL utility functions for OPDS operations
-- Handles URL construction, parsing, and manipulation

local url = require("socket.url")
local logger = require("logger")

local UrlUtils = {}

--- Build an absolute URL from a base URL and relative href
-- @param base_url string Base URL
-- @param href string Relative or absolute URL
-- @return string Absolute URL
function UrlUtils.buildAbsolute(base_url, href)
	return url.absolute(base_url, href)
end

--- Extract filename from URL, handling query parameters and URL decoding
-- @param item_url string URL to extract filename from
-- @return string Extracted and decoded filename
function UrlUtils.extractFilename(item_url)
	-- Remove query parameters and fragments
	local filename = item_url:gsub("?.*", ""):gsub("#.*", "")

	-- Extract just the filename part
	filename = filename:gsub(".*/", "")

	-- URL decode the filename
	filename = url.unescape(filename)

	return filename
end

--- Parse filename from Content-Disposition header
-- @param disposition string Content-Disposition header value
-- @return string|nil Extracted and decoded filename or nil
function UrlUtils.parseContentDisposition(disposition)
	if not disposition then return nil end

	-- Try quoted filename first: filename="example.epub"
	local filename = disposition:match('filename="([^"]+)"')
	if filename then
		return url.unescape(filename)
	end

	-- Try unquoted filename: filename=example.epub
	filename = disposition:match('filename=([^;]+)')
	if filename then
		return url.unescape(filename)
	end

	return nil
end

--- Determine if a URL is searchable (contains %s placeholder)
-- @param catalog_url string URL to check
-- @return boolean True if URL contains search placeholder
function UrlUtils.isSearchable(catalog_url)
	return catalog_url and catalog_url:match("%%s") and true or false
end

--- Create a search URL by replacing search terms placeholder
-- @param template string URL template with {searchTerms} or %s
-- @param search_query string Search query (already URL encoded)
-- @return string Search URL with query inserted
function UrlUtils.buildSearchUrl(template, search_query)
	if not template or not search_query then return nil end

	-- Handle both {searchTerms} and %s patterns
	local search_url = template:gsub("{searchTerms}", search_query)
	search_url = search_url:gsub("%%s", search_query)

	return search_url
end

--- Check if a link should be treated as a catalog navigation link
-- @param link table Link object from OPDS feed
-- @param catalog_type string Expected catalog MIME type pattern
-- @return boolean True if link is a navigation link
function UrlUtils.isCatalogNavigationLink(link, catalog_type)
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

--- Check if a link should be treated as an acquisition link
-- @param link table Link object from OPDS feed
-- @param acquisition_pattern string Pattern to match acquisition rel
-- @return boolean True if link is an acquisition link
function UrlUtils.isAcquisitionLink(link, acquisition_pattern)
	return link.rel and link.rel:match(acquisition_pattern)
end

return UrlUtils
