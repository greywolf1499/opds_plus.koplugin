local helper = require("helper")

describe("OPDSParser", function()
	local OPDSParser

	local function parse(text)
		return OPDSParser:parse(text)
	end

	local function feed_of(body)
		return parse("<feed>" .. body .. "</feed>").feed
	end

	local function titles(entries)
		local result = {}
		for i, entry in ipairs(entries) do
			result[i] = entry.title
		end
		return result
	end

	before_each(function()
		helper.reset()
		OPDSParser = helper.load("core.parser")
	end)

	after_each(helper.reset)

	describe("character references", function()
		it("decodes the five predefined entities", function()
			local feed = feed_of("<title>&lt;a&gt; &amp; &quot;b&quot; &apos;c&apos;</title>")
			assert.equals([[<a> & "b" 'c']], feed.title)
		end)

		it("decodes decimal and hexadecimal references, including beyond the Basic Multilingual Plane", function()
			local feed = feed_of("<title>&#233;&#xE9;|&#x1F600;&#128512;</title>")
			assert.equals("\u{e9}\u{e9}|\u{1F600}\u{1F600}", feed.title)
		end)

		it("decodes references in attribute values, which carry query strings", function()
			local feed = feed_of([[<link href="/x?a=1&amp;b=2" title="A &amp; B"/>]])
			assert.equals("/x?a=1&b=2", feed.link[1].href)
			assert.equals("A & B", feed.link[1].title)
		end)

		it("leaves entities it does not know untouched", function()
			local feed = feed_of("<title>a&nbsp;b &copy;</title>")
			assert.equals("a&nbsp;b &copy;", feed.title)
		end)

		it("leaves a malformed numeric reference as it is instead of failing the whole feed", function()
			local feed = feed_of("<title>a &#xZZ; b &#12abc; c</title>")
			assert.equals("a &#xZZ; b &#12abc; c", feed.title)
		end)
	end)

	describe("structure", function()
		it("collects entry, link, author, meta and Url as lists, even when there is only one", function()
			local feed = parse([[<feed>
				<link rel="self" href="/a"/>
				<author><name>Ann</name></author>
				<entry>
					<title>One</title>
					<meta property="p">v</meta>
				</entry>
			</feed>]]).feed
			assert.equals(1, #feed.link)
			assert.equals(1, #feed.author)
			assert.equals(1, #feed.entry)
			assert.equals(1, #feed.entry[1].meta)

			local description = parse([[<OpenSearchDescription><Url type="t" template="x"/></OpenSearchDescription>]])
			assert.equals(1, #description.OpenSearchDescription.Url)
		end)

		it("keeps only the last occurrence of any other repeated element", function()
			assert.equals("second", feed_of("<title>first</title><title>second</title>").title)
		end)

		it("keeps the prefix of namespaced elements and attributes", function()
			local feed = feed_of([[
				<opensearch:totalResults>42</opensearch:totalResults>
				<entry><link rel="r" pse:count="12" pse:lastRead="3"/></entry>]])
			assert.equals("42", feed["opensearch:totalResults"])
			assert.equals("12", feed.entry[1].link[1]["pse:count"])
			assert.equals("3", feed.entry[1].link[1]["pse:lastRead"])
		end)

		it("reads single-quoted and multi-line attributes", function()
			local feed = feed_of("<link\n\trel='next'\n\thref='/page/2'\n\ttype=\"application/atom+xml\"/>")
			assert.same({ rel = "next", href = "/page/2", type = "application/atom+xml" }, feed.link[1])
		end)

		it("stores the text of a meta element next to its attributes", function()
			local feed = parse(helper.fixture("opds1/series_shapes.xml")).feed
			local metas = feed.entry[3].meta
			assert.same({ property = "belongs-to-collection", id = "series", ["#text"] = "Dune" }, metas[1])
			-- luxl drops the leading "#" of an attribute value, which CatalogUtils relies on when matching refines
			assert.same({ property = "group-position", refines = "series", ["#text"] = "3" }, metas[2])
		end)

		it("turns an element without text into an empty table, never an empty string", function()
			local feed = feed_of("<subtitle/><entry><summary/><content></content></entry>")
			assert.same({}, feed.subtitle)
			assert.same({}, feed.entry[1].summary)
			assert.equals("table", type(feed.entry[1].content))
		end)

		it("keeps the attributes of the XML declaration on the root", function()
			local root = parse('<?xml version="1.0" encoding="UTF-8"?><feed><title>t</title></feed>')
			assert.equals("1.0", root.version)
			assert.equals("UTF-8", root.encoding)
			assert.equals("t", root.feed.title)
		end)
	end)

	describe("entry content", function()
		it("keeps escaped HTML as text", function()
			local feed = feed_of([[<entry><content type="html">&lt;p&gt;A &lt;b&gt;bold&lt;/b&gt; claim&lt;/p&gt;</content></entry>]])
			assert.equals("<p>A <b>bold</b> claim</p>", feed.entry[1].content)
		end)

		it("keeps nested XHTML as one text node", function()
			local feed = parse(helper.fixture("opds1/calibre_content_server.xml")).feed
			local content = feed.entry[1].content
			assert.equals("string", type(content))
			assert.truthy(content:find('<div xmlns="http://www.w3.org/1999/xhtml">', 1, true))
			assert.truthy(content:find("<br />SERIES: Dumas Romances [2.0]<br />", 1, true))
			assert.truthy(content:find("<p>Edmond Dant\u{e8}s is wrongly imprisoned...</p>", 1, true))
			assert.truthy(content:find("<p>A tale of <b>revenge</b> & redemption.</p>", 1, true))
			assert.truthy(content:find("RATING: \u{2605}\u{2605}\u{2605}\u{2605}", 1, true))
		end)

		it("unwraps CDATA", function()
			local feed = feed_of([==[<entry><content type="html"><![CDATA[<p>Hi & <b>bye</b></p>]]></content></entry>]==])
			assert.equals("<p>Hi & <b>bye</b></p>", feed.entry[1].content)
		end)

		it("closes <br> and <hr> written without a slash", function()
			local feed = feed_of([[<entry><content type="html">a<br>b<br/>c<hr>d</content></entry>]])
			assert.equals("a<br />b<br />c<hr />d", feed.entry[1].content)
		end)

		it("keeps quotes and escaped angle brackets inside content", function()
			local feed = feed_of([[<entry><content type="xhtml"><div>say "hi" it's &lt;ok&gt;</div></content></entry>]])
			assert.equals([[<div>say "hi" it's <ok></div>]], feed.entry[1].content)
		end)

		it("does not let a self-closing content tag swallow the entries after it", function()
			local feed = parse(helper.fixture("opds1/navigation_root.xml")).feed
			assert.same({ "Popular", "Latest", "Authors", "Subjects", "About this library" }, titles(feed.entry))
			assert.equals("/opds/new", feed.entry[2].link[1].href)
			assert.equals("Browse by author", feed.entry[3].content)
		end)
	end)

	describe("input quirks", function()
		it("ignores comments and the xml-stylesheet instruction", function()
			local text = '<?xml version="1.0"?><?xml-stylesheet type="text/xsl" href="x.xsl"?>'
				.. "<!-- one --><feed><!-- two --><title>t</title></feed>"
			assert.equals("t", parse(text).feed.title)
		end)

		it("accepts a byte order mark", function()
			assert.equals("T", parse('\239\187\191<?xml version="1.0"?><feed><title>T</title></feed>').feed.title)
		end)

		it("parses the same feed with Windows line endings", function()
			local text = helper.fixture("opds1/calibre_content_server.xml"):gsub("\n", "\r\n")
			local feed = parse(text).feed
			assert.same({ "The Count of Monte Cristo", "Short Stories" }, titles(feed.entry))
			assert.equals("/get/EPUB/17/Library", feed.entry[1].link[1].href)
			assert.truthy(feed.entry[1].content:find("SERIES: Dumas Romances [2.0]", 1, true))
		end)

		it("gives a page that is not a feed no feed", function()
			local root = parse("<html><head><title>502 Bad Gateway</title></head><body><h1>Bad</h1></body></html>")
			assert.is_nil(root.feed)
			assert.equals("502 Bad Gateway", root.html.head.title)
		end)

		it("returns an empty table for text that is not XML", function()
			assert.same({}, parse(""))
			assert.same({}, parse("not xml at all"))
		end)

		it("reads an OpenSearch description", function()
			local description = parse([[<?xml version="1.0" encoding="UTF-8"?>
				<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
					<ShortName>Library</ShortName>
					<Url type="application/atom+xml" template="https://example.org/opds/search?q={searchTerms}&amp;page={startPage?}"/>
					<Url type="text/html" template="https://example.org/search?q={searchTerms}"/>
				</OpenSearchDescription>]]).OpenSearchDescription
			assert.equals("Library", description.ShortName)
			assert.same({
				type = "application/atom+xml",
				template = "https://example.org/opds/search?q={searchTerms}&page={startPage?}",
			}, description.Url[1])
			assert.equals("text/html", description.Url[2].type)
		end)
	end)

	describe("feeds as the servers send them", function()
		it("reads a navigation root", function()
			local feed = parse(helper.fixture("opds1/navigation_root.xml")).feed
			assert.equals("Example Library & Archive", feed.title)
			assert.equals(3, #feed.link)
			assert.equals("application/opensearchdescription+xml", feed.link[3].type)
		end)

		it("reads a Calibre-Web acquisition feed with its pagination and OpenSearch data", function()
			local feed = parse(helper.fixture("opds1/calibre_web_acquisition.xml")).feed
			assert.equals("Calibre-Web", feed.title)
			assert.equals(9, #feed.link)
			assert.equals("5", feed["opensearch:totalResults"])
			assert.equals("2", feed["opensearch:itemsPerPage"])
			assert.equals("Calibre-Web", feed.author[1].name)

			local hobbit = feed.entry[1]
			assert.equals("The Hobbit, or There and Back Again", hobbit.title)
			assert.equals("J. R. R. Tolkien", hobbit.author[1].name)
			assert.equals(6, #hobbit.link)
			assert.equals("eng", hobbit["dcterms:language"])
			assert.equals("Pride & Prejudice", feed.entry[2].title)
		end)

		it("reads every author of a Calibre entry", function()
			local feed = parse(helper.fixture("opds1/calibre_content_server.xml")).feed
			assert.equals(2, #feed.entry[1].author)
			assert.equals("Auguste Maquet", feed.entry[1].author[2].name)
		end)

		it("reads the page-streaming attributes of a Komga entry", function()
			local feed = parse(helper.fixture("opds1/komga_pse.xml")).feed
			assert.equals(4, #feed.entry)
			local stream = feed.entry[1].link[4]
			assert.equals("http://vaemendis.net/opds-pse/stream", stream.rel)
			assert.equals("/api/v1/books/1/pages/{pageNumber}?zero_based=true", stream.href)
			assert.equals("180", stream["pse:count"])
			assert.equals("12", stream["pse:lastRead"])
		end)

		it("reads the relative links and HTML content of a COPS feed", function()
			local feed = parse(helper.fixture("opds1/cops_relative_links.xml")).feed
			local book = feed.entry[1]
			assert.equals("L'\u{c9}tranger", book.title)
			assert.equals("feed.php?page=3&id=4", book.author[1].uri)
			assert.equals("fetch.php?data=12&type=epub&id=12", book.link[1].href)
			assert.equals([[<p class="description">Aujourd'hui, maman est morte.</p>]], book.content)
			assert.equals("feed.php?query={searchTerms}", feed.link[4].href)
		end)
	end)
end)
