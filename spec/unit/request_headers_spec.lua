local helper = require("helper")

-- Custom headers can carry credentials (tokens, cookies), so these specs lean towards the hostile cases:
-- header injection, reserved names, and requests that must never receive a catalog's headers.
describe("RequestHeaders", function()
	local RequestHeaders

	before_each(function()
		helper.reset()
		RequestHeaders = helper.load("utils.request_headers")
	end)

	after_each(helper.reset)

	local function assertRejected(reason, name, value, label)
		local ok, got = RequestHeaders.validate(name, value)
		assert.is_false(ok, label)
		assert.equals(reason, got, label)
	end

	local function assertParseError(text, line, reason, name)
		local label = string.format("%q", text)
		local list, got_line, got_reason, got_name = RequestHeaders.parse(text)
		assert.is_nil(list, label)
		assert.equals(line, got_line, label)
		assert.equals(reason, got_reason, label)
		assert.equals(name, got_name, label)
	end

	local function assertOrigins(cases)
		for _, case in ipairs(cases) do
			assert.equals(case[1], RequestHeaders.originKey(case[2]), case[2])
		end
	end

	local function assertNoOrigin(urls)
		for _, url in ipairs(urls) do
			assert.is_nil(RequestHeaders.originKey(url), url)
		end
	end

	describe("validate", function()
		it("accepts an ordinary header", function()
			assert.is_true(RequestHeaders.validate("X-Api-Key", "abc123"))
		end)

		it("accepts every punctuation character HTTP allows in a header name", function()
			assert.is_true(RequestHeaders.validate("!#$%&'*+-.^_`|~", "v"))
			assert.is_true(RequestHeaders.validate("a1B2", "v"))
		end)

		it("accepts the headers people use for credentials", function()
			for _, name in ipairs({ "Authorization", "Cookie", "X-Api-Key", "User-Agent" }) do
				assert.is_true(RequestHeaders.validate(name, "secret"), name)
			end
		end)

		it("rejects names that are not a valid header token", function()
			local bad_names = {
				"", " ", "X Api", " X-Api", "X-Api ", "X:Api", "X-Api:", "X/Api", "X(Api)", "X\"Api", "X@Api",
				"X,Api", "X;Api", "X<Api>", "X=Api", "X?Api", "X[Api]", "X\\Api", "X{Api}", "X\tApi", "Caf\u{e9}",
				"X-Api\n", "X-Api\r\nInjected", "X-Api\0",
			}
			for _, name in ipairs(bad_names) do
				assertRejected("name", name, "v", string.format("%q", name))
			end
		end)

		it("rejects a name that is not a string", function()
			assertRejected("name", nil, "v", "nil")
			assertRejected("name", 42, "v", "number")
			assertRejected("name", { "X-Api" }, "v", "table")
		end)

		it("rejects headers that frame the request, whatever their letter case", function()
			local reserved = {
				"Accept-Encoding", "Connection", "Content-Length", "Host", "Keep-Alive",
				"Proxy-Connection", "TE", "Trailer", "Transfer-Encoding", "Upgrade",
			}
			for _, name in ipairs(reserved) do
				for _, variant in ipairs({ name, name:lower(), name:upper() }) do
					assertRejected("reserved", variant, "x", variant)
				end
			end
		end)

		it("does not treat a name that only contains a reserved word as reserved", function()
			local names = {
				"X-Host", "Hosts", "X-Forwarded-Host", "Connection-Id", "Upgrade-Insecure-Requests", "X-Content-Length",
			}
			for _, name in ipairs(names) do
				assert.is_true(RequestHeaders.validate(name, "x"), name)
			end
		end)

		it("rejects an empty value or one that is only whitespace", function()
			for _, value in ipairs({ "", " ", "   ", "\t", " \t " }) do
				assertRejected("value", "X-Api", value, string.format("%q", value))
			end
		end)

		it("rejects a value that is not a string", function()
			assertRejected("value", "X-Api", nil, "nil")
			assertRejected("value", "X-Api", 42, "number")
			assertRejected("value", "X-Api", true, "boolean")
			assertRejected("value", "X-Api", { "v" }, "table")
		end)

		it("rejects every control character except the tab in a value", function()
			local controls = { 127 }
			for byte = 0, 31 do
				if byte ~= 9 then
					table.insert(controls, byte)
				end
			end
			for _, byte in ipairs(controls) do
				assertRejected("value", "X-Api", "ab" .. string.char(byte) .. "cd", "byte " .. byte)
			end
		end)

		it("rejects a value that tries to start another header", function()
			assertRejected("value", "X-Api", "abc\r\nHost: evil.test", "CRLF")
			assertRejected("value", "X-Api", "abc\nHost: evil.test", "LF")
			assertRejected("value", "X-Api", "abc\rHost: evil.test", "CR")
			assertRejected("value", "X-Api", "abc\r\n", "trailing CRLF")
		end)

		it("accepts a tab or spaces inside the value", function()
			assert.is_true(RequestHeaders.validate("X-Api", "a\tb"))
			assert.is_true(RequestHeaders.validate("X-Api", "Bearer  two spaces"))
		end)

		it("accepts non-ASCII text in the value", function()
			assert.is_true(RequestHeaders.validate("X-Name", "Zo\u{eb} \u{2615}"))
		end)

		it("reports a bad name before a reserved name, and a reserved name before a bad value", function()
			assertRejected("name", "Bad Name", "", "bad name and empty value")
			assertRejected("reserved", "Host", "", "reserved name and empty value")
		end)
	end)

	describe("parse", function()
		it("returns an empty list for nil, empty and blank text", function()
			for _, text in ipairs({ "", "   ", "\n", "\r\n\r\n", " \t \n  " }) do
				local list, line, reason = RequestHeaders.parse(text)
				assert.same({}, list)
				assert.is_nil(line)
				assert.is_nil(reason)
			end
			assert.same({}, RequestHeaders.parse(nil))
		end)

		it("reads one header per line, keeping their order and the letter case of the names", function()
			local list = RequestHeaders.parse("X-Api-Key: abc\nCookie: sid=1\nauthorization: Bearer t")
			assert.same({
				{ name = "X-Api-Key", value = "abc" },
				{ name = "Cookie", value = "sid=1" },
				{ name = "authorization", value = "Bearer t" },
			}, list)
		end)

		it("trims the name and the value but keeps the whitespace inside the value", function()
			assert.same({ { name = "X-A", value = "two   words" } }, RequestHeaders.parse("  X-A  :\t two   words \t"))
		end)

		it("keeps colons that are part of the value", function()
			local list = RequestHeaders.parse("Authorization: Bearer a:b:c\nReferer: https://example.com:8443/x")
			assert.same({
				{ name = "Authorization", value = "Bearer a:b:c" },
				{ name = "Referer", value = "https://example.com:8443/x" },
			}, list)
		end)

		it("accepts LF, CRLF and CR line endings, with or without a final line break", function()
			local expected = { { name = "A", value = "1" }, { name = "B", value = "2" } }
			assert.same(expected, RequestHeaders.parse("A: 1\nB: 2"))
			assert.same(expected, RequestHeaders.parse("A: 1\nB: 2\n"))
			assert.same(expected, RequestHeaders.parse("A: 1\r\nB: 2\r\n"))
			assert.same(expected, RequestHeaders.parse("A: 1\rB: 2\r"))
		end)

		it("skips blank lines", function()
			local list = RequestHeaders.parse("\nA: 1\n\n  \t \nB: 2\n\n")
			assert.same({ { name = "A", value = "1" }, { name = "B", value = "2" } }, list)
		end)

		it("never lets a line break end up inside a name or a value", function()
			local list = RequestHeaders.parse("A: 1\r\nB: 2\rC: 3\nD: 4")
			assert.equals(4, #list)
			for _, header in ipairs(list) do
				assert.is_nil(header.name:find("[\r\n]"), header.name)
				assert.is_nil(header.value:find("[\r\n]"), header.name)
			end
		end)

		it("reports a line without a colon as a format error", function()
			assertParseError("A: 1\nnot a header\nB: 2", 2, "format", nil)
		end)

		it("counts blank lines and every kind of line break in the reported line number", function()
			assertParseError("A: 1\n\n   \nbroken", 4, "format", nil)
			assertParseError("A: 1\r\n\r\nbroken", 3, "format", nil)
			assertParseError("A: 1\r\rbroken", 3, "format", nil)
		end)

		it("reports an empty or invalid name together with the name as typed", function()
			assertParseError(": value", 1, "name", "")
			assertParseError("  : value", 1, "name", "")
			assertParseError("X A: v", 1, "name", "X A")
			assertParseError("A: 1\nCaf\u{e9}: v", 2, "name", "Caf\u{e9}")
		end)

		it("reports a reserved header with the name as typed", function()
			assertParseError("hOsT: example.org", 1, "reserved", "hOsT")
			assertParseError("A: 1\nB: 2\nTransfer-Encoding: chunked", 3, "reserved", "Transfer-Encoding")
		end)

		it("reports an empty value", function()
			assertParseError("X-Api:", 1, "value", "X-Api")
			assertParseError("X-Api:    ", 1, "value", "X-Api")
			assertParseError("X-Api: \t", 1, "value", "X-Api")
		end)

		it("reports a value with a control character", function()
			assertParseError("X-Api: a\0b", 1, "value", "X-Api")
			assertParseError("X-Api: a\127b", 1, "value", "X-Api")
			assertParseError("A: 1\nX-Api: a\vb", 2, "value", "X-Api")
		end)

		it("reports a repeated name whatever its letter case, at the line of the repeat", function()
			assertParseError("X-A: 1\nx-a: 2", 2, "duplicate", "x-a")
			assertParseError("X-A: 1\n\nB: 2\nX-a : 3", 4, "duplicate", "X-a")
		end)

		it("stops at the first problem and returns no partial list", function()
			assertParseError("A: 1\nbroken\nHost: x\nB:", 2, "format", nil)
			assertParseError("Host: x\nbroken", 1, "reserved", "Host")
		end)

		it("does not let a line break in a value smuggle in a reserved header", function()
			assertParseError("X-Api: 1\r\nHost: evil.test", 2, "reserved", "Host")
			assertParseError("X-Api: 1\rHost: evil.test", 2, "reserved", "Host")
		end)
	end)

	describe("format", function()
		it("returns an empty string for nil and for an empty list", function()
			assert.equals("", RequestHeaders.format(nil))
			assert.equals("", RequestHeaders.format({}))
		end)

		it("writes one 'Name: value' line per header, without a trailing line break", function()
			local text = RequestHeaders.format({
				{ name = "X-Api-Key", value = "abc" },
				{ name = "Cookie", value = "sid=1" },
			})
			assert.equals("X-Api-Key: abc\nCookie: sid=1", text)
		end)

		it("skips entries that are not complete headers", function()
			local text = RequestHeaders.format({
				{ name = "A", value = "1" },
				"junk",
				{ name = "B" },
				{ value = "x" },
				{ name = 5, value = "x" },
				{ name = "C", value = 7 },
				{ name = "D", value = "4" },
			})
			assert.equals("A: 1\nD: 4", text)
		end)
	end)

	describe("parse and format together", function()
		it("gives back the same list after formatting and parsing it", function()
			local list = {
				{ name = "Authorization", value = "Bearer a:b:c" },
				{ name = "x-lower", value = "two  spaces and\ttab" },
				{ name = "X-Unicode", value = "caf\u{e9} \u{2615}" },
			}
			assert.same(list, RequestHeaders.parse(RequestHeaders.format(list)))
		end)

		it("normalises messy input when it is formatted back", function()
			local list = RequestHeaders.parse("  A :1 \r\n\r\n B:   two  words\t\n")
			assert.equals("A: 1\nB: two  words", RequestHeaders.format(list))
		end)
	end)

	describe("copy", function()
		it("returns nil for anything but a table", function()
			assert.is_nil(RequestHeaders.copy(nil))
			assert.is_nil(RequestHeaders.copy("X-A: 1"))
			assert.is_nil(RequestHeaders.copy(5))
		end)

		it("returns a new empty list for an empty list", function()
			local list = {}
			local copy = RequestHeaders.copy(list)
			assert.same({}, copy)
			assert.are_not.equal(list, copy)
		end)

		it("returns an equal list in the same order", function()
			local list = { { name = "B", value = "2" }, { name = "A", value = "1" } }
			assert.same(list, RequestHeaders.copy(list))
		end)

		it("returns a list that can be changed without touching the original", function()
			local list = { { name = "A", value = "1" } }
			local copy = RequestHeaders.copy(list)
			copy[1].value = "changed"
			table.insert(copy, { name = "B", value = "2" })
			assert.same({ { name = "A", value = "1" } }, list)
		end)

		it("is not affected by later changes to the original", function()
			local list = { { name = "A", value = "1" } }
			local copy = RequestHeaders.copy(list)
			list[1].value = "changed"
			list[1].name = "Other"
			assert.same({ { name = "A", value = "1" } }, copy)
		end)

		it("drops entries that are not complete headers and fields that are not part of a header", function()
			local copy = RequestHeaders.copy({
				{ name = "A", value = "1", note = "extra" },
				"junk",
				{ name = "B" },
				{ name = "C", value = 3 },
			})
			assert.same({ { name = "A", value = "1" } }, copy)
		end)
	end)

	describe("originKey", function()
		it("spells out scheme, host and port, whichever part of the URL follows", function()
			assertOrigins({
				{ "https://example.com:443", "https://example.com" },
				{ "https://example.com:443", "https://example.com/" },
				{ "https://example.com:443", "https://example.com/opds/catalog?q=1#top" },
				{ "http://example.com:80", "http://example.com/opds" },
			})
		end)

		it("keeps an explicit port, including the default port of the other scheme", function()
			assertOrigins({
				{ "http://example.com:8080", "http://example.com:8080/x" },
				{ "https://example.com:8443", "https://example.com:8443" },
				{ "http://example.com:443", "http://example.com:443/" },
				{ "https://example.com:80", "https://example.com:80/" },
			})
		end)

		it("fills in the default port of the scheme when it is written out", function()
			assertOrigins({
				{ "https://example.com:443", "https://example.com:443/x" },
				{ "http://example.com:80", "http://example.com:80/x" },
			})
		end)

		it("ignores the letter case of the scheme and the host", function()
			assertOrigins({
				{ "https://example.com:443", "HTTPS://Example.COM/Path" },
				{ "http://example.com:80", "hTtP://EXAMPLE.com/" },
			})
		end)

		it("normalises an empty port and leading zeros in the port", function()
			assertOrigins({
				{ "https://example.com:443", "https://example.com:/x" },
				{ "https://example.com:443", "https://example.com:00443/x" },
				{ "http://example.com:80", "http://example.com:0080/" },
			})
		end)

		it("leaves user info out of the origin", function()
			assertOrigins({
				{ "https://example.com:443", "https://user:secret@example.com/opds" },
				{ "https://example.com:8443", "https://user@example.com:8443/opds" },
			})
		end)

		it("takes the host after the user info, so a trusted name there cannot pass for the host", function()
			assertOrigins({
				{ "https://evil.test:443", "https://example.com@evil.test/opds" },
				{ "https://evil.test:443", "https://example.com:443@evil.test/opds" },
			})
		end)

		it("ends the user info at the last @, as a browser does", function()
			assertOrigins({
				{ "https://example.com:443", "https://me@mail.test:secret@example.com/opds" },
			})
		end)

		-- The authority ends at the first "/", "?" or "#" (RFC 3986, and KOReader's patched socket.url)
		it("does not read an @ after the host as user info", function()
			assertOrigins({
				{ "https://example.com:443", "https://example.com/mail@evil.test" },
				{ "https://example.com:443", "https://example.com?next=a@evil.test" },
				{ "https://example.com:443", "https://example.com#a@evil.test" },
				{ "https://example.com:443", "https://example.com?@evil.test/x" },
			})
		end)

		it("keeps the brackets of an IPv6 literal and lowercases it", function()
			assertOrigins({
				{ "https://[2001:db8::1]:443", "https://[2001:DB8::1]/x" },
				{ "http://[::1]:8080", "http://[::1]:8080/x" },
				{ "https://[::1]:443", "https://[::1]:/x" },
				{ "https://[::1]:9000", "https://user:pw@[::1]:9000/x" },
			})
		end)

		it("returns nil for a malformed IPv6 literal", function()
			assertNoOrigin({
				"https://[::1/x",
				"https://[::1]x/",
				"https://[]/",
				"https://[::1]:abc/",
				"https://[::1]:80:80/",
			})
		end)

		it("returns nil for schemes other than http and https", function()
			assertNoOrigin({
				"ftp://example.com/x",
				"file:///etc/passwd",
				"javascript://example.com/%0Aalert(1)",
				"http+unix://example.com/",
				"httpx://example.com/",
				"opds://example.com/",
			})
		end)

		it("returns nil when there is no scheme or no host", function()
			assertNoOrigin({
				"",
				"example.com/opds",
				"//example.com/opds",
				"/opds/catalog",
				" https://example.com/",
				"https:/example.com",
				"https:example.com",
				"https://",
				"https:///opds",
				"https://:443/",
				"https://user:pw@/x",
				"https://?q=1",
			})
		end)

		it("returns nil for a port that is not a number", function()
			assertNoOrigin({
				"https://example.com:abc/",
				"https://example.com:80a/",
				"https://example.com:443:443/",
			})
		end)

		it("returns nil when the URL is not a string", function()
			assert.is_nil(RequestHeaders.originKey(nil))
			assert.is_nil(RequestHeaders.originKey(443))
			assert.is_nil(RequestHeaders.originKey({ "https://example.com/" }))
		end)
	end)

	describe("forUrl", function()
		local function headersOf(value)
			return { { name = "Authorization", value = value } }
		end

		local servers

		before_each(function()
			servers = {
				{ title = "A", url = "https://a.example.org/opds", headers = headersOf("Bearer A") },
				{ title = "B", url = "http://b.example.org:8080/opds", headers = headersOf("Bearer B") },
			}
		end)

		local function assertNoHeaders(urls)
			for _, url in ipairs(urls) do
				assert.is_nil(RequestHeaders.forUrl(servers, url), url)
			end
		end

		it("returns the headers of the catalog on the same origin", function()
			local url = "https://a.example.org/opds/book.epub?x=1"
			assert.same(headersOf("Bearer A"), RequestHeaders.forUrl(servers, url))
			assert.same(headersOf("Bearer B"), RequestHeaders.forUrl(servers, "http://b.example.org:8080/cover.jpg"))
		end)

		it("ignores user info, letter case and an explicit default port when comparing origins", function()
			servers[1].url = "https://user:pw@A.Example.org:443/opds"
			assert.same(headersOf("Bearer A"), RequestHeaders.forUrl(servers, "HTTPS://a.example.ORG/x"))
			assert.same(headersOf("Bearer A"), RequestHeaders.forUrl(servers, "https://a.example.org:443/x"))
		end)

		it("returns nil for a different host", function()
			assertNoHeaders({ "https://c.example.org/opds", "https://example.org/opds", "https://sub.a.example.org/opds" })
		end)

		it("returns nil for a host that only looks like the catalog's", function()
			assertNoHeaders({
				"https://a.example.org.evil.test/opds",
				"https://evil-a.example.org/opds",
				"https://xa.example.org/opds",
				"https://a.example.org@evil.test/opds",
				"https://evil.test?@a.example.org/opds",
			})
		end)

		it("returns nil when the scheme differs, so plain http never gets the headers of an https catalog", function()
			assertNoHeaders({
				"http://a.example.org/opds",
				"http://a.example.org:443/opds",
				"https://b.example.org:8080/opds",
			})
		end)

		it("returns nil when the port differs", function()
			assertNoHeaders({
				"https://a.example.org:8443/opds",
				"http://b.example.org/opds",
				"http://b.example.org:80/opds",
				"http://b.example.org:8081/opds",
			})
		end)

		it("uses the first catalog with headers when several share an origin", function()
			table.insert(servers, 1, { url = "https://a.example.org/other", headers = headersOf("first") })
			assert.same(headersOf("first"), RequestHeaders.forUrl(servers, "https://a.example.org/x"))
		end)

		it("skips catalogs on the same origin that have no headers", function()
			local catalogs = {
				{ url = "https://a.example.org/one" },
				{ url = "https://a.example.org/two", headers = {} },
				{ url = "https://a.example.org/three", headers = headersOf("third") },
			}
			assert.same(headersOf("third"), RequestHeaders.forUrl(catalogs, "https://a.example.org/x"))
		end)

		it("ignores catalog entries that are malformed", function()
			local catalogs = {
				"junk",
				42,
				{ url = 7, headers = headersOf("url is a number") },
				{ headers = headersOf("no url") },
				{ url = "https://a.example.org/", headers = "Authorization: text" },
				servers[1],
			}
			assert.same(headersOf("Bearer A"), RequestHeaders.forUrl(catalogs, "https://a.example.org/x"))
		end)

		it("returns nil when the URL is not an http(s) URL, even if a catalog has an equally odd one", function()
			local catalogs = {
				{ url = "ftp://example.org/", headers = headersOf("ftp") },
				{ url = "not a url", headers = headersOf("junk") },
				{ url = "https://", headers = headersOf("no host") },
			}
			assert.is_nil(RequestHeaders.forUrl(catalogs, "ftp://example.org/file"))
			assert.is_nil(RequestHeaders.forUrl(catalogs, "not a url"))
			assert.is_nil(RequestHeaders.forUrl(catalogs, "https://"))
			assert.is_nil(RequestHeaders.forUrl(catalogs, nil))
		end)

		it("returns nil without catalogs", function()
			local url = "https://a.example.org/opds"
			assert.is_nil(RequestHeaders.forUrl(nil, url))
			assert.is_nil(RequestHeaders.forUrl({}, url))
			assert.is_nil(RequestHeaders.forUrl("https://a.example.org/opds", url))
		end)
	end)

	describe("apply", function()
		it("adds the custom headers to the request headers", function()
			local headers = RequestHeaders.apply({ Accept = "application/atom+xml" }, {
				{ name = "X-Api-Key", value = "k" },
				{ name = "Cookie", value = "sid=1" },
			})
			assert.same({ Accept = "application/atom+xml", ["X-Api-Key"] = "k", Cookie = "sid=1" }, headers)
		end)

		it("creates the headers when the request has none", function()
			assert.same({ ["X-Api-Key"] = "k" }, RequestHeaders.apply(nil, { { name = "X-Api-Key", value = "k" } }))
		end)

		it("leaves the request without headers when no custom header applies", function()
			assert.is_nil(RequestHeaders.apply(nil, nil))
			assert.is_nil(RequestHeaders.apply(nil, {}))
			assert.is_nil(RequestHeaders.apply(nil, { { name = "Host", value = "x" } }))
		end)

		it("returns the request headers as they are when the list is not a table", function()
			assert.same({ Accept = "x" }, RequestHeaders.apply({ Accept = "x" }, nil))
			assert.same({ Accept = "x" }, RequestHeaders.apply({ Accept = "x" }, "X-Api-Key: k"))
		end)

		it("never replaces a header the request sets, whatever the letter case of either name", function()
			local headers = RequestHeaders.apply({
				Accept = "application/atom+xml",
				["user-agent"] = "KOReader",
				Authorization = "Basic abc",
			}, {
				{ name = "accept", value = "text/evil" },
				{ name = "USER-AGENT", value = "evil" },
				{ name = "Authorization", value = "Bearer evil" },
			})
			assert.same({
				Accept = "application/atom+xml",
				["user-agent"] = "KOReader",
				Authorization = "Basic abc",
			}, headers)
		end)

		it("adds only the first of two custom headers whose names differ in letter case", function()
			local headers = RequestHeaders.apply({}, { { name = "X-A", value = "1" }, { name = "x-a", value = "2" } })
			assert.same({ ["X-A"] = "1" }, headers)
		end)

		it("skips entries that are not valid and keeps the others", function()
			local headers = RequestHeaders.apply({}, {
				{ name = "Host", value = "evil.test" },
				{ name = "content-length", value = "0" },
				{ name = "X-Empty", value = "   " },
				{ name = "X Bad", value = "v" },
				{ name = 5, value = "v" },
				{ name = "X-No-Value" },
				"junk",
				42,
				true,
				{ name = "Good", value = "1" },
			})
			assert.same({ Good = "1" }, headers)
		end)

		it("does not pass on a line break from an entry that was edited by hand", function()
			local headers = RequestHeaders.apply({}, {
				{ name = "X-A", value = "1\r\nHost: evil.test" },
				{ name = "X-B\r\nHost", value = "evil.test" },
				{ name = "X-C", value = "1\nX-Injected: 2" },
			})
			assert.same({}, headers)
		end)

		it("does not change the custom header list", function()
			local list = { { name = "Host", value = "x" }, { name = "X-A", value = "1" } }
			RequestHeaders.apply({ ["x-a"] = "request" }, list)
			assert.same({ { name = "Host", value = "x" }, { name = "X-A", value = "1" } }, list)
		end)
	end)

	describe("headers of a catalog on a request", function()
		it("reach requests to the origin of the catalog and no other", function()
			local servers = {
				{ url = "https://a.example.org/opds", headers = { { name = "Authorization", value = "Bearer A" } } },
			}
			local function sentTo(url)
				return RequestHeaders.apply({ Accept = "application/atom+xml" }, RequestHeaders.forUrl(servers, url))
			end

			assert.same(
				{ Accept = "application/atom+xml", Authorization = "Bearer A" },
				sentTo("https://a.example.org/book.epub")
			)
			local others = {
				"http://a.example.org/book.epub",
				"https://a.example.org:8443/book.epub",
				"https://evil.test/book.epub",
				"https://a.example.org@evil.test/book.epub",
			}
			for _, url in ipairs(others) do
				assert.same({ Accept = "application/atom+xml" }, sentTo(url), url)
			end
		end)
	end)
end)
