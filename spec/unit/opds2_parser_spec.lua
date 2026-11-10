local helper = require("helper")
local shims = require("support.json_shims")

describe("OPDS 2.0 parsing", function()
	local OPDSParser

	before_each(function()
		helper.reset()
		helper.stub("rapidjson", shims.rapidjson())
		OPDSParser = helper.load("core.parser")
	end)

	after_each(helper.reset)

	describe("detectFormat", function()
		it("reads the format from the first character of the payload", function()
			assert.equals(OPDSParser.OPDS2, OPDSParser.detectFormat('{"metadata":{}}'))
			assert.equals(OPDSParser.ATOM, OPDSParser.detectFormat("<feed/>"))
		end)

		it("looks past a byte order mark and whitespace", function()
			assert.equals(OPDSParser.OPDS2, OPDSParser.detectFormat('\239\187\191 \n {"a":1}'))
			assert.equals(OPDSParser.ATOM, OPDSParser.detectFormat("\239\187\191\n<feed/>"))
		end)

		it("trusts the payload over the content type", function()
			-- test.opds.io sends OPDS 2.0 as application/json, some servers label Atom as JSON
			assert.equals(OPDSParser.OPDS2, OPDSParser.detectFormat("{}", "application/atom+xml"))
			assert.equals(OPDSParser.ATOM, OPDSParser.detectFormat("<feed/>", "application/opds+json"))
		end)

		it("uses the content type only when the payload gives no hint", function()
			assert.equals(OPDSParser.OPDS2, OPDSParser.detectFormat("", "application/opds+json; charset=utf-8"))
			assert.equals(OPDSParser.ATOM, OPDSParser.detectFormat("", "application/atom+xml"))
			assert.equals(OPDSParser.ATOM, OPDSParser.detectFormat(""))
		end)
	end)

	describe("parse", function()
		it("tags an OPDS 2.0 feed and leaves Atom feeds untagged", function()
			local feed = OPDSParser:parse(helper.fixture("opds2/test_opds_home.json"))
			assert.is_true(OPDSParser.isOpds2(feed))
			assert.equals("OPDS 2.0 Test Catalog", feed.metadata.title)

			local atom = OPDSParser:parse("<feed><title>Atom</title></feed>")
			assert.is_false(OPDSParser.isOpds2(atom))
			assert.is_nil(atom[OPDSParser.FORMAT_KEY])
		end)

		it("parses JSON sent as text with a byte order mark", function()
			local feed = OPDSParser:parse('\239\187\191{"metadata":{"title":"T"}}', "text/plain")
			assert.is_true(OPDSParser.isOpds2(feed))
			assert.equals("T", feed.metadata.title)
		end)

		it("parses an Atom feed with a byte order mark", function()
			local feed = OPDSParser:parse("\239\187\191<feed><title>Atom</title></feed>")
			assert.equals("Atom", feed.feed.title)
		end)

		it("drops the reading parts of every publication, in groups too", function()
			local feed = OPDSParser:parse(helper.fixture("opds2/komga_latest_books.json"))
			for _, publication in ipairs(feed.publications) do
				for _, key in ipairs({ "readingOrder", "resources", "toc", "landmarks", "pageList" }) do
					assert.is_nil(publication[key], key)
				end
				assert.is_table(publication.metadata)
			end

			local catalog = OPDSParser:parse(helper.fixture("opds2/komga_catalog.json"))
			for _, group in ipairs(catalog.groups) do
				for _, publication in ipairs(group.publications or {}) do
					assert.is_nil(publication.readingOrder)
				end
			end
		end)

		it("raises a readable error for broken JSON", function()
			local ok, err = pcall(OPDSParser.parse, OPDSParser, '{"metadata":')
			assert.is_false(ok)
			assert.matches("Cannot read the OPDS 2.0 feed", err)
		end)

		it("raises an error for JSON that is not an object", function()
			local ok, err = pcall(OPDSParser.parse, OPDSParser, "[1, 2]")
			assert.is_false(ok)
			assert.matches("not a JSON object", err)
		end)
	end)
end)
