local helper = require("helper")

describe("UrlUtils", function()
	local UrlUtils

	before_each(function()
		helper.reset()
		UrlUtils = helper.load("utils.url_utils")
	end)

	after_each(helper.reset)

	describe("buildAbsolute", function()
		local base = "https://example.org/opds/catalog/index.xml?page=1"

		it("resolves a root-relative path", function()
			assert.equals("https://example.org/cover/1.jpg", UrlUtils.buildAbsolute(base, "/cover/1.jpg"))
		end)

		it("resolves a path relative to the base directory", function()
			assert.equals("https://example.org/opds/catalog/sub.xml", UrlUtils.buildAbsolute(base, "sub.xml"))
		end)

		it("resolves parent directory segments", function()
			assert.equals("https://example.org/opds/other.xml", UrlUtils.buildAbsolute(base, "../other.xml"))
		end)

		it("resolves a protocol-relative URL with the scheme of the base", function()
			assert.equals("https://cdn.example.org/a.epub", UrlUtils.buildAbsolute(base, "//cdn.example.org/a.epub"))
		end)

		it("resolves a query-only href against the base path", function()
			assert.equals("https://example.org/opds/catalog/index.xml?page=2", UrlUtils.buildAbsolute(base, "?page=2"))
		end)

		it("returns an absolute href unchanged", function()
			assert.equals("http://other.test/x", UrlUtils.buildAbsolute(base, "http://other.test/x"))
		end)
	end)

	describe("extractFilename", function()
		it("takes the last path segment", function()
			assert.equals("book.epub", UrlUtils.extractFilename("https://example.org/dl/42/book.epub"))
		end)

		it("ignores the query string and the fragment", function()
			assert.equals("book.epub", UrlUtils.extractFilename("https://example.org/dl/book.epub?token=a/b#top"))
		end)

		it("decodes percent escapes", function()
			assert.equals("Les Misérables.epub", UrlUtils.extractFilename("https://example.org/Les%20Mis%C3%A9rables.epub"))
		end)

		it("returns an empty name for a URL that ends in a slash", function()
			assert.equals("", UrlUtils.extractFilename("https://example.org/dl/"))
		end)
	end)

	describe("parseContentDisposition", function()
		it("reads a quoted filename", function()
			assert.equals("My Book.epub", UrlUtils.parseContentDisposition('attachment; filename="My Book.epub"'))
		end)

		it("reads an unquoted filename that is followed by other parameters", function()
			assert.equals("book.epub", UrlUtils.parseContentDisposition("attachment; filename=book.epub; size=12"))
		end)

		it("decodes percent escapes", function()
			assert.equals("a b.epub", UrlUtils.parseContentDisposition('attachment; filename="a%20b.epub"'))
		end)

		it("prefers the quoted filename when both forms are present", function()
			assert.equals("plain.epub", UrlUtils.parseContentDisposition('attachment; filename="plain.epub"; filename=other.epub'))
		end)

		it("returns nil without a filename parameter", function()
			assert.is_nil(UrlUtils.parseContentDisposition("inline"))
		end)

		it("returns nil without a header", function()
			assert.is_nil(UrlUtils.parseContentDisposition(nil))
		end)
	end)

	describe("isSearchable", function()
		it("is true for a URL with a %s placeholder", function()
			assert.is_true(UrlUtils.isSearchable("https://example.org/search?q=%s"))
		end)

		it("is false for a plain URL", function()
			assert.is_false(UrlUtils.isSearchable("https://example.org/search"))
		end)

		it("is false for nil", function()
			assert.is_false(UrlUtils.isSearchable(nil))
		end)
	end)

	describe("buildSearchUrl", function()
		it("fills the %s placeholder", function()
			assert.equals("https://example.org/s?q=dune", UrlUtils.buildSearchUrl("https://example.org/s?q=%s", "dune"))
		end)

		it("fills the {searchTerms} placeholder", function()
			assert.equals(
				"https://example.org/s?q=dune",
				UrlUtils.buildSearchUrl("https://example.org/s?q={searchTerms}", "dune")
			)
		end)

		it("fills every placeholder", function()
			assert.equals("/s?a=x&b=x", UrlUtils.buildSearchUrl("/s?a=%s&b={searchTerms}", "x"))
		end)

		it("keeps percent escapes of an encoded query intact", function()
			assert.equals(
				"https://example.org/s?q=caf%C3%A9%20au%20lait",
				UrlUtils.buildSearchUrl("https://example.org/s?q=%s", "caf%C3%A9%20au%20lait")
			)
			assert.equals(
				"https://example.org/s?q=100%25",
				UrlUtils.buildSearchUrl("https://example.org/s?q={searchTerms}", "100%25")
			)
		end)

		it("returns nil when the template or the query is missing", function()
			assert.is_nil(UrlUtils.buildSearchUrl(nil, "x"))
			assert.is_nil(UrlUtils.buildSearchUrl("https://example.org/s?q=%s", nil))
		end)
	end)

	describe("isCatalogNavigationLink", function()
		local catalog_type = "^application/atom%+xml"
		local catalog_rel = { subsection = true, ["http://opds-spec.org/sort/new"] = true }

		it("accepts a catalog link with a navigation rel", function()
			local link = { type = "application/atom+xml;profile=opds-catalog", rel = "subsection" }
			assert.is_true(UrlUtils.isCatalogNavigationLink(link, catalog_type, catalog_rel))
		end)

		it("accepts a catalog link without a rel", function()
			local link = { type = "application/atom+xml;profile=opds-catalog" }
			assert.is_true(UrlUtils.isCatalogNavigationLink(link, catalog_type, catalog_rel))
		end)

		it("rejects a catalog link with another rel", function()
			local link = { type = "application/atom+xml", rel = "alternate" }
			assert.is_false(UrlUtils.isCatalogNavigationLink(link, catalog_type, catalog_rel))
		end)

		it("rejects a link that is not a catalog", function()
			assert.is_false(UrlUtils.isCatalogNavigationLink({ type = "text/html" }, catalog_type, catalog_rel))
			assert.is_false(UrlUtils.isCatalogNavigationLink({}, catalog_type, catalog_rel))
		end)
	end)

	describe("isAcquisitionLink", function()
		local pattern = "^http://opds%-spec%.org/acquisition"

		it("matches acquisition rels including the subtypes", function()
			assert.is_truthy(UrlUtils.isAcquisitionLink({ rel = "http://opds-spec.org/acquisition" }, pattern))
			assert.is_truthy(UrlUtils.isAcquisitionLink({ rel = "http://opds-spec.org/acquisition/open-access" }, pattern))
		end)

		it("does not match other rels or a missing rel", function()
			assert.is_falsy(UrlUtils.isAcquisitionLink({ rel = "http://opds-spec.org/image" }, pattern))
			assert.is_falsy(UrlUtils.isAcquisitionLink({}, pattern))
		end)
	end)
end)
