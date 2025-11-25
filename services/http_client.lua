-- Utility to fetch content from URLs
local logger = require("logger")
local Constants = require("models.constants")

local function getUrlContent(url, timeout, maxtime, username, password)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local parsed = socket_url.parse(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return false, "Unsupported protocol"
    end
    if not timeout then timeout = Constants.TIMEOUTS.DEFAULT end

    local sink = {}
    socketutil:set_timeout(timeout, maxtime or Constants.TIMEOUTS.MAX_TIME)
    local request = {
        url      = url,
        method   = "GET",
        sink     = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
        user     = username, -- Add username
        password = password, -- Add password
    }

    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)

    if code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    then
        logger.warn("request interrupted:", code)
        return false, code
    end
    if headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return false, "Network or remote server unavailable"
    end
    if not code or code < Constants.HTTP_SUCCESS_MIN or code > Constants.HTTP_SUCCESS_MAX then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        if code == Constants.HTTP_STATUS.UNAUTHORIZED then
            return false, "Authentication required (401)"
        elseif code == Constants.HTTP_STATUS.FORBIDDEN then
            return false, "Authentication failed (403)"
        end
        return false, "Remote server error or unavailable"
    end
    if headers and headers["content-length"] then
        local content_length = tonumber(headers["content-length"])
        if #content ~= content_length then
            return false, "Incomplete content received"
        end
    end

    return true, content
end

return getUrlContent
