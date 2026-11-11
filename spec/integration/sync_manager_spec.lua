local helper = require("helper")
local ui_stub = require("support.ui")
local registry_stub = require("support.documentregistry")

describe("SyncManager", function()
	local SyncManager, DownloadManager, Constants
	local ui, state, device, registry, chooser, downloads, duplicates_to_return, dir

	local SERVER_URL = "https://library.example.org/opds"
	local BOOKS = "https://library.example.org/dl/"

	-- The real download manager gives sync its getFiletype; only the downloading itself is replaced.
	local function load_sync()
		local stubs = {
			device = device,
			["document/documentregistry"] = registry,
			docsettings = {},
			["socket.http"] = {},
			socketutil = {},
			["ui/downloadmgr"] = chooser,
			["core.state_manager"] = {
				getInstance = function()
					return state
				end,
			},
		}
		for name, stand_in in pairs(ui.stubs) do
			stubs[name] = stand_in
		end
		SyncManager = helper.load("core.sync_manager", stubs)
		Constants = require("models.constants")
		DownloadManager = require("core.download_manager")
		-- helper.reset unloads this module and its per-test replacement.
		---@diagnostic disable-next-line: duplicate-set-field
		DownloadManager.downloadPendingSyncs = function(browser, dl_list)
			local snapshot = {}
			for index, item in ipairs(dl_list) do
				snapshot[index] = item
			end
			downloads[#downloads + 1] = { list = snapshot, forced = browser.sync_force }
			return duplicates_to_return
		end
	end

	-- An entry as genItemTableFromCatalog builds it, with one acquisition link per href.
	local function book(title, hrefs, fields)
		local item = { title = title, acquisitions = {} }
		for _, href in ipairs(type(hrefs) == "table" and hrefs or { hrefs }) do
			item.acquisitions[#item.acquisitions + 1] = { href = href, type = "application/octet-stream" }
		end
		for key, value in pairs(fields or {}) do
			item[key] = value
		end
		return item
	end

	-- What browser:genItemTableFromURL gives for a feed: the entries, and the links of the feed in `hrefs`.
	local function page(entries, next_href)
		local items = { hrefs = { next = next_href } }
		for index, item in ipairs(entries) do
			items[index] = item
		end
		return items
	end

	-- The parts of OPDSBrowser that sync uses. `pages` maps a feed address to what fetching it gives.
	local function new_browser(pages, fields)
		local browser = {
			settings = { sync_dir = "/sync" },
			servers = {},
			pending_syncs = {},
			fetched = {},
			updated = {},
			genItemTableFromURL = function(self, url)
				self.fetched[#self.fetched + 1] = url
				local result = pages[url]
				if type(result) == "function" then
					return result(self)
				end
				return result or {}
			end,
			getFileName = function(_, item)
				return item.title
			end,
			getLocalDownloadPath = function(_, filename, filetype)
				return "/sync/" .. filename .. "." .. filetype
			end,
			updateFieldInCatalog = function(self, server, name, value)
				self.updated[#self.updated + 1] = { server = server, name = name, value = value }
			end,
		}
		for key, value in pairs(fields or {}) do
			browser[key] = value
		end
		return browser
	end

	local function new_server(fields)
		local server = { url = SERVER_URL, title = "Library", sync = true }
		for key, value in pairs(fields or {}) do
			server[key] = value
		end
		return server
	end

	before_each(function()
		helper.reset()
		ui = ui_stub.new()
		registry = registry_stub.new()
		state = {
			dirty = 0,
			markDirty = function(self)
				self.dirty = self.dirty + 1
			end,
		}
		device = { home_dir = "/sdcard", isAndroid = function() return false end }
		chooser = {
			new = function(self, options)
				self.options = options
				return self
			end,
			chooseDir = function(self, start_dir)
				self.start_dir = start_dir
				self.chosen = true
			end,
		}
		downloads = {}
		duplicates_to_return = nil
		dir = helper.tmpdir()
		load_sync()
	end)

	after_each(helper.reset)

	describe("parseFiletypes", function()
		it("is nil without a list, which means every type", function()
			assert.is_nil(SyncManager.parseFiletypes(nil))
		end)

		it("makes a lookup of the types in the list", function()
			assert.same({ epub = true, mobi = true }, SyncManager.parseFiletypes("epub, mobi"))
		end)

		it("ignores case, spaces and empty items", function()
			assert.same({ epub = true, mobi = true }, SyncManager.parseFiletypes(" EPUB ,  Mobi,, "))
		end)

		it("is nil, which means every type, when the list has nothing in it", function()
			assert.is_nil(SyncManager.parseFiletypes(""))
			assert.is_nil(SyncManager.parseFiletypes(" , ,"))
		end)
	end)

	describe("getSyncDownloadList", function()
		local server

		before_each(function()
			server = new_server()
		end)

		local function sync_list(pages, fields)
			local browser = new_browser(pages, fields)
			browser.sync_server = server
			browser.sync_max_dl = browser.sync_max_dl or 50
			return SyncManager.getSyncDownloadList(browser), browser
		end

		it("gives the entries of the feed, newest first", function()
			local newest, older = book("New", BOOKS .. "new.epub"), book("Old", BOOKS .. "old.epub")

			local list = sync_list({ [SERVER_URL] = page({ newest, older }) })

			assert.same({ newest, older }, list)
		end)

		it("stops at the book that came last time", function()
			local newest = book("New", BOOKS .. "new.epub")
			server.last_download = BOOKS .. "old.epub"

			local list = sync_list({
				[SERVER_URL] = page({ newest, book("Old", BOOKS .. "old.epub"), book("Older", BOOKS .. "older.epub") }),
			})

			assert.same({ newest }, list)
		end)

		it("gives nil when the newest book is the one that came last time", function()
			server.last_download = BOOKS .. "new.epub"

			local list = sync_list({ [SERVER_URL] = page({ book("New", BOOKS .. "new.epub") }) })

			assert.is_nil(list)
		end)

		it("takes everything when forced", function()
			server.last_download = BOOKS .. "new.epub"

			local list = sync_list({
				[SERVER_URL] = page({ book("New", BOOKS .. "new.epub"), book("Old", BOOKS .. "old.epub") }),
			}, { sync_force = true })

			assert.equals(2, #list)
		end)

		it("follows the next page until it has enough", function()
			local pages = {
				[SERVER_URL] = page({ book("A", BOOKS .. "a.epub"), book("B", BOOKS .. "b.epub") }, SERVER_URL .. "?page=2"),
				[SERVER_URL .. "?page=2"] = page({ book("C", BOOKS .. "c.epub"), book("D", BOOKS .. "d.epub") }),
			}

			local list, browser = sync_list(pages, { sync_max_dl = 3 })

			assert.equals(4, #list)
			assert.same({ SERVER_URL, SERVER_URL .. "?page=2" }, browser.fetched)
		end)

		it("does not fetch more pages than it needs", function()
			local pages = {
				[SERVER_URL] = page({ book("A", BOOKS .. "a.epub"), book("B", BOOKS .. "b.epub") }, SERVER_URL .. "?page=2"),
			}

			local list, browser = sync_list(pages, { sync_max_dl = 2 })

			assert.equals(2, #list)
			assert.same({ SERVER_URL }, browser.fetched)
		end)

		it("stops at the last page", function()
			local list, browser = sync_list({ [SERVER_URL] = page({ book("A", BOOKS .. "a.epub") }) })

			assert.equals(1, #list)
			assert.equals(1, #browser.fetched)
		end)

		it("keeps what it has when a later page comes back empty", function()
			local pages = {
				[SERVER_URL] = page({ book("A", BOOKS .. "a.epub") }, SERVER_URL .. "?page=2"),
				[SERVER_URL .. "?page=2"] = {},
			}

			local list = sync_list(pages)

			assert.equals(1, #list)
		end)

		it("does not turn to the next page once it reaches the book from last time", function()
			server.last_download = BOOKS .. "b.epub"
			local pages = {
				[SERVER_URL] = page({ book("A", BOOKS .. "a.epub"), book("B", BOOKS .. "b.epub") }, SERVER_URL .. "?page=2"),
			}

			local list, browser = sync_list(pages)

			assert.equals(1, #list)
			assert.same({ SERVER_URL }, browser.fetched)
		end)

		it("skips entries without a book, such as a notice at the top", function()
			local notice = { title = "Notice", acquisitions = {} }
			local wanted = book("A", BOOKS .. "a.epub")

			local list = sync_list({ [SERVER_URL] = page({ notice, wanted }) })

			assert.same({ wanted }, list)
		end)

		it("gives an empty list for a feed without a single book", function()
			local list = sync_list({
				[SERVER_URL] = page({ { title = "Authors", acquisitions = {} }, { title = "Series", acquisitions = {} } }),
			})

			assert.same({}, list)
		end)

		it("gives an empty list when the feed can't be fetched", function()
			local list = sync_list({})

			assert.same({}, list)
		end)

		it("takes entries that only point to a book's own feed, as Project Gutenberg's do", function()
			local first = { title = "Alice", url = "https://pg.example.org/ebooks/1.opds", acquisitions = {} }
			local second = { title = "Moby Dick", url = "https://pg.example.org/ebooks/2.opds", acquisitions = {} }

			local list = sync_list({ [SERVER_URL] = page({ first, second }) })

			assert.same({ first, second }, list)
		end)

		it("stops at the book feed from last time", function()
			local first = { title = "Alice", url = "https://pg.example.org/ebooks/1.opds", acquisitions = {} }
			local second = { title = "Moby Dick", url = "https://pg.example.org/ebooks/2.opds", acquisitions = {} }
			server.last_download = second.url

			local list = sync_list({ [SERVER_URL] = page({ first, second }) })

			assert.same({ first }, list)
		end)
	end)

	describe("fillPendingSyncs", function()
		local server

		before_each(function()
			server = new_server({ username = "reader", password = "secret" })
		end)

		local function fill(pages, fields)
			local browser = new_browser(pages, fields)
			SyncManager.fillPendingSyncs(browser, server)
			return browser
		end

		it("queues the new books with where to put them and how to fetch them", function()
			local browser = fill({
				[SERVER_URL] = page({ book("Dune", BOOKS .. "dune.epub", { content = "A desert planet." }) }),
			})

			assert.same({
				{
					file = "/sync/Dune.epub",
					url = BOOKS .. "dune.epub",
					username = "reader",
					password = "secret",
					catalog = SERVER_URL,
					info = "A desert planet.",
				},
			}, browser.pending_syncs)
		end)

		it("takes over the catalog's details and marks the catalog as synced", function()
			server.raw_names = true

			local browser = fill({ [SERVER_URL] = page({ book("Dune", BOOKS .. "dune.epub") }) })

			assert.equals("reader", browser.root_catalog_username)
			assert.equals("secret", browser.root_catalog_password)
			assert.equals("Library", browser.root_catalog_title)
			assert.is_true(browser.root_catalog_raw_names)
			assert.equals(server, browser.sync_server)
			assert.same({ [SERVER_URL] = true }, browser.sync_server_list)
		end)

		it("remembers the newest book, to stop there next time", function()
			local browser = fill({
				[SERVER_URL] = page({ book("New", BOOKS .. "new.epub"), book("Old", BOOKS .. "old.epub") }),
			})

			assert.same({ { server = server, name = "last_download", value = BOOKS .. "new.epub" } }, browser.updated)
		end)

		it("queues nothing, and remembers nothing, when nothing is new", function()
			server.last_download = BOOKS .. "new.epub"

			local browser = fill({ [SERVER_URL] = page({ book("New", BOOKS .. "new.epub") }) })

			assert.same({}, browser.pending_syncs)
			assert.same({}, browser.updated)
			assert.same({ [SERVER_URL] = true }, browser.sync_server_list)
		end)

		it("queues at most the number of books set in the settings", function()
			local entries = {}
			for index = 1, 5 do
				entries[index] = book("Book " .. index, BOOKS .. index .. ".epub")
			end

			local browser = fill({ [SERVER_URL] = page(entries) }, { settings = { sync_dir = "/sync", sync_max_dl = 3 } })

			assert.equals(3, #browser.pending_syncs)
			assert.equals(BOOKS .. "1.epub", browser.pending_syncs[1].url)
			assert.equals(BOOKS .. "3.epub", browser.pending_syncs[3].url)
		end)

		it("queues up to the default number of books when the settings give none", function()
			local browser = fill({ [SERVER_URL] = page({ book("Dune", BOOKS .. "dune.epub") }) })

			assert.equals(Constants.SYNC.DEFAULT_MAX_DOWNLOADS, browser.sync_max_dl)
		end)

		it("queues one file per book, the first type KOReader can open", function()
			local browser = fill({
				[SERVER_URL] = page({ book("Dune", { BOOKS .. "dune.xyz", BOOKS .. "dune.epub", BOOKS .. "dune.pdf" }) }),
			})

			assert.equals(1, #browser.pending_syncs)
			assert.equals(BOOKS .. "dune.epub", browser.pending_syncs[1].url)
		end)

		it("skips a book that comes in no type KOReader can open", function()
			local browser = fill({ [SERVER_URL] = page({ book("Dune", BOOKS .. "dune.xyz") }) })

			assert.same({}, browser.pending_syncs)
		end)

		it("takes only the types the user asked for", function()
			local epub_only = book("Epub only", BOOKS .. "one.epub")
			local both = book("Both", { BOOKS .. "two.epub", BOOKS .. "two.pdf" })

			local browser = fill(
				{ [SERVER_URL] = page({ epub_only, both }) },
				{ settings = { sync_dir = "/sync", filetypes = "pdf" } }
			)

			assert.equals(1, #browser.pending_syncs)
			assert.equals(BOOKS .. "two.pdf", browser.pending_syncs[1].url)
		end)

		it("does not mind the case of the types the user asked for, or of the file extension", function()
			local browser = fill(
				{ [SERVER_URL] = page({ book("Shouting", BOOKS .. "SHOUTING.EPUB"), book("Quiet", BOOKS .. "quiet.epub") }) },
				{ settings = { sync_dir = "/sync", filetypes = "EPUB" } }
			)

			assert.equals(2, #browser.pending_syncs)
		end)

		it("takes the second entry of a book's own feed, which has the most options", function()
			local entry = { title = "Alice", url = "https://pg.example.org/ebooks/1.opds", acquisitions = {} }
			local pages = {
				[SERVER_URL] = page({ entry }),
				[entry.url] = page({
					book("Alice (short)", "https://pg.example.org/ebooks/1.txt"),
					book("Alice", { "https://pg.example.org/ebooks/1.epub", "https://pg.example.org/ebooks/1.mobi" }),
				}),
			}

			local browser = fill(pages)

			assert.equals(1, #browser.pending_syncs)
			assert.equals("https://pg.example.org/ebooks/1.epub", browser.pending_syncs[1].url)
		end)
	end)

	describe("checkAndStartSync", function()
		local function feed(title, fields)
			return page({ book(title, BOOKS .. title .. ".epub", fields) })
		end

		it("asks for a sync folder first", function()
			local browser = new_browser({}, { settings = {} })

			SyncManager.checkAndStartSync(browser)

			assert.truthy(ui:last().text:find("Please choose a folder for sync downloads first.", 1, true))
			assert.is_nil(browser.sync)
			assert.same({}, downloads)
		end)

		it("says when no catalog is set to sync", function()
			local browser = new_browser({})
			browser.servers = { new_server({ sync = false }) }

			SyncManager.checkAndStartSync(browser)

			assert.truthy(ui:last().text:find("No catalogs are set to sync.", 1, true))
			assert.same({}, browser.fetched)
		end)

		it("syncs the catalogs set to sync", function()
			local one = new_server({ url = "https://one.example.org/opds", title = "One" })
			local two = new_server({ url = "https://two.example.org/opds", title = "Two", sync = false })
			local three = new_server({ url = "https://three.example.org/opds", title = "Three" })
			local browser = new_browser({
				[one.url] = feed("one"),
				[two.url] = feed("two"),
				[three.url] = feed("three"),
			})
			browser.servers = { one, two, three }

			SyncManager.checkAndStartSync(browser)

			assert.same({ one.url, three.url }, browser.fetched)
			assert.equals(1, #downloads)
			assert.equals(2, #downloads[1].list)
		end)

		it("syncs the one catalog asked for even when it is not set to sync", function()
			local one = new_server({ url = "https://one.example.org/opds", title = "One" })
			local two = new_server({ url = "https://two.example.org/opds", title = "Two", sync = false })
			local browser = new_browser({ [one.url] = feed("one"), [two.url] = feed("two") })
			browser.servers = { one, two }

			-- Row 1 of the list is "Downloads", so the catalog at servers[2] is on row 3
			SyncManager.checkAndStartSync(browser, 3)

			assert.same({ two.url }, browser.fetched)
		end)

		it("is in sync mode only while it reads the feeds, with a notice that goes away", function()
			local during
			local server = new_server()
			local browser = new_browser({
				[SERVER_URL] = function(self)
					during = self.sync
					return feed("dune")
				end,
			})
			browser.servers = { server }

			SyncManager.checkAndStartSync(browser)

			assert.is_true(during)
			assert.is_false(browser.sync)
			assert.equals("Synchronizing lists…", ui.shown[1].text)
			assert.equals(ui.shown[1], ui.closed[1])
		end)

		it("hands the pending books to the download manager", function()
			local browser = new_browser({ [SERVER_URL] = feed("dune") })
			browser.servers = { new_server() }

			SyncManager.checkAndStartSync(browser)

			assert.equals(1, #downloads)
			assert.equals(BOOKS .. "dune.epub", downloads[1].list[1].url)
			assert.is_false(downloads[1].forced == true)
		end)

		it("says so when there is nothing new", function()
			local server = new_server({ last_download = BOOKS .. "dune.epub" })
			local browser = new_browser({ [SERVER_URL] = feed("dune") })
			browser.servers = { server }

			SyncManager.checkAndStartSync(browser)

			assert.equals("Up to date!", ui:last().text)
			assert.same({}, downloads)
		end)

		it("reports a failure, and leaves sync mode and the notice behind it", function()
			local browser = new_browser({
				[SERVER_URL] = function()
					error("feed exploded")
				end,
			})
			browser.servers = { new_server() }

			SyncManager.checkAndStartSync(browser)

			assert.truthy(ui:last().text:find("Sync failed:", 1, true))
			assert.truthy(ui:last().text:find("feed exploded", 1, true))
			assert.is_false(browser.sync)
			assert.equals(ui.shown[1], ui.closed[1])
			assert.same({}, downloads)
		end)
	end)

	describe("downloadPendingSyncs", function()
		local browser, entry

		before_each(function()
			entry = { file = dir .. "/Dune.epub", url = BOOKS .. "dune.epub", catalog = SERVER_URL }
			browser = new_browser({})
			browser.pending_syncs = { entry }
		end)

		it("downloads the pending books and asks nothing when there are no duplicates", function()
			duplicates_to_return = {}

			SyncManager.downloadPendingSyncs(browser)

			assert.equals(1, #downloads)
			assert.same({ entry }, downloads[1].list)
			assert.same({}, ui.shown)
		end)

		describe("when books were already on the device", function()
			local duplicate_viewer

			before_each(function()
				duplicates_to_return = { { file = dir .. "/Dune.epub", url = BOOKS .. "dune.epub" } }
				SyncManager.downloadPendingSyncs(browser)
				duplicate_viewer = ui:last()
			end)

			it("lists them in a dialog", function()
				assert.equals("TextViewer", duplicate_viewer.kind)
				assert.equals("Duplicate files", duplicate_viewer.title)
				assert.equals("These files are already on the device:\n" .. dir .. "/Dune.epub", duplicate_viewer.text)
			end)

			it("does nothing more when the user says so", function()
				ui:press(duplicate_viewer, "Do nothing")

				assert.equals(duplicate_viewer, ui.closed[1])
				assert.equals(1, #downloads)
				assert.is_nil(browser.sync_force)
			end)

			it("downloads them again over the old files when the user wants that", function()
				ui:press(duplicate_viewer, "Overwrite")

				assert.equals(duplicate_viewer, ui.closed[1])
				assert.equals(2, #downloads)
				assert.is_true(downloads[2].forced)
				assert.equals(dir .. "/Dune.epub", downloads[2].list[#downloads[2].list].file)
			end)

			it("downloads them into a folder of copies when the user wants that", function()
				ui:press(duplicate_viewer, "Download copies")

				assert.equals(2, #downloads)
				assert.is_true(downloads[2].forced)
				assert.equals(dir .. "/copies/Dune.epub", duplicates_to_return[1].file)
				assert.equals("directory", require("lfs").attributes(dir .. "/copies", "mode"))
			end)
		end)
	end)

	describe("the settings dialogs", function()
		local browser

		before_each(function()
			browser = new_browser({})
		end)

		it("shows the maximum number of books, and saves the user's choice", function()
			SyncManager.showMaxSyncDialog(browser)

			local spin = ui:last()
			assert.equals("SpinWidget", spin.kind)
			assert.equals(Constants.SYNC.DEFAULT_MAX_DOWNLOADS, spin.value)
			assert.equals(Constants.SYNC.MAX_DOWNLOADS_LIMIT, spin.value_max)

			spin.callback({ value = 120 })

			assert.equals(120, browser.settings.sync_max_dl)
			assert.equals(1, state.dirty)
		end)

		it("starts the maximum at the saved value", function()
			browser.settings.sync_max_dl = 30

			SyncManager.showMaxSyncDialog(browser)

			assert.equals(30, ui:last().value)
		end)

		it("saves the folder the user chooses for sync", function()
			SyncManager.showSyncDirChooser(browser)

			assert.is_true(chooser.chosen)
			assert.is_nil(chooser.start_dir)

			chooser.options.onConfirm("/mnt/sd/Sync")

			assert.equals("/mnt/sd/Sync", browser.settings.sync_dir)
			assert.equals(1, state.dirty)
		end)

		it("starts the folder chooser in the home folder on Android", function()
			device.isAndroid = function()
				return true
			end

			SyncManager.showSyncDirChooser(browser)

			assert.equals("/sdcard", chooser.start_dir)
		end)

		describe("the file types dialog", function()
			it("shows the saved types and the keyboard", function()
				browser.settings.filetypes = "epub, mobi"

				SyncManager.showFiletypesDialog(browser)

				local dialog = ui:last()
				assert.equals("epub, mobi", dialog.input)
				assert.is_true(dialog.keyboard_shown)
			end)

			it("saves what the user typed", function()
				SyncManager.showFiletypesDialog(browser)
				local dialog = ui:last()
				dialog.typed = "epub, pdf"

				ui:press(dialog, "Save")

				assert.equals("epub, pdf", browser.settings.filetypes)
				assert.equals(dialog, ui.closed[1])
				assert.equals(1, state.dirty)
			end)

			it("clears the setting when the user empties the field, which means every type", function()
				browser.settings.filetypes = "epub"
				SyncManager.showFiletypesDialog(browser)
				local dialog = ui:last()
				dialog.typed = ""

				ui:press(dialog, "Save")

				assert.is_nil(browser.settings.filetypes)
			end)

			it("keeps the setting when the user cancels", function()
				browser.settings.filetypes = "epub"
				SyncManager.showFiletypesDialog(browser)
				local dialog = ui:last()
				dialog.typed = "pdf"

				ui:press(dialog, "Cancel")

				assert.equals("epub", browser.settings.filetypes)
				assert.equals(dialog, ui.closed[1])
				assert.equals(0, state.dirty)
			end)
		end)
	end)
end)
