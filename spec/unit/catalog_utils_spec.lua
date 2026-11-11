local helper = require("helper")

describe("CatalogUtils", function()
	local CatalogUtils

	before_each(function()
		helper.reset()
		CatalogUtils = helper.load("utils.catalog_utils")
	end)

	after_each(helper.reset)

	-- Series name and index as a list, so a missing index shows up as a shorter list
	local function seriesOf(entry)
		return { CatalogUtils.parseEntrySeries(entry) }
	end

	describe("buildRootEntry", function()
		it("builds the menu entry from the settings of a catalog", function()
			local headers = { { name = "X-Api-Key", value = "k" } }
			local entry = CatalogUtils.buildRootEntry({
				title = "My Library",
				url = "https://example.org/opds",
				username = "ann",
				password = "secret",
				raw_names = true,
				headers = headers,
				sync = false,
			})
			assert.same({
				text = "My Library",
				mandatory = "\u{f2c0}",
				url = "https://example.org/opds",
				username = "ann",
				password = "secret",
				raw_names = true,
				headers = headers,
				searchable = false,
				sync = false,
			}, entry)
		end)

		it("leaves out what the catalog does not have", function()
			local entry = CatalogUtils.buildRootEntry({ title = "Bare", url = "http://example.org/opds" })
			assert.same({ text = "Bare", mandatory = "", url = "http://example.org/opds", searchable = false }, entry)
		end)

		it("marks a catalog as searchable only when its URL has a %s placeholder", function()
			local function searchable(url)
				return CatalogUtils.buildRootEntry({ title = "t", url = url }).searchable
			end
			assert.is_true(searchable("https://example.org/search?q=%s"))
			assert.is_false(searchable("https://example.org/opds"))
			assert.is_false(searchable("https://example.org/a%20b"))
			assert.is_false(searchable(nil))
		end)

		it("shows a lock for a catalog with a username", function()
			local entry = CatalogUtils.buildRootEntry({ title = "t", url = "u", username = "ann" })
			assert.equals("\u{f2c0}", entry.mandatory)
		end)

		it("shows a sync icon for a catalog that syncs", function()
			local entry = CatalogUtils.buildRootEntry({ title = "t", url = "u", sync = true })
			assert.equals("\u{f46a} ", entry.mandatory)
		end)

		it("shows the sync icon before the lock when a catalog has both", function()
			local entry = CatalogUtils.buildRootEntry({ title = "t", url = "u", username = "ann", sync = true })
			assert.equals("\u{f46a} \u{f2c0}", entry.mandatory)
		end)
	end)

	describe("parseEntryTitle", function()
		it("returns a plain title as it is", function()
			assert.equals("Dune", CatalogUtils.parseEntryTitle("Dune"))
		end)

		it("returns the text inside the div of an XHTML title", function()
			assert.equals("Div Title", CatalogUtils.parseEntryTitle({ type = "xhtml", div = "Div Title" }))
		end)

		it("returns the default for a missing title", function()
			assert.equals("Unknown", CatalogUtils.parseEntryTitle(nil))
			assert.equals("Untitled", CatalogUtils.parseEntryTitle(nil, "Untitled"))
			assert.equals("Untitled", CatalogUtils.parseEntryTitle(42, "Untitled"))
		end)

		it("returns the default for an empty <title></title>", function()
			-- core/parser.lua turns an element without text and attributes into an empty table
			assert.equals("Untitled", CatalogUtils.parseEntryTitle({}, "Untitled"))
		end)

		it("returns the default for an XHTML title whose div is an empty string", function()
			assert.equals("Untitled", CatalogUtils.parseEntryTitle({ type = "xhtml", div = "" }, "Untitled"))
		end)

		-- core/parser.lua turns <title type="text"/> into { type = "text" }
		it("returns the default for a typed title without text", function()
			assert.equals("Untitled", CatalogUtils.parseEntryTitle({ type = "text" }, "Untitled"))
		end)

		-- core/parser.lua turns <title type="xhtml"><div xmlns="..."></div></title> into this table
		it("returns the default for an XHTML title with an empty div", function()
			local title = { type = "xhtml", div = { xmlns = "http://www.w3.org/1999/xhtml" } }
			assert.equals("Untitled", CatalogUtils.parseEntryTitle(title, "Untitled"))
		end)

		-- Atom only allows child elements in a title of type="xhtml"
		it("returns the default for a div in a title without a type", function()
			assert.equals("Untitled", CatalogUtils.parseEntryTitle({ div = "Dune" }, "Untitled"))
		end)

		it("never returns anything but a string", function()
			for _, title in ipairs({ { type = "text" }, { type = "xhtml", div = {} }, { type = "xhtml", div = 7 }, true, 3.5 }) do
				assert.equals("string", type(CatalogUtils.parseEntryTitle(title, "Untitled")))
			end
		end)
	end)

	describe("parseEntryAuthor", function()
		it("returns the name of a single author element", function()
			assert.equals("Ann", CatalogUtils.parseEntryAuthor({ name = "Ann" }))
		end)

		it("returns the name of a list with one author", function()
			assert.equals("Ann", CatalogUtils.parseEntryAuthor({ { name = "Ann" } }))
		end)

		it("joins the names of several author elements in order", function()
			assert.equals("Ann, Bob, Cy", CatalogUtils.parseEntryAuthor({ { name = "Ann" }, { name = "Bob" }, { name = "Cy" } }))
		end)

		it("skips author elements without a usable name", function()
			local authors = { { name = "Ann" }, { uri = "https://example.org/bob" }, "junk", { name = {} }, { name = "Cy" } }
			assert.equals("Ann, Cy", CatalogUtils.parseEntryAuthor(authors))
		end)

		it("joins several names inside one author element", function()
			assert.equals("Ann, Bob", CatalogUtils.parseEntryAuthor({ name = { "Ann", "Bob" } }))
			assert.equals("A, B, C", CatalogUtils.parseEntryAuthor({ { name = { "A", "B" } }, { name = "C" } }))
		end)

		it("returns nil rather than the default when there is no usable author", function()
			local default = "Unknown Author"
			assert.is_nil(CatalogUtils.parseEntryAuthor(nil, default))
			assert.is_nil(CatalogUtils.parseEntryAuthor({}, default))
			assert.is_nil(CatalogUtils.parseEntryAuthor({ name = {} }, default))
			assert.is_nil(CatalogUtils.parseEntryAuthor({ { uri = "x" }, "junk" }, default))
			assert.is_nil(CatalogUtils.parseEntryAuthor("Ann", default))
		end)

		it("returns the default for a name that is neither text nor a list", function()
			assert.equals("Unknown Author", CatalogUtils.parseEntryAuthor({ name = 5 }))
			assert.equals("Anonymous", CatalogUtils.parseEntryAuthor({ { name = 5 } }, "Anonymous"))
		end)
	end)

	describe("parseEntryDetails", function()
		it("reads publisher, issue date and language from Dublin Core elements", function()
			assert.same({ "Allen & Unwin", "1937-09-21", "eng" }, { CatalogUtils.parseEntryDetails({
				["dcterms:publisher"] = " Allen & Unwin ",
				["dcterms:issued"] = "1937-09-21T00:00:00+00:00",
				["dcterms:language"] = "eng",
			}) })
			assert.same({ "Penguin", "1813", "en" }, { CatalogUtils.parseEntryDetails({
				["dc:publisher"] = "Penguin",
				["dc:issued"] = "1813",
				["dc:language"] = "en",
			}) })
		end)

		it("reads a publisher that holds a name, and skips blank or odd values", function()
			assert.same({ "Feedbooks" }, { CatalogUtils.parseEntryDetails({ publisher = { name = "Feedbooks" } }) })
			assert.same({}, { CatalogUtils.parseEntryDetails({ ["dc:publisher"] = " ", ["dc:language"] = {} }) })
		end)
	end)

	describe("parseEntrySeries", function()
		it("returns nothing for an entry without a series", function()
			assert.same({}, seriesOf({}))
			assert.same({}, seriesOf({ title = "Standalone", content = "A plain description", summary = "Short" }))
		end)

		describe("from dc: elements", function()
			it("reads <dc:series> and <dc:series_index> (Calibre-Web-Automated)", function()
				assert.same({ "Dune", "2" }, seriesOf({ ["dc:series"] = "Dune", ["dc:series_index"] = "2" }))
			end)

			it("reads <dc:seriesPosition> (dir2opds)", function()
				assert.same({ "Dune", "2" }, seriesOf({ ["dc:series"] = "Dune", ["dc:seriesPosition"] = "2" }))
			end)

			it("prefers <dc:series_index> when an entry has both kinds of index", function()
				local entry = { ["dc:series"] = "Dune", ["dc:series_index"] = "5", ["dc:seriesPosition"] = "9" }
				assert.same({ "Dune", "5" }, seriesOf(entry))
			end)

			it("trims the name and the index", function()
				assert.same({ "Dune", "2" }, seriesOf({ ["dc:series"] = "  Dune\n", ["dc:series_index"] = " 2 " }))
			end)

			it("returns the name alone when the index is missing or blank", function()
				assert.same({ "Dune" }, seriesOf({ ["dc:series"] = "Dune" }))
				assert.same({ "Dune" }, seriesOf({ ["dc:series"] = "Dune", ["dc:series_index"] = "   " }))
			end)

			it("ignores an index when there is no series name", function()
				assert.same({}, seriesOf({ ["dc:series_index"] = "2" }))
			end)

			it("moves on to the other sources when the name is blank or not text", function()
				local content = "SERIES: Dune [3]"
				assert.same({ "Dune", "3" }, seriesOf({ ["dc:series"] = "   ", content = content }))
				assert.same({ "Dune", "3" }, seriesOf({ ["dc:series"] = {}, content = content }))
			end)
		end)

		describe("from EPUB3 collection metadata (Grimmory)", function()
			it("reads the collection name and the position that refines it", function()
				local entry = {
					meta = {
						{ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" },
						{ property = "group-position", refines = "series", ["#text"] = "3" },
					},
				}
				assert.same({ "Dune", "3" }, seriesOf(entry))
			end)

			it("accepts refines with a leading #", function()
				local entry = {
					meta = {
						{ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" },
						{ property = "group-position", refines = "#series", ["#text"] = "3" },
					},
				}
				assert.same({ "Dune", "3" }, seriesOf(entry))
			end)

			it("finds the position before or after the collection", function()
				local entry = {
					meta = {
						{ property = "group-position", refines = "series", ["#text"] = "3" },
						{ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" },
					},
				}
				assert.same({ "Dune", "3" }, seriesOf(entry))
			end)

			it("uses the first collection together with its own position", function()
				local entry = {
					meta = {
						{ property = "belongs-to-collection", id = "first", ["#text"] = "Dune" },
						{ property = "belongs-to-collection", id = "second", ["#text"] = "Arrakis Saga" },
						{ property = "group-position", refines = "second", ["#text"] = "9" },
						{ property = "group-position", refines = "first", ["#text"] = "3" },
					},
				}
				assert.same({ "Dune", "3" }, seriesOf(entry))
			end)

			it("returns the name alone when no position refines the collection", function()
				local entry = {
					meta = {
						{ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" },
						{ property = "group-position", refines = "other", ["#text"] = "3" },
						{ property = "group-position", ["#text"] = "4" },
					},
				}
				assert.same({ "Dune" }, seriesOf(entry))
			end)

			it("returns the name alone when the collection has no id", function()
				local entry = {
					meta = {
						{ property = "belongs-to-collection", ["#text"] = "Dune" },
						{ property = "group-position", refines = "series", ["#text"] = "3" },
					},
				}
				assert.same({ "Dune" }, seriesOf(entry))
			end)

			it("ignores other properties and entries that are not tables", function()
				local entry = {
					meta = {
						"junk",
						{ property = "title-type", ["#text"] = "main" },
						{ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" },
					},
				}
				assert.same({ "Dune" }, seriesOf(entry))
			end)

			it("reads the position from group-position, not from other refinements of the collection", function()
				local entry = {
					meta = {
						{ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" },
						{ property = "collection-type", refines = "#series", ["#text"] = "series" },
						{ property = "group-position", refines = "#series", ["#text"] = "3" },
					},
				}
				assert.same({ "Dune", "3" }, seriesOf(entry))
			end)

			it("ignores a collection without a name", function()
				local entry = {
					meta = { { property = "belongs-to-collection", id = "series", ["#text"] = "  " } },
					content = "SERIES: Dune [3]",
				}
				assert.same({ "Dune", "3" }, seriesOf(entry))
			end)

			it("skips a collection without a name for the next one", function()
				local entry = {
					meta = {
						{ property = "belongs-to-collection", id = "empty" },
						{ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" },
						{ property = "group-position", refines = "series", ["#text"] = "3" },
					},
				}
				assert.same({ "Dune", "3" }, seriesOf(entry))
			end)

			it("returns nothing when the metadata is not a list", function()
				assert.same({}, seriesOf({ meta = "Dune" }))
			end)

			it("keeps the name from the metadata even when it has no position", function()
				local entry = {
					meta = { { property = "belongs-to-collection", id = "series", ["#text"] = "Dune" } },
					content = "SERIES: Other [3]",
				}
				assert.same({ "Dune" }, seriesOf(entry))
			end)
		end)

		describe("from the SERIES line of the content or summary (Calibre, Calibre-Web)", function()
			it("reads the name and the index", function()
				assert.same({ "Dune", "3" }, seriesOf({ content = "SERIES: Dune [3]" }))
			end)

			it("reads the line in the markup Calibre writes", function()
				local content = '<div xmlns="http://www.w3.org/1999/xhtml">RATING: ****<br />TAGS: Adventure, Classics'
					.. "<br />SERIES: Dumas Romances [2.0]<br /><p>Edmond is wrongly imprisoned...</p></div>"
				assert.same({ "Dumas Romances", "2" }, seriesOf({ content = content }))
			end)

			it("reads a line that comes right after the opening div", function()
				local content = '<div xmlns="http://www.w3.org/1999/xhtml">SERIES: Dune [3]<br /><p>Arrakis.</p></div>'
				assert.same({ "Dune", "3" }, seriesOf({ content = content }))
			end)

			it("reads a line that is indented or follows a line break in the source", function()
				assert.same({ "Dune", "3" }, seriesOf({ content = "RATING: ****<br />\n\t  SERIES: Dune [3]<br />" }))
			end)

			it("stops the name at the next tag", function()
				assert.same({ "Dune", "3" }, seriesOf({ content = "SERIES: Dune [3]</p>" }))
				assert.same({ "Dune" }, seriesOf({ content = "SERIES: Dune</p>" }))
			end)

			it("reads the summary when the content has no series", function()
				local entry = { content = "A plain description", summary = "SERIES: Dune [4]<br />Arrakis, again." }
				assert.same({ "Dune", "4" }, seriesOf(entry))
			end)

			it("reads the summary when the content is an empty element", function()
				assert.same({ "Dune", "4" }, seriesOf({ content = {}, summary = "SERIES: Dune [4]" }))
			end)

			it("accepts <br/> and <br> as line breaks", function()
				assert.same({ "Dune", "3" }, seriesOf({ content = "RATING: ****<br/>SERIES: Dune [3]" }))
				assert.same({ "Dune", "3" }, seriesOf({ content = "RATING: ****<br>SERIES: Dune [3]" }))
			end)

			it("reads a line up to the third and no further", function()
				assert.same({ "Dune", "3" }, seriesOf({ content = "RATING: ****<br />TAGS: Sci-Fi<br />SERIES: Dune [3]" }))
				assert.same({}, seriesOf({ content = "a<br />b<br />c<br />SERIES: Dune [3]" }))
			end)

			it("returns the name alone when the line has no index", function()
				assert.same({ "Dune" }, seriesOf({ content = "SERIES: Dune" }))
			end)

			it("keeps brackets that do not hold a number as part of the name", function()
				assert.same({ "Dune [Extra]" }, seriesOf({ content = "SERIES: Dune [Extra]" }))
				assert.same({ "Dune [Book]", "3" }, seriesOf({ content = "SERIES: Dune [Book] [3]" }))
			end)

			it("reads an index only at the end of the line", function()
				assert.same({ "Dune [3] Extra" }, seriesOf({ content = "SERIES: Dune [3] Extra" }))
			end)

			it("ignores a SERIES line without a name", function()
				assert.same({}, seriesOf({ content = "SERIES:" }))
				assert.same({}, seriesOf({ content = "SERIES:   <br />text" }))
				assert.same({}, seriesOf({ content = "SERIES: [3]" }))
			end)

			it("moves on to the summary when the line has an index but no name", function()
				assert.same({ "Dune", "4" }, seriesOf({ content = "SERIES: [3]", summary = "SERIES: Dune [4]" }))
			end)

			it("only reads SERIES in capitals at the start of a line", function()
				assert.same({}, seriesOf({ content = "Just text SERIES: Dune [3]" }))
				assert.same({}, seriesOf({ content = "series: Dune [3]" }))
			end)

			it("ignores content that is not text", function()
				assert.same({}, seriesOf({ content = {} }))
				assert.same({}, seriesOf({ content = 5, summary = 6 }))
			end)
		end)

		describe("when an entry has several sources", function()
			local function sources()
				return {
					["dc:series"] = "From elements",
					["dc:series_index"] = "1",
					meta = {
						{ property = "belongs-to-collection", id = "s", ["#text"] = "From meta" },
						{ property = "group-position", refines = "s", ["#text"] = "2" },
					},
					content = "SERIES: From content [3]",
					summary = "SERIES: From summary [4]",
				}
			end

			it("prefers the dc: elements", function()
				assert.same({ "From elements", "1" }, seriesOf(sources()))
			end)

			it("prefers the metadata to the content", function()
				local entry = sources()
				entry["dc:series"] = nil
				assert.same({ "From meta", "2" }, seriesOf(entry))
			end)

			it("prefers the content to the summary", function()
				local entry = sources()
				entry["dc:series"], entry.meta = nil, nil
				assert.same({ "From content", "3" }, seriesOf(entry))
			end)

			it("falls back to the summary", function()
				local entry = sources()
				entry["dc:series"], entry.meta, entry.content = nil, nil, nil
				assert.same({ "From summary", "4" }, seriesOf(entry))
			end)
		end)

		describe("index", function()
			local function indexOf(raw)
				return select(2, CatalogUtils.parseEntrySeries({ ["dc:series"] = "Dune", ["dc:series_index"] = raw }))
			end

			it("drops a fractional part that is only zeros", function()
				local cases = { { "20.0", "20" }, { "20.00", "20" }, { "3.", "3" }, { "100.0", "100" }, { "0.0", "0" } }
				for _, case in ipairs(cases) do
					assert.equals(case[2], indexOf(case[1]), case[1])
				end
			end)

			it("drops trailing zeros of a real fraction", function()
				assert.equals("3.5", indexOf("3.50"))
				assert.equals("12.1", indexOf("12.100"))
			end)

			it("keeps whole numbers and other fractions as they are", function()
				for _, raw in ipairs({ "10", "100", "0", "7", "2.5", "1.05" }) do
					assert.equals(raw, indexOf(raw), raw)
				end
			end)

			it("keeps text that is not a plain number as it is", function()
				for _, raw in ipairs({ "007", "1e3", "1.0.0", "III", "2a" }) do
					assert.equals(raw, indexOf(raw), raw)
				end
			end)

			it("normalises the index read from the SERIES line too", function()
				assert.equals("2", select(2, CatalogUtils.parseEntrySeries({ content = "SERIES: Dune [2.0]" })))
			end)

			it("is nil when blank or not text", function()
				assert.is_nil(indexOf("   "))
				assert.is_nil(indexOf({}))
			end)
		end)
	end)

	describe("extractPSEStreamInfo", function()
		it("normalizes Kavita cursors without advancing completed chapters", function()
			local href = "https://library.example/proxy/api/opds/secret/image?chapterId=42&pageNumber={pageNumber}"
			for _, case in ipairs({ { 0, 1 }, { 1, 2 }, { 6, 7 }, { 7, 7 }, { 99, 7 } }) do
				local count, page = CatalogUtils.extractPSEStreamInfo({
					href = href, ["pse:count"] = "7", ["pse:lastRead"] = tostring(case[1]),
				})
				assert.equals(7, count)
				assert.equals(case[2], page)
			end
		end)

		it("uses the resolved Kavita URL but leaves standard and malformed positions alone", function()
			local link = { href = "image?chapterId=42", ["pse:count"] = "7", ["pse:lastRead"] = "3" }
			local base = "https://library.example/proxy/api/opds/secret/"
			assert.equals(4, select(2, CatalogUtils.extractPSEStreamInfo(link, base .. link.href)))
			for _, href in ipairs({
				"https://library.example/opds/v1.2/books/book/pages/{pageNumber}",
				"https://library.example/stream?next=/api/opds/secret/image?chapterId=42",
				base .. "image?chapterId=invalid",
			}) do
				assert.equals(3, select(2, CatalogUtils.extractPSEStreamInfo(link, href)))
			end
			for _, value in ipairs({ -1, 1.5, "invalid", math.huge }) do
				link["pse:lastRead"] = value
				assert.is_nil(select(2, CatalogUtils.extractPSEStreamInfo(link, base .. link.href)))
			end
			link["pse:lastRead"] = nil
			assert.is_nil(select(2, CatalogUtils.extractPSEStreamInfo(link, base .. link.href)))
		end)

		it("reads the page count and the last page read", function()
			local link = { href = "/stream/{pageNumber}", ["pse:count"] = "12", ["pse:lastRead"] = "3" }
			local count, last_read = CatalogUtils.extractPSEStreamInfo(link)
			assert.equals(12, count)
			assert.equals(3, last_read)
		end)

		it("accepts any namespace prefix", function()
			local count, last_read = CatalogUtils.extractPSEStreamInfo({ ["foo:count"] = "7", ["bar:lastRead"] = "2" })
			assert.equals(7, count)
			assert.equals(2, last_read)
		end)

		it("reads the count alone", function()
			local count, last_read = CatalogUtils.extractPSEStreamInfo({ ["pse:count"] = "12" })
			assert.equals(12, count)
			assert.is_nil(last_read)
		end)

		it("rejects unusable counts and bounds whole-number resume positions", function()
			for _, count in ipairs({ 0, -1, 1.5, math.huge, "many" }) do
				assert.is_nil(CatalogUtils.extractPSEStreamInfo({ ["pse:count"] = count }))
			end
			assert.same({ 12, 12 }, { CatalogUtils.extractPSEStreamInfo({
				["pse:count"] = "12", ["pse:lastRead"] = "99",
			}) })
			assert.same({ 12 }, { CatalogUtils.extractPSEStreamInfo({
				["pse:count"] = 12, ["pse:lastRead"] = 2.5,
			}) })
		end)

		it("returns nil for a last page read that is zero or negative", function()
			local count, last_read = CatalogUtils.extractPSEStreamInfo({ ["pse:count"] = "12", ["pse:lastRead"] = "0" })
			assert.equals(12, count)
			assert.is_nil(last_read)
			assert.is_nil(select(2, CatalogUtils.extractPSEStreamInfo({ ["pse:lastRead"] = "-3" })))
		end)

		it("returns nil for values that are not numbers", function()
			local count, last_read = CatalogUtils.extractPSEStreamInfo({ ["pse:count"] = "many", ["pse:lastRead"] = "" })
			assert.is_nil(count)
			assert.is_nil(last_read)
		end)

		it("ignores keys that only look like the PSE attributes", function()
			local link = { count = "5", lastRead = "5", ["pse:counter"] = "5", ["pse:lastReadDate"] = "5" }
			local count, last_read = CatalogUtils.extractPSEStreamInfo(link)
			assert.is_nil(count)
			assert.is_nil(last_read)
		end)

		it("returns nil for a link without PSE attributes", function()
			local count, last_read = CatalogUtils.extractPSEStreamInfo({ rel = "x", href = "/y", type = "image/jpeg" })
			assert.is_nil(count)
			assert.is_nil(last_read)
		end)
	end)

	describe("getDescription", function()
		it("returns an empty string when the entry has no text content", function()
			assert.equals("", CatalogUtils.getDescription({}))
			assert.equals("", CatalogUtils.getDescription({ content = {} }))
			assert.equals("", CatalogUtils.getDescription({ content = 5 }))
		end)

		it("returns plain text as it is", function()
			assert.equals("A plain description.", CatalogUtils.getDescription({ content = "A plain description." }))
		end)

		it("turns HTML into plain text", function()
			assert.equals("Hello World", CatalogUtils.getDescription({ content = "<p>Hello <b>World</b></p>" }))
			assert.equals("Line1\nLine2", CatalogUtils.getDescription({ content = "Line1<br />Line2" }))
			assert.equals("Tom & Jerry", CatalogUtils.getDescription({ content = "<p>Tom &amp; Jerry</p>" }))
		end)

		it("turns HTML that was escaped once more into plain text", function()
			assert.equals("Hi", CatalogUtils.getDescription({ content = "&lt;p&gt;Hi&lt;/p&gt;" }))
		end)

		it("removes the matching metadata line without changing the source or surrounding fields", function()
			local content = '<div xmlns="http://www.w3.org/1999/xhtml">RATING: ****<br />TAGS: Sci-Fi'
				.. "<br />SERIES: Dune [3.00]<br /><p>Arrakis &amp; <em>spice</em>.</p></div>"
			local entry = { content = content, series = "Dune", series_index = "3" }
			assert.equals("RATING: ****\nTAGS: Sci-Fi\n\tArrakis & spice.", CatalogUtils.getDescription(entry))
			assert.equals(content, entry.content)
		end)

		it("handles the recognized break forms, escaped names and metadata-only descriptions", function()
			for _, br in ipairs({ "<br>", "<br/>", "<br />" }) do
				assert.equals("A cat and a mouse.", CatalogUtils.getDescription({
					content = "<div>SERIES: Tom &amp; Jerry [2.50]" .. br .. "A cat and a mouse.</div>",
					series = "Tom & Jerry", series_index = "2.5",
				}))
			end
			assert.equals("", CatalogUtils.getDescription({ content = "SERIES: Dune", series = "Dune" }))
		end)

		it("keeps mismatched, undisplayed and malformed series metadata", function()
			for _, entry in ipairs({
				{ content = "SERIES: Dune [3]", series = "Other", series_index = "3" },
				{ content = "SERIES: Dune [3]", series = "Dune", series_index = "4" },
				{ content = "SERIES: Dune [3]", series = "Dune" },
				{ content = "SERIES: Dune [3]" },
				{ content = "SERIES: Dune [3..5]", series = "Dune", series_index = "3..5" },
				{ content = "SERIES: [3]", series = "Dune", series_index = "3" },
			}) do
				assert.equals(entry.content, CatalogUtils.getDescription(entry))
			end
		end)

		it("does not mistake prose or later fields for a metadata prefix", function()
			for _, content in ipairs({
				"A story about SERIES: Dune [3]",
				"A novel.<br />SERIES: Dune [3]",
				"RATING: ****\nA novel.<br />SERIES: Dune [3]",
				"RATING: ****<br />TAGS: Sci-Fi<br />Notes<br />SERIES: Dune [3]",
				"SERIES: Dune [3]<em> is the topic of this essay.</em>",
				"SERIES: Dune [3]\nThe story must not disappear.",
			}) do
				assert.equals(require("util").htmlToPlainTextIfHtml(content), CatalogUtils.getDescription({
					content = content, series = "Dune", series_index = "3",
				}))
			end
		end)
	end)
end)
