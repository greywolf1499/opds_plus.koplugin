local helper = require("helper")
local fake_http = require("support.fake_http")
local socketutil_stub = require("support.socketutil")

describe("HttpClient", function()
	local HttpClient, http, socketutil
	local url = "https://example.org/opds"

	before_each(function()
		helper.reset()
		http = fake_http.new()
		socketutil = socketutil_stub.new()
		HttpClient = helper.load("services.http_client", {
			["socket.http"] = http,
			socketutil = socketutil,
			["ffi/sha2"] = require("support.sha256_stub"),
		})
	end)

	after_each(helper.reset)

	it("makes opaque cache identities while preserving canonical Basic origins", function()
		local key = HttpClient.cacheKey(url, "reader", "secret")
		assert.matches("^request%-v2:%x+$", key)
		assert.equals(key, HttpClient.cacheKey(url, "reader", "secret", "https://EXAMPLE.org:443/other"))
		assert.is_not.equals(key, HttpClient.cacheKey(url, "reader", "secret", false))
		assert.is_not.equals(HttpClient.cacheKey(url), HttpClient.cacheKey(url, ""))
	end)

	describe("fetch", function()
		it("returns the body of a successful response", function()
			http:on(url, { code = 200, body = "<feed/>" })

			local result = HttpClient.fetch(url)

			assert.is_true(result:isOk())
			assert.equals("<feed/>", result.value)
		end)

		it("sends a GET request with the credentials it was given", function()
			http:on(url, { code = 200, body = "" })

			HttpClient.fetch(url, nil, nil, "reader", "s3cret")

			assert.equals(1, #http.requests)
			assert.equals("GET", http.requests[1].method)
			assert.equals("reader", http.requests[1].user)
			assert.equals("s3cret", http.requests[1].password)
		end)

		it("sets the timeouts for the request and resets them afterwards", function()
			local seen
			http:on(url, function()
				seen = { block = socketutil.block_timeout, total = socketutil.total_timeout }
				return { code = 200, body = "" }
			end)

			HttpClient.fetch(url, 7, 21)

			assert.same({ block = 7, total = 21 }, seen)
			assert.equals(socketutil.DEFAULT_BLOCK_TIMEOUT, socketutil.block_timeout)
			assert.equals(socketutil.DEFAULT_TOTAL_TIMEOUT, socketutil.total_timeout)
		end)

		it("rejects URLs that are not http or https without sending anything", function()
			local invalid = { n = 7, nil, "", "http:", "http://", "ftp://example.org/feed", "file:///etc/passwd", "example.org/feed" }
			for index = 1, invalid.n do
				local result = HttpClient.fetch(invalid[index])

				assert.is_true(result:isErr())
				assert.equals(HttpClient.ErrorCodes.UNSUPPORTED_PROTOCOL, result.code)
			end
			assert.equals(0, #http.requests)
		end)

		it("maps socket timeouts to TIMEOUT", function()
			for _, code in ipairs({ "timeout", "wantread", "sink timeout" }) do
				http.routes = {}
				http:on(url, { error = code })

				local result = HttpClient.fetch(url)

				assert.equals(HttpClient.ErrorCodes.TIMEOUT, result.code)
				assert.equals(code, result.error)
			end
		end)

		it("maps an unreachable server to NETWORK_ERROR", function()
			local result = HttpClient.fetch(url)

			assert.equals(HttpClient.ErrorCodes.NETWORK_ERROR, result.code)
		end)

		it("maps 401 to AUTH_REQUIRED and 403 to AUTH_FAILED", function()
			http:on(url .. "/401", { code = 401 })
			http:on(url .. "/403", { code = 403 })

			assert.equals(HttpClient.ErrorCodes.AUTH_REQUIRED, HttpClient.fetch(url .. "/401").code)
			assert.equals(HttpClient.ErrorCodes.AUTH_FAILED, HttpClient.fetch(url .. "/403").code)
		end)

		it("maps other statuses outside 2xx to SERVER_ERROR", function()
			for _, code in ipairs({ 199, 300, 304, 404, 500, 503 }) do
				http.routes = {}
				http:on(url, { code = code })

				assert.equals(HttpClient.ErrorCodes.SERVER_ERROR, HttpClient.fetch(url).code, "status " .. code)
			end
		end)

		it("accepts the whole 2xx range", function()
			for _, code in ipairs({ 200, 201, 299 }) do
				http.routes = {}
				http:on(url, { code = code, body = "x" })

				assert.is_true(HttpClient.fetch(url):isOk(), "status " .. code)
			end
		end)

		it("detects a body shorter than its Content-Length", function()
			http:on(url, { code = 200, body = "12345", headers = { ["Content-Length"] = "10" } })

			local result = HttpClient.fetch(url)

			assert.equals(HttpClient.ErrorCodes.INCOMPLETE_CONTENT, result.code)
		end)

		it("accepts a body that matches its Content-Length", function()
			http:on(url, { code = 200, body = "12345", headers = { ["Content-Length"] = "5" } })

			assert.equals("12345", HttpClient.fetch(url).value)
		end)

		it("reports a body that arrives after the total time allowed as a timeout", function()
			local now = 1000
			helper.stub("socketutil", socketutil_stub.new({ time = function() return now end }))
			http:on(url, function()
				now = now + 100
				return { code = 200, body = "late" }
			end)

			local result = HttpClient.fetch(url, 5, 15)

			assert.equals(HttpClient.ErrorCodes.TIMEOUT, result.code)
			assert.equals("sink timeout", result.error)
		end)

		it("does not cut off a slow body when no total time is asked for", function()
			local now = 1000
			helper.stub("socketutil", socketutil_stub.new({ time = function() return now end }))
			http:on(url, function()
				now = now + 100
				return { code = 200, body = "slow" }
			end)

			assert.equals("slow", HttpClient.fetch(url, 5).value)
		end)

		describe("when redirected", function()
			local MIRROR = "https://cdn.example.net/cover.jpg"

			it("returns the body of the address the redirect leads to", function()
				http:on(url, { code = 302, headers = { Location = MIRROR }, body = "<html>moved</html>" })
				http:on(MIRROR, { code = 200, body = "JPEG" })

				local result = HttpClient.fetch(url)

				assert.is_true(result:isOk())
				assert.equals("JPEG", result.value)
			end)

			it("follows a permanent redirect (308), which LuaSocket leaves alone", function()
				http:on(url, { code = 308, headers = { Location = MIRROR } })
				http:on(MIRROR, { code = 200, body = "JPEG" })

				assert.equals("JPEG", HttpClient.fetch(url).value)
			end)

			it("sends the credentials again when the redirect stays on the same server", function()
				http:on(url, { code = 301, headers = { Location = "/opds/cover/1" } })
				http:on("https://example.org/opds/cover/1", { code = 200, body = "JPEG" })

				HttpClient.fetch(url, nil, nil, "reader", "s3cret")

				assert.equals("reader", http.requests[2].user)
				assert.equals("s3cret", http.requests[2].password)
			end)

			it("keeps the credentials and the custom headers of a catalog away from another server", function()
				HttpClient.setCatalogs({ { url = url, headers = { { name = "X-Api-Key", value = "abc" } } } })
				http:on(url, { code = 302, headers = { Location = MIRROR } })
				http:on(MIRROR, { code = 200, body = "JPEG" })

				HttpClient.fetch(url, nil, nil, "reader", "s3cret")

				assert.equals("abc", http.requests[1].headers["X-Api-Key"])
				assert.equals("reader", http.requests[1].user)
				assert.is_nil(http.requests[2].headers["X-Api-Key"])
				assert.is_nil(http.requests[2].user)
				assert.is_nil(http.requests[2].password)
			end)

			it("checks the length of what the redirect led to, not of the redirect", function()
				http:on(url, {
					code = 302,
					headers = { Location = MIRROR, ["Content-Length"] = "18" },
					body = "<html>moved</html>",
				})
				http:on(MIRROR, { code = 200, body = "JPEG", headers = { ["Content-Length"] = "4" } })

				assert.equals("JPEG", HttpClient.fetch(url).value)
			end)

			it("maps what the address the redirect leads to answers", function()
				http:on(url, { code = 302, headers = { Location = MIRROR } })
				http:on(MIRROR, { code = 401 })

				assert.equals(HttpClient.ErrorCodes.AUTH_REQUIRED, HttpClient.fetch(url).code)
			end)

			it("reports a redirect that never ends as a server error", function()
				http:on(url, { code = 302, headers = { Location = url } })

				assert.equals(HttpClient.ErrorCodes.SERVER_ERROR, HttpClient.fetch(url).code)
				assert.equals(6, #http.requests)
			end)
		end)
	end)

	describe("custom headers", function()
		it("sends the headers of the catalog on the same origin", function()
			HttpClient.setCatalogs({
				{ url = "https://example.org/opds", headers = { { name = "CF-Access-Client-Id", value = "abc" } } },
			})
			http:on(url, { code = 200, body = "" })

			HttpClient.fetch(url)

			assert.equals("abc", http.requests[1].headers["CF-Access-Client-Id"])
		end)

		it("does not send them to another origin", function()
			HttpClient.setCatalogs({
				{ url = "https://example.org/opds", headers = { { name = "X-Token", value = "t" } } },
			})
			http:on("https://other.example/opds", { code = 200, body = "" })
			http:on("http://example.org/opds", { code = 200, body = "" })
			http:on("https://example.org:8443/opds", { code = 200, body = "" })

			HttpClient.fetch("https://other.example/opds")
			HttpClient.fetch("http://example.org/opds")
			HttpClient.fetch("https://example.org:8443/opds")

			for _, request in ipairs(http.requests) do
				assert.is_nil(request.headers["X-Token"], request.url)
			end
		end)

		it("reads the catalog list on every request, so edits take effect", function()
			local catalogs = { { url = "https://example.org/opds" } }
			HttpClient.setCatalogs(catalogs)
			http:on(url, { code = 200, body = "" })

			HttpClient.fetch(url)
			catalogs[1].headers = { { name = "X-Token", value = "late" } }
			HttpClient.fetch(url)

			assert.is_nil(http.requests[1].headers["X-Token"])
			assert.equals("late", http.requests[2].headers["X-Token"])
		end)

		it("sends no custom headers when no catalog is registered", function()
			http:on(url, { code = 200, body = "" })

			HttpClient.fetch(url)

			assert.same({}, http.requests[1].headers)
		end)

		it("keeps headers the request sets itself ahead of custom ones", function()
			HttpClient.setCatalogs({
				{ url = url, headers = { { name = "accept", value = "text/plain" }, { name = "X-Other", value = "1" } } },
			})

			local headers = HttpClient.withCustomHeaders(url, { Accept = "application/atom+xml" })

			assert.same({ Accept = "application/atom+xml", ["X-Other"] = "1" }, headers)
		end)
	end)

	describe("as a function (legacy interface)", function()
		it("returns true and the body on success", function()
			http:on(url, { code = 200, body = "ok" })

			local success, body = HttpClient(url)

			assert.is_true(success)
			assert.equals("ok", body)
		end)

		it("returns false and the message on failure", function()
			http:on(url, { code = 401 })

			local success, message = HttpClient.getUrlContent(url)

			assert.is_false(success)
			assert.equals("Authentication required (401)", message)
		end)
	end)
end)
