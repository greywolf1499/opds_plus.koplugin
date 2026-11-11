-- Characterization ("golden") tests for the OPDS 1.x entry model.
--
-- genItemTableFromCatalog turns a parsed Atom feed into what the browser, the cover menus and the sync
-- code consume: items with `url`, `acquisitions`, cover fields, series, and the feed-level links, facets
-- and search URL. These specs pin that model, feed shape by feed shape, so that the parser and
-- navigation code can be reworked (OPDS 2.0 support in particular) without changing what users see.
local helper = require("helper")

describe("NavigationHandler.genItemTableFromCatalog", function()
	local NavigationHandler, OPDSParser, make_context
	local registry, search_calls, osd_template

	local BASE = "https://library.example.org/opds/catalog/"

	local function parse_fixture(name)
		return OPDSParser:parse(helper.fixture("opds1/" .. name))
	end

	local function generate(catalog, base, options)
		return NavigationHandler.genItemTableFromCatalog(catalog, base or BASE, make_context(options))
	end

	local function from_fixture(name, base, options)
		return generate(parse_fixture(name), base, options)
	end

	-- Items of a feed made of the given XML (entries and feed-level links).
	local function from_xml(body, options)
		return generate(OPDSParser:parse("<feed>" .. body .. "</feed>"), BASE, options)
	end

	local function entry(inner)
		return "<entry><title>Book</title>" .. inner .. "</entry>"
	end

	local function acquisition(href, mime)
		return string.format('<link rel="http://opds-spec.org/acquisition" href="%s" type="%s"/>', href, mime)
	end

	before_each(function()
		helper.reset()
		registry = require("support.documentregistry").new()
		search_calls = {}
		osd_template = "/opds/search?q=%s"
		helper.stub("document/documentregistry", registry)
		-- Reading an OpenSearch description is the one network call this module makes. The stand-in returns
		-- osd_template, which a test sets to nil for a description that cannot be read.
		helper.stub("core.feed_fetcher", {
			getSearchTemplate = function(...)
				search_calls[#search_calls + 1] = { ... }
				return osd_template
			end,
		})
		OPDSParser = require("core.parser")
		NavigationHandler = require("core.navigation_handler")
		make_context = require("support.context")
	end)

	after_each(helper.reset)

	it("returns an empty table and nothing else for a missing catalog", function()
		local items, facets, search = NavigationHandler.genItemTableFromCatalog(nil, BASE, make_context())
		assert.same({}, items)
		assert.is_nil(facets)
		assert.is_nil(search)
	end)

	it("accepts a catalog that is the feed itself, without the feed wrapper", function()
		local catalog = parse_fixture("navigation_root.xml")
		local items = generate(catalog.feed)
		assert.equals(5, #items)
	end)

	describe("a navigation feed", function()
		local items, hrefs

		before_each(function()
			items = from_fixture("navigation_root.xml", "https://catalog.example.org/opds/")
			hrefs = items.hrefs
		end)

		it("lists every entry with its title", function()
			local titles = {}
			for i, item in ipairs(items) do
				titles[i] = item.text
			end
			assert.same({ "Popular", "Latest", "Authors", "Subjects", "About this library" }, titles)
		end)

		it("opens sub-catalogs through subsection, sort and rel-less links", function()
			assert.equals("https://catalog.example.org/opds/popular", items[1].url)
			assert.equals("https://catalog.example.org/opds/new", items[2].url)
			assert.equals("https://catalog.example.org/opds/authors/", items[3].url)
			assert.equals("https://catalog.example.org/opds/subjects/", items[4].url)
		end)

		it("does not open a link to an HTML page", function()
			assert.is_nil(items[5].url)
			assert.same({}, items[5].acquisitions)
		end)

		it("offers no download for a sub-catalog", function()
			for _, item in ipairs(items) do
				assert.same({}, item.acquisitions)
			end
		end)

		it("collects the feed's catalog links by relation, as absolute URLs", function()
			assert.same({
				self = "https://catalog.example.org/opds/",
				start = "https://catalog.example.org/opds/",
			}, hrefs)
		end)

		it("reads the OpenSearch description for the search URL", function()
			local _, _, search = from_fixture("navigation_root.xml", "https://catalog.example.org/opds/")
			assert.equals("https://catalog.example.org/opds/search?q=%s", search)
			assert.equals("https://catalog.example.org/opds/search.xml", search_calls[1][1])
		end)

		it("passes the catalog's credentials on when reading the search description", function()
			from_fixture("navigation_root.xml", "https://catalog.example.org/opds/", {
				username = "reader",
				password = "secret",
			})
			local call = search_calls[#search_calls]
			assert.equals("reader", call[3])
			assert.equals("secret", call[4])
		end)
	end)

	describe("a Calibre-Web acquisition feed", function()
		local items, hrefs, search

		before_each(function()
			local _
			items, _, search = from_fixture("calibre_web_acquisition.xml", "https://cw.example.org/opds/new")
			hrefs = items.hrefs
		end)

		it("keeps the pagination links", function()
			assert.equals("https://cw.example.org/opds/new?offset=2", hrefs.next)
			assert.equals("https://cw.example.org/opds/new?offset=0", hrefs.previous)
			assert.equals("https://cw.example.org/opds/new", hrefs.first)
			assert.equals("https://cw.example.org/opds/new?offset=4", hrefs.last)
			assert.equals("https://cw.example.org/opds/new", hrefs.self)
			assert.equals("https://cw.example.org/opds", hrefs.start)
			assert.equals("https://cw.example.org/opds", hrefs.up)
		end)

		it("reads the language of each book", function()
			assert.equals("eng", items[1].language)
			assert.is_nil(items[1].publisher)
		end)

		it("prefers the OpenSearch description over an inline search template", function()
			assert.equals("https://cw.example.org/opds/search?q=%s", search)
			assert.equals("https://cw.example.org/opds/osd", search_calls[1][1])
		end)

		it("lists a download per format, in the order the server sent them", function()
			assert.same({
				{ type = "application/epub+zip", href = "https://cw.example.org/opds/download/1/epub/", title = "EPUB" },
				{
					type = "application/x-mobipocket-ebook",
					href = "https://cw.example.org/opds/download/1/mobi/",
					title = "MOBI",
				},
				{ type = "application/pdf", href = "https://cw.example.org/opds/download/1/pdf/", title = "PDF" },
			}, items[1].acquisitions)
		end)

		it("lists the PDF once, at the address the server sent", function()
			local pdfs = {}
			for _, acquisition_item in ipairs(items[1].acquisitions) do
				if acquisition_item.type == "application/pdf" then
					pdfs[#pdfs + 1] = acquisition_item
				end
			end
			assert.equals(1, #pdfs)
			assert.equals("https://cw.example.org/opds/download/1/pdf/", pdfs[1].href)
		end)

		it("does not turn a related link into a download or a sub-catalog", function()
			-- The "Other books by" link has rel="related" and the catalog type
			assert.is_nil(items[1].url)
			assert.equals(3, #items[1].acquisitions)
		end)

		it("sets the title, author and description", function()
			local hobbit = items[1]
			assert.equals("The Hobbit, or There and Back Again", hobbit.title)
			assert.equals("J. R. R. Tolkien", hobbit.author)
			assert.equals("The Hobbit, or There and Back Again - J. R. R. Tolkien", hobbit.text)
			assert.truthy(hobbit.content:find("^Bilbo Baggins is a hobbit"))
			assert.equals("Pride & Prejudice - Jane Austen", items[2].text)
		end)

		it("takes the cover from the thumbnail link", function()
			assert.equals("https://cw.example.org/opds/cover/1", items[1].cover_url)
			assert.is_true(items[1].lazy_load_cover)
		end)
	end)

	describe("a Calibre content server feed", function()
		local items

		before_each(function()
			items = from_fixture("calibre_content_server.xml", "http://calibre.example.org:8080/opds/navcatalog/4f")
		end)

		it("joins every author", function()
			assert.equals("Alexandre Dumas, Auguste Maquet", items[1].author)
			assert.equals("The Count of Monte Cristo - Alexandre Dumas, Auguste Maquet", items[1].text)
		end)

		it("reads the series from the SERIES line of the content", function()
			assert.equals("Dumas Romances", items[1].series)
			assert.equals("2", items[1].series_index)
			assert.is_nil(items[2].series)
		end)

		it("resolves the search template to the %s form", function()
			local _, _, search = from_fixture("calibre_content_server.xml", "http://calibre.example.org:8080/opds/x")
			assert.equals("http://calibre.example.org:8080/opds/search/%s", search)
			assert.same({}, search_calls)
		end)

		it("shows the thumbnail by default and the full image when large covers are preferred", function()
			assert.equals("http://calibre.example.org:8080/get/thumb/17/Library", items[1].cover_url)

			local large = from_fixture("calibre_content_server.xml", "http://calibre.example.org:8080/opds/x", {
				prefer_large_covers = true,
			})
			assert.equals("http://calibre.example.org:8080/get/cover/17/Library", large[1].cover_url)
			assert.equals("http://calibre.example.org:8080/get/thumb/17/Library", large[1].thumbnail)
			assert.equals("http://calibre.example.org:8080/get/cover/17/Library", large[1].image)
		end)

		it("has no cover for a book without artwork", function()
			assert.is_nil(items[2].cover_url)
			assert.is_nil(items[2].lazy_load_cover)
		end)
	end)

	describe("series", function()
		local items

		before_each(function()
			items = from_fixture("series_shapes.xml", "https://library.example.org/opds/series/12")
		end)

		it("reads dc:series with dc:series_index", function()
			assert.equals("Dune", items[1].series)
			assert.equals("1", items[1].series_index)
		end)

		it("reads dc:series with dc:seriesPosition", function()
			assert.equals("Dune", items[2].series)
			assert.equals("2", items[2].series_index)
		end)

		it("reads EPUB3 collection metadata", function()
			assert.equals("Dune", items[3].series)
			assert.equals("3", items[3].series_index)
		end)

		it("reads the SERIES line of a summary", function()
			assert.equals("Dune", items[4].series)
			assert.equals("4", items[4].series_index)
		end)

		it("keeps the mapped summary source while presenting only its description text", function()
			assert.equals("Arrakis, again.", require("utils.catalog_utils").getDescription(items[4]))
			assert.equals("SERIES: Dune [4]<br />Arrakis, again.", items[4].content)
		end)

		it("leaves a standalone book without a series", function()
			assert.is_nil(items[5].series)
			assert.is_nil(items[5].series_index)
		end)
	end)

	describe("page streaming", function()
		local items

		before_each(function()
			items = from_fixture("komga_pse.xml", "https://komga.example.org/opds/v1.2/series/42")
		end)

		it("offers the download and the stream of a book", function()
			assert.same({
				{
					type = "application/zip",
					href = "https://komga.example.org/api/v1/books/1/file/Volume%201.cbz",
					title = "Volume 1.cbz",
				},
				{
					type = "image/jpeg",
					href = "https://komga.example.org/api/v1/books/1/pages/{pageNumber}?zero_based=true",
					count = 180,
					last_read = 12,
				},
			}, items[1].acquisitions)
		end)

		it("leaves the last read page out when the server has none", function()
			assert.same({
				{
					type = "image/jpeg",
					href = "https://komga.example.org/api/v1/books/2/pages/{pageNumber}?zero_based=true",
					count = 176,
				},
			}, items[2].acquisitions)
		end)

		it("ignores a stream that does not say how many pages it has", function()
			assert.same({}, items[3].acquisitions)
			assert.is_nil(items[3].url)
		end)

		it("shows the cover of a book, even one that is only streamed", function()
			assert.equals("https://komga.example.org/api/v1/books/1/thumbnail", items[1].cover_url)
			assert.equals("https://komga.example.org/api/v1/books/2/thumbnail", items[2].cover_url)
		end)

		it("shows the artwork of a sub-catalog when navigation thumbnails are on", function()
			assert.equals("https://komga.example.org/opds/v1.2/series/43", items[4].url)
			assert.equals("https://komga.example.org/api/v1/series/43/thumbnail", items[4].cover_url)
		end)

		it("hides the artwork of a sub-catalog when navigation thumbnails are off", function()
			local plain = from_fixture("komga_pse.xml", "https://komga.example.org/opds/v1.2/series/42", {
				navigation_thumbnails = false,
			})
			assert.is_nil(plain[4].cover_url)
			assert.equals("https://komga.example.org/api/v1/books/1/thumbnail", plain[1].cover_url)
		end)

		it("shows no cover for an entry that is neither a book nor a sub-catalog", function()
			assert.equals("https://komga.example.org/api/v1/books/3/thumbnail", items[3].thumbnail)
			assert.is_nil(items[3].cover_url)
		end)
	end)

	describe("relative links", function()
		it("resolves them against the URL of the feed, query string included", function()
			local items, _, search = from_fixture("cops_relative_links.xml", "https://cops.example.org/cops/feed.php?page=5")
			assert.equals("https://cops.example.org/cops/fetch.php?data=12&type=epub&id=12", items[1].acquisitions[1].href)
			assert.equals("https://cops.example.org/cops/fetch.php?data=13&type=pdf&id=12", items[1].acquisitions[2].href)
			assert.equals("https://cops.example.org/cops/fetch.php?height=225&id=12", items[1].cover_url)
			assert.equals("https://cops.example.org/cops/feed.php?page=2&id=C", items[2].url)
			assert.equals("https://cops.example.org/cops/feed.php?query=%s", search)
			assert.equals("https://cops.example.org/cops/feed.php?page=5&n=2", items.hrefs.next)
		end)

		it("resolves a root-relative link against the host", function()
			local items = from_xml(entry(acquisition("/dl/1.epub", "application/epub+zip")))
			assert.equals("https://library.example.org/dl/1.epub", items[1].acquisitions[1].href)
		end)

		it("keeps an absolute link on another host", function()
			local items = from_xml(entry(acquisition("https://files.example.net/1.epub", "application/epub+zip")))
			assert.equals("https://files.example.net/1.epub", items[1].acquisitions[1].href)
		end)
	end)

	describe("acquisition links", function()
		it("takes any relation below the acquisition namespace", function()
			local items = from_xml(entry([[
				<link rel="http://opds-spec.org/acquisition/open-access" href="/a.epub" type="application/epub+zip"/>
				<link rel="http://opds-spec.org/acquisition/sample" href="/s.epub" type="application/epub+zip" title="Sample"/>]]))
			assert.same({
				{ type = "application/epub+zip", href = "https://library.example.org/a.epub" },
				{ type = "application/epub+zip", href = "https://library.example.org/s.epub", title = "Sample" },
			}, items[1].acquisitions)
		end)

		it("marks a borrow link without an address", function()
			local items = from_xml(entry('<link rel="http://opds-spec.org/acquisition/borrow" href="/borrow/1" type="application/atom+xml"/>'))
			assert.same({ { type = "borrow" } }, items[1].acquisitions)
		end)

		it("offers a related link whose type KOReader can open", function()
			local items = from_xml(entry('<link rel="related" href="/files/1.epub" type="application/epub+zip" title="EPUB"/>'))
			assert.same({
				{ type = "application/epub+zip", href = "https://library.example.org/files/1.epub", title = "EPUB" },
			}, items[1].acquisitions)
		end)

		it("skips an alternate link even when the type is supported", function()
			local items = from_xml(entry('<link rel="alternate" href="/files/1.epub" type="application/epub+zip"/>'))
			assert.same({}, items[1].acquisitions)
		end)

		it("skips a related link whose type KOReader cannot open", function()
			local items = from_xml(entry('<link rel="related" href="/files/1.xyz" type="application/x-unknown"/>'))
			assert.same({}, items[1].acquisitions)
		end)

		it("ignores a link with neither relation nor title", function()
			local items = from_xml(entry('<link href="/files/1.epub" type="application/epub+zip"/>'))
			assert.same({}, items[1].acquisitions)
		end)
	end)

	describe("PDF links that no other rule took", function()
		it("gets .pdf appended when the address has no extension", function()
			local items = from_xml(entry('<link rel="related" href="/get/5" title="pdf"/>'))
			assert.same({ { type = "pdf", href = "https://library.example.org/get/5.pdf" } }, items[1].acquisitions)
		end)

		it("keeps the query string when it appends .pdf", function()
			local items = from_xml(entry('<link rel="related" href="/get?id=5" title="pdf"/>'))
			assert.equals("https://library.example.org/get.pdf?id=5", items[1].acquisitions[1].href)
		end)

		it("is not added again when the address already ends in .pdf", function()
			local items = from_xml(entry('<link rel="related" href="/get/5.pdf" title="pdf"/>'))
			assert.same({}, items[1].acquisitions)
		end)

		it("is not added when the address ends in /pdf/", function()
			local items = from_xml(entry('<link rel="related" href="/download/5/pdf/" title="pdf"/>'))
			assert.same({}, items[1].acquisitions)
		end)

		it("is not added for a sub-catalog", function()
			local items = from_xml(entry(
				'<link rel="subsection" href="/pdf-books" type="application/atom+xml;profile=opds-catalog" title="pdf"/>'
			))
			assert.same({}, items[1].acquisitions)
			assert.equals("https://library.example.org/pdf-books", items[1].url)
		end)
	end)

	describe("covers", function()
		local IMAGE = '<link rel="http://opds-spec.org/image" href="/img/1.jpg" type="image/jpeg"/>'
		local THUMBNAIL = '<link rel="http://opds-spec.org/image/thumbnail" href="/thumb/1.jpg" type="image/jpeg"/>'
		local DOWNLOAD = acquisition("/dl/1.epub", "application/epub+zip")

		it("uses the thumbnail when both are there", function()
			local items = from_xml(entry(DOWNLOAD .. IMAGE .. THUMBNAIL))
			assert.equals("https://library.example.org/thumb/1.jpg", items[1].cover_url)
		end)

		it("uses the image when the book has no thumbnail", function()
			local items = from_xml(entry(DOWNLOAD .. IMAGE))
			assert.equals("https://library.example.org/img/1.jpg", items[1].cover_url)
		end)

		it("uses the thumbnail when large covers are preferred but there is no image", function()
			local items = from_xml(entry(DOWNLOAD .. THUMBNAIL), { prefer_large_covers = true })
			assert.equals("https://library.example.org/thumb/1.jpg", items[1].cover_url)
		end)

		it("uses the image when large covers are preferred", function()
			local items = from_xml(entry(DOWNLOAD .. IMAGE .. THUMBNAIL), { prefer_large_covers = true })
			assert.equals("https://library.example.org/img/1.jpg", items[1].cover_url)
		end)

		it("understands the older cover relations", function()
			local items = from_xml(entry(DOWNLOAD
				.. '<link rel="x-stanza-cover-image" href="/img/2.jpg" type="image/jpeg"/>'
				.. '<link rel="x-stanza-cover-image-thumbnail" href="/thumb/2.jpg" type="image/jpeg"/>'))
			assert.equals("https://library.example.org/thumb/2.jpg", items[1].cover_url)
		end)

		it("shows nothing for an entry that is neither a book nor a sub-catalog", function()
			local items = from_xml(entry(THUMBNAIL))
			assert.is_nil(items[1].cover_url)
		end)
	end)

	describe("descriptions", function()
		it("takes the content", function()
			local items = from_xml(entry('<content type="text">The content</content>'))
			assert.equals("The content", items[1].content)
		end)

		it("falls back to the summary", function()
			local items = from_xml(entry("<summary>The summary</summary>"))
			assert.equals("The summary", items[1].content)
		end)

		it("prefers the content over the summary", function()
			local items = from_xml(entry('<content type="text">The content</content><summary>The summary</summary>'))
			assert.equals("The content", items[1].content)
		end)

		it("falls back to the summary when the content is empty", function()
			local items = from_xml(entry('<content type="text"/><summary>The summary</summary>'))
			assert.equals("The summary", items[1].content)
		end)

		it("falls back to the summary when the content is only whitespace", function()
			local items = from_xml(entry('<content type="text">  </content><summary>The summary</summary>'))
			assert.equals("The summary", items[1].content)
		end)

		it("has no description when the content is empty and there is no summary", function()
			-- The download and book info dialogs read nil as "no description", so it must not be a table
			local items = from_xml(entry('<content type="text"/>'))
			assert.is_nil(items[1].content)
		end)

		it("keeps the markup of HTML content for the description dialog to convert", function()
			local items = from_xml(entry('<content type="html">&lt;p&gt;One&lt;/p&gt;</content>'))
			assert.equals("<p>One</p>", items[1].content)
		end)
	end)

	describe("titles and authors", function()
		it("names an entry without a title Unknown", function()
			local items = from_xml("<entry><author><name>Ann</name></author></entry>")
			assert.equals("Unknown", items[1].title)
			assert.equals("Unknown - Ann", items[1].text)
		end)

		it("shows just the title for an entry without an author", function()
			local items = from_xml(entry(""))
			assert.equals("Book", items[1].text)
			assert.is_nil(items[1].author)
		end)

		it("reads an XHTML title", function()
			local items = from_xml('<entry><title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">Fancy</div></title></entry>')
			assert.equals("Fancy", items[1].title)
		end)
	end)

	describe("search", function()
		local TEMPLATE = '<link rel="search" href="/search/{searchTerms}" type="application/atom+xml" title="Search"/>'
		local DESCRIPTION = '<link rel="search" href="/osd.xml" type="application/opensearchdescription+xml"/>'

		it("turns an inline template into a URL with %s", function()
			local _, _, search = from_xml(TEMPLATE)
			assert.equals("https://library.example.org/search/%s", search)
			assert.same({}, search_calls)
		end)

		it("prefers the OpenSearch description when the template comes first", function()
			local _, _, search = from_xml(TEMPLATE .. DESCRIPTION)
			assert.equals("https://library.example.org/opds/search?q=%s", search)
		end)

		it("prefers the OpenSearch description when the template comes last", function()
			local _, _, search = from_xml(DESCRIPTION .. TEMPLATE)
			assert.equals("https://library.example.org/opds/search?q=%s", search)
		end)

		it("finds no search in a feed without one", function()
			local _, _, search = from_xml(entry(""))
			assert.is_nil(search)
		end)

		it("gives no search when the OpenSearch description cannot be read", function()
			osd_template = nil
			local _, _, search = from_xml(DESCRIPTION)
			assert.is_nil(search)
		end)

		it("keeps the inline template when the OpenSearch description cannot be read", function()
			osd_template = nil
			local _, _, template_first = from_xml(TEMPLATE .. DESCRIPTION)
			local _, _, template_last = from_xml(DESCRIPTION .. TEMPLATE)
			assert.equals("https://library.example.org/search/%s", template_first)
			assert.equals("https://library.example.org/search/%s", template_last)
		end)

		it("does not look for search or facets while syncing, but still follows the pagination", function()
			local items, facets, search = from_xml(
				TEMPLATE
					.. DESCRIPTION
					.. '<link rel="http://opds-spec.org/facet" href="/f" type="application/atom+xml" title="F"/>'
					.. '<link rel="next" href="/page/2" type="application/atom+xml"/>',
				{ sync = true }
			)
			assert.is_nil(search)
			assert.is_nil(facets)
			assert.same({}, search_calls)
			assert.equals("https://library.example.org/page/2", items.hrefs.next)
		end)
	end)

	describe("facets", function()
		local function facet(href, title, group)
			return string.format(
				'<link rel="http://opds-spec.org/facet" href="%s" title="%s" type="application/atom+xml;profile=opds-catalog"%s/>',
				href,
				title,
				group and (' opds:facetGroup="' .. group .. '"') or ""
			)
		end

		it("groups the facet links by their facet group", function()
			local _, facets = from_xml(facet("/f/fiction", "Fiction", "Genre") .. facet("/f/poetry", "Poetry", "Genre")
				.. facet("/f/en", "English", "Language"))
			assert.equals(2, #facets.Genre)
			assert.equals("Fiction", facets.Genre[1].title)
			assert.equals("/f/poetry", facets.Genre[2].href)
			assert.equals(1, #facets.Language)
		end)

		it("puts a facet without a group under Filters", function()
			local _, facets = from_xml(facet("/f/new", "Newest"))
			assert.equals("Newest", facets.Filters[1].title)
		end)

		it("keeps the counts and the active mark of a facet", function()
			local _, facets = from_xml(
				'<link rel="http://opds-spec.org/facet" href="/f" title="Fiction" thr:count="12" opds:activeFacet="true"'
					.. ' type="application/atom+xml;profile=opds-catalog"/>'
			)
			assert.equals("12", facets.Filters[1]["thr:count"])
			assert.equals("true", facets.Filters[1]["opds:activeFacet"])
		end)

		it("has no facets when the feed sends none", function()
			local _, facets = from_xml(entry(""))
			assert.is_nil(facets)
		end)
	end)
end)
