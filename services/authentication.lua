local Document = require("utils.auth_document")
local HttpClient = require("services.http_client")
local RequestHeaders = require("utils.request_headers")
local TlsHostname = require("services.tls_hostname")
local logger = require("logger")
local socketutil = require("socketutil")
local url = require("socket.url")
local _ = require("gettext")

local Authentication = { CA_FILE = "data/ca-bundle.crt" }

-- Discovery is public, read-only and never authorizes advertised login/token endpoints.
function Authentication.fetch(address, source)
    local parsed = type(address) == "string" and url.parse(address)
    if not parsed or parsed.scheme ~= "https" or parsed.userinfo
        or address:find("[%z\1-\32\127]") or address:find("\\", 1, true)
        or not RequestHeaders.originKey(source)
        or RequestHeaders.originKey(address) ~= RequestHeaders.originKey(source) then
        logger.warn("OPDS: refusing unscoped authentication discovery")
        return nil, _("The authentication document must use HTTPS on the catalog's own server. No request was sent.")
    end
    if require("libs/libkoreader-lfs").attributes(Authentication.CA_FILE, "mode") ~= "file" then
        logger.warn("OPDS: authentication discovery has no CA bundle")
        return nil, _("The certificate trust bundle is unavailable. Authentication discovery was not attempted.")
    end
    local request = TlsHostname.options(Authentication.CA_FILE)
    request.url, request.method = address, "GET"
    request.headers = { Accept = Document.TYPE, ["Accept-Encoding"] = "identity" }
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers, __, info = HttpClient.request(request, {
        https_only = true, basic_auth_origin = false, custom_headers = false, max_redirects = 0,
        max_bytes = Document.MAX_BYTES, total_timeout = true,
    })
    socketutil:reset_timeout()
    if not ok or code ~= 200 or not headers then
        logger.warn("OPDS: authentication discovery request failed")
        return nil, _("Could not securely load the authentication document. Check its address and certificate.")
    end
    local document, recognized, err = Document.parse(info.body, headers["content-type"])
    if not recognized or not document then
        logger.warn("OPDS: invalid authentication discovery response")
        return nil, err or _("The linked resource is not an OPDS authentication document.")
    end
    return document
end

return Authentication
