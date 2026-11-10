-- The OPDS 2.0 mapper, through NavigationHandler.genItemTableFromCatalog, on trimmed captures of
-- test.opds.io and the Komga demo and on a synthetic feed of edge cases (spec/fixtures/opds2).
local helper = require("helper")
local shims = require("support.json_shims")

describe("OPDS 2.0 mapping", function()
	local NavigationHandler, OPDSParser, make_context
	local search_calls, osd_template, debug_lines

	local BASE = "https://library.example.org/opds2/edge?page=2"

	local function generate(name, base, options)
		local catalog = OPDSParser:parse(helper.fixture("opds2/" .. name))
		debug_lines = {}
		return NavigationHandler.genItemTableFromCatalog(catalog, base or BASE, make_context(options), function(...)
			debug_lines[#debug_lines + 1] = table.concat({ ... }, " ")
		end)
	end

	local function from_json(json, options)
		local catalog = OPDSParser:parse(json)
		return NavigationHandler.genItemTableFromCatalog(catalog, BASE, make_context(options))
	end

	local function texts(items)
		local out = {}
		for i, item in ipairs(items) do
			out[i] = item.text
		end
		return out
	end

	before_each(function()
		helper.reset()
		search_calls = {}
		osd_template = "/opds/search?q=%s"
		helper.stub("rapidjson", shims.rapidjson())
		helper.stub("document/documentregistry", require("support.documentregistry").new())
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

	describe("test.opds.io home", function()
		local HOME = "https://test.opds.io/2.0/home.json"

		it("lists navigation, then groups, then publications", function()
			local items = generate("test_opds_home.json", HOME)
			assert.same({
				"Explore (Navigation Feed)",
				"French Books (Publications Feed)",
				"Third Link",
				"French Classics",
				"More Navigation - French Books",
				"More Navigation - English Books",
				"Moby-Dick - Herman Melville",
			}, texts(items))
		end)

		it("makes a group with a link a folder for that link", function()
			local items = generate("test_opds_home.json", HOME)
			assert.equals("https://test.opds.io/2.0/publications.json", items[4].url)
			assert.same({}, items[4].acquisitions)
		end)

		it("skips a group of inline publications that has no link, saying so in the debug log", function()
			generate("test_opds_home.json", HOME)
			assert.matches("Skipping OPDS 2.0 group without a link: English Classics", table.concat(debug_lines, "\n"))
		end)

		it("gives navigation entries a folder url and no acquisitions", function()
			local items = generate("test_opds_home.json", HOME)
			assert.equals("https://test.opds.io/2.0/navigation.json", items[1].url)
			assert.equals("Explore (Navigation Feed)", items[1].title)
			assert.is_nil(items[1].author)
			assert.same({}, items[1].acquisitions)
		end)

		it("records the self link among the feed links", function()
			local items = generate("test_opds_home.json", HOME)
			assert.equals(HOME, items.hrefs.self)
		end)
	end)

	describe("test.opds.io publications", function()
		local URL = "https://test.opds.io/2.0/publications.json"

		it("maps title, authors, series and description", function()
			local items = generate("test_opds_publications.json", URL)
			assert.equals("Voyage au centre de la Terre - Jules Verne", items[1].text)
			assert.equals("Voyage au centre de la Terre", items[1].title)
			assert.equals("Jules Verne", items[1].author)
			assert.equals("Les classiques SF de Verne", items[1].series)
			assert.equals("5", items[1].series_index)
			assert.matches("^Le professeur Lidenbrock", items[1].content)
			assert.equals("Jules Verne, Second Author", items[3].author)
		end)

		it("lists the acquisition link", function()
			local items = generate("test_opds_publications.json", URL)
			assert.same({ {
				type = "application/epub+zip",
				href = "https://test.opds.io/assets/centredelaterre/file.epub",
			} }, items[1].acquisitions)
		end)

		it("takes the smallest image as thumbnail and the largest as cover", function()
			local items = generate("test_opds_publications.json", URL)
			assert.equals("https://test.opds.io/assets/centredelaterre/small.jpg", items[1].thumbnail)
			assert.equals("https://test.opds.io/assets/centredelaterre/normal.jpg", items[1].image)
			assert.equals(items[1].thumbnail, items[1].cover_url)
			assert.is_true(items[1].lazy_load_cover)
		end)

		it("shows the large image when large covers are preferred", function()
			local items = generate("test_opds_publications.json", URL, { prefer_large_covers = true })
			assert.equals("https://test.opds.io/assets/centredelaterre/normal.jpg", items[1].cover_url)
		end)
	end)

	describe("Komga", function()
		it("reads authors from contributors and trims a whole series position", function()
			local items = generate("komga_latest_books.json", "https://demo.komga.org/opds/v2/libraries/books/latest")
			assert.equals("Moby Dick; Or, The Whale - Herman Melville", items[1].text)
			assert.equals("Moby Dick; Or, The Whale", items[1].series)
			assert.equals("1", items[1].series_index)
		end)

		it("uses the only image, which has neither rel nor size, for both covers", function()
			local items = generate("komga_latest_books.json", "https://demo.komga.org/opds/v2/libraries/books/latest")
			assert.equals("https://demo.komga.org/opds/v2/books/0NW37HGHFP62J/thumbnail", items[1].thumbnail)
			assert.equals(items[1].thumbnail, items[1].image)
		end)

		it("keeps only the file download: the manifest and progression links are not books", function()
			local items = generate("komga_latest_books.json", "https://demo.komga.org/opds/v2/libraries/books/latest")
			assert.same({ {
				type = "application/epub+zip",
				href = "https://demo.komga.org/opds/v2/books/0NW37HGHFP62J/file",
			} }, items[1].acquisitions)
		end)

		it("turns the templated search link into a %s URL", function()
			local _, _, search_url = generate("komga_latest_books.json", "https://demo.komga.org/opds/v2/libraries/books/latest")
			assert.equals("https://demo.komga.org/opds/v2/search?query=%s", search_url)
		end)

		it("flattens navigation groups and makes linked groups folders", function()
			local items = generate("komga_catalog.json", "https://demo.komga.org/opds/v2/catalog")
			local list = texts(items)
			assert.equals("Recommended", list[1])
			assert.truthy(table.concat(list, "|"):find("Libraries - ", 1, true))
			assert.truthy(table.concat(list, "|"):find("Keep Reading", 1, true))
			assert.truthy(table.concat(list, "|"):find("Latest Series - ", 1, true))
		end)
	end)

	describe("edge cases", function()
		it("resolves relative links against the self link and reads rel lists", function()
			local items = generate("edge_cases.json")
			assert.same({
				self = "https://library.example.org/opds2/edge?page=2",
				next = "https://library.example.org/opds2/edge?page=3",
				["http://example.org/rel/other"] = "https://library.example.org/opds2/edge?page=3",
				previous = "https://library.example.org/opds2/edge?page=1",
				first = "https://library.example.org/opds2/edge?page=1",
				last = "https://library.example.org/opds2/edge?page=20",
			}, items.hrefs)
		end)

		it("falls back to the request address without a self link", function()
			local items = from_json('{"links":[{"rel":"next","href":"p3"}]}')
			assert.equals("https://library.example.org/opds2/p3", items.hrefs.next)
		end)

		it("skips self, broken and href-less navigation links, and picks the English title", function()
			local items = generate("edge_cases.json")
			assert.equals("New", items[1].text)
			assert.equals("https://library.example.org/opds2/new", items[1].url)
			assert.equals("Borrowed - Ann Author, Bob Writer", items[2].text)
		end)

		it("picks the UI language of a localized string when there is one", function()
			local items = generate("edge_cases.json")
			assert.equals("Ann Author, Bob Writer", items[2].author)
			local catalog = OPDSParser:parse(helper.fixture("opds2/edge_cases.json"))
			local context = make_context()
			context.language = "fr_FR"
			local french = NavigationHandler.genItemTableFromCatalog(catalog, BASE, context)
			assert.equals("Anne Auteur, Bob Writer", french[2].author)
		end)

		it("skips empty groups and groups of inline publications without a link", function()
			local items = generate("edge_cases.json")
			assert.same({ "New", "Borrowed - Ann Author, Bob Writer", "Unknown - Cee Contributor" }, texts(items))
		end)

		it("groups facets with their counts and marks the active one", function()
			local _, facets = generate("edge_cases.json")
			assert.same({
				Genre = {
					{
						title = "Science fiction",
						href = "https://library.example.org/opds2/edge?genre=sf",
						["thr:count"] = "12",
						["opds:activeFacet"] = "true",
					},
					{
						title = "Fantasy",
						href = "https://library.example.org/opds2/edge?genre=fantasy",
						["thr:count"] = "8",
					},
				},
				Filters = {
					{ title = "Newest", href = "https://library.example.org/opds2/edge?sort=new" },
				},
			}, facets)
		end)

		it("maps borrow, indirect and other readable links, and leaves out the web page", function()
			local items = generate("edge_cases.json")
			assert.same({
				{ type = "borrow" },
				{ type = "application/epub+zip", href = "https://library.example.org/adept/1" },
				{ type = "application/vnd.comicbook+zip", href = "https://library.example.org/files/1.cbz", title = "Comic" },
			}, items[2].acquisitions)
		end)

		it("prefers images by rel over their order", function()
			local items = generate("edge_cases.json")
			assert.equals("https://library.example.org/img/1-thumb.jpg", items[2].thumbnail)
			assert.equals("https://library.example.org/img/1-cover.jpg", items[2].image)
		end)

		it("keeps a fractional series position and reads a collection that has one", function()
			local items = generate("edge_cases.json")
			assert.equals("Saga", items[2].series)
			assert.equals("2.5", items[2].series_index)
			assert.equals("Box set", items[3].series)
			assert.equals("3", items[3].series_index)
		end)

		it("ignores a collection without a position", function()
			local items = generate("test_opds_publications.json", "https://test.opds.io/2.0/publications.json")
			assert.equals("Les classiques SF de Verne", items[1].series)
			local plain = from_json('{"publications":[{"metadata":{"title":"T","belongsTo":{"collection":"Domaine Public"}}}]}')
			assert.is_nil(plain[1].series)
		end)

		it("falls back to the default title for a null one and keeps the HTML description", function()
			local items = generate("edge_cases.json")
			assert.equals("Unknown", items[3].title)
			assert.equals("<p>A <b>borrowed</b> book.</p>", items[2].content)
			assert.is_nil(items[3].cover_url)
		end)

		it("expands the templated search link with only the search terms", function()
			local _, _, search_url = generate("edge_cases.json")
			assert.equals("https://library.example.org/opds2/search?query=%s", search_url)
			assert.same({}, search_calls)
		end)

		it("reads an OpenSearch description in preference to a template", function()
			local _, _, search_url = from_json([[{"links":[
				{"rel":"search","href":"/opds2/s{?query}","type":"application/opds+json","templated":true},
				{"rel":"search","href":"/osd.xml","type":"application/opensearchdescription+xml"}]}]])
			assert.equals(1, #search_calls)
			assert.equals("https://library.example.org/osd.xml", search_calls[1][1])
			assert.equals("https://library.example.org/opds/search?q=%s", search_url)
		end)

		it("offers no search or facets while syncing", function()
			local items, facets, search_url = generate("edge_cases.json", nil, { sync = true })
			assert.is_nil(facets)
			assert.is_nil(search_url)
			assert.equals("https://library.example.org/opds2/edge?page=3", items.hrefs.next)
		end)
	end)
end)
