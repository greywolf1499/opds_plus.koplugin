local helper = require("helper")

describe("OPDS authentication documents", function()
    local Document
    before_each(function()
        helper.reset()
        Document = helper.load("utils.auth_document", { rapidjson = require("support.json_shims").rapidjson() })
    end)
    after_each(helper.reset)

    it("distinguishes catalogs, web pages and malformed declared authentication JSON", function()
        local doc, identified = Document.parse('{"metadata":{"title":"Books"},"navigation":[]}', "application/opds+json")
        assert.is_nil(doc)
        assert.is_false(identified)
        doc, identified = Document.parse("<html></html>", "text/html")
        assert.is_nil(doc)
        assert.is_false(identified)
        local err
        doc, identified, err = Document.parse("{bad", "Application/Opds-Authentication+Json; charset=utf-8")
        assert.is_nil(doc)
        assert.is_true(identified)
        assert.matches("Invalid OPDS", err)
        assert.has_no.errors(function() Document.parse("", "") end)
    end)

    it("shows provider labels and unsupported flows without retaining advertised token URLs", function()
        local doc = Document.parse([[{
            "id":"https://catalog.example/auth", "title":"Library", "description":"",
            "authentication":[
                {"type":"http://opds-spec.org/auth/basic", "labels":{"login":"Card","password":"PIN"}},
                {"type":"http://opds-spec.org/auth/oauth/password",
                 "links":[{"rel":"authenticate","href":"https://other.example/token"}]}
            ]}]], "application/json")
        assert.matches("Card", Document.describe(doc))
        assert.matches("PIN", Document.describe(doc))
        assert.matches("OAuth login is not supported", Document.describe(doc))
        assert.is_nil(doc.flows[2].links)
    end)

    it("parses discovery links without splitting quoted punctuation or URI commas", function()
        local header = '<other>; title="semi; comma, \\"quoted\\""; rel=preload, '
            .. '</auth,a>; TYPE="application/opds-authentication+json"; REL="alternate http://opds-spec.org/auth/document"'
        assert.equals("/auth,a", Document.headerLink(header))
        assert.is_nil(Document.headerLink('</auth>; rel="http://opds-spec.org/auth/document"; type="text/html"'))
        assert.equals("/auth", Document.feedLink({ links = {
            { href = "/auth", rel = { Document.REL }, type = Document.TYPE },
        } }))
    end)

    it("recognizes BOM-prefixed JSON without a specific authentication content type", function()
        local doc, identified = Document.parse('\239\187\191{"id":"https://catalog.example/auth",'
            .. '"title":"Library","authentication":[{"type":"http://opds-spec.org/auth/basic"}]}', "application/json")
        assert.is_true(identified)
        assert.equals("Library", doc.title)
    end)

    it("refuses oversized documents and malformed flow entries rather than showing partial information", function()
        local doc, identified, err = Document.parse(string.rep(" ", Document.MAX_BYTES + 1), Document.TYPE)
        assert.is_nil(doc)
        assert.is_true(identified)
        assert.matches("too large", err)
        doc, identified, err = Document.parse('{"id":"https://catalog.example/auth","title":"Library",'
            .. '"authentication":[{"type":"http://opds-spec.org/auth/basic"},42]}', Document.TYPE)
        assert.is_nil(doc)
        assert.is_true(identified)
        assert.matches("Invalid OPDS", err)
    end)
end)
