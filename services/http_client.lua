-- HTTP Client for fetching content from URLs
-- Provides both Result-based and legacy (boolean, value) return patterns

local logger = require("logger")
local Constants = require("models.constants")
local RequestHeaders = require("utils.request_headers")
local Result = require("utils.result")

local HttpClient = {}

-- The live list of catalogs, which is where the custom headers of each catalog are kept
local catalogs = nil

--- Error codes for HTTP client operations
HttpClient.ErrorCodes = {
    UNSUPPORTED_PROTOCOL = "UNSUPPORTED_PROTOCOL",
    TIMEOUT = "TIMEOUT",
    NETWORK_ERROR = "NETWORK_ERROR",
    AUTH_REQUIRED = "AUTH_REQUIRED",
    AUTH_FAILED = "AUTH_FAILED",
    SERVER_ERROR = "SERVER_ERROR",
    INCOMPLETE_CONTENT = "INCOMPLETE_CONTENT",
}

--- Register the list of catalogs, so requests pick up the custom headers of the catalog they go to
-- The list is read on every request, so catalogs edited later are seen without registering again
-- @param servers table|nil List of catalogs
function HttpClient.setCatalogs(servers)
    catalogs = servers
end

--- Get the custom headers a request to a URL should carry
-- Only a catalog on the same origin as the URL (scheme, host and port) can provide them
-- @param url string URL the request goes to
-- @return table|nil Header list, as kept by the catalog
function HttpClient.customHeadersFor(url)
    return RequestHeaders.forUrl(catalogs, url)
end

--- Add the custom headers of the catalog a URL belongs to
-- @param url string URL the request goes to
-- @param headers table|nil Headers the request sets itself; these are never replaced
-- @return table|nil The headers to send
function HttpClient.withCustomHeaders(url, headers)
    return RequestHeaders.apply(headers, HttpClient.customHeadersFor(url))
end

--- Fetch content from a URL
-- @param url string URL to fetch
-- @param timeout number|nil Connection timeout (default: Constants.TIMEOUTS.DEFAULT)
-- @param maxtime number|nil Maximum request time (default: Constants.TIMEOUTS.MAX_TIME)
-- @param username string|nil HTTP auth username
-- @param password string|nil HTTP auth password
-- @return Result Result object with content on success, error on failure
function HttpClient.fetch(url, timeout, maxtime, username, password)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local parsed = socket_url.parse(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return Result.err("Unsupported protocol", HttpClient.ErrorCodes.UNSUPPORTED_PROTOCOL)
    end

    if not timeout then timeout = Constants.TIMEOUTS.DEFAULT end

    local sink = {}
    socketutil:set_timeout(timeout, maxtime or Constants.TIMEOUTS.MAX_TIME)
    local request = {
        url      = url,
        method   = "GET",
        headers  = HttpClient.withCustomHeaders(url),
        sink     = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
        user     = username,
        password = password,
    }

    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)

    -- Handle timeout errors
    if code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    then
        logger.warn("request interrupted:", code)
        return Result.err(tostring(code), HttpClient.ErrorCodes.TIMEOUT)
    end

    -- Handle network errors
    if headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return Result.err("Network or remote server unavailable", HttpClient.ErrorCodes.NETWORK_ERROR)
    end

    -- Handle HTTP error codes
    if not code or code < Constants.HTTP_SUCCESS_MIN or code > Constants.HTTP_SUCCESS_MAX then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        if code == Constants.HTTP_STATUS.UNAUTHORIZED then
            return Result.err("Authentication required (401)", HttpClient.ErrorCodes.AUTH_REQUIRED)
        elseif code == Constants.HTTP_STATUS.FORBIDDEN then
            return Result.err("Authentication failed (403)", HttpClient.ErrorCodes.AUTH_FAILED)
        end
        return Result.err("Remote server error or unavailable", HttpClient.ErrorCodes.SERVER_ERROR)
    end

    -- Verify content length if provided
    if headers and headers["content-length"] then
        local content_length = tonumber(headers["content-length"])
        if #content ~= content_length then
            return Result.err("Incomplete content received", HttpClient.ErrorCodes.INCOMPLETE_CONTENT)
        end
    end

    return Result.ok(content)
end

--- Legacy function for backward compatibility
-- Returns (success, value_or_error) tuple instead of Result
-- @param url string URL to fetch
-- @param timeout number|nil Connection timeout
-- @param maxtime number|nil Maximum request time
-- @param username string|nil HTTP auth username
-- @param password string|nil HTTP auth password
-- @return boolean, string Success flag and content or error message
local function getUrlContent(url, timeout, maxtime, username, password)
    local result = HttpClient.fetch(url, timeout, maxtime, username, password)
    return result:unpack()
end

-- Export both the legacy function (for backward compatibility) and the module
HttpClient.getUrlContent = getUrlContent

-- Return the legacy function as the default export for backward compatibility
-- Consumers can require("services.http_client") and use it directly
-- Or require("services.http_client").fetch() to get Result-based API
setmetatable(HttpClient, {
    __call = function(_, ...)
        return getUrlContent(...)
    end
})

return HttpClient
