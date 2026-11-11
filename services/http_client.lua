-- HTTP Client for fetching content from URLs
-- Provides both Result-based and legacy (boolean, value) return patterns

local logger = require("logger")
local Constants = require("models.constants")
local RequestHeaders = require("utils.request_headers")
local Result = require("utils.result")
local UrlUtils = require("utils.url_utils")

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
    INSECURE_REDIRECT = "INSECURE_REDIRECT",
    HOST_NOT_ALLOWED = "HOST_NOT_ALLOWED",
    TOO_LARGE = "TOO_LARGE",
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

-- Statuses a redirect is followed for. LuaSocket follows all of them but 308.
local REDIRECT_STATUSES = {
    [Constants.HTTP_STATUS.MOVED_PERMANENTLY] = true,
    [Constants.HTTP_STATUS.FOUND] = true,
    [Constants.HTTP_STATUS.SEE_OTHER] = true,
    [Constants.HTTP_STATUS.TEMPORARY_REDIRECT] = true,
    [Constants.HTTP_STATUS.PERMANENT_REDIRECT] = true,
}

-- Headers that are credentials in themselves: only the origin they were set for may see them
local CREDENTIAL_HEADERS = {
    ["authorization"] = true,
    ["cookie"] = true,
    ["proxy-authorization"] = true,
}

local function isHttps(origin)
    return origin ~= nil and origin:sub(1, 6) == "https:"
end

-- Why a request to a URL must not be made, nil when it may be
local function refusalFor(url, options, is_redirect)
    local origin = RequestHeaders.originKey(url)
    if not origin then
        return HttpClient.ErrorCodes.UNSUPPORTED_PROTOCOL
    end
    if options.https_only and not isHttps(origin) then
        return is_redirect and HttpClient.ErrorCodes.INSECURE_REDIRECT or HttpClient.ErrorCodes.UNSUPPORTED_PROTOCOL
    end
    if options.allow_host then
        local host = require("socket.url").parse(url).host
        if not host or not options.allow_host(host:lower()) then
            return HttpClient.ErrorCodes.HOST_NOT_ALLOWED
        end
    end
    return nil
end

-- The headers of the request that one hop sends: always a copy, so the caller's table is never changed
local function headersForHop(request, url, same_origin, options)
    local headers
    if request.headers then
        headers = {}
        for name, value in pairs(request.headers) do
            if same_origin or not CREDENTIAL_HEADERS[tostring(name):lower()] then
                headers[name] = value
            end
        end
    end
    if options.custom_headers ~= false then
        headers = HttpClient.withCustomHeaders(url, headers)
    end
    return headers
end

-- A sink that keeps the body in memory, and gives up on one that grows past max_bytes
local function memorySink(chunks, options)
    local sink
    if options.total_timeout then
        sink = require("socketutil").table_sink(chunks)
    else
        sink = require("ltn12").sink.table(chunks)
    end
    local size = 0
    return function(chunk, err)
        if chunk then
            size = size + #chunk
            if options.max_bytes and size > options.max_bytes then
                return nil, HttpClient.ErrorCodes.TOO_LARGE
            end
        end
        return sink(chunk, err)
    end
end

-- Where a response sends the request on to, nil when it is not to be followed
local function redirectTarget(url, code, headers, options)
    if not REDIRECT_STATUSES[code] or not headers or not headers.location then
        return nil
    end
    -- Spaces are not allowed in a Location, but some servers send them anyway
    local location = headers.location:match("^%s*(.-)%s*$")
    if location == "" then
        return nil
    end
    local target = UrlUtils.buildAbsolute(url, (location:gsub(" ", "%%20")))
    local target_origin = RequestHeaders.originKey(target)
    if not target_origin then
        return nil
    end
    -- A downgrade is handed back for the caller to explain, unless the request must be https all along
    if isHttps(RequestHeaders.originKey(url)) and not isHttps(target_origin) and not options.https_only then
        return nil
    end
    return target
end

