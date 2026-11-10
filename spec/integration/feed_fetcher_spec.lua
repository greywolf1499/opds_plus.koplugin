local helper = require("helper")
local fake_http = require("support.fake_http")
local socketutil_stub = require("support.socketutil")
local cache_stub = require("support.cache")
local ui_stub = require("support.ui")
local registry_stub = require("support.documentregistry")

describe("FeedFetcher", function()
	local FeedFetcher, HttpClient, http, socketutil, ui, Cache

	local URL = "https://library.example.org/opds/"
	local FEED = "<feed><title>Library</title><entry><title>A Book</title></entry></feed>"

	local function route(url, response)
		http:on(url, response)
	end

	-- Loads the module with `overrides` (module name -> stand-in) on top of the usual ones.
	local function load_fetcher(overrides)
		local stubs = {
			["socket.http"] = http,
			socketutil = socketutil,
			cache = Cache,
			["document/documentregistry"] = registry_stub.new(),
		}
		for name, stand_in in pairs(ui.stubs) do
			stubs[name] = stand_in
		end
		for name, stand_in in pairs(overrides or {}) do
			stubs[name] = stand_in
		end
		FeedFetcher = helper.load("core.feed_fetcher", stubs)
		HttpClient = require("services.http_client")
	end

	local function message()
		return ui:last() and ui:last().text
	end

	before_each(function()
		helper.reset()
		http = fake_http.new()
		socketutil = socketutil_stub.new()
		ui = ui_stub.new()
		Cache = cache_stub.new()
		load_fetcher()
	end)

	after_each(helper.reset)

	describe("fetchFeed", function()
		it("returns the body and the headers of a successful response", function()
			route(URL, { code = 200, body = FEED, headers = { ETag = '"v1"' } })

			local xml, headers = FeedFetcher.fetchFeed(URL)

			assert.equals(FEED, xml)
			assert.equals('"v1"', headers.etag)
			assert.same({}, ui:texts())
		end)

		it("returns nothing for an empty body, without a message", function()
			route(URL, { code = 200, body = "" })

			local xml = FeedFetcher.fetchFeed(URL)

			assert.is_falsy(xml)
			assert.same({}, ui:texts())
		end)

		it("sends a GET that asks for an uncompressed body, with the credentials", function()
			route(URL, { code = 200, body = FEED })

			FeedFetcher.fetchFeed(URL, false, "reader", "s3cret")

			local request = http.requests[1]
			assert.equals("GET", request.method)
			assert.equals("identity", request.headers["Accept-Encoding"])
			assert.equals("reader", request.user)
			assert.equals("s3cret", request.password)
		end)

		it("uses the timeouts for large responses and resets them afterwards", function()
			local seen
			route(URL, function()
				seen = { block = socketutil.block_timeout, total = socketutil.total_timeout }
				return { code = 200, body = FEED }
			end)

			FeedFetcher.fetchFeed(URL)

			assert.same({ block = socketutil.LARGE_BLOCK_TIMEOUT, total = socketutil.LARGE_TOTAL_TIMEOUT }, seen)
			assert.equals(socketutil.DEFAULT_BLOCK_TIMEOUT, socketutil.block_timeout)
		end)

		it("sends the custom headers of the catalog, but never replaces its own", function()
			HttpClient.setCatalogs({
				{
					url = "https://library.example.org/opds",
					headers = {
						{ name = "X-Api-Key", value = "abc" },
						{ name = "Accept-Encoding", value = "gzip" },
					},
				},
			})
			route(URL, { code = 200, body = FEED })

			FeedFetcher.fetchFeed(URL)

			assert.equals("abc", http.requests[1].headers["X-Api-Key"])
			assert.equals("identity", http.requests[1].headers["Accept-Encoding"])
		end)

		it("keeps the custom headers of a catalog away from other servers", function()
			HttpClient.setCatalogs({
				{ url = "https://library.example.org/opds", headers = { { name = "X-Api-Key", value = "abc" } } },
			})
			route("https://elsewhere.example.net/feed", { code = 200, body = FEED })

			FeedFetcher.fetchFeed("https://elsewhere.example.net/feed")

			assert.is_nil(http.requests[1].headers["X-Api-Key"])
		end)

		describe("with a copy to revalidate", function()
			local cached = { xml = "<feed>old</feed>", etag = '"v1"', last_modified = "Wed, 01 Jan 2025 00:00:00 GMT" }

			it("asks whether the copy is still current", function()
				route(URL, { code = 200, body = FEED })

				FeedFetcher.fetchFeed(URL, false, nil, nil, cached)

				assert.equals('"v1"', http.requests[1].headers["If-None-Match"])
				assert.equals("Wed, 01 Jan 2025 00:00:00 GMT", http.requests[1].headers["If-Modified-Since"])
			end)

			it("sends only the validators it has", function()
				route(URL, { code = 200, body = FEED })

				FeedFetcher.fetchFeed(URL, false, nil, nil, { xml = "<feed/>", etag = '"v2"' })

				assert.equals('"v2"', http.requests[1].headers["If-None-Match"])
				assert.is_nil(http.requests[1].headers["If-Modified-Since"])
			end)

			it("returns the copy when the server answers not modified", function()
				route(URL, { code = 304, headers = { etag = '"v1"' } })

				local xml, headers = FeedFetcher.fetchFeed(URL, false, nil, nil, cached)

				assert.equals("<feed>old</feed>", xml)
				assert.equals('"v1"', headers.etag)
				assert.same({}, ui:texts())
			end)

			it("returns the new feed when the server sends one", function()
				route(URL, { code = 200, body = FEED })

				assert.equals(FEED, (FeedFetcher.fetchFeed(URL, false, nil, nil, cached)))
			end)

			it("treats a not modified answer as an error when there is no copy", function()
				route(URL, { code = 304, status = "HTTP/1.1 304 Not Modified" })

				assert.is_nil(FeedFetcher.fetchFeed(URL))
				assert.equals("Cannot get catalog. Server response status: HTTP/1.1 304 Not Modified.", message())
			end)
		end)

		describe("asking for the headers only", function()
			it("sends a HEAD request and returns the headers whatever the status", function()
				route(URL, { code = 302, headers = { Location = "https://files.example.org/book.epub" } })

				local headers = FeedFetcher.fetchFeed(URL, true)

				assert.equals("HEAD", http.requests[1].method)
				assert.equals("https://files.example.org/book.epub", headers.location)
				assert.same({}, ui:texts())
			end)

			it("never asks to revalidate a copy", function()
				route(URL, { code = 200 })

				FeedFetcher.fetchFeed(URL, true, nil, nil, { xml = "<feed/>", etag = '"v1"' })

				assert.is_nil(http.requests[1].headers["If-None-Match"])
			end)
		end)

		describe("when the server refuses", function()
			local function fails_with(code, expected)
				route(URL, { code = code, headers = {}, status = "HTTP/1.1 " .. code .. " Reason" })

				assert.is_nil(FeedFetcher.fetchFeed(URL))
				assert.equals(expected, message())
			end

			it("asks for a username and password on 401", function()
				fails_with(401, "Authentication required for catalog. Please add a username and password.")
			end)

			it("says the credentials are wrong on 403", function()
				fails_with(403, "Failed to authenticate. Please check your username and password.")
			end)

			it("says the catalog is missing on 404", function()
				fails_with(404, "Catalog not found.")
			end)

			it("explains a 406 as a refusal to serve uncompressed content", function()
				fails_with(406, "Cannot get catalog. Server refuses to serve uncompressed content.")
			end)

			it("quotes the status line of any other failure", function()
				fails_with(500, "Cannot get catalog. Server response status: HTTP/1.1 500 Reason.")
			end)

			it("reports the transport error when there is no response", function()
				route(URL, { error = "timeout" })

				assert.is_nil(FeedFetcher.fetchFeed(URL))
				assert.equals("Cannot get catalog. Server response status: timeout.", message())
			end)

			it("logs the failure", function()
				route(URL, { code = 404 })

				FeedFetcher.fetchFeed(URL)

				assert.is_true(require("logger").logged("dbg", "Failed to fetch catalog"))
			end)
		end)

		describe("redirects", function()
			it("tells where a permanently moved catalog went", function()
				route(URL, { code = 301, headers = { Location = "https://new.example.org/opds/" } })

				assert.is_nil(FeedFetcher.fetchFeed(URL))
				assert.equals(
					"The catalog has been permanently moved. Please update catalog URL to 'https://new.example.org/opds/'.",
					message()
				)
			end)

			it("refuses to follow an HTTPS address that redirects to plain HTTP", function()
				route(URL, { code = 302, headers = { Location = "http://library.example.org/opds/" } })

				assert.is_nil(FeedFetcher.fetchFeed(URL))

				local shown = ui:last()
				assert.equals("notice-warning", shown.icon)
				assert.truthy(shown.text:find("'https://library.example.org/opds/'", 1, true))
				assert.truthy(shown.text:find("'http://library.example.org/opds/'", 1, true))
				assert.truthy(shown.text:find("downgrade", 1, true))
			end)

			it("treats a redirect that stays on HTTPS as an ordinary failure", function()
				route(URL, { code = 302, status = "HTTP/1.1 302 Found", headers = { Location = "https://other.example.org/" } })

				assert.is_nil(FeedFetcher.fetchFeed(URL))
				assert.equals("Cannot get catalog. Server response status: HTTP/1.1 302 Found.", message())
				assert.is_nil(ui:last().icon)
			end)

			it("treats a redirect between plain HTTP addresses as an ordinary failure", function()
				route("http://library.example.org/opds/", {
					code = 302,
					status = "HTTP/1.1 302 Found",
					headers = { Location = "http://library.example.org/other/" },
				})

				assert.is_nil(FeedFetcher.fetchFeed("http://library.example.org/opds/"))
				assert.equals("Cannot get catalog. Server response status: HTTP/1.1 302 Found.", message())
			end)

			it("survives a redirect without a Location header", function()
				route(URL, { code = 302, status = "HTTP/1.1 302 Found" })

				local ok, result = pcall(FeedFetcher.fetchFeed, URL)

				assert.is_true(ok, result)
				assert.is_nil(result)
				assert.equals("Cannot get catalog. Server response status: HTTP/1.1 302 Found.", message())
			end)

			it("survives a permanent redirect without a Location header", function()
				route(URL, { code = 301, status = "HTTP/1.1 301 Moved Permanently" })

				local ok, result = pcall(FeedFetcher.fetchFeed, URL)

				assert.is_true(ok, result)
				assert.is_nil(result)
				assert.equals("Cannot get catalog. Server response status: HTTP/1.1 301 Moved Permanently.", message())
			end)
		end)
	end)

	describe("parseFeed", function()
		local KEY = "opds|catalog|" .. URL

		it("returns the parsed feed", function()
			route(URL, { code = 200, body = FEED })

			local catalog = FeedFetcher.parseFeed(URL)

			assert.equals("Library", catalog.feed.title)
			assert.equals("A Book", catalog.feed.entry[1].title)
		end)

		it("returns nothing, and keeps nothing, when the feed cannot be fetched", function()
			route(URL, { code = 404 })

			assert.is_nil(FeedFetcher.parseFeed(URL))
			assert.is_nil(Cache.instances[1].items[KEY])
		end)

		it("keeps a feed that comes with an ETag", function()
			route(URL, { code = 200, body = FEED, headers = { ETag = '"v1"' } })

			FeedFetcher.parseFeed(URL)

			assert.same({ xml = FEED, etag = '"v1"' }, Cache.instances[1].items[KEY])
		end)

		it("keeps a feed that comes with a modification date", function()
			route(URL, { code = 200, body = FEED, headers = { ["Last-Modified"] = "Wed, 01 Jan 2025 00:00:00 GMT" } })

			FeedFetcher.parseFeed(URL)

			assert.same({ xml = FEED, last_modified = "Wed, 01 Jan 2025 00:00:00 GMT" }, Cache.instances[1].items[KEY])
		end)

		it("does not keep a feed the server gave no way to revalidate", function()
			route(URL, { code = 200, body = FEED })

			FeedFetcher.parseFeed(URL)

			assert.is_nil(Cache.instances[1].items[KEY])
		end)

		it("asks the server to confirm a kept feed, and reuses it when nothing changed", function()
			local answers = {
				{ code = 200, body = FEED, headers = { ETag = '"v1"' } },
				{ code = 304, headers = { ETag = '"v1"' } },
			}
			route(URL, function()
				return table.remove(answers, 1)
			end)

			FeedFetcher.parseFeed(URL)
			local again = FeedFetcher.parseFeed(URL)

			assert.equals(2, #http.requests)
			assert.is_nil(http.requests[1].headers["If-None-Match"])
			assert.equals('"v1"', http.requests[2].headers["If-None-Match"])
			assert.equals("A Book", again.feed.entry[1].title)
		end)

		it("reports a confirmed copy through the debug callback", function()
			local answers = {
				{ code = 200, body = FEED, headers = { ETag = '"v1"' } },
				{ code = 304 },
			}
			route(URL, function()
				return table.remove(answers, 1)
			end)
			local reported = {}

			FeedFetcher.parseFeed(URL)
			FeedFetcher.parseFeed(URL, nil, nil, function(...)
				reported[#reported + 1] = table.concat({ ... }, " ")
			end)

			assert.same({ "Cache hit for " .. URL }, reported)
		end)

		it("replaces a kept feed that changed", function()
			local newer = "<feed><title>Newer</title></feed>"
			local answers = {
				{ code = 200, body = FEED, headers = { ETag = '"v1"' } },
				{ code = 200, body = newer, headers = { ETag = '"v2"' } },
			}
			route(URL, function()
				return table.remove(answers, 1)
			end)

			FeedFetcher.parseFeed(URL)
			local catalog = FeedFetcher.parseFeed(URL)

			assert.equals("Newer", catalog.feed.title)
			assert.same({ xml = newer, etag = '"v2"' }, Cache.instances[1].items[KEY])
		end)

		it("keeps each address apart", function()
			local other = "https://library.example.org/opds/new"
			route(URL, { code = 200, body = FEED, headers = { ETag = '"v1"' } })
			route(other, { code = 200, body = FEED })

			FeedFetcher.parseFeed(URL)
			FeedFetcher.parseFeed(other)

			assert.is_nil(http:requests_to(other)[1].headers["If-None-Match"])
		end)

		it("sends the credentials", function()
			route(URL, { code = 200, body = FEED })

			FeedFetcher.parseFeed(URL, "reader", "s3cret")

			assert.equals("reader", http.requests[1].user)
		end)
	end)

	describe("parseFeedResult", function()
		it("wraps the parsed feed", function()
			route(URL, { code = 200, body = FEED })

			local result = FeedFetcher.parseFeedResult(URL)

			assert.is_true(result:isOk())
			assert.equals("Library", result.value.feed.title)
		end)

		it("is an error when the feed cannot be fetched", function()
			route(URL, { code = 500 })

			local result = FeedFetcher.parseFeedResult(URL)

			assert.is_true(result:isErr())
			assert.equals("Failed to fetch or parse feed", result.error)
		end)

		it("is an error when parsing raises", function()
			helper.reset()
			load_fetcher({
				["core.parser"] = {
					parse = function()
						error("boom")
					end,
				},
			})
			route(URL, { code = 200, body = FEED })

			local result = FeedFetcher.parseFeedResult(URL)

			assert.is_true(result:isErr())
			assert.truthy(result.error:find("boom", 1, true))
		end)
	end)

	describe("getServerFileName", function()
		local DOWNLOAD = "https://library.example.org/opds/download/42/epub"

		it("asks the server with a HEAD request", function()
			route(DOWNLOAD, { code = 200 })

			FeedFetcher.getServerFileName(DOWNLOAD, "epub", "reader", "s3cret")

			assert.equals("HEAD", http.requests[1].method)
			assert.equals("reader", http.requests[1].user)
		end)

		it("takes the name the server gives in Content-Disposition", function()
			route(DOWNLOAD, { code = 200, headers = { ["Content-Disposition"] = 'attachment; filename="The%20Hobbit.epub"' } })

			assert.equals("The Hobbit.epub", FeedFetcher.getServerFileName(DOWNLOAD, "epub"))
		end)

		it("takes the name from the address a redirect leads to", function()
			route(DOWNLOAD, { code = 302, headers = { Location = "https://files.example.org/books/Dune.epub" } })

			assert.equals("Dune.epub", FeedFetcher.getServerFileName(DOWNLOAD, "epub"))
		end)

		it("decodes the name in the address a redirect leads to", function()
			route(DOWNLOAD, { code = 302, headers = { Location = "https://files.example.org/books/Dune%20(1965).epub" } })

			assert.equals("Dune (1965).epub", FeedFetcher.getServerFileName(DOWNLOAD, "epub"))
		end)

		it("leaves the query string of the redirect address out of the name", function()
			route(DOWNLOAD, {
				code = 302,
				headers = { Location = "https://files.example.org/books/Dune.epub?X-Amz-Signature=abc123&Expires=99" },
			})

			assert.equals("Dune.epub", FeedFetcher.getServerFileName(DOWNLOAD, "epub"))
		end)

		it("takes the name from the address when the redirect address has no file name", function()
			local plain = "https://library.example.org/get/42"
			route(plain, { code = 302, headers = { Location = "https://files.example.org/books/" } })

			assert.equals("42.epub", FeedFetcher.getServerFileName(plain, "epub"))
		end)

		it("takes the name from the address when the server says nothing", function()
			local plain = "https://library.example.org/get/42"
			route(plain, { code = 200 })

			assert.equals("42.epub", FeedFetcher.getServerFileName(plain, "epub"))
		end)

		it("falls back to the address when the server cannot be reached, without a message", function()
			local plain = "https://library.example.org/get/42"
			route(plain, { error = "timeout" })

			assert.equals("42.epub", FeedFetcher.getServerFileName(plain, "epub"))
			assert.same({}, ui:texts())
		end)

		it("adds the file type when the name has an extension nothing opens", function()
			route(DOWNLOAD, { code = 200, headers = { ["Content-Disposition"] = 'attachment; filename="book.xyz"' } })

			assert.equals("book.xyz.epub", FeedFetcher.getServerFileName(DOWNLOAD, "epub"))
		end)

		it("keeps an extension something opens", function()
			route(DOWNLOAD, { code = 200, headers = { ["Content-Disposition"] = 'attachment; filename="book.pdf"' } })

			assert.equals("book.pdf", FeedFetcher.getServerFileName(DOWNLOAD, "epub"))
		end)

		it("adds nothing when no file type is wanted", function()
			route(DOWNLOAD, { code = 200, headers = { ["Content-Disposition"] = 'attachment; filename="book"' } })

			assert.equals("book", FeedFetcher.getServerFileName(DOWNLOAD))
		end)
	end)

	describe("getSearchTemplate", function()
		local OSD_URL = "https://library.example.org/opds/osd.xml"
		local OSD = [[<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <ShortName>Library</ShortName>
  <Url type="application/rss+xml" template="https://library.example.org/search.rss?q={searchTerms}"/>
  <Url type="application/atom+xml" template="https://library.example.org/opds/search?q={searchTerms}"/>
</OpenSearchDescription>]]

		it("returns the template of the Atom search with the search terms as %s", function()
			route(OSD_URL, { code = 200, body = OSD })

			local template = FeedFetcher.getSearchTemplate(OSD_URL, "application/atom%+xml")

			assert.equals("https://library.example.org/opds/search?q=%s", template)
		end)

		it("returns nothing when no search is of the wanted type", function()
			route(OSD_URL, { code = 200, body = OSD })

			assert.is_nil(FeedFetcher.getSearchTemplate(OSD_URL, "application/opensearchdescription%+xml"))
		end)

		it("returns nothing when the description is not an OpenSearch description", function()
			route(OSD_URL, { code = 200, body = FEED })

			assert.is_nil(FeedFetcher.getSearchTemplate(OSD_URL, "application/atom%+xml"))
		end)

		it("returns nothing when the description cannot be fetched", function()
			route(OSD_URL, { code = 404 })

			assert.is_nil(FeedFetcher.getSearchTemplate(OSD_URL, "application/atom%+xml"))
		end)

		it("reads the description with the credentials", function()
			route(OSD_URL, { code = 200, body = OSD })

			FeedFetcher.getSearchTemplate(OSD_URL, "application/atom%+xml", "reader", "s3cret")

			assert.equals("reader", http.requests[1].user)
			assert.equals("s3cret", http.requests[1].password)
		end)
	end)

	describe("genItemTableFromURL", function()
		it("hands the parsed catalog and its address to the function that builds the items", function()
			route(URL, { code = 200, body = FEED })
			local received

			local result = FeedFetcher.genItemTableFromURL(URL, nil, nil, nil, function(catalog, url)
				received = { catalog = catalog, url = url }
				return "items"
			end)

			assert.equals("items", result)
			assert.equals(URL, received.url)
			assert.equals("Library", received.catalog.feed.title)
			assert.same({}, ui:texts())
		end)

		it("tells the user when the catalog cannot be read, and still builds the items from nothing", function()
			route(URL, { code = 404 })
			local received = "not called"

			FeedFetcher.genItemTableFromURL(URL, nil, nil, nil, function(catalog)
				received = catalog
			end)

			assert.is_nil(received)
			assert.truthy(table.concat(ui:texts(), "\n"):find("Cannot get catalog info from " .. URL, 1, true))
		end)
	end)
end)
