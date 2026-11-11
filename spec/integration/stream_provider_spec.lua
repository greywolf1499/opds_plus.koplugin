local helper = require("helper")
local json = require("dkjson")
local fake_http = require("support.fake_http")
local json_shims = require("support.json_shims")
local socketutil_stub = require("support.socketutil")

describe("Streaming progress provider contracts", function()
    local Provider, http, state
    local BASE = "https://library.example/proxy"
    local KAVITA = BASE .. "/api/opds/secret/image?chapterId=42&pageNumber={pageNumber}"
    local KOMGA = BASE .. "/opds/v1.2/books/book/pages/{pageNumber}"

    before_each(function()
        helper.reset()
        http = fake_http.new()
        state = { position = 3, completed = false, modified = "before", count = 10, writes = 0, token = "token" }
        Provider = helper.load("services.stream_provider", {
            ["socket.http"] = http, socketutil = socketutil_stub.new(), rapidjson = json_shims.rapidjson(),
        })
    end)
    after_each(helper.reset)

    local function create(kind)
        local stream = kind == "kavita" and KAVITA or KOMGA
        local root = BASE .. (kind == "kavita" and "/api/opds/secret" or "/opds/v1.2/")
        local created = Provider.new(stream, 10, root, "reader", "secret")
        assert.is_true(created.success)
        local provider = created.value
        local function write(request)
            state.writes = state.writes + 1
            state.body = json.decode(request.body)
            state.position = kind == "kavita" and state.body.pageNum or state.body.page
            state.completed = state.position == state.count
            state.modified = "after"
            if state.after_write then state.after_write() end
            if state.timeout then return { error = "timeout" } end
            return { code = kind == "kavita" and 200 or 204, body = "true" }
        end
        if kind == "kavita" then
            http:on(BASE .. "/api/Plugin/authenticate?apiKey=secret&pluginName=KOReader-OPDS",
                function() return { code = 200, body = json.encode({ token = state.token }) } end)
            http:on(BASE .. "/api/Reader/chapter-info?chapterId=42&extractPdf=true", function()
                return { code = 200, body = json.encode({
                    pages = state.count, volumeId = 5, seriesId = 6, libraryId = 7,
                }) }
            end)
            http:on(BASE .. "/api/Reader/get-progress?chapterId=42", function()
                return { code = 200, body = json.encode({
                    chapterId = 42, pageNum = state.position, lastModifiedUtc = state.modified,
                    bookScrollId = state.locator,
                }) }
            end)
            http:on(BASE .. "/api/Reader/progress", write)
        else
            http:on(BASE .. "/api/v1/books/book", function()
                return { code = 200, body = json.encode({
                    id = "book", media = { pagesCount = state.count },
                    readProgress = state.position and {
                        page = state.position, completed = state.completed, lastModified = state.modified,
                    } or json.null,
                }) }
            end)
            http:on(BASE .. "/api/v1/books/book/read-progress", write)
        end
        return provider
    end

    it("refuses unknown origins, foreign apps/accounts, unsafe identities and userinfo before HTTP", function()
        for _, case in ipairs({
            { KAVITA, BASE .. "/api/opds/other" },
            { KAVITA, "https://foreign.example/proxy/api/opds/secret" },
            { KAVITA, "http://library.example/proxy/api/opds/secret" },
            { KAVITA, "https://library.example:8443/proxy/api/opds/secret" },
            { KAVITA, "https://library.example/other/api/opds/secret" },
            { KOMGA, BASE .. "/another-app" },
            { KOMGA:gsub("/book/", "/%%2e%%2e/"), BASE .. "/opds/v1.2/" },
            { KOMGA:gsub("https://", "https://reader:secret@"), BASE .. "/opds/v1.2/" },
        }) do
            assert.is_false(Provider.new(case[1], 10, case[2]).success)
        end
        assert.is_false(Provider.new(KAVITA, 10, nil).success)
        assert.is_false(Provider.new(KAVITA, math.huge, BASE .. "/api/opds/secret").success)
        assert.same({}, http.requests)
    end)

    it("pulls provider positions and preserves completion without writing", function()
        for _, kind in ipairs({ "kavita", "komga" }) do
            http.routes = {}
            local provider = create(kind)
            state.position, state.completed = 3, false
            local result = provider:pull()
            assert.is_true(result.success)
            assert.equals(kind == "kavita" and 4 or 3, result.value.page)
            assert.is_false(result.value.completed)
            state.position, state.completed = 10, true
            result = provider:pull()
            assert.equals(10, result.value.page)
            assert.is_true(result.value.completed)
        end
        assert.equals(0, state.writes)
    end)

    it("represents an unread Komga book without inventing a read-progress record", function()
        local provider = create("komga")
        state.position = nil
        assert.same({ position = 0, page = 1, completed = false }, provider:pull().value)
        assert.equals(0, state.writes)
    end)

    it("writes exact parent IDs and honors rewinds using Kavita's cursor", function()
        local provider = create("kavita")
        require("services.http_client").setCatalogs({
            { url = BASE .. "/api/opds/secret", headers = {
                { name = "X-Access-Key", value = "gateway" },
                { name = "Authorization", value = "Bearer gateway" },
            } },
        })
        local baseline = provider:pull().value
        local result = provider:synchronize(baseline, 2)
        assert.is_true(result.success)
        assert.is_true(result.value.written)
        assert.is_nil(result.value.conflict)
        assert.same({ volumeId = 5, chapterId = 42, pageNum = 1, seriesId = 6, libraryId = 7 }, state.body)
        assert.equals(2, result.value.remote.page)
        for _, request in ipairs(http.requests) do
            assert.is_false(request.raw.redirect)
            assert.equals("reader", request.user)
            assert.equals("gateway", request.headers["X-Access-Key"])
            if request.url:find("/api/Reader/", 1, true) then
                assert.equals("Bearer token", request.headers.Authorization)
            end
        end
        result = provider:synchronize(result.value.remote, 10)
        assert.equals(10, state.body.pageNum)
        assert.is_true(result.value.remote.completed)
        result = provider:synchronize(result.value.remote, 1)
        assert.equals(0, state.body.pageNum)
        assert.is_false(result.value.remote.completed)
    end)

    it("uses Komga's 204 PATCH contract, including automatic final-page completion", function()
        local provider = create("komga")
        local baseline = provider:pull().value
        local result = provider:synchronize(baseline, 10)
        assert.is_true(result.success)
        assert.is_true(result.value.remote.completed)
        assert.same({ page = 10 }, state.body)
        assert.equals("PATCH", http.requests[3].method)
        result = provider:synchronize(result.value.remote, 1)
        assert.is_false(result.value.remote.completed)
        assert.same({ page = 1 }, state.body)
        for _, request in ipairs(http.requests) do assert.is_not.equals("DELETE", request.method) end
    end)

    it("returns fresh remote conflicts without overwriting concurrent changes", function()
        for _, kind in ipairs({ "kavita", "komga" }) do
            http.routes = {}
            local provider = create(kind)
            local baseline = provider:pull().value
            state.modified = "another-reader"
            local result = provider:synchronize(baseline, 8)
            assert.is_true(result.success)
            assert.is_true(result.value.conflict)
            assert.equals("another-reader", result.value.remote.modified)
            state.modified = "before"
        end
        assert.equals(0, state.writes)
    end)

    it("reconciles an applied-but-unacknowledged write without sending it twice", function()
        local provider = create("komga")
        local baseline = provider:pull().value
        state.timeout = true
        assert.is_false(provider:synchronize(baseline, 7).success)
        assert.equals(1, state.writes)
        state.timeout = false
        local result = provider:synchronize(baseline, 7)
        assert.is_true(result.success)
        assert.is_false(result.value.written)
        assert.equals(1, state.writes)
    end)

    it("detects a changed server position during post-write confirmation", function()
        local provider = create("komga")
        local baseline = provider:pull().value
        state.after_write = function() state.position = 2 end
        local result = provider:synchronize(baseline, 7)
        assert.is_true(result.success)
        assert.is_true(result.value.written)
        assert.is_true(result.value.conflict)
        assert.equals(2, result.value.remote.page)
        assert.equals(1, state.writes)
    end)

    it("refuses changed counts, malformed positions, document locators and invalid choices", function()
        local provider = create("kavita")
        state.count = 11
        assert.equals("COUNT_CHANGED", provider:pull().code)
        state.count, state.position = 10, 1.5
        assert.equals("INVALID", provider:pull().code)
        state.position, state.modified = 3, string.rep("x", 65)
        assert.equals("INVALID", provider:pull().code)
        state.modified = "before"
        state.position, state.locator = 3, "chapter-location"
        assert.equals("UNSUPPORTED", provider:pull().code)
        assert.equals("INVALID", provider:synchronize(nil, 11).code)
        assert.equals(0, state.writes)
    end)

    it("rejects malformed token headers without issuing a progress request", function()
        local provider = create("kavita")
        state.token = "token\r\nX-Test: value"
        assert.equals("INVALID", provider:pull().code)
        assert.equals(1, #http.requests)
        assert.is_false(require("logger").logged("warn", state.token))
    end)

    it("never follows progress redirects or forwards credentials to them", function()
        local provider = create("komga")
        http.routes = {}
        http:on(BASE .. "/api/v1/books/book", { code = 302, headers = { Location = "https://foreign.example/book" } })
        assert.equals(302, provider:pull().code)
        assert.equals(1, #http.requests)
        assert.equals(0, state.writes)
    end)

    it("refuses a redirected write without replaying it or acknowledging progress", function()
        local provider = create("komga")
        local baseline = provider:pull().value
        http.routes[#http.routes].response = { code = 307, headers = { Location = "https://foreign.example/progress" } }
        local result = provider:synchronize(baseline, 7)
        assert.is_false(result.success)
        assert.equals(307, result.code)
        assert.equals(3, #http.requests)
        assert.equals(BASE .. "/api/v1/books/book/read-progress", http.requests[3].url)
        assert.equals("PATCH", http.requests[3].method)
    end)
end)
