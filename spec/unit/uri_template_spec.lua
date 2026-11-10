local helper = require("helper")

describe("UriTemplate", function()
	local UriTemplate

	before_each(function()
		helper.reset()
		UriTemplate = helper.load("utils.uri_template")
	end)

	after_each(helper.reset)

	describe("expand", function()
		-- Examples from RFC 6570 section 3.2
		local variables = {
			var = "value",
			hello = "Hello World!",
			path = "/foo/bar",
			empty = "",
			x = "1024",
			y = "768",
		}

		local cases = {
			{ "{var}", "value" },
			{ "{hello}", "Hello%20World%21" },
			{ "{+var}", "value" },
			{ "{+hello}", "Hello%20World!" },
			{ "{+path}/here", "/foo/bar/here" },
			{ "here?ref={+path}", "here?ref=/foo/bar" },
			{ "map?{x,y}", "map?1024,768" },
			{ "{x,hello,y}", "1024,Hello%20World%21,768" },
			{ "{+x,hello,y}", "1024,Hello%20World!,768" },
			{ "{+path,x}/here", "/foo/bar,1024/here" },
			{ "{#x,hello,y}", "#1024,Hello%20World!,768" },
			{ "{#path,x}/here", "#/foo/bar,1024/here" },
			{ "X{.var}", "X.value" },
			{ "X{.x,y}", "X.1024.768" },
			{ "{/var}", "/value" },
			{ "{/var,x}/here", "/value/1024/here" },
			{ "{;x,y}", ";x=1024;y=768" },
			{ "{;x,y,empty}", ";x=1024;y=768;empty" },
			{ "{?x,y}", "?x=1024&y=768" },
			{ "{?x,y,empty}", "?x=1024&y=768&empty=" },
			{ "?fixed=yes{&x}", "?fixed=yes&x=1024" },
			{ "{&x,y,empty}", "&x=1024&y=768&empty=" },
		}

		for _, case in ipairs(cases) do
			it("expands " .. case[1], function()
				assert.equals(case[2], UriTemplate.expand(case[1], variables))
			end)
		end

		it("leaves out variables that have no value", function()
			assert.equals("/search?query=dune", UriTemplate.expand("/search{?query,author}", { query = "dune" }))
			assert.equals("/search", UriTemplate.expand("/search{?query,author}", {}))
		end)

		it("keeps %XX escapes only where reserved expansion allows them", function()
			assert.equals("a%20b", UriTemplate.expand("{+v}", { v = "a%20b" }))
			assert.equals("a%2520b", UriTemplate.expand("{v}", { v = "a%20b" }))
		end)

		it("accepts level 4 modifiers and expands the whole value", function()
			assert.equals("?q=value", UriTemplate.expand("{?q:3}", { q = "value" }))
			assert.equals("/value", UriTemplate.expand("{/q*}", { q = "value" }))
		end)

		it("encodes multibyte characters byte by byte", function()
			assert.equals("caf%C3%A9", UriTemplate.expand("{v}", { v = "café" }))
		end)
	end)

	describe("variables", function()
		it("lists names in order of first appearance, without modifiers", function()
			assert.same({ "query", "page", "author" },
				UriTemplate.variables("/s{?query,page}{&author:2,query}"))
		end)
	end)

	describe("toSearchUrl", function()
		it("puts %s where the query variable goes", function()
			assert.equals("/search?query=%s", UriTemplate.toSearchUrl("/search{?query}"))
		end)

		it("leaves the other variables out", function()
			assert.equals("/opds/search?query=%s", UriTemplate.toSearchUrl("/opds/search{?query,title,author}"))
		end)

		it("recognises other common names for the search terms", function()
			assert.equals("/s?searchTerms=%s", UriTemplate.toSearchUrl("/s{?searchTerms}"))
			assert.equals("/s/%s", UriTemplate.toSearchUrl("/s{/q}"))
		end)

		it("uses the only variable of a template, whatever its name", function()
			assert.equals("/find?words=%s", UriTemplate.toSearchUrl("/find{?words}"))
		end)

		it("gives nil when no variable can take the search terms", function()
			assert.is_nil(UriTemplate.toSearchUrl("/find{?a,b}"))
			assert.is_nil(UriTemplate.toSearchUrl(nil))
		end)

		it("keeps existing escapes, which the search dialog's %s substitution leaves alone", function()
			local url = UriTemplate.toSearchUrl("/s%20x{?query}")
			assert.equals("/s%20x?query=%s", url)
			assert.equals("/s%20x?query=a%20b", (url:gsub("%%s", function() return "a%20b" end)))
		end)
	end)
end)
