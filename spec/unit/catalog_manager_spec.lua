local helper = require("helper")

describe("CatalogManager", function()
	local CatalogManager, RequestHeaders

	local function identity(text)
		return text
	end

	-- The fields of the add/edit dialog, in dialog order: title, URL, username, password, raw names, sync and
	-- custom headers. An unchecked box is nil, as in the dialog.
	local function dialogFields(overrides)
		local values = { "Shelf", "https://example.org/opds", "", "" }
		for index, value in pairs(overrides or {}) do
			values[index] = value
		end
		return values
	end

	-- Like KOReader's Menu widget, number the entries it shows: "Downloads" is entry 1, the catalogs follow.
	local function numbered(menu)
		for index, entry in ipairs(menu) do
			entry.idx = index
		end
		return menu
	end

	local function library(servers)
		return servers, numbered(CatalogManager.genItemTableFromRoot(servers, {}, identity))
	end

	local function pluck(list, key)
		local values = {}
		for _, item in ipairs(list) do
			values[#values + 1] = item[key]
		end
		return values
	end

	before_each(function()
		helper.reset()
		CatalogManager = helper.load("core.catalog_manager")
		RequestHeaders = require("utils.request_headers")
	end)

	after_each(helper.reset)

	describe("genItemTableFromRoot", function()
		it("starts with a Downloads entry that counts the queued downloads", function()
			local menu = CatalogManager.genItemTableFromRoot({}, { {}, {}, {} }, function(text)
				return "<" .. text .. ">"
			end)

			assert.same({ { text = "<Downloads>", mandatory = 3 } }, menu)
		end)

		it("lists the catalogs after Downloads in their saved order", function()
			local menu = CatalogManager.genItemTableFromRoot({
				{ title = "First", url = "http://one.example" },
				{ title = "Second", url = "http://two.example" },
			}, {}, identity)

			assert.same({ "Downloads", "First", "Second" }, pluck(menu, "text"))
		end)

		it("carries the connection details of a catalog on its entry", function()
			local headers = { { name = "X-Token", value = "abc" } }

			local entry = CatalogManager.genItemTableFromRoot({
				{
					title = "Shelf",
					url = "https://example.org/opds",
					username = "me",
					password = "secret",
					raw_names = true,
					sync = true,
					headers = headers,
				},
			}, {}, identity)[2]

			assert.equals("https://example.org/opds", entry.url)
			assert.equals("me", entry.username)
			assert.equals("secret", entry.password)
			assert.is_true(entry.raw_names)
			assert.is_true(entry.sync)
			assert.same(headers, entry.headers)
		end)

		it("marks synchronised and password-protected catalogs with their own icons", function()
			local menu = CatalogManager.genItemTableFromRoot({
				{ title = "plain", url = "http://a.example" },
				{ title = "sync", url = "http://b.example", sync = true },
				{ title = "auth", url = "http://c.example", username = "me" },
				{ title = "both", url = "http://d.example", sync = true, username = "me" },
			}, {}, identity)
			local plain, sync, auth, both = menu[2].mandatory, menu[3].mandatory, menu[4].mandatory, menu[5].mandatory

			assert.equals("", plain)
			assert.are_not.equal("", sync)
			assert.are_not.equal("", auth)
			assert.are_not.equal(sync, auth)
			assert.equals(sync .. auth, both)
		end)

		it("offers a search only for catalogs whose URL has a %s placeholder", function()
			local menu = CatalogManager.genItemTableFromRoot({
				{ title = "search", url = "https://example.org/search?q=%s" },
				{ title = "escaped", url = "https://example.org/my%20books" },
				{ title = "plain", url = "https://example.org/opds" },
			}, {}, identity)

			assert.is_true(menu[2].searchable)
			assert.is_false(menu[3].searchable)
			assert.is_false(menu[4].searchable)
		end)
	end)

	describe("editCatalogFromInput when adding a catalog", function()
		it("appends the catalog to the list and to the menu", function()
			local servers, menu = library({ { title = "Old", url = "http://old.example/opds" } })

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "New", "https://new.example/opds" }))

			assert.same({ "Old", "New" }, pluck(servers, "title"))
			assert.same({ "Downloads", "Old", "New" }, pluck(menu, "text"))
			assert.equals("https://new.example/opds", servers[2].url)
			assert.equals("https://new.example/opds", menu[3].url)
		end)

		it("adds the first catalog right after the Downloads entry", function()
			local servers, menu = library({})

			local new_idx, itemnumber = CatalogManager.editCatalogFromInput(servers, menu, dialogFields())

			assert.same({ "Shelf" }, pluck(servers, "title"))
			assert.same({ "Downloads", "Shelf" }, pluck(menu, "text"))
			assert.equals(2, new_idx)
			assert.equals(2, itemnumber)
		end)

		it("reports the menu position of the new catalog and asks for a refresh", function()
			local servers, menu = library({ { title = "Old", url = "http://old.example/opds" } })

			local new_idx, itemnumber, refresh = CatalogManager.editCatalogFromInput(servers, menu, dialogFields())

			assert.equals(3, new_idx)
			assert.equals(3, itemnumber)
			assert.is_true(refresh)
		end)

		it("does not ask for a refresh when told not to", function()
			local servers, menu = library({})

			local refresh = select(3, CatalogManager.editCatalogFromInput(servers, menu, dialogFields(), nil, true))

			assert.is_false(refresh)
			assert.equals(1, #servers)
		end)

		it("stores every field of the dialog on the catalog", function()
			local servers, menu = library({})

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({
				"Shelf",
				"https://example.org/opds",
				"me",
				"secret",
				true,
				true,
				{ { name = "X-Token", value = "abc" } },
			}))

			assert.same({
				title = "Shelf",
				url = "https://example.org/opds",
				username = "me",
				password = "secret",
				raw_names = true,
				sync = true,
				headers = { { name = "X-Token", value = "abc" } },
			}, servers[1])
		end)

		it("describes the new catalog in the menu like a menu built from the saved list", function()
			local servers, menu = library({})

			local new_idx = CatalogManager.editCatalogFromInput(servers, menu, dialogFields({
				"Shelf",
				"https://example.org/search?q=%s",
				"me",
				"secret",
				nil,
				true,
			}))

			local rebuilt = CatalogManager.genItemTableFromRoot(servers, {}, identity)
			assert.same(rebuilt[new_idx], menu[new_idx])
			assert.is_true(menu[new_idx].searchable)
		end)

		describe("URL", function()
			local cases = {
				{ "https://example.org/opds", "https://example.org/opds" },
				{ "http://example.org/opds", "http://example.org/opds" },
				{ "opds://example.org/feed", "opds://example.org/feed" },
				{ "example.org/opds", "http://example.org/opds" },
				{ "example.org", "http://example.org" },
				{ "localhost:8080/opds", "http://localhost:8080/opds" },
				{ "192.168.1.10:8083", "http://192.168.1.10:8083" },
			}
			for _, case in ipairs(cases) do
				it("is stored as " .. case[2] .. " when typed as " .. case[1], function()
					local servers, menu = library({})

					CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Shelf", case[1] }))

					assert.equals(case[2], servers[1].url)
					assert.equals(case[2], menu[2].url)
				end)
			end

			it("is stored the way validateCatalogUrl normalises it, so the Save dialog and the list agree", function()
				for _, typed in ipairs({ "example.org/opds", "localhost:8080/opds", "https://example.org/opds" }) do
					local servers, menu = library({})
					local ok, normalised = CatalogManager.validateCatalogUrl(typed)

					CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Shelf", typed }))

					assert.is_true(ok)
					assert.equals(normalised, servers[1].url)
				end
			end)
		end)

		describe("credentials", function()
			it("are not stored when the fields are empty", function()
				local servers, menu = library({})

				CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Shelf", "http://a.example", "", "" }))

				assert.is_nil(servers[1].username)
				assert.is_nil(servers[1].password)
				assert.is_nil(menu[2].username)
			end)

			it("keep a username given without a password", function()
				local servers, menu = library({})

				CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Shelf", "http://a.example", "me", "" }))

				assert.equals("me", servers[1].username)
				assert.is_nil(servers[1].password)
			end)

			it("keep a password given without a username", function()
				local servers, menu = library({})

				CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Shelf", "http://a.example", "", "pw" }))

				assert.is_nil(servers[1].username)
				assert.equals("pw", servers[1].password)
			end)
		end)

		describe("custom headers", function()
			local function headerList()
				return {
					{ name = "Authorization", value = "Bearer abc" },
					{ name = "X-Api-Key", value = "k1" },
				}
			end

			it("are stored on the catalog and shown on its menu entry", function()
				local servers, menu = library({})

				CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ [7] = headerList() }))

				assert.same(headerList(), servers[1].headers)
				assert.same(headerList(), menu[2].headers)
			end)

			it("are copied, so changing the dialog's list afterwards does not change the catalog", function()
				local servers, menu = library({})
				local list = headerList()

				CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ [7] = list }))
				list[1].value = "changed"
				table.insert(list, { name = "X-Other", value = "v" })

				assert.same(headerList(), servers[1].headers)
			end)

			it("leave out entries that are not a name and a value", function()
				local servers, menu = library({})
				local list = {
					"junk",
					{ name = 5, value = "x" },
					{ name = "X-No-Value" },
					{ value = "no name" },
					{ name = "X-Good", value = "ok" },
				}

				CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ [7] = list }))

				assert.same({ { name = "X-Good", value = "ok" } }, servers[1].headers)
			end)

			local unusable = {
				{ "are missing", nil },
				{ "are an empty list", {} },
				{ "only have invalid entries", { "junk", { name = "X-No-Value" } } },
				{ "are not a list", "X-Token: abc" },
			}
			for _, case in ipairs(unusable) do
				it("are not stored when they " .. case[1], function()
					local servers, menu = library({})

					CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ [7] = case[2] }))

					assert.is_nil(servers[1].headers)
					assert.is_nil(menu[2].headers)
				end)
			end

			it("apply to requests to the catalog even when its URL was typed without http://", function()
				local servers, menu = library({})

				CatalogManager.editCatalogFromInput(
					servers,
					menu,
					dialogFields({ "Shelf", "example.org:8443/opds", "", "", nil, nil, headerList() })
				)

				assert.same(headerList(), RequestHeaders.forUrl(servers, "http://example.org:8443/opds/books?page=2"))
				assert.is_nil(RequestHeaders.forUrl(servers, "http://example.org/opds"))
				assert.is_nil(RequestHeaders.forUrl(servers, "http://other.example:8443/opds"))
			end)
		end)
	end)

	describe("editCatalogFromInput when editing a catalog", function()
		local a, b, c, servers, menu

		before_each(function()
			a = { title = "A", url = "http://a.example/opds" }
			b = { title = "B", url = "http://b.example/opds", username = "old", password = "oldpw", sync = true }
			c = { title = "C", url = "http://c.example/opds" }
			servers, menu = library({ a, b, c })
		end)

		it("replaces the edited catalog in the list and in the menu", function()
			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "B2", "https://b2.example/opds" }), menu[3])

			assert.same({ "A", "B2", "C" }, pluck(servers, "title"))
			assert.same({ "Downloads", "A", "B2", "C" }, pluck(menu, "text"))
			assert.equals("https://b2.example/opds", servers[2].url)
			assert.equals("https://b2.example/opds", menu[3].url)
		end)

		it("reports the edited position, selects no menu item and asks for a refresh", function()
			local new_idx, itemnumber, refresh =
				CatalogManager.editCatalogFromInput(servers, menu, dialogFields(), menu[3])

			assert.equals(3, new_idx)
			assert.equals(-1, itemnumber)
			assert.is_true(refresh)
		end)

		it("leaves the other catalogs and their menu entries as they were", function()
			local first_entry, last_entry = menu[2], menu[4]

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "B2", "https://b2.example/opds" }), menu[3])

			assert.equals(a, servers[1])
			assert.equals(c, servers[3])
			assert.equals(first_entry, menu[2])
			assert.equals(last_entry, menu[4])
		end)

		it("takes every field from the dialog, so cleared credentials are removed", function()
			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "B", "http://b.example/opds", "", "" }), menu[3])

			assert.same({ title = "B", url = "http://b.example/opds" }, servers[2])
			assert.equals("", menu[3].mandatory)
		end)

		it("keeps the catalog the default one", function()
			b.is_default = true

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields(), menu[3])

			assert.is_true(servers[2].is_default)
		end)

		it("does not make an edited catalog the default one", function()
			b.is_default = true

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields(), menu[2])

			assert.is_nil(servers[1].is_default)
			assert.equals(b, CatalogManager.findDefaultCatalog(servers))
		end)

		it("keeps the sync checkpoint while the address stays the same", function()
			b.last_download = "http://b.example/opds/book/9"

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "B renamed", "http://b.example/opds" }), menu[3])

			assert.equals("http://b.example/opds/book/9", servers[2].last_download)
		end)

		it("keeps the sync checkpoint when the unchanged address is typed without its protocol", function()
			b.last_download = "http://b.example/opds/book/9"

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "B", "b.example/opds" }), menu[3])

			assert.equals("http://b.example/opds/book/9", servers[2].last_download)
		end)

		it("drops the sync checkpoint when the address changes, as it belongs to the feed of the old one", function()
			b.last_download = "http://b.example/opds/book/9"

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "B", "https://moved.example/opds" }), menu[3])

			assert.is_nil(servers[2].last_download)
		end)

		it("does not give an edited catalog the checkpoint of its neighbour", function()
			a.last_download = "http://a.example/opds/book/1"

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "B", "http://b.example/opds" }), menu[3])

			assert.is_nil(servers[2].last_download)
			assert.equals("http://a.example/opds/book/1", servers[1].last_download)
		end)

		it("replaces the custom headers", function()
			b.headers = { { name = "X-Old", value = "1" } }

			CatalogManager.editCatalogFromInput(
				servers,
				menu,
				dialogFields({ [7] = { { name = "X-New", value = "2" } } }),
				menu[3]
			)

			assert.same({ { name = "X-New", value = "2" } }, servers[2].headers)
		end)

		it("removes the custom headers when the dialog has none", function()
			b.headers = { { name = "X-Old", value = "1" } }

			CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ [7] = {} }), menu[3])

			assert.is_nil(servers[2].headers)
			assert.is_nil(menu[3].headers)
		end)

		it("moves the headers to the new address, so they no longer go to the old one", function()
			local headers = { { name = "X-Token", value = "abc" } }
			b.headers = headers

			CatalogManager.editCatalogFromInput(
				servers,
				menu,
				dialogFields({ "B", "https://moved.example/opds", "", "", nil, nil, headers }),
				menu[3]
			)

			assert.same(headers, RequestHeaders.forUrl(servers, "https://moved.example/opds/feed"))
			assert.is_nil(RequestHeaders.forUrl(servers, "http://b.example/opds/feed"))
		end)
	end)

	describe("deleteCatalog", function()
		local function threeCatalogs()
			return library({
				{ title = "A", url = "http://a.example/opds" },
				{ title = "B", url = "http://b.example/opds" },
				{ title = "C", url = "http://c.example/opds" },
			})
		end

		it("removes the catalog from the list and from the menu", function()
			local servers, menu = threeCatalogs()

			CatalogManager.deleteCatalog(servers, menu, menu[3])

			assert.same({ "A", "C" }, pluck(servers, "title"))
			assert.same({ "Downloads", "A", "C" }, pluck(menu, "text"))
		end)

		it("returns the menu it was given", function()
			local servers, menu = threeCatalogs()

			assert.equals(menu, CatalogManager.deleteCatalog(servers, menu, menu[3]))
		end)

		it("removes the first catalog", function()
			local servers, menu = threeCatalogs()

			CatalogManager.deleteCatalog(servers, menu, menu[2])

			assert.same({ "B", "C" }, pluck(servers, "title"))
			assert.same({ "Downloads", "B", "C" }, pluck(menu, "text"))
		end)

		it("removes the last catalog", function()
			local servers, menu = threeCatalogs()

			CatalogManager.deleteCatalog(servers, menu, menu[4])

			assert.same({ "A", "B" }, pluck(servers, "title"))
			assert.same({ "Downloads", "A", "B" }, pluck(menu, "text"))
		end)

		it("removes the only catalog and keeps the Downloads entry", function()
			local servers, menu = library({ { title = "A", url = "http://a.example/opds" } })

			CatalogManager.deleteCatalog(servers, menu, menu[2])

			assert.same({}, servers)
			assert.same({ "Downloads" }, pluck(menu, "text"))
		end)

		it("stops the headers of a deleted catalog from applying", function()
			local servers, menu = library({
				{ title = "A", url = "http://a.example/opds", headers = { { name = "X-Token", value = "abc" } } },
			})

			CatalogManager.deleteCatalog(servers, menu, menu[2])

			assert.is_nil(RequestHeaders.forUrl(servers, "http://a.example/opds"))
		end)
	end)

	it("keeps the catalog list and the menu in step through adds, an edit and a delete", function()
		local servers, menu = library({})

		CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "One", "http://one.example" }))
		CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Two", "http://two.example" }))
		CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Three", "http://three.example" }))
		numbered(menu)
		CatalogManager.editCatalogFromInput(servers, menu, dialogFields({ "Two edited", "http://two.example" }), menu[3])
		numbered(menu)
		CatalogManager.deleteCatalog(servers, menu, menu[2])

		assert.same({ "Two edited", "Three" }, pluck(servers, "title"))
		assert.same({ "Downloads", "Two edited", "Three" }, pluck(menu, "text"))
		assert.same({ "http://two.example", "http://three.example" }, pluck(servers, "url"))
		assert.same({ "http://two.example", "http://three.example" }, { menu[2].url, menu[3].url })
	end)

	describe("findCatalogByUrl", function()
		it("returns the catalog and its position", function()
			local a = { title = "A", url = "http://a.example/opds" }
			local b = { title = "B", url = "http://b.example/opds" }

			local found, idx = CatalogManager.findCatalogByUrl({ a, b }, "http://b.example/opds")

			assert.equals(b, found)
			assert.equals(2, idx)
		end)

		it("returns nil for a URL that differs even slightly", function()
			local servers = { { title = "A", url = "http://a.example/opds" } }

			local found, idx = CatalogManager.findCatalogByUrl(servers, "http://a.example/opds/")

			assert.is_nil(found)
			assert.is_nil(idx)
		end)

		it("returns the first of several catalogs with the same URL", function()
			local first = { title = "First", url = "http://a.example/opds" }
			local second = { title = "Second", url = "http://a.example/opds" }

			local found, idx = CatalogManager.findCatalogByUrl({ first, second }, "http://a.example/opds")

			assert.equals(first, found)
			assert.equals(1, idx)
		end)
	end)

	describe("findCatalogByTitle", function()
		it("returns the catalog and its position", function()
			local a = { title = "A", url = "http://a.example/opds" }
			local b = { title = "B", url = "http://b.example/opds" }

			local found, idx = CatalogManager.findCatalogByTitle({ a, b }, "B")

			assert.equals(b, found)
			assert.equals(2, idx)
		end)

		it("returns nil when no catalog has exactly that title", function()
			local servers = { { title = "Library", url = "http://a.example/opds" } }

			local found, idx = CatalogManager.findCatalogByTitle(servers, "library")

			assert.is_nil(found)
			assert.is_nil(idx)
		end)
	end)

	describe("default catalog", function()
		local a, b, c, servers

		before_each(function()
			a = { title = "A", url = "http://a.example/opds" }
			b = { title = "B", url = "http://b.example/opds" }
			c = { title = "C", url = "http://c.example/opds" }
			servers = { a, b, c }
		end)

		it("is none until one is chosen", function()
			local found, idx = CatalogManager.findDefaultCatalog(servers)

			assert.is_nil(found)
			assert.is_nil(idx)
		end)

		it("is found with its position once chosen", function()
			CatalogManager.setDefaultCatalog(servers, b)

			local found, idx = CatalogManager.findDefaultCatalog(servers)

			assert.equals(b, found)
			assert.equals(2, idx)
		end)

		it("moves to the newly chosen catalog, leaving no flag on the old one", function()
			CatalogManager.setDefaultCatalog(servers, a)

			CatalogManager.setDefaultCatalog(servers, c)

			assert.is_nil(a.is_default)
			assert.is_nil(b.is_default)
			assert.is_true(c.is_default)
		end)

		it("is recognised by the catalog itself, not by catalogs that look the same", function()
			local twin_one = { title = "Same", url = "http://same.example/opds" }
			local twin_two = { title = "Same", url = "http://same.example/opds" }

			CatalogManager.setDefaultCatalog({ twin_one, twin_two }, twin_two)

			assert.is_nil(twin_one.is_default)
			assert.is_true(twin_two.is_default)
		end)

		it("is cleared when no catalog is given", function()
			CatalogManager.setDefaultCatalog(servers, b)

			CatalogManager.setDefaultCatalog(servers, nil)

			assert.is_nil(CatalogManager.findDefaultCatalog(servers))
			assert.is_nil(b.is_default)
		end)

		it("ends up being a single catalog even if several were flagged in a hand-edited settings file", function()
			a.is_default, b.is_default, c.is_default = true, true, true

			CatalogManager.setDefaultCatalog(servers, b)

			assert.is_nil(a.is_default)
			assert.is_true(b.is_default)
			assert.is_nil(c.is_default)
		end)

		it("is the first flagged catalog when several are flagged", function()
			b.is_default, c.is_default = true, true

			local found, idx = CatalogManager.findDefaultCatalog(servers)

			assert.equals(b, found)
			assert.equals(2, idx)
		end)

		it("is not a catalog flagged with false", function()
			a.is_default = false

			assert.is_nil(CatalogManager.findDefaultCatalog(servers))
		end)
	end)

	describe("validateCatalogUrl", function()
		local accepted = {
			{ "https://example.org/opds", "https://example.org/opds" },
			{ "http://example.org/opds", "http://example.org/opds" },
			{ "https://example.org:8443/opds/", "https://example.org:8443/opds/" },
			{ "http://192.168.1.10:8083/opds", "http://192.168.1.10:8083/opds" },
			{ "http://my-server.local/opds", "http://my-server.local/opds" },
			{ "http://user:secret@example.org/opds", "http://user:secret@example.org/opds" },
			{ "http://example.org/search?q=%s", "http://example.org/search?q=%s" },
			{ "example.org/opds", "http://example.org/opds" },
			{ "example.org", "http://example.org" },
			{ "localhost:8080/opds", "http://localhost:8080/opds" },
			{ "192.168.1.10:8083/opds", "http://192.168.1.10:8083/opds" },
			-- Docker and NAS host names often have underscores
			{ "http://calibre_web:8083/opds", "http://calibre_web:8083/opds" },
			{ "my_nas.local/opds", "http://my_nas.local/opds" },
			{ "http://[::1]:8083/opds", "http://[::1]:8083/opds" },
			{ "https://[fe80::1]/opds", "https://[fe80::1]/opds" },
			{ "[::1]:8083/opds", "http://[::1]:8083/opds" },
			{ "http://example.org:/opds", "http://example.org:/opds" },
			-- A protocol in capitals is not understood when it is sent, so it is stored in lower case
			{ "HTTP://example.org/opds", "http://example.org/opds" },
			{ "Https://Example.org/OPDS", "https://Example.org/OPDS" },
			-- Whitespace around a pasted URL is not part of it
			{ "  https://example.org/opds  ", "https://example.org/opds" },
			{ "example.org/opds\n", "http://example.org/opds" },
			{ "\thttp://example.org/opds\r\n", "http://example.org/opds" },
		}
		for _, case in ipairs(accepted) do
			it("accepts " .. string.format("%q", case[1]) .. " as " .. case[2], function()
				local ok, url = CatalogManager.validateCatalogUrl(case[1])

				assert.is_true(ok)
				assert.equals(case[2], url)
			end)
		end

		local rejected = {
			{ "no URL", nil, "URL cannot be empty" },
			{ "an empty URL", "", "URL cannot be empty" },
			{ "an FTP URL", "ftp://example.org/opds", "Only HTTP and HTTPS protocols are supported" },
			{ "a file URL", "file:///etc/passwd", "Only HTTP and HTTPS protocols are supported" },
			{ "an opds:// URL", "opds://example.org/feed", "Only HTTP and HTTPS protocols are supported" },
			{ "a URL without a host", "http://", "Missing hostname" },
			{ "a URL with only a path", "http:///opds", "Missing hostname" },
			{ "a URL with only a port", "https://:8080/opds", "Missing hostname" },
			{ "a host with a space", "http://exa mple.org/opds", "Invalid hostname format" },
			{ "a host with a special character", "http://exa$mple.org/opds", "Invalid hostname format" },
			{ "a host with a colon but no brackets", "http://exa:mple/opds", "Invalid port" },
			{ "an IPv6 address without brackets", "http://fe80::1/opds", "Invalid hostname format" },
			{ "an IPv6 address with a stray bracket", "http://[::1/opds", "Invalid hostname format" },
			{ "only spaces", "   ", "URL cannot be empty" },
			{ "only a line break", "\n", "URL cannot be empty" },
			{ "a port that is not a number", "http://example.org:80a/opds", "Invalid port" },
			{ "a port that is too big", "http://example.org:65536/opds", "Invalid port" },
			{ "port 0", "http://example.org:0/opds", "Invalid port" },
		}
		for _, case in ipairs(rejected) do
			it("rejects " .. case[1] .. " and says why", function()
				local ok, message = CatalogManager.validateCatalogUrl(case[2])

				assert.is_false(ok)
				assert.equals(case[3], message)
			end)
		end

		it("accepts the highest port", function()
			assert.same({ true, "http://example.org:65535/opds" }, { CatalogManager.validateCatalogUrl("http://example.org:65535/opds") })
		end)

		it("translates the messages it gives", function()
			helper.reset()
			local translating = helper.load("core.catalog_manager", {
				gettext = function(text)
					return "<" .. text .. ">"
				end,
			})
			local messages = {}
			for _, typed in ipairs({ "", "ftp://example.org", "http://", "http://exa$mple.org", "http://example.org:99999" }) do
				messages[#messages + 1] = select(2, translating.validateCatalogUrl(typed))
			end

			assert.same({
				"<URL cannot be empty>",
				"<Only HTTP and HTTPS protocols are supported>",
				"<Missing hostname>",
				"<Invalid hostname format>",
				"<Invalid port>",
			}, messages)
		end)
	end)

	describe("getSyncEnabledCatalogs", function()
		it("lists the catalogs with sync turned on, in order", function()
			local servers = {
				{ title = "A", sync = true },
				{ title = "B", sync = false },
				{ title = "C" },
				{ title = "D", sync = true },
			}

			assert.same({ "A", "D" }, pluck(CatalogManager.getSyncEnabledCatalogs(servers), "title"))
		end)

		it("returns an empty list when no catalog syncs", function()
			assert.same({}, CatalogManager.getSyncEnabledCatalogs({ { title = "A" } }))
		end)
	end)

	describe("getAuthenticatedCatalogs", function()
		it("lists the catalogs that have a username, in order", function()
			local servers = {
				{ title = "A", username = "me" },
				{ title = "B" },
				{ title = "C", username = "you", password = "pw" },
			}

			assert.same({ "A", "C" }, pluck(CatalogManager.getAuthenticatedCatalogs(servers), "title"))
		end)

		it("returns an empty list when no catalog needs a login", function()
			assert.same({}, CatalogManager.getAuthenticatedCatalogs({ { title = "A" } }))
		end)
	end)

	describe("getCatalogStats", function()
		it("counts catalogs, logins, syncing catalogs and searchable catalogs", function()
			local stats = CatalogManager.getCatalogStats({
				{ title = "A", url = "https://a.example/opds", username = "me", sync = true },
				{ title = "B", url = "https://b.example/search?q=%s", sync = true },
				{ title = "C", url = "https://c.example/my%20books" },
				{ title = "D", url = "https://d.example/search/%s/1", username = "you" },
			})

			assert.same({ total = 4, with_auth = 2, with_sync = 2, searchable = 2 }, stats)
		end)

		it("counts nothing for an empty list", function()
			assert.same({ total = 0, with_auth = 0, with_sync = 0, searchable = 0 }, CatalogManager.getCatalogStats({}))
		end)

		it("does not count a percent-encoded %25s as a search placeholder", function()
			local stats = CatalogManager.getCatalogStats({ { title = "A", url = "https://a.example/q?x=%25s" } })

			assert.equals(0, stats.searchable)
		end)

		it("copes with a catalog that has no URL", function()
			local stats = CatalogManager.getCatalogStats({ { title = "A" } })

			assert.same({ total = 1, with_auth = 0, with_sync = 0, searchable = 0 }, stats)
		end)

		it("counts as searchable the catalogs the menu offers a search for", function()
			local servers = {
				{ title = "A", url = "https://a.example/search?q=%s" },
				{ title = "B", url = "https://b.example/opds" },
				{ title = "C", url = "https://c.example/%20/%s" },
			}
			local offered = 0
			for _, entry in ipairs(CatalogManager.genItemTableFromRoot(servers, {}, identity)) do
				if entry.searchable then
					offered = offered + 1
				end
			end

			assert.equals(offered, CatalogManager.getCatalogStats(servers).searchable)
		end)
	end)

	describe("exportCatalogs", function()
		local function catalogs()
			return {
				{
					title = "A",
					url = "http://a.example/opds",
					username = "me",
					password = "secret",
					raw_names = true,
					sync = true,
					last_download = "http://a.example/book/9",
					is_default = true,
				},
				{ title = "B", url = "http://b.example/opds" },
			}
		end

		it("exports the title, URL and options without credentials, sync state or default flag", function()
			assert.same({
				{ title = "A", url = "http://a.example/opds", raw_names = true, sync = true },
				{ title = "B", url = "http://b.example/opds" },
			}, CatalogManager.exportCatalogs(catalogs()))
		end)

		it("adds the username and password when asked to", function()
			local exported = CatalogManager.exportCatalogs(catalogs(), true)

			assert.same({
				title = "A",
				url = "http://a.example/opds",
				username = "me",
				password = "secret",
				raw_names = true,
				sync = true,
			}, exported[1])
		end)

		it("exports copies that can be changed without touching the catalogs", function()
			local servers = catalogs()

			CatalogManager.exportCatalogs(servers)[1].title = "changed"

			assert.equals("A", servers[1].title)
		end)

		it("exports an empty list as an empty list", function()
			assert.same({}, CatalogManager.exportCatalogs({}))
		end)
	end)

	describe("importCatalogs", function()
		it("appends the catalogs and reports how many were imported", function()
			local servers = { { title = "Old", url = "http://old.example/opds" } }

			local imported, skipped = CatalogManager.importCatalogs(servers, {
				{ title = "B", url = "http://b.example/opds" },
				{
					title = "C",
					url = "http://c.example/opds",
					username = "me",
					password = "secret",
					raw_names = true,
					sync = true,
				},
			})

			assert.equals(2, imported)
			assert.equals(0, skipped)
			assert.same({ "Old", "B", "C" }, pluck(servers, "title"))
			assert.same({
				title = "C",
				url = "http://c.example/opds",
				username = "me",
				password = "secret",
				raw_names = true,
				sync = true,
			}, servers[3])
		end)

		it("skips entries that lack a title or a URL", function()
			local servers = {}

			local imported, skipped = CatalogManager.importCatalogs(servers, {
				{ url = "http://no-title.example/opds" },
				{ title = "No URL" },
				{ title = "Fine", url = "http://fine.example/opds" },
			})

			assert.equals(1, imported)
			assert.equals(2, skipped)
			assert.same({ "Fine" }, pluck(servers, "title"))
		end)

		it("imports a catalog whose URL is already listed unless asked to merge", function()
			local servers = { { title = "Old", url = "http://a.example/opds" } }

			local imported, skipped =
				CatalogManager.importCatalogs(servers, { { title = "Again", url = "http://a.example/opds" } })

			assert.equals(1, imported)
			assert.equals(0, skipped)
			assert.same({ "Old", "Again" }, pluck(servers, "title"))
		end)

		it("skips a catalog whose URL is already listed when merging", function()
			local servers = { { title = "Old", url = "http://a.example/opds" } }

			local imported, skipped = CatalogManager.importCatalogs(servers, {
				{ title = "Again", url = "http://a.example/opds" },
				{ title = "New", url = "http://new.example/opds" },
			}, true)

			assert.equals(1, imported)
			assert.equals(1, skipped)
			assert.same({ "Old", "New" }, pluck(servers, "title"))
		end)

		it("skips repeats within the imported data when merging", function()
			local servers = {}

			local imported, skipped = CatalogManager.importCatalogs(servers, {
				{ title = "First", url = "http://a.example/opds" },
				{ title = "Second", url = "http://a.example/opds" },
			}, true)

			assert.equals(1, imported)
			assert.equals(1, skipped)
			assert.same({ "First" }, pluck(servers, "title"))
		end)

		it("imports nothing from an empty list", function()
			local servers = {}

			local imported, skipped = CatalogManager.importCatalogs(servers, {})

			assert.equals(0, imported)
			assert.equals(0, skipped)
			assert.same({}, servers)
		end)

		it("restores what exportCatalogs exported with credentials", function()
			local original = {
				{ title = "A", url = "http://a.example/opds", username = "me", password = "secret", raw_names = true, sync = true },
				{ title = "B", url = "http://b.example/opds" },
			}
			local restored = {}

			CatalogManager.importCatalogs(restored, CatalogManager.exportCatalogs(original, true), true)

			assert.same(original, restored)
		end)
	end)

	describe("sortCatalogs", function()
		local function catalogs()
			return {
				{ title = "banana", url = "http://c.example/opds" },
				{ title = "cherry", url = "http://a.example/opds" },
				{ title = "apple", url = "http://b.example/opds" },
			}
		end

		it("sorts by title, ascending", function()
			assert.same({ "apple", "banana", "cherry" }, pluck(CatalogManager.sortCatalogs(catalogs(), "title", true), "title"))
		end)

		it("sorts by title, descending", function()
			assert.same({ "cherry", "banana", "apple" }, pluck(CatalogManager.sortCatalogs(catalogs(), "title", false), "title"))
		end)

		it("sorts by URL, ascending", function()
			assert.same({ "cherry", "apple", "banana" }, pluck(CatalogManager.sortCatalogs(catalogs(), "url", true), "title"))
		end)

		it("sorts by URL, descending", function()
			assert.same({ "banana", "apple", "cherry" }, pluck(CatalogManager.sortCatalogs(catalogs(), "url", false), "title"))
		end)

		it("sorts catalogs without sync before those with sync, ascending", function()
			local servers = { { title = "on", sync = true }, { title = "off" } }

			assert.same({ "off", "on" }, pluck(CatalogManager.sortCatalogs(servers, "sync", true), "title"))
		end)

		it("sorts catalogs with sync before those without, descending", function()
			local servers = { { title = "off" }, { title = "on", sync = true } }

			assert.same({ "on", "off" }, pluck(CatalogManager.sortCatalogs(servers, "sync", false), "title"))
		end)

		it("sorts a catalog without a title before the others, ascending", function()
			local servers = { { title = "apple" }, { url = "http://untitled.example/opds" } }

			local sorted = CatalogManager.sortCatalogs(servers, "title", true)

			assert.equals("http://untitled.example/opds", sorted[1].url)
			assert.equals("apple", sorted[2].title)
		end)

		it("returns a new list and leaves the given one in its order", function()
			local servers = catalogs()

			local sorted = CatalogManager.sortCatalogs(servers, "title", true)

			assert.are_not.equal(servers, sorted)
			assert.same({ "banana", "cherry", "apple" }, pluck(servers, "title"))
		end)

		it("keeps every catalog when the sort key is unknown", function()
			local sorted = CatalogManager.sortCatalogs(catalogs(), "size", true)

			local titles = pluck(sorted, "title")
			table.sort(titles)
			assert.same({ "apple", "banana", "cherry" }, titles)
		end)
	end)

	describe("duplicateCatalog", function()
		local function original()
			return {
				title = "Shelf",
				url = "https://example.org/opds",
				username = "me",
				password = "secret",
				raw_names = true,
				sync = true,
				last_download = "https://example.org/book/9",
				is_default = true,
			}
		end

		it("copies the connection details but not the sync marker or the default flag", function()
			assert.same({
				title = "Copy of Shelf",
				url = "https://example.org/opds",
				username = "me",
				password = "secret",
				raw_names = true,
				sync = true,
			}, CatalogManager.duplicateCatalog(original()))
		end)

		it("uses the given title", function()
			assert.equals("Backup", CatalogManager.duplicateCatalog(original(), "Backup").title)
		end)

		it("builds the default title with the translation of \"Copy of \"", function()
			helper.reset()
			local translating = helper.load("core.catalog_manager", {
				gettext = function(text)
					return text == "Copy of " and "Kopie van " or text
				end,
			})

			assert.equals("Kopie van Shelf", translating.duplicateCatalog(original()).title)
		end)

		it("copies the custom HTTP headers, so the copy still reaches a server that needs them", function()
			local server = original()
			server.headers = { { name = "X-Token", value = "abc" } }

			local copy = CatalogManager.duplicateCatalog(server)

			assert.same({ { name = "X-Token", value = "abc" } }, copy.headers)
		end)

		it("does not share the header list with the original, so editing one leaves the other alone", function()
			local server = original()
			server.headers = { { name = "X-Token", value = "abc" } }

			local copy = CatalogManager.duplicateCatalog(server)
			copy.headers[1].value = "changed"
			table.insert(copy.headers, { name = "X-Other", value = "1" })

			assert.same({ { name = "X-Token", value = "abc" } }, server.headers)
		end)

		it("gives a catalog without headers none, not an empty list", function()
			local server = original()
			server.headers = {}

			assert.is_nil(CatalogManager.duplicateCatalog(server).headers)
		end)
	end)
end)
