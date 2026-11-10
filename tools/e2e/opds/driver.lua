-- KOReader user patch for the live catalog smoke run: tools/e2e/opds/live.sh installs it as
-- patches/2-opds-live.lua.
--
-- Fetches real catalogs through the installed plugin's own modules (HTTP client, parser, mappers) inside a
-- real KOReader, so TLS, rapidjson and the document registry are the real ones. Writes one line per check to
-- $OPDS_LIVE_OUT ("PASS <name>", "FAIL <name>: <why>", "SKIP <name>: <why>" or "INFO <name>: <details>"),
-- then "DONE". Logins come from the environment only and are never written out.
--
-- One request per second at most: these are other people's servers.
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local logger = require("logger")

local OUT = os.getenv("OPDS_LIVE_OUT")
local WORK = os.getenv("OPDS_LIVE_WORK")
if not (OUT and WORK) then
	return
end
assert(WORK:match("^/tmp/opds_plus_test_live%.[%w]+$"), "unexpected work dir " .. WORK)

local out = assert(io.open(OUT, "a"))
local function report(line)
	out:write(line, "\n")
	out:flush()
	logger.info("OPDS live:", line)
end

local failures = 0
local function check(name, ok, why)
	if ok then
		report("PASS " .. name)
	else
		failures = failures + 1
		report("FAIL " .. name .. ": " .. tostring(why))
	end
	return ok
end

-- "user:password" from an environment variable, or nothing
local function login(variable)
	local value = variable and os.getenv(variable)
	if not value or value == "" then
		return nil
	end
	local user, password = value:match("^([^:]+):(.*)$")
	return user and { user = user, password = password }
end

-- Each target: what the feed should be, and what it should hold
local TARGETS = {
	{ name = "test.opds.io navigation", url = "https://test.opds.io/2.0/home.json", format = "opds2", folders = true },
	{ name = "test.opds.io publications", url = "https://test.opds.io/2.0/publications.json", format = "opds2", books = true },
	{ name = "Komga OPDS 2", url = "https://demo.komga.org/opds/v2/catalog", login = "OPDS_LIVE_KOMGA",
		format = "opds2", folders = true, search = true, follow = 2 },
	{ name = "Komga OPDS 2 latest books", url = "https://demo.komga.org/opds/v2/libraries/books/latest",
		login = "OPDS_LIVE_KOMGA", format = "opds2", books = true },
	{ name = "Komga OPDS 1.2", url = "https://demo.komga.org/opds/v1.2/catalog", login = "OPDS_LIVE_KOMGA",
		format = "atom", folders = true, search = true, follow = 2 },
	{ name = "Project Gutenberg", url = "https://www.gutenberg.org/ebooks.opds/", format = "atom",
		folders = true, search = true, follow = 1 },
	{ name = "Calibre-Web", url = os.getenv("OPDS_LIVE_CWA_URL"), login = "OPDS_LIVE_CWA", format = "atom",
		folders = true, search = true, follow = 2 },
	{ name = "web page", url = "https://www.gutenberg.org/", web_page = true },
}

