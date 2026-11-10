-- Feed Fetcher for OPDS Browser
-- Handles all HTTP requests, caching, and feed parsing

local BD = require("ui/bidi")
local Cache = require("cache")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDSParser = require("core.parser")
local Constants = require("models.constants")
local HttpClient = require("services.http_client")
local UrlUtils = require("utils.url_utils")
local FileUtils = require("utils.file_utils")
local Result = require("utils.result")

local FeedFetcher = {}

-- Create the catalog cache
local CatalogCache = Cache:new {
	slots = Constants.CACHE_SLOTS,
}

-- Fetch raw XML feed from URL
-- @param item_url string URL to fetch from
-- @param headers_only boolean If true, only fetch headers (HEAD request)
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param cached table|nil Earlier copy of the feed ({ xml, etag, last_modified }) the server may confirm unchanged
-- @return string|table XML content or headers, nil on error
-- @return table|nil Response headers of a GET
function FeedFetcher.fetchFeed(item_url, headers_only, username, password, cached)
	socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
	local own_headers = { ["Accept-Encoding"] = "identity" }
	if cached and not headers_only then
		own_headers["If-None-Match"] = cached.etag
		own_headers["If-Modified-Since"] = cached.last_modified
	end
	-- Redirects are followed by the client rather than by LuaSocket, which drops the credentials of a
	-- redirect to the same server and sends the custom headers of the catalog to any other
	local code, headers, status, info = socket.skip(1, HttpClient.request({
		url      = item_url,
		method   = headers_only and "HEAD" or "GET",
		headers  = own_headers,
		user     = username,
		password = password,
	}))
	socketutil:reset_timeout()

	if headers_only then
		return headers
	end

	if cached and code == Constants.HTTP_STATUS.NOT_MODIFIED then
		return cached.xml, headers
	end

	if code == Constants.HTTP_STATUS.OK then
		local xml = info.body
		return xml ~= "" and xml, headers
	end

	-- Handle errors
	local text, icon
	if headers and headers.location and code == Constants.HTTP_STATUS.MOVED_PERMANENTLY then
		text = T(_("The catalog has been permanently moved. Please update catalog URL to '%1'."),
			BD.url(headers.location))
	elseif headers and headers.location and code == Constants.HTTP_STATUS.FOUND
		and info.url:match("^https")
		and headers.location:match("^http[^s]") then
		text = T(
			_(
				"Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
			BD.url(info.url), BD.url(headers.location))
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
	-- One request per feed: a server that tags or dates its feeds answers "not modified" when the copy
	-- kept here is still current, and one that does not just sends the feed.
	local key = "opds|catalog|" .. item_url
	local cached = CatalogCache:check(key)
	local feed, headers = FeedFetcher.fetchFeed(item_url, false, username, password, cached)

	if feed and cached and feed == cached.xml then
		if debug_callback then
			debug_callback("Cache hit for", item_url)
		end
	elseif feed and headers and (headers["etag"] or headers["last-modified"]) then
		CatalogCache:insert(key, {
			xml = feed,
			etag = headers["etag"],
			last_modified = headers["last-modified"],
		})
	end

	if feed then
		return OPDSParser:parse(feed)
	end

	return nil
end

-- Parse feed with Result-based error handling
-- @param item_url string URL to fetch and parse
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @return Result Result with parsed feed or error
function FeedFetcher.parseFeedResult(item_url, username, password, debug_callback)
	local result = Result.wrapPcall(FeedFetcher.parseFeed)(item_url, username, password, debug_callback)

	-- Convert nil success to error
	if result:isOk() and result.value == nil then
		return Result.err("Failed to fetch or parse feed")
	end

	return result
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
		filename = UrlUtils.parseContentDisposition(headers["content-disposition"])

		if not filename and headers["location"] then
			-- Same rules as for the address itself: no query string, and percent-escapes decoded
			local from_location = UrlUtils.extractFilename(headers["location"])
			if from_location ~= "" then
				filename = from_location
			end
		end
	end

	if not filename then
		filename = UrlUtils.extractFilename(item_url)
	end

	filename = FileUtils.ensureExtension(filename, filetype, function(suffix)
		return DocumentRegistry:hasProvider("dummy." .. suffix)
	end)

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
	local result = FeedFetcher.parseFeedResult(item_url, username, password, debug_callback)

	local catalog = result:unwrapOrElse(function(err)
		logger.info("Cannot get catalog info from", item_url, err)
		UIManager:show(InfoMessage:new {
			text = T(_("Cannot get catalog info from %1"), (item_url and BD.url(item_url) or "nil")),
		})
		return nil
	end)

	-- Call the provided catalog parser function
	-- Pass catalog and the item_url
	return catalog_parser(catalog, item_url)
end

-- Clear the catalog cache
function FeedFetcher.clearCache()
	CatalogCache:clear()
end

return FeedFetcher
