local helper = require("helper")
local fake_http = require("support.fake_http")
local socketutil_stub = require("support.socketutil")
local ltn12 = require("ltn12")

describe("HttpClient.request", function()
	local HttpClient, http, socketutil

	local function redirect(code, location)
		return { code = code, headers = { Location = location }, body = "moved" }
	end

	local function urls()
		local seen = {}
		for _, request in ipairs(http.requests) do
			seen[#seen + 1] = request.url
		end
		return seen
	end

	before_each(function()
		helper.reset()
		http = fake_http.new()
		socketutil = socketutil_stub.new()
		HttpClient = helper.load("services.http_client", {
			["socket.http"] = http,
			socketutil = socketutil,
		})
	end)

	after_each(helper.reset)

	describe("a request without redirects", function()
		it("returns what LuaSocket does, plus the body and the URL it ended at", function()
			http:on("https://a.example/feed", {
				code = 200, body = "<feed/>", headers = { ETag = '"1"' }, status = "HTTP/1.1 200 OK",
			})

			local ok, code, headers, status, info = HttpClient.request({ url = "https://a.example/feed" })

			assert.equals(1, ok)
			assert.equals(200, code)
			assert.equals('"1"', headers.etag)
			assert.equals("HTTP/1.1 200 OK", status)
			assert.equals("<feed/>", info.body)
			assert.equals("https://a.example/feed", info.url)
			assert.equals(0, info.redirects)
		end)

		it("returns nil and the reason when the transport fails", function()
			http:on("https://a.example/feed", { error = "timeout" })

			local ok, err, _, _, info = HttpClient.request({ url = "https://a.example/feed" })

			assert.is_nil(ok)
			assert.equals("timeout", err)
			assert.equals("https://a.example/feed", info.url)
		end)

		it("hands error statuses back like any other response", function()
			http:on("https://a.example/feed", { code = 404, body = "gone" })

			local ok, code = HttpClient.request({ url = "https://a.example/feed" })

			assert.equals(1, ok)
			assert.equals(404, code)
		end)

		it("leaves the request it was given alone", function()
			http:on("https://a.example/start", redirect(302, "https://b.example/end"))
			http:on("https://b.example/end", { code = 200 })
			local request = { url = "https://a.example/start", headers = { Accept = "text/xml" } }

			HttpClient.request(request)

			assert.equals("https://a.example/start", request.url)
			assert.same({ Accept = "text/xml" }, request.headers)
			assert.is_nil(request.sink)
		end)

		it("refuses a URL that is not http or https without sending anything", function()
			for _, bad in ipairs({ "ftp://a.example/feed", "file:///etc/passwd", "a.example/feed" }) do
				local ok, err = HttpClient.request({ url = bad })

				assert.is_nil(ok)
				assert.equals(HttpClient.ErrorCodes.UNSUPPORTED_PROTOCOL, err)
			end
			assert.equals(0, #http.requests)
		end)
	end)

	describe("following redirects", function()
		it("follows 301, 302, 303, 307 and 308", function()
			for _, status in ipairs({ 301, 302, 303, 307, 308 }) do
				http.routes, http.requests = {}, {}
				http:on("https://a.example/old", redirect(status, "https://a.example/new"))
				http:on("https://a.example/new", { code = 200, body = "new" })

				local ok, code, _, _, info = HttpClient.request({ url = "https://a.example/old" })

				assert.equals(1, ok, status)
				assert.equals(200, code, status)
				assert.equals("new", info.body, status)
				assert.same({ "https://a.example/old", "https://a.example/new" }, urls())
			end
		end)

		it("resolves a relative Location against the URL it came from", function()
			http:on("https://a.example/opds", redirect(301, "/opds/"))
			http:on("https://a.example/opds/", redirect(302, "all"))
			http:on("https://a.example/opds/all", redirect(302, "//b.example/feed"))
			http:on("https://b.example/feed", { code = 200 })

			local _, code, _, _, info = HttpClient.request({ url = "https://a.example/opds" })

			assert.equals(200, code)
			assert.equals(3, info.redirects)
			assert.equals("https://b.example/feed", info.url)
		end)

		it("encodes spaces in a Location, which servers send unescaped now and then", function()
			http:on("https://a.example/start", redirect(302, "/my books/a b.epub"))
			http:on("https://a.example/my%20books/a%20b.epub", { code = 200, body = "book" })

			local _, code = HttpClient.request({ url = "https://a.example/start" })

			assert.equals(200, code)
		end)

		it("stops after five redirects, like LuaSocket, and returns the last one as received", function()
			http:on(function() return true end, redirect(302, "/again"))

			local ok, code, headers, _, info = HttpClient.request({ url = "https://a.example/start" })

			assert.equals(1, ok)
			assert.equals(302, code)
			assert.equals("/again", headers.location)
			assert.equals(6, #http.requests)
			assert.equals(5, info.redirects)
		end)

		it("honours a lower limit", function()
			http:on(function() return true end, redirect(302, "/again"))

			HttpClient.request({ url = "https://a.example/start" }, { max_redirects = 1 })

			assert.equals(2, #http.requests)
		end)

		it("hands a redirect without a usable Location back as it is", function()
			for _, headers in ipairs({ {}, { Location = "" }, { Location = "   " } }) do
				http.routes, http.requests = {}, {}
				http:on("https://a.example/start", { code = 302, headers = headers })

				local _, code = HttpClient.request({ url = "https://a.example/start" })

				assert.equals(302, code)
				assert.equals(1, #http.requests)
			end
		end)

		it("does not follow the statuses that only look like redirects", function()
			for _, status in ipairs({ 300, 304, 305 }) do
				http.routes, http.requests = {}, {}
				http:on("https://a.example/start", redirect(status, "/elsewhere"))

				local _, code = HttpClient.request({ url = "https://a.example/start" })

				assert.equals(status, code)
				assert.equals(1, #http.requests)
			end
		end)

		it("follows redirects of HEAD but not of other methods", function()
			http:on("https://a.example/start", redirect(302, "/end"))
			http:on("https://a.example/end", { code = 200 })

			local _, head_code = HttpClient.request({ url = "https://a.example/start", method = "HEAD" })
			http.requests = {}
			local _, post_code = HttpClient.request({ url = "https://a.example/start", method = "POST" })

			assert.equals(200, head_code)
			assert.equals(302, post_code)
			assert.equals(1, #http.requests)
		end)

		it("leaves redirects to other schemes than http and https alone", function()
			http:on("https://a.example/start", redirect(302, "ftp://a.example/file"))

			local _, code, headers = HttpClient.request({ url = "https://a.example/start" })

			assert.equals(302, code)
			assert.equals("ftp://a.example/file", headers.location)
			assert.equals(1, #http.requests)
		end)

		it("passes the Location of the last redirect on as a hint, which download names are taken from", function()
			http:on("https://a.example/start", redirect(302, "/files/book.epub"))
			http:on("https://a.example/files/book.epub", { code = 200 })
			http:on("https://a.example/own", { code = 200, headers = { Location = "/own-location" } })

			local _, _, hinted = HttpClient.request({ url = "https://a.example/start" })
			local _, _, own = HttpClient.request({ url = "https://a.example/own" })

			assert.equals("/files/book.epub", hinted.location)
			assert.equals("/own-location", own.location)
		end)

		it("never lets LuaSocket follow a redirect itself", function()
			http:on("https://a.example/start", redirect(302, "/end"))
			http:on("https://a.example/end", { code = 200 })

			HttpClient.request({ url = "https://a.example/start" })

			assert.is_false(http.requests[1].raw.redirect)
			assert.is_false(http.requests[2].raw.redirect)
		end)

		it("keeps the method and every other option, TLS settings included, on every hop", function()
			http:on("https://a.example/start", redirect(302, "https://b.example/end"))
			http:on("https://b.example/end", { code = 200 })

			HttpClient.request({
				url = "https://a.example/start",
				method = "HEAD",
				verify = "peer",
				cafile = "/data/ca-bundle.crt",
				protocol = "any",
			})

			for hop = 1, 2 do
				local raw = http.requests[hop].raw
				assert.equals("HEAD", raw.method)
				assert.equals("peer", raw.verify)
				assert.equals("/data/ca-bundle.crt", raw.cafile)
				assert.equals("any", raw.protocol)
			end
		end)

		it("returns what the failing hop says when a later request fails", function()
			http:on("https://a.example/start", redirect(302, "https://b.example/end"))
			http:on("https://b.example/end", { error = "closed" })

			local ok, err, _, _, info = HttpClient.request({ url = "https://a.example/start" })

			assert.is_nil(ok)
			assert.equals("closed", err)
			assert.equals("https://b.example/end", info.url)
			assert.equals(1, info.redirects)
		end)
	end)

	describe("credentials", function()
		it("scopes the first request to the supplied catalog origin, not its target", function()
			for _, target in ipairs({
				"https://b.example/book", "https://a.example:8443/book", "http://a.example/book",
			}) do
				http:on(target, { code = 200 })
				HttpClient.request({ url = target, user = "reader", password = "secret" },
					{ basic_auth_origin = "https://a.example/opds" })
				local request = http.requests[#http.requests]
				assert.is_nil(request.user, target)
				assert.is_nil(request.password, target)
			end
			http:on("https://a.example/book", { code = 200 })
			HttpClient.request({ url = "https://a.example/book", user = "reader", password = "secret" },
				{ basic_auth_origin = "https://A.Example:443/opds?key=example" })
			assert.equals("reader", http.requests[4].user)
			assert.equals("secret", http.requests[4].password)
			HttpClient.request({ url = "https://a.example/book", user = "reader", password = "secret" },
				{ basic_auth_origin = false })
			assert.is_nil(http.requests[5].user)
			assert.is_nil(http.requests[5].password)
		end)

		it("keeps Basic provenance separate from provider tokens and destination headers on every hop", function()
			HttpClient.setCatalogs({
				{ url = "https://b.example/opds", headers = { { name = "X-Access", value = "destination" } } },
			})
			http:on("https://b.example/book", redirect(302, "https://a.example/book"))
			http:on("https://a.example/book", redirect(302, "https://c.example/book"))
			http:on("https://c.example/book", { code = 200 })
			HttpClient.request({
				url = "https://b.example/book", user = "reader", password = "secret",
				headers = { Authorization = "Bearer provider" },
			}, { basic_auth_origin = "https://a.example/opds" })
			assert.is_nil(http.requests[1].user)
			assert.equals("Bearer provider", http.requests[1].headers.Authorization)
			assert.equals("destination", http.requests[1].headers["X-Access"])
			assert.equals("reader", http.requests[2].user)
			assert.is_nil(http.requests[2].headers.Authorization)
			assert.is_nil(http.requests[2].headers["X-Access"])
			assert.is_nil(http.requests[3].user)
			assert.is_nil(http.requests[3].password)
			assert.is_nil(http.requests[3].headers.Authorization)
		end)

		it("sends Basic credentials again when the redirect stays on the same origin", function()
			http:on("https://a.example/opds", redirect(301, "/opds/"))
			http:on("https://a.example/opds/", { code = 200 })

			HttpClient.request({ url = "https://a.example/opds", user = "reader", password = "secret" })

			assert.equals("reader", http.requests[2].user)
			assert.equals("secret", http.requests[2].password)
		end)

		it("sends them to no other origin: other host, other port or other scheme", function()
			for _, hop in ipairs({
				{ "https://a.example/opds", "https://b.example/opds" },
				{ "https://a.example/opds", "https://a.example:8443/opds" },
				{ "http://a.example/opds", "https://a.example/opds" },
			}) do
				local from, to = hop[1], hop[2]
				http.routes, http.requests = {}, {}
				http:on(from, redirect(302, to))
				http:on(to, { code = 200 })

				HttpClient.request({ url = from, user = "reader", password = "secret" })

				assert.equals("reader", http.requests[1].user, to)
				assert.is_nil(http.requests[2].user, to)
				assert.is_nil(http.requests[2].password, to)
			end
		end)

		it("keeps Authorization, Cookie and Proxy-Authorization headers to the origin they were set for", function()
			http:on("https://a.example/start", redirect(302, "https://b.example/end"))
			http:on("https://b.example/end", { code = 200 })

			HttpClient.request({
				url = "https://a.example/start",
				headers = {
					Authorization = "Bearer token",
					cookie = "session=1",
					["PROXY-AUTHORIZATION"] = "Basic abc",
					Accept = "application/atom+xml",
					["User-Agent"] = "OPDSPlus",
				},
			})

			local first, second = http.requests[1].headers, http.requests[2].headers
			assert.equals("Bearer token", first.Authorization)
			assert.equals("session=1", first.cookie)
			assert.is_nil(second.Authorization)
			assert.is_nil(second.cookie)
			assert.is_nil(second["PROXY-AUTHORIZATION"])
			assert.equals("application/atom+xml", second.Accept)
			assert.equals("OPDSPlus", second["User-Agent"])
		end)

		it("keeps those headers on a redirect within the same origin", function()
			http:on("https://a.example/start", redirect(302, "/end"))
			http:on("https://a.example/end", { code = 200 })

			HttpClient.request({ url = "https://a.example/start", headers = { Authorization = "Bearer token" } })

			assert.equals("Bearer token", http.requests[2].headers.Authorization)
		end)
	end)

	describe("custom headers", function()
		local function catalog(url, name, value)
			return { url = url, headers = { { name = name, value = value } } }
		end

		it("sends the custom headers of a catalog to its own origin, on every hop there", function()
			HttpClient.setCatalogs({ catalog("https://a.example/opds", "X-Api-Key", "key-a") })
			http:on("https://a.example/opds", redirect(301, "/opds/"))
			http:on("https://a.example/opds/", { code = 200 })

			HttpClient.request({ url = "https://a.example/opds" })

			assert.equals("key-a", http.requests[1].headers["X-Api-Key"])
			assert.equals("key-a", http.requests[2].headers["X-Api-Key"])
		end)

		it("does not send them to the origin a redirect leads to", function()
			HttpClient.setCatalogs({ catalog("https://a.example/opds", "X-Api-Key", "key-a") })
			http:on("https://a.example/opds", redirect(302, "https://tracker.example/hop"))
			http:on("https://tracker.example/hop", { code = 200 })

			HttpClient.request({ url = "https://a.example/opds" })

			assert.equals("key-a", http.requests[1].headers["X-Api-Key"])
			assert.is_nil(http.requests[2].headers and http.requests[2].headers["X-Api-Key"])
		end)

		it("sends the custom headers of another catalog to that catalog, and only to it", function()
			HttpClient.setCatalogs({
				catalog("https://a.example/opds", "X-Api-Key", "key-a"),
				catalog("https://b.example/opds", "X-Api-Key", "key-b"),
			})
			http:on("https://a.example/opds", redirect(302, "https://b.example/opds"))
			http:on("https://b.example/opds", { code = 200 })

			HttpClient.request({ url = "https://a.example/opds" })

			assert.equals("key-a", http.requests[1].headers["X-Api-Key"])
			assert.equals("key-b", http.requests[2].headers["X-Api-Key"])
		end)

		it("sends none when told not to", function()
			HttpClient.setCatalogs({ catalog("https://a.example/opds", "X-Api-Key", "key-a") })
			http:on("https://a.example/opds", { code = 200 })

			HttpClient.request({ url = "https://a.example/opds" }, { custom_headers = false })

			assert.is_nil(http.requests[1].headers["X-Api-Key"])
		end)
	end)

	describe("the https policy", function()
		it("does not follow a redirect from https to http, and hands the redirect back for the caller to explain", function()
			http:on("https://a.example/start", redirect(302, "http://a.example/end"))
			http:on("http://a.example/end", { code = 200 })

			local ok, code, headers = HttpClient.request({ url = "https://a.example/start" })

			assert.equals(1, ok)
			assert.equals(302, code)
			assert.equals("http://a.example/end", headers.location)
			assert.same({ "https://a.example/start" }, urls())
		end)

		it("follows a redirect from http to https", function()
			http:on("http://a.example/start", redirect(301, "https://a.example/start"))
			http:on("https://a.example/start", { code = 200 })

			local _, code = HttpClient.request({ url = "http://a.example/start" })

			assert.equals(200, code)
		end)

		it("with https_only, refuses an http URL before sending anything", function()
			local ok, err = HttpClient.request({ url = "http://a.example/start" }, { https_only = true })

			assert.is_nil(ok)
			assert.equals(HttpClient.ErrorCodes.UNSUPPORTED_PROTOCOL, err)
			assert.equals(0, #http.requests)
		end)

		it("with https_only, refuses a redirect to http instead of handing it back", function()
			http:on("https://a.example/start", redirect(302, "http://a.example/end"))

			local ok, err, _, _, info = HttpClient.request({ url = "https://a.example/start" }, { https_only = true })

			assert.is_nil(ok)
			assert.equals(HttpClient.ErrorCodes.INSECURE_REDIRECT, err)
			assert.equals("http://a.example/end", info.url)
			assert.equals(1, #http.requests)
		end)
	end)

	describe("the host policy", function()
		local function only_a(host)
			return host == "a.example"
		end

		it("refuses a first URL on a host that is not allowed, before sending anything", function()
			local ok, err = HttpClient.request({ url = "https://b.example/start" }, { allow_host = only_a })

			assert.is_nil(ok)
			assert.equals(HttpClient.ErrorCodes.HOST_NOT_ALLOWED, err)
			assert.equals(0, #http.requests)
		end)

		it("refuses a redirect to a host that is not allowed, without sending that request", function()
			http:on("https://a.example/start", redirect(302, "https://evil.example/end"))
			http:on("https://evil.example/end", { code = 200 })

			local ok, err, _, _, info = HttpClient.request({ url = "https://a.example/start" }, { allow_host = only_a })

			assert.is_nil(ok)
			assert.equals(HttpClient.ErrorCodes.HOST_NOT_ALLOWED, err)
			assert.equals("https://evil.example/end", info.url)
			assert.same({ "https://a.example/start" }, urls())
		end)

		it("hands the host to the check lower-cased and without the port", function()
			local seen = {}
			http:on("https://A.Example:8443/start", { code = 200 })

			HttpClient.request({ url = "https://A.Example:8443/start" }, {
				allow_host = function(host)
					seen[#seen + 1] = host
					return true
				end,
			})

			assert.same({ "a.example" }, seen)
		end)
	end)

	describe("the body", function()
		it("keeps the body of the last response only", function()
			http:on("https://a.example/start", redirect(302, "/end"))
			http:on("https://a.example/end", { code = 200, body = "<feed/>" })

			local _, _, _, _, info = HttpClient.request({ url = "https://a.example/start" })

			assert.equals("<feed/>", info.body)
		end)

		it("gives up on a body over max_bytes", function()
			http:on("https://a.example/big", { code = 200, body = string.rep("x", 20) })

			local ok, err = HttpClient.request({ url = "https://a.example/big" }, { max_bytes = 10 })

			assert.is_nil(ok)
			assert.equals(HttpClient.ErrorCodes.TOO_LARGE, err)
		end)

		it("accepts a body of exactly max_bytes", function()
			http:on("https://a.example/big", { code = 200, body = string.rep("x", 10) })

			local ok, code = HttpClient.request({ url = "https://a.example/big" }, { max_bytes = 10 })

			assert.equals(1, ok)
			assert.equals(200, code)
		end)

		it("asks for a new sink on every hop, so a redirect body never reaches the final destination", function()
			http:on("https://a.example/start", redirect(302, "/end"))
			http:on("https://a.example/end", { code = 200, body = "payload" })
			local bodies = {}

			local _, _, _, _, info = HttpClient.request({ url = "https://a.example/start" }, {
				sink = function()
					local chunks = {}
					bodies[#bodies + 1] = chunks
					return ltn12.sink.table(chunks)
				end,
			})

			assert.equals(2, #bodies)
			assert.equals("moved", table.concat(bodies[1]))
			assert.equals("payload", table.concat(bodies[2]))
			assert.is_nil(info.body)
		end)

		it("returns the reason, without a request, when a sink cannot be made", function()
			local ok, err = HttpClient.request({ url = "https://a.example/start" }, {
				sink = function()
					return nil, "disk full"
				end,
			})

			assert.is_nil(ok)
			assert.equals("disk full", err)
			assert.equals(0, #http.requests)
		end)
	end)

	describe("the total timeout", function()
		local now

		before_each(function()
			helper.reset()
			now = 1000
			socketutil = socketutil_stub.new({ time = function() return now end })
			HttpClient = helper.load("services.http_client", {
				["socket.http"] = http,
				socketutil = socketutil,
			})
			socketutil:set_timeout(5, 10)
			http:on("https://a.example/slow", function()
				now = now + 11
				return { code = 200, body = "late" }
			end)
		end)

		it("stops a body that takes longer when asked to", function()
			local ok, err = HttpClient.request({ url = "https://a.example/slow" }, { total_timeout = true })

			assert.is_nil(ok)
			assert.equals("sink timeout", err)
		end)

		it("leaves it alone otherwise, like the sink KOReader's own catalog browser uses", function()
			local ok, code, _, _, info = HttpClient.request({ url = "https://a.example/slow" })

			assert.equals(1, ok)
			assert.equals(200, code)
			assert.equals("late", info.body)
		end)
	end)
end)