local function start()
	local FileManager = require("apps/filemanager/filemanager")
	if not check("plugin loaded", FileManager.instance and FileManager.instance.opds_plus,
			"FileManager.instance.opds_plus is missing") then
		return
	end
	local FeedFetcher = require("core.feed_fetcher")
	local NavigationHandler = require("core.navigation_handler")
	local OPDSParser = require("core.parser")
	local BrowserContext = require("core.browser_context")
	local DownloadManager = require("core.download_manager")
	local UrlUtils = require("utils.url_utils")
	local OPDSBrowser = require("ui.browser")
	local util = require("util")

	-- What the plugin would have shown
	local shown = {}
	UIManager.show = function(_, widget)
		shown[#shown + 1] = widget and widget.text or "?"
	end

	local last_request = 0
	local function polite()
		local wait = 1 - (os.time() - last_request)
		if wait > 0 then
			ffiUtil.sleep(wait)
		end
		last_request = os.time()
	end

	-- Fetches and maps one feed: the items, or nothing and why
	local function open(url, credentials, target)
		polite()
		local before = #shown
		local context = BrowserContext.withAuth(OPDSBrowser, credentials and credentials.user,
			credentials and credentials.password)
		local catalog = FeedFetcher.parseFeed(url, context.username, context.password)
		if not catalog then
			return nil, shown[#shown] or "no feed"
		end
		if #shown > before then
			return nil, shown[#shown]
		end
		local format = OPDSParser.isOpds2(catalog) and "opds2" or "atom"
		if target and target.format and format ~= target.format then
			return nil, "got " .. format .. ", expected " .. target.format
		end
		local items, facets, search_url = NavigationHandler.genItemTableFromCatalog(catalog, url, context)
		if #shown > before then
			return nil, shown[#shown]
		end
		return { items = items, facets = facets, search_url = search_url, format = format }
	end

	local function describe(feed)
		local folders, books, downloads, covers = 0, 0, 0, 0
		for _, item in ipairs(feed.items) do
			if item.acquisitions and #item.acquisitions > 0 then
				books = books + 1
				for _, link in ipairs(item.acquisitions) do
					if link.href and DownloadManager.getFiletype(link) then
						downloads = downloads + 1
						break
					end
				end
			elseif item.url then
				folders = folders + 1
			end
			if item.cover_url then
				covers = covers + 1
			end
		end
		return { folders = folders, books = books, downloads = downloads, covers = covers,
			facets = feed.facets and #feed.facets or 0, next = feed.items.hrefs and feed.items.hrefs.next }
	end

	local function summary(counts)
		return string.format("%d folders, %d books (%d downloadable), %d covers, %d facet groups%s",
			counts.folders, counts.books, counts.downloads, counts.covers, counts.facets,
			counts.next and ", has a next page" or "")
	end

	for _, target in ipairs(TARGETS) do
		local credentials = login(target.login)
		if not target.url then
			report("SKIP " .. target.name .. ": no URL in the environment")
		elseif target.login and not credentials then
			report("SKIP " .. target.name .. ": set " .. target.login .. "=user:password")
		elseif target.web_page then
			local feed, why = open(target.url)
			check(target.name .. " is explained", not feed and tostring(why):find("web page", 1, true), why)
		else
			local feed, why = open(target.url, credentials, target)
			if check(target.name .. " opens as " .. target.format, feed, why) then
				local counts = describe(feed)
				report("INFO " .. target.name .. ": " .. summary(counts))
				if target.folders then
					check(target.name .. " has folders", counts.folders > 0, summary(counts))
				end
				if target.books then
					check(target.name .. " has downloadable books", counts.downloads > 0, summary(counts))
				end
				if target.search then
					check(target.name .. " has search", feed.search_url and UrlUtils.isSearchable(feed.search_url),
						feed.search_url)
					if feed.search_url then
						local results, search_why = open(UrlUtils.buildSearchUrl(feed.search_url,
							util.urlEncode("the")), credentials)
						if check(target.name .. " search answers", results, search_why) then
							report("INFO " .. target.name .. " search: " .. summary(describe(results)))
						end
					end
				end
				-- Walk down the first folders not seen yet, to reach books
				local depth, current = 0, feed
				local seen = { [target.url] = true }
				while depth < (target.follow or 0) do
					local folder
					for _, item in ipairs(current.items) do
						if item.url and not seen[item.url] and not (item.acquisitions and #item.acquisitions > 0) then
							folder = item
							break
						end
					end
					if not folder then
						break
					end
					depth = depth + 1
					seen[folder.url] = true
					local inner, inner_why = open(folder.url, credentials)
					if not check(target.name .. " folder " .. depth .. " (" .. tostring(folder.title) .. ") opens",
							inner, inner_why) then
						break
					end
					report("INFO " .. target.name .. " folder " .. depth .. ": " .. summary(describe(inner)))
					current = inner
				end
			end
		end
	end
end

UIManager:scheduleIn(3, function()
	local ok, err = pcall(start)
	if not ok then
		check("driver", false, err)
	end
	report(failures == 0 and "DONE" or ("DONE with " .. failures .. " failures"))
	out:close()
	UIManager:quit(0)
end)