--- Make a request and follow its redirects here, instead of leaving them to LuaSocket
-- LuaSocket builds the request after a redirect from the headers alone. Basic credentials are dropped,
-- even when the redirect stays on the same server, TLS settings are dropped, and the custom headers of a
-- catalog go along to wherever the redirect points. Here every hop is built from the original request:
--  * Basic credentials and Authorization, Cookie and Proxy-Authorization headers only go to the origin
--    (scheme, host and port) of the first URL
--  * the custom headers of a catalog only go to that catalog's origin
--  * every other option of the request, TLS settings included, is kept
-- 301, 302, 303, 307 and 308 are followed, for GET and HEAD. A redirect that is not followed is returned
-- as it was received, so callers can explain it: one with no usable Location, one to another scheme than
-- http or https, one from https to http, and the one that goes past the limit.
-- @param request table What socket.http.request takes (url, method, headers, user, password, TLS options),
-- without sink and source
-- @param options table|nil Optional settings:
--   max_redirects number  Redirects to follow (default Constants.MAX_REDIRECTS)
--   https_only boolean    Refuse every URL that is not https, a redirect to http included
--   allow_host function   Called with the lower-cased host of every URL; returns false to refuse it
--   custom_headers boolean  Set false to never add the custom headers of catalogs
--   max_bytes number      Refuse a body larger than this (only when the body is kept in memory)
--   total_timeout boolean Stop a body that outlasts socketutil's total timeout (only when the body is kept in
--                         memory; a sink of your own decides for itself)
--   sink function         Called before every request, returns the sink for its body; a fresh one each time
--                         keeps the body of a redirect out of the destination. Without it, the body is kept in
--                         memory.
-- @return 1|nil, number|string, table|nil, string|nil, table Like socket.http.request: 1, status code,
-- headers (lower-cased names) and status line; or nil and the reason, which is an ErrorCodes value when the
-- request was refused. The last value is info: { url = the URL the last request went to, redirects = how many
-- were followed, body = the body when kept in memory }.
function HttpClient.request(request, options)
    options = options or {}
    local http = require("socket.http")
    local max_redirects = options.max_redirects or Constants.MAX_REDIRECTS
    local first_origin = RequestHeaders.originKey(request.url)
    local follows = request.source == nil and (request.method == nil or request.method == "GET"
        or request.method == "HEAD")
    local url = request.url
    local info = { url = url, redirects = 0 }
    local last_location

    while true do
        info.url = url
        local refusal = refusalFor(url, options, info.redirects > 0)
        if refusal then
            return nil, refusal, nil, nil, info
        end

        local sink, chunks
        if options.sink then
            local sink_error
            sink, sink_error = options.sink()
            if not sink then
                return nil, sink_error, nil, nil, info
            end
        else
            chunks = {}
            sink = memorySink(chunks, options)
        end

        local same_origin = RequestHeaders.originKey(url) == first_origin
        local hop = {}
        for key, value in pairs(request) do
            hop[key] = value
        end
        hop.url = url
        hop.redirect = false
        hop.sink = sink
        hop.headers = headersForHop(request, url, same_origin, options)
        if not same_origin then
            hop.user, hop.password = nil, nil
        end

        local ok, code, headers, status = http.request(hop)
        if not ok then
            return nil, code, nil, nil, info
        end
        info.body = chunks and table.concat(chunks) or nil

        local target
        if follows and info.redirects < max_redirects then
            target = redirectTarget(url, code, headers, options)
        end
        if not target then
            if info.redirects > 0 and last_location and headers then
                headers.location = headers.location or last_location
            end
            return 1, code, headers, status, info
        end
        last_location = headers.location
        info.redirects = info.redirects + 1
        url = target
    end
end

--- Fetch content from a URL
-- @param url string URL to fetch
-- @param timeout number|nil Connection timeout (default: Constants.TIMEOUTS.DEFAULT)
-- @param maxtime number|nil Maximum request time (default: Constants.TIMEOUTS.MAX_TIME)
-- @param username string|nil HTTP auth username
-- @param password string|nil HTTP auth password
-- @return Result Result object with content on success, error on failure
function HttpClient.fetch(url, timeout, maxtime, username, password)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local parsed = type(url) == "string" and socket_url.parse(url)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        return Result.err("Unsupported protocol", HttpClient.ErrorCodes.UNSUPPORTED_PROTOCOL)
    end

    if not timeout then timeout = Constants.TIMEOUTS.DEFAULT end

    socketutil:set_timeout(timeout, maxtime or Constants.TIMEOUTS.MAX_TIME)
    local code, headers, status, info = socket.skip(1, HttpClient.request({
        url      = url,
        method   = "GET",
        user     = username,
        password = password,
    }, { total_timeout = maxtime ~= nil }))
    socketutil:reset_timeout()
    local content = info.body or ""

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
