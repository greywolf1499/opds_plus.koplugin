-- Feed Fetcher for OPDS Browser
-- Handles all HTTP requests, caching, and feed parsing

local BD = require("ui/bidi")
local Cache = require("cache")
local InfoMessage = require("ui/widget/infomessage")
local OPDSParser = require("opdsparser")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDSConstants = require("opds_constants")
local OPDSUtils = require("opds_utils")

local FeedFetcher = {}

-- Create the catalog cache
local CatalogCache = Cache:new {
	slots = OPDSConstants.CACHE_SLOTS,
}

-- Fetch raw XML feed from URL
-- @param item_url string URL to fetch from
-- @param headers_only boolean If true, only fetch headers (HEAD request)
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @return string|table XML content or headers, nil on error
function FeedFetcher.fetchFeed(item_url, headers_only, username, password)
	local sink = {}
	socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
	local request = {
		url      = item_url,
		method   = headers_only and "HEAD" or "GET",
		headers  = {
			["Accept-Encoding"] = "identity",
		},
		sink     = ltn12.sink.table(sink),
		user     = username,
		password = password,
	}
	local code, headers, status = socket.skip(1, http.request(request))
	socketutil:reset_timeout()

	if headers_only then
		return headers
	end

	if code == 200 then
		local xml = table.concat(sink)
		return xml ~= "" and xml
	end

	-- Handle errors
	local text, icon
	if headers and code == 301 then
		text = T(_("The catalog has been permanently moved. Please update catalog URL to '%1'."),
			BD.url(headers.location))
	elseif headers and code == 302
		and item_url:match("^https")
		and headers.location:match("^http[^s]") then
		text = T(
			_(
				"Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
			BD.url(item_url), BD.url(headers.location))
		icon = "notice-warning"
	else
		local error_message = {
			["401"] = _("Authentication required for catalog. Please add a username and password."),
			["403"] = _("Failed to authenticate. Please check your username and password."),
			["404"] = _("Catalog not found."),
			["406"] = _("Cannot get catalog. Server refuses to serve uncompressed content."),
		}
		text = code and error_message[tostring(code)] or
			T(_("Cannot get catalog. Server response status: %1."), status or code)
	end

	UIManager:show(InfoMessage:new {
		text = text,
		icon = icon,
	})
	logger.dbg(string.format("OPDS: Failed to fetch catalog `%s`: %s", item_url, text))

	return nil
end

-- Parse feed with caching support
-- @param item_url string URL to fetch and parse
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @return table Parsed feed or nil on error
function FeedFetcher.parseFeed(item_url, username, password, debug_callback)
	local headers = FeedFetcher.fetchFeed(item_url, true, username, password)
	local feed_last_modified = headers and headers["last-modified"]
	local feed

	if feed_last_modified then
		local hash = "opds|catalog|" .. item_url .. "|" .. feed_last_modified
		feed = CatalogCache:check(hash)
		if feed then
			if debug_callback then
				debug_callback("Cache hit for", item_url)
			end
		else
			if debug_callback then
				debug_callback("Cache miss, fetching", item_url)
			end
			feed = FeedFetcher.fetchFeed(item_url, false, username, password)
			if feed then
				CatalogCache:insert(hash, feed)
			end
		end
	else
		feed = FeedFetcher.fetchFeed(item_url, false, username, password)
	end

	if feed then
		return OPDSParser:parse(feed)
	end

	return nil
end

-- Extract server filename from URL headers
-- @param item_url string URL to check
-- @param filetype string|nil Desired file extension
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @return string Filename extracted from server or URL
function FeedFetcher.getServerFileName(item_url, filetype, username, password)
	local headers = FeedFetcher.fetchFeed(item_url, true, username, password)
	local filename

	if headers then
		filename = OPDSUtils.parseContentDisposition(headers["content-disposition"])

		if not filename and headers["location"] then
			filename = headers["location"]:gsub(".*/", "")
		end
	end

	if not filename then
		filename = OPDSUtils.extractFilenameFromUrl(item_url)
	end

	filename = OPDSUtils.ensureFileExtension(filename, filetype)

	return filename
end

-- Get OpenSearch template from descriptor URL
-- @param osd_url string OpenSearch descriptor URL
-- @param search_template_type string Expected template MIME type pattern
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @return string|nil Search template URL with {searchTerms} placeholder
function FeedFetcher.getSearchTemplate(osd_url, search_template_type, username, password, debug_callback)
	local search_descriptor = FeedFetcher.parseFeed(osd_url, username, password, debug_callback)

	---@diagnostic disable-next-line: undefined-field
	if search_descriptor and search_descriptor.OpenSearchDescription and search_descriptor.OpenSearchDescription.Url then
		---@diagnostic disable-next-line: undefined-field
		for _, candidate in ipairs(search_descriptor.OpenSearchDescription.Url) do
			if candidate.type and candidate.template and candidate.type:find(search_template_type) then
				return candidate.template:gsub("{searchTerms}", "%%s")
			end
		end
	end

	return nil
end

-- Generate item table from URL (wrapper for common pattern)
-- @param item_url string URL to fetch catalog from
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @param catalog_parser function Function to parse catalog into item table
-- @return table Item table suitable for menu display
function FeedFetcher.genItemTableFromURL(item_url, username, password, debug_callback, catalog_parser)
	local ok, catalog = pcall(FeedFetcher.parseFeed, item_url, username, password, debug_callback)

	if not ok then
		logger.info("Cannot get catalog info from", item_url, catalog)
		UIManager:show(InfoMessage:new {
			text = T(_("Cannot get catalog info from %1"), (item_url and BD.url(item_url) or "nil")),
		})
		---@diagnostic disable-next-line: cast-local-type
		catalog = nil
	end

	-- Call the provided catalog parser function
	return catalog_parser(catalog, item_url)
end

-- Clear the catalog cache
function FeedFetcher.clearCache()
	CatalogCache:clear()
end

-- Get cache statistics
-- @return number, number Used slots, total slots
function FeedFetcher.getCacheStats()
	return CatalogCache:used_size(), CatalogCache.slots
end

return FeedFetcher
