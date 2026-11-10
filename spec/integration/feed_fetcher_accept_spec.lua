local helper = require("helper")
local fake_http = require("support.fake_http")
local socketutil_stub = require("support.socketutil")
local cache_stub = require("support.cache")
local ui_stub = require("support.ui")
local registry_stub = require("support.documentregistry")
local shims = require("support.json_shims")

describe("FeedFetcher content negotiation", function()
	local FeedFetcher, HttpClient, Constants, http, ui, Cache

	local URL = "https://library.example.org/opds/"
	local OTHER = "https://library.example.org/opds/new"
	local ATOM = "<feed><title>Library</title></feed>"
	local OPDS2 = '{"metadata":{"title":"Library"},"navigation":[]}'

	before_each(function()
		helper.reset()
		helper.stub("rapidjson", shims.rapidjson())
		http = fake_http.new()
		ui = ui_stub.new()
		Cache = cache_stub.new()
		local stubs = {
			["socket.http"] = http,
			socketutil = socketutil_stub.new(),
			cache = Cache,
			["document/documentregistry"] = registry_stub.new(),
		}
		for name, stand_in in pairs(ui.stubs) do
			stubs[name] = stand_in
		end
		FeedFetcher = helper.load("core.feed_fetcher", stubs)
		HttpClient = require("services.http_client")
		Constants = require("models.constants")
	end)

	after_each(helper.reset)

	local function accepts()
		local seen = {}
		for i, request in ipairs(http.requests) do
			seen[i] = request.headers["Accept"] or false
		end
		return seen
	end

	-- Refuses any request that carries an Accept header with `code`, and serves the feed otherwise
	local function refuses_accept(url, code)
		http:on(url, function(request)
			if request.headers["Accept"] then
				return { code = code, headers = {}, status = "HTTP/1.1 " .. code .. " Refused" }
			end
			return { code = 200, body = ATOM }
		end)
	end

	describe("the Accept header", function()
		it("asks catalogs for OPDS 2.0, then OPDS 1, then anything", function()
			http:on(URL, { code = 200, body = ATOM })

			FeedFetcher.fetchFeed(URL)

			assert.same({ "application/opds+json, application/atom+xml;profile=opds-catalog, */*" }, accepts())
			assert.equals(Constants.CATALOG_ACCEPT, http.requests[1].headers["Accept"])
			assert.equals("identity", http.requests[1].headers["Accept-Encoding"])
		end)

		it("is left out of a HEAD request, which asks about a book", function()
			http:on(URL, { code = 200, headers = {} })

			FeedFetcher.fetchFeed(URL, true)

			assert.same({ false }, accepts())
		end)

		it("gives way to the Accept header a catalog sets itself", function()
			HttpClient.setCatalogs({
				{ url = "https://library.example.org/opds", headers = { { name = "accept", value = "application/atom+xml" } } },
			})
			http:on(URL, { code = 200, body = ATOM })

			FeedFetcher.fetchFeed(URL)

			local headers = http.requests[1].headers
			assert.equals("application/atom+xml", headers["accept"])
			assert.is_nil(headers["Accept"])
		end)
	end)

	describe("a server that refuses it", function()
		for _, code in ipairs({ 406, 415 }) do
			it("is asked again without it after a " .. code .. ", and nothing is shown", function()
				refuses_accept(URL, code)

				local xml = FeedFetcher.fetchFeed(URL)

				assert.equals(ATOM, xml)
				assert.same({ Constants.CATALOG_ACCEPT, false }, accepts())
				assert.same({}, ui:texts())
			end)
		end

		it("is not sent it again until KOReader restarts, on any of its catalogs", function()
			refuses_accept(URL, 406)
			refuses_accept(OTHER, 406)

			FeedFetcher.fetchFeed(URL)
			FeedFetcher.fetchFeed(OTHER)

			assert.same({ Constants.CATALOG_ACCEPT, false, false }, accepts())
		end)

		it("does not change what other servers are sent", function()
			refuses_accept(URL, 406)
			http:on("https://elsewhere.example.net/opds", { code = 200, body = ATOM })

			FeedFetcher.fetchFeed(URL)
			FeedFetcher.fetchFeed("https://elsewhere.example.net/opds")

			assert.same({ Constants.CATALOG_ACCEPT, false, Constants.CATALOG_ACCEPT }, accepts())
		end)

		it("explains the refusal only when the request without it fails too", function()
			http:on(URL, { code = 406, headers = {}, status = "HTTP/1.1 406 Not Acceptable" })

			assert.is_nil(FeedFetcher.fetchFeed(URL))
			assert.equals(2, #http.requests)
			assert.same({ "Cannot get catalog. Server refuses to serve uncompressed content." }, ui:texts())
		end)

		it("is not asked twice after a 406 to a request that had no Accept", function()
			HttpClient.setCatalogs({
				{ url = "https://library.example.org/opds", headers = { { name = "Accept", value = "text/xml" } } },
			})
			http:on(URL, { code = 406, headers = {} })

			FeedFetcher.fetchFeed(URL)

			assert.equals(1, #http.requests)
		end)
	end)

	describe("the fragment of an address", function()
		it("is never sent, and is left out of the cache key", function()
			http:on(URL, { code = 200, body = ATOM, headers = { ETag = '"v1"' } })

			local catalog = FeedFetcher.parseFeed(URL .. "#opdsplus-group=2")

			assert.equals("Library", catalog.feed.title)
			assert.equals(URL, http.requests[1].url)
			assert.is_table(Cache.instances[1].items["opds|catalog|" .. URL])
		end)
	end)

	describe("the type of the payload", function()
		local OPDSParser

		before_each(function()
			OPDSParser = require("core.parser")
		end)

		it("reads an OPDS 2.0 feed", function()
			http:on(URL, { code = 200, body = OPDS2, headers = { ["Content-Type"] = "application/opds+json" } })

			local catalog = FeedFetcher.parseFeed(URL)

			assert.is_true(OPDSParser.isOpds2(catalog))
			assert.equals("Library", catalog.metadata.title)
		end)

		it("hands the content type to the parser, and keeps it for a copy the server confirms", function()
			local types = {}
			local parse = OPDSParser.parse
			OPDSParser.parse = function(self, text, content_type)
				types[#types + 1] = content_type or false
				return parse(self, text, content_type)
			end
			local served = 0
			http:on(URL, function()
				served = served + 1
				if served == 1 then
					return { code = 200, body = OPDS2, headers = { ETag = '"v1"', ["Content-Type"] = "application/json" } }
				end
				return { code = 304, headers = {} }
			end)

			FeedFetcher.parseFeed(URL)
			FeedFetcher.parseFeed(URL)
			OPDSParser.parse = parse

			assert.same({ "application/json", "application/json" }, types)
		end)

		it("explains that a web page is not a catalog", function()
			http:on(URL, {
				code = 200,
				body = "<!DOCTYPE html>\n<html><head><title>Sign in</title></head></html>",
				headers = { ["Content-Type"] = "text/html; charset=utf-8" },
			})

			assert.is_nil(FeedFetcher.parseFeed(URL))
			assert.equals(1, #ui:texts())
			assert.truthy(ui:texts()[1]:find("This address is a web page, not an OPDS catalog", 1, true))
		end)
	end)

	describe("isWebPage", function()
		it("knows HTML and XHTML pages", function()
			assert.is_true(FeedFetcher.isWebPage("<!doctype html><html></html>"))
			assert.is_true(FeedFetcher.isWebPage("\239\187\191  <HTML lang=\"en\">"))
			assert.is_true(FeedFetcher.isWebPage(
				'<?xml version="1.0"?>\n<!-- generated -->\n<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0//EN">'))
		end)

		it("leaves feeds, search descriptions and odd payloads alone", function()
			assert.is_false(FeedFetcher.isWebPage(ATOM))
			assert.is_false(FeedFetcher.isWebPage('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"/>'))
			assert.is_false(FeedFetcher.isWebPage("<OpenSearchDescription/>"))
			assert.is_false(FeedFetcher.isWebPage(OPDS2))
			assert.is_false(FeedFetcher.isWebPage("<htmlish/>"))
			assert.is_false(FeedFetcher.isWebPage(nil))
		end)
	end)
end)
