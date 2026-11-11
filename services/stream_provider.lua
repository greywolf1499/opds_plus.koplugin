local CatalogUtils = require("utils.catalog_utils")
local HttpClient = require("services.http_client")
local JsonDecode = require("utils.json_decode")
local RequestHeaders = require("utils.request_headers")
local Result = require("utils.result")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local _ = require("gettext")

local Provider = {}
Provider.__index = Provider

local function fail(message, code)
    logger.warn("OPDS+ stream progress:", message, code)
    return Result.err(message, code)
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function validModified(value)
    return value == nil or (type(value) == "string" and #value <= 64)
end

local function unsupported()
    return fail(_("Streaming progress synchronization is not supported for this catalog link."), "UNSUPPORTED")
end

function Provider.new(stream_url, count, catalog_url, username, password)
    local origin = RequestHeaders.originKey(catalog_url)
    if not origin or RequestHeaders.originKey(stream_url) ~= origin then return unsupported() end
    local stream, catalog = url.parse(stream_url), url.parse(catalog_url)
    if not stream or not catalog or stream.userinfo or catalog.userinfo
        or not integer(count, 1, 2147483647) then return unsupported() end
    if (username ~= nil and type(username) ~= "string") or (password ~= nil and type(password) ~= "string") then
        return fail(_("Invalid catalog credentials."), "INVALID")
    end
    local provider = CatalogUtils.parseKavitaStream(stream_url)
    if provider then
        local prefix, key = (catalog.path or ""):match("^(.-)/api/opds/([^/]+)")
        if not prefix or url.unescape(key) ~= url.unescape(provider.api_key)
            or provider.base ~= url.build { scheme = stream.scheme, authority = stream.authority, path = prefix }
            or not integer(tonumber(provider.chapter), 1, 2147483647) then return unsupported() end
        provider.kind = "kavita"
    else
        local prefix, book = (stream.path or ""):match("^(.-)/opds/v1%.2/books/([^/]+)/pages/{pageNumber}$")
        local root_prefix = (catalog.path or ""):match("^(.-)/opds/v1%.2/")
            or (catalog.path or ""):match("^(.-)/opds/v1%.2$")
        if not prefix or root_prefix ~= prefix or not url.unescape(book):match("^[%w_%-]+$") then
            return unsupported()
        end
        provider = {
            kind = "komga", book = url.unescape(book),
            base = url.build { scheme = stream.scheme, authority = stream.authority, path = prefix },
        }
    end
    provider.count, provider.origin = count, origin
    provider.username, provider.password = username, password
    return Result.ok(setmetatable(provider, Provider))
end

function Provider:request(method, endpoint, expected_code, body, token)
    local headers = { Accept = "application/json", ["Accept-Encoding"] = "identity", ["Cache-Control"] = "no-cache" }
    if token then headers.Authorization = "Bearer " .. token end
    if body then
        headers["Content-Type"], headers["Content-Length"] = "application/json", tostring(#body)
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local response = { HttpClient.request({
        url = self.base .. endpoint, method = method, headers = headers,
        user = self.username, password = self.password,
        source = body and ltn12.source.string(body) or nil,
    }, {
        basic_auth_origin = self.origin, max_redirects = 0, max_bytes = 1024 * 1024, total_timeout = true,
    }) }
    socketutil:reset_timeout()
    if not response[1] or response[2] ~= expected_code or not response[3] then
        return fail(_("Could not communicate with the server's reading-progress API."),
            type(response[2]) == "number" and response[2] or "NETWORK")
    end
    return Result.ok(response[5].body)
end

function Provider:authenticate()
    if self.kind ~= "kavita" then return Result.ok(nil) end
    local result = self:request("POST",
        "/api/Plugin/authenticate?apiKey=" .. self.api_key .. "&pluginName=KOReader-OPDS", 200)
    if not result.success then return result end
    local auth = JsonDecode.decode(result.value)
    if type(auth) ~= "table" or type(auth.token) ~= "string" or not auth.token:find("%S")
        or not RequestHeaders.validate("Authorization", "Bearer " .. auth.token) then
        return fail(_("The server returned an invalid progress authentication response."), "INVALID")
    end
    return Result.ok(auth.token)
end

local function invalid()
    return fail(_("The server returned invalid reading progress."), "INVALID")
end

local function changedCount()
    return fail(_("The page count changed. Refresh the catalog before synchronizing progress."), "COUNT_CHANGED")
end

function Provider:read(token)
    local snapshot
    if self.kind == "kavita" then
        local result = self:request("GET",
            "/api/Reader/chapter-info?chapterId=" .. self.chapter .. "&extractPdf=true", 200, nil, token)
        if not result.success then return result end
        local chapter = JsonDecode.decode(result.value)
        if type(chapter) ~= "table" or not integer(chapter.pages, 1, 2147483647) then return invalid() end
        if chapter.pages ~= self.count then return changedCount() end
        for __, field in ipairs({ "volumeId", "seriesId", "libraryId" }) do
            if not integer(chapter[field], 1, 2147483647) then return invalid() end
        end
        result = self:request("GET", "/api/Reader/get-progress?chapterId=" .. self.chapter, 200, nil, token)
        if not result.success then return result end
        local progress = JsonDecode.decode(result.value)
        if type(progress) ~= "table" or progress.chapterId ~= tonumber(self.chapter)
            or not integer(progress.pageNum, 0, self.count)
            or not validModified(progress.lastModifiedUtc) then
            return invalid()
        end
        if (progress.bookScrollId ~= nil and progress.bookScrollId ~= "")
            or (progress.koboSpan ~= nil and progress.koboSpan ~= "") then
            return fail(_("The server's document locator cannot be synchronized with a page stream."), "UNSUPPORTED")
        end
        snapshot = {
            position = progress.pageNum, page = math.min(progress.pageNum + 1, self.count),
            completed = progress.pageNum == self.count, modified = progress.lastModifiedUtc,
            volume = chapter.volumeId, series = chapter.seriesId, library = chapter.libraryId,
        }
    else
        local result = self:request("GET", "/api/v1/books/" .. self.book, 200)
        if not result.success then return result end
        local book = JsonDecode.decode(result.value)
        if type(book) ~= "table" or book.id ~= self.book or type(book.media) ~= "table"
            or not integer(book.media.pagesCount, 1, 2147483647) then return invalid() end
        if book.media.pagesCount ~= self.count then return changedCount() end
        local progress = book.readProgress
        if progress == nil then
            snapshot = { position = 0, page = 1, completed = false }
        else
            if type(progress) ~= "table" or not integer(progress.page, 0, self.count)
                or type(progress.completed) ~= "boolean"
                or not validModified(progress.lastModified) then
                return invalid()
            end
            snapshot = {
                position = progress.page, page = math.max(progress.page, 1),
                completed = progress.completed, modified = progress.lastModified,
            }
        end
    end
    return Result.ok(snapshot)
end

function Provider:pull()
    local auth = self:authenticate()
    if not auth.success then return auth end
    return self:read(auth.value)
end

function Provider.same(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.position == right.position and left.completed == right.completed and left.modified == right.modified
end

function Provider:target(page)
    return self.kind == "kavita" and page < self.count and page - 1 or page, page == self.count
end

-- A fresh preflight narrows, but cannot eliminate, these APIs' non-atomic GET-to-write race.
function Provider:synchronize(expected, page)
    if not integer(page, 1, self.count) then
        return fail(_("Invalid streaming progress position."), "INVALID")
    end
    local auth = self:authenticate()
    if not auth.success then return auth end
    local result = self:read(auth.value)
    if not result.success then return result end
    local remote = result.value
    local target, completed = self:target(page)
    if remote.position == target and remote.completed == completed then
        return Result.ok({ remote = remote, written = false })
    end
    if not Provider.same(expected, remote) then
        return Result.ok({ remote = remote, conflict = true })
    end
    if self.kind == "kavita" then
        local body = string.format('{"volumeId":%d,"chapterId":%d,"pageNum":%d,"seriesId":%d,"libraryId":%d}',
            remote.volume, tonumber(self.chapter), target, remote.series, remote.library)
        result = self:request("POST", "/api/Reader/progress", 200, body, auth.value)
        if result.success and JsonDecode.decode(result.value) ~= true then return invalid() end
    else
        result = self:request("PATCH", "/api/v1/books/" .. self.book .. "/read-progress", 204,
            string.format('{"page":%d}', target))
    end
    if not result.success then return result end
    result = self:read(auth.value)
    if not result.success then return result end
    remote = result.value
    return Result.ok({
        remote = remote, written = true,
        conflict = remote.position ~= target or remote.completed ~= completed or nil,
    })
end

return Provider
