local helper = require("helper")
local lfs = require("lfs")
local fake_http = require("support.fake_http")
local socketutil_stub = require("support.socketutil")
local ui_stub = require("support.ui")
local registry_stub = require("support.documentregistry")
local docsettings_stub = require("support.docsettings")

describe("DownloadManager", function()
	local DownloadManager, Constants, HttpClient
	local http, socketutil, ui, registry, doc_settings, state, device, reader_settings, dir
	local fs = helper.fs

	local HOST = "https://library.example.org"
	local URL = HOST .. "/download/dune.epub"
	local CATALOG = HOST .. "/opds"
	local BODY = "PK-the-book"
	local PROGRESS = "Downloading… (tap to cancel)"

	local function load_manager()
		local stubs = {
			["socket.http"] = http,
			socketutil = socketutil,
			["document/documentregistry"] = registry,
			docsettings = doc_settings,
			device = device,
			["core.state_manager"] = {
				getInstance = function()
					return state
				end,
			},
		}
		for name, stand_in in pairs(ui.stubs) do
			stubs[name] = stand_in
		end
		DownloadManager = helper.load("core.download_manager", stubs)
		Constants = require("models.constants")
		HttpClient = require("services.http_client")
	end

	-- What OPDSBrowser gives the download manager: only the fields and methods it uses.
	local function new_browser(fields)
		local browser = {
			settings = {},
			downloads = {},
			sync_server_list = { [CATALOG] = true },
			updates = 0,
			getServerFileName = function(_, _, filetype)
				return "from-the-server." .. filetype
			end,
			updateDownloadListItemTable = function(self)
				self.updates = self.updates + 1
			end,
		}
		for key, value in pairs(fields or {}) do
			browser[key] = value
		end
		return browser
	end

	-- A queue or sync entry whose book is served by the fake server.
	local function entry(name, response, fields)
		local item = { file = dir .. "/" .. name, url = HOST .. "/download/" .. name, catalog = CATALOG }
		for key, value in pairs(fields or {}) do
			item[key] = value
		end
		http:on(item.url, response or { code = 200, body = "contents of " .. name })
		return item
	end

	local function age(path, seconds)
		local then_ = os.time() - seconds
		assert(lfs.touch(path, then_, then_))
	end

	-- A book document as DocumentRegistry:openDocument gives it. `renders` marks one KOReader lays out
	-- itself (CreDocument), which has loadDocument() and no page count.
	local function book_document(props, renders)
		local document = { closed = false, loads = {} }
		function document:getProps()
			return props
		end
		function document:close()
			self.closed = true
		end
		if renders then
			function document:loadDocument(full)
				self.loads[#self.loads + 1] = full
				return self.loadable ~= false
			end
		else
			function document:getPageCount()
				return 321
			end
		end
		return document
	end

	before_each(function()
		helper.reset()
		http = fake_http.new()
		socketutil = socketutil_stub.new()
		ui = ui_stub.new()
		registry = registry_stub.new()
		doc_settings = docsettings_stub.new()
		state = {
			dirty = 0,
			markDirty = function(self)
				self.dirty = self.dirty + 1
			end,
		}
		device = {}
		reader_settings = {}
		dir = helper.tmpdir()
		helper.global("G_reader_settings", {
			readSetting = function(_, key)
				return reader_settings[key]
			end,
		})
		load_manager()
	end)

	after_each(helper.reset)

	describe("getFiletype", function()
		it("takes the type from the extension in the link when KOReader can open it", function()
			local link = { href = HOST .. "/books/dune.epub", type = "application/zip" }

			assert.equals("epub", DownloadManager.getFiletype(link))
		end)

		it("prefers the extension to the mimetype", function()
			local link = { href = HOST .. "/books/dune.pdf", type = "application/epub+zip" }

			assert.equals("pdf", DownloadManager.getFiletype(link))
		end)

		it("goes by the mimetype when the link has no extension", function()
			local link = { href = HOST .. "/download/42", type = "application/epub+zip" }

			assert.equals("epub", DownloadManager.getFiletype(link))
		end)

		it("maps a comic book type KOReader registers under another name", function()
			registry:add_extension("cbr")
			local link = { href = HOST .. "/download/42", type = "application/x-cbr" }

			assert.equals("cbr", DownloadManager.getFiletype(link))
		end)

		it("is nil when neither the extension nor the mimetype is something KOReader opens", function()
			local link = { href = HOST .. "/download/42", type = "application/zip" }

			assert.is_nil(DownloadManager.getFiletype(link))
		end)
	end)

	describe("getCurrentDownloadDir", function()
		it("is the sync folder while syncing", function()
			reader_settings.download_dir = "/downloads"
			local browser = new_browser({ sync = true, settings = { sync_dir = "/sync" } })

			assert.equals("/sync", DownloadManager.getCurrentDownloadDir(browser))
		end)

		it("is the download folder set in KOReader", function()
			reader_settings.download_dir = "/downloads"
			reader_settings.home_dir = "/home"

			assert.equals("/downloads", DownloadManager.getCurrentDownloadDir(new_browser()))
		end)

		it("is the home folder when there is no download folder", function()
			reader_settings.home_dir = "/home"
			reader_settings.lastdir = "/last"
			device.home_dir = "/device-home"

			assert.equals("/home", DownloadManager.getCurrentDownloadDir(new_browser()))
		end)

		it("is then the home folder of the device, and last the folder opened last", function()
			reader_settings.lastdir = "/last"
			device.home_dir = "/device-home"
			assert.equals("/device-home", DownloadManager.getCurrentDownloadDir(new_browser()))

			device.home_dir = nil
			assert.equals("/last", DownloadManager.getCurrentDownloadDir(new_browser()))
		end)
	end)

	describe("getLocalDownloadPath", function()
		before_each(function()
			reader_settings.download_dir = "/books"
		end)

		it("joins the download folder, the name and the type in lower case", function()
			local path = DownloadManager.getLocalDownloadPath(new_browser(), "Dune", "EPUB", URL)

			assert.equals("/books/Dune.epub", path)
		end)

		it("asks the browser for the name the server gives when there is none", function()
			local asked
			local browser = new_browser({
				getServerFileName = function(_, remote_url, filetype)
					asked = { remote_url, filetype }
					return "Dune (1965).epub"
				end,
			})

			local path = DownloadManager.getLocalDownloadPath(browser, nil, "epub", URL)

			assert.equals("/books/Dune (1965).epub", path)
			assert.same({ URL, "epub" }, asked)
		end)

		it("does not double the slash for the root folder", function()
			reader_settings.download_dir = "/"

			assert.equals("/Dune.epub", DownloadManager.getLocalDownloadPath(new_browser(), "Dune", "epub", URL))
		end)

		it("keeps a slash in a title from being taken for a folder", function()
			local path = DownloadManager.getLocalDownloadPath(new_browser(), "AC/DC", "epub", URL)

			assert.equals("/books/AC_DC.epub", path)
		end)

		it("drops bytes that are not valid UTF-8, as getSafeFilename does", function()
			local path = DownloadManager.getLocalDownloadPath(new_browser(), "Caf\233", "epub", URL)

			assert.equals("/books/Caf.epub", path)
		end)
	end)

	describe("saveDescription", function()
		local FILE = "/books/Dune.epub"
		local props, document

		before_each(function()
			props = { title = "Dune" }
			document = book_document(props)
			registry.open_document = function()
				return document
			end
		end)

		it("saves it as custom metadata, keeping the properties of the book as the original ones", function()
			local saved = DownloadManager.saveDescription(FILE, "A desert planet.")

			assert.is_true(saved)
			assert.same({ description = "A desert planet." }, doc_settings.saved[FILE].custom_props)
			assert.equals("Dune", doc_settings.saved[FILE].doc_props.title)
			assert.equals(321, doc_settings.saved[FILE].doc_props.pages)
			assert.is_true(document.closed)
		end)

		it("loads only the metadata of a book KOReader lays out itself", function()
			document = book_document(props, true)

			assert.is_true(DownloadManager.saveDescription(FILE, "A desert planet."))

			assert.same({ false }, document.loads)
			assert.is_nil(doc_settings.saved[FILE].doc_props.pages)
		end)

		it("leaves a book alone whose metadata can't be loaded", function()
			document = book_document(props, true)
			document.loadable = false

			assert.is_false(DownloadManager.saveDescription(FILE, "A desert planet."))

			assert.is_nil(doc_settings.saved[FILE])
			assert.is_true(document.closed)
		end)

		it("ignores a description that is not text, or is blank", function()
			for _, description in ipairs({ 42, "", "  \n\t " }) do
				assert.is_false(DownloadManager.saveDescription(FILE, description))
			end
			assert.is_false(DownloadManager.saveDescription(FILE, nil))

			assert.same({}, doc_settings.saved)
			assert.same({}, registry.calls)
		end)

		it("leaves a book with custom metadata of its own alone", function()
			doc_settings.has_custom_metadata[FILE] = true

			assert.is_false(DownloadManager.saveDescription(FILE, "A desert planet."))

			assert.same({}, doc_settings.saved)
		end)

		it("keeps the description the book carries", function()
			props.description = "Written by the publisher."

			assert.is_false(DownloadManager.saveDescription(FILE, "A desert planet."))

			assert.same({}, doc_settings.saved)
		end)

		it("does replace a description of the book that is blank", function()
			props.description = "  "

			assert.is_true(DownloadManager.saveDescription(FILE, "A desert planet."))
		end)

		it("does not open a file KOReader has no provider for", function()
			registry.open_document = function()
				error("must not be called")
			end

			assert.is_false(DownloadManager.saveDescription("/books/Dune.xyz", "A desert planet."))
		end)

		it("does nothing when the book can't be opened", function()
			registry.open_document = function() end

			assert.is_false(DownloadManager.saveDescription(FILE, "A desert planet."))

			assert.same({}, doc_settings.saved)
		end)

		it("closes the book even when reading its properties fails", function()
			function document:getProps()
				error("corrupt")
			end

			assert.is_false(DownloadManager.saveDescription(FILE, "A desert planet."))

			assert.is_true(document.closed)
		end)

		it("reports it when KOReader couldn't write the metadata", function()
			doc_settings.flush_result = nil

			assert.is_false(DownloadManager.saveDescription(FILE, "A desert planet."))
		end)

		it("never raises, whatever goes wrong while saving, and logs it", function()
			doc_settings.flush_error = "disk full"

			assert.is_false(DownloadManager.saveDescription(FILE, "A desert planet."))

			assert.is_true(require("logger").logged("warn", "could not save the description"))
		end)
	end)

	describe("downloadFile", function()
		it("reports an empty URL before opening the destination or making a request", function()
			local target = dir .. "/untouched.epub"
			fs.write(target, "keep this file")

			assert.is_false(DownloadManager.downloadFile(new_browser(), target, ""))

			assert.equals("keep this file", fs.read(target))
			assert.same({}, http.requests)
			assert.same({ "Invalid download URL." }, ui:texts())
		end)

		local browser, target

		before_each(function()
			browser = new_browser()
			target = dir .. "/Dune.epub"
		end)

		it("saves the response in the file and reports success", function()
			http:on(URL, { code = 200, body = BODY })

			local ok = DownloadManager.downloadFile(browser, target, URL)

			assert.is_true(ok)
			assert.equals(BODY, fs.read(target))
			assert.same({}, ui:texts())
		end)

		it("calls back with the path of the file", function()
			http:on(URL, { code = 200, body = BODY })
			local arrived

			DownloadManager.downloadFile(browser, target, URL, nil, nil, function(path)
				arrived = path
			end)

			assert.equals(target, arrived)
		end)

		it("asks for an uncompressed body and sends the credentials", function()
			http:on(URL, { code = 200, body = BODY })

			DownloadManager.downloadFile(browser, target, URL, "reader", "s3cret")

			local request = http.requests[1]
			assert.equals("identity", request.headers["Accept-Encoding"])
			assert.equals("reader", request.user)
			assert.equals("s3cret", request.password)
		end)

		it("sends the custom headers of the catalog", function()
			HttpClient.setCatalogs({
				{ url = HOST .. "/opds", headers = { { name = "X-Api-Key", value = "abc" } } },
			})
			http:on(URL, { code = 200, body = BODY })

			DownloadManager.downloadFile(browser, target, URL)

			assert.equals("abc", http.requests[1].headers["X-Api-Key"])
		end)

		it("uses the timeouts meant for files and resets them afterwards", function()
			local seen
			http:on(URL, function()
				seen = { block = socketutil.block_timeout, total = socketutil.total_timeout }
				return { code = 200, body = BODY }
			end)

			DownloadManager.downloadFile(browser, target, URL)

			assert.same({ block = socketutil.FILE_BLOCK_TIMEOUT, total = socketutil.FILE_TOTAL_TIMEOUT }, seen)
			assert.equals(socketutil.DEFAULT_BLOCK_TIMEOUT, socketutil.block_timeout)
		end)

		it("refuses an address that is not http or https, without a request", function()
			local ok = DownloadManager.downloadFile(browser, target, "ftp://library.example.org/dune.epub")

			assert.is_false(ok)
			assert.same({ "Invalid protocol:\nftp" }, ui:texts())
			assert.same({}, http.requests)
			assert.is_nil(fs.read(target))
		end)

		it("deletes the file and says why when the server refuses", function()
			http:on(URL, { code = 404, status = "HTTP/1.1 404 Not Found", body = "<html>gone</html>" })
			local arrived = false

			local ok = DownloadManager.downloadFile(browser, target, URL, nil, nil, function()
				arrived = true
			end)

			assert.is_false(ok)
			assert.is_false(arrived)
			assert.same({ "Could not save file to:\n" .. target .. "\nHTTP/1.1 404 Not Found" }, ui:texts())
			assert.is_false(fs.exists(target))
		end)

		it("shows what the network said when there was no response", function()
			http:on(URL, { error = "connection refused" })

			local ok = DownloadManager.downloadFile(browser, target, URL)

			assert.is_false(ok)
			assert.same({ "Could not save file to:\n" .. target .. "\nconnection refused" }, ui:texts())
			assert.is_false(fs.exists(target))
		end)

		describe("redirects", function()
			local MIRROR = "https://mirror.example.net/dune.epub"

			it("saves the book from the address a redirect leads to, not what the redirect said", function()
				http:on(URL, { code = 302, headers = { Location = MIRROR }, body = "<html>moved</html>" })
				http:on(MIRROR, { code = 200, body = BODY })

				local ok = DownloadManager.downloadFile(browser, target, URL)

				assert.is_true(ok)
				assert.equals(BODY, fs.read(target))
				assert.same({}, ui:texts())
			end)

			it("follows a permanent redirect (308), which LuaSocket leaves alone", function()
				http:on(URL, { code = 308, headers = { Location = MIRROR } })
				http:on(MIRROR, { code = 200, body = BODY })

				assert.is_true(DownloadManager.downloadFile(browser, target, URL))
				assert.equals(BODY, fs.read(target))
			end)

			it("sends the credentials again when the redirect stays on the same server", function()
				http:on(URL, { code = 301, headers = { Location = "/files/dune.epub" } })
				http:on(HOST .. "/files/dune.epub", { code = 200, body = BODY })

				DownloadManager.downloadFile(browser, target, URL, "reader", "s3cret")

				assert.equals(HOST .. "/files/dune.epub", http.requests[2].url)
				assert.equals("reader", http.requests[2].user)
				assert.equals("s3cret", http.requests[2].password)
			end)

			it("keeps the credentials away from another server", function()
				http:on(URL, { code = 302, headers = { Location = MIRROR } })
				http:on(MIRROR, { code = 200, body = BODY })

				DownloadManager.downloadFile(browser, target, URL, "reader", "s3cret")

				assert.equals("reader", http.requests[1].user)
				assert.is_nil(http.requests[2].user)
				assert.is_nil(http.requests[2].password)
			end)

			it("keeps the custom headers of a catalog away from another server", function()
				HttpClient.setCatalogs({
					{ url = CATALOG, headers = { { name = "X-Api-Key", value = "abc" } } },
				})
				http:on(URL, { code = 302, headers = { Location = MIRROR } })
				http:on(MIRROR, { code = 200, body = BODY })

				DownloadManager.downloadFile(browser, target, URL)

				assert.equals("abc", http.requests[1].headers["X-Api-Key"])
				assert.is_nil(http.requests[2].headers["X-Api-Key"])
				assert.equals("identity", http.requests[2].headers["Accept-Encoding"])
			end)

			it("deletes the file and says why when the address a redirect leads to refuses", function()
				http:on(URL, { code = 302, headers = { Location = MIRROR } })
				http:on(MIRROR, { code = 404, status = "HTTP/1.1 404 Not Found", body = "<html>gone</html>" })

				local ok = DownloadManager.downloadFile(browser, target, URL)

				assert.is_false(ok)
				assert.same({ "Could not save file to:\n" .. target .. "\nHTTP/1.1 404 Not Found" }, ui:texts())
				assert.is_false(fs.exists(target))
			end)

			it("fails cleanly when the file cannot be written again for the next address", function()
				http:on(URL, function()
					-- The path turns into a folder while the first answer is on its way
					os.remove(target)
					assert(lfs.mkdir(target))
					return { code = 302, headers = { Location = MIRROR } }
				end)
				http:on(MIRROR, { code = 200, body = BODY })

				local ok = DownloadManager.downloadFile(browser, target, URL)

				assert.is_false(ok)
				assert.truthy(ui:last().text:find("Could not save file to:", 1, true))
				assert.equals(1, #http.requests)
			end)
		end)

		it("refuses a redirect from https to http, and deletes the file", function()
			http:on(URL, { code = 302, headers = { Location = "http://mirror.example.net/dune.epub" } })

			local ok = DownloadManager.downloadFile(browser, target, URL)

			assert.is_false(ok)
			local widget = ui:last()
			assert.equals("notice-warning", widget.icon)
			assert.truthy(widget.text:find("Insecure HTTPS → HTTP downgrade", 1, true))
			assert.truthy(widget.text:find("'" .. URL .. "'", 1, true))
			assert.truthy(widget.text:find("'http://mirror.example.net/dune.epub'", 1, true))
			assert.is_false(fs.exists(target))
		end)

		it("takes a redirect on plain http that never ends for an ordinary failure", function()
			local plain = "http://library.example.org/download/dune.epub"
			http:on(plain, { code = 302, headers = { Location = plain } })

			local ok = DownloadManager.downloadFile(browser, target, plain)

			assert.is_false(ok)
			assert.truthy(ui:last().text:find("Could not save file to:", 1, true))
			assert.is_nil(ui:last().icon)
		end)

		it("survives a redirect without a Location header", function()
			http:on(URL, { code = 302, status = "HTTP/1.1 302 Found" })

			local ok = DownloadManager.downloadFile(browser, target, URL)

			assert.is_false(ok)
			assert.same({ "Could not save file to:\n" .. target .. "\nHTTP/1.1 302 Found" }, ui:texts())
			assert.is_false(fs.exists(target))
		end)

		it("fails without a request when the file can't be created", function()
			http:on(URL, { code = 200, body = BODY })
			local missing = dir .. "/no/such/folder/Dune.epub"
			local arrived = false

			local ok = DownloadManager.downloadFile(browser, missing, URL, nil, nil, function()
				arrived = true
			end)

			assert.is_false(ok)
			assert.is_false(arrived)
			assert.same({}, http.requests)
			assert.same({ "Could not save file to:\n" .. missing .. "\nNo such file or directory" }, ui:texts())
		end)

		describe("with a description from the catalog", function()
			before_each(function()
				registry.open_document = function()
					return book_document({ title = "Dune" })
				end
				http:on(URL, { code = 200, body = BODY })
			end)

			it("saves it with the book", function()
				DownloadManager.downloadFile(browser, target, URL, nil, nil, nil, { description = "A desert planet." })

				assert.same({ description = "A desert planet." }, doc_settings.saved[target].custom_props)
			end)

			it("does not when the setting is off", function()
				browser.settings.save_book_description = false

				DownloadManager.downloadFile(browser, target, URL, nil, nil, nil, { description = "A desert planet." })

				assert.same({}, doc_settings.saved)
			end)

			it("does when the browser has no settings", function()
				browser.settings = nil

				DownloadManager.downloadFile(browser, target, URL, nil, nil, nil, { description = "A desert planet." })

				assert.is_not_nil(doc_settings.saved[target])
			end)

			it("does not when the download failed", function()
				http.routes = {}
				http:on(URL, { code = 404 })

				DownloadManager.downloadFile(browser, target, URL, nil, nil, nil, { description = "A desert planet." })

				assert.same({}, doc_settings.saved)
			end)

			it("still succeeds when saving it fails", function()
				doc_settings.flush_error = "disk full"

				local ok = DownloadManager.downloadFile(browser, target, URL, nil, nil, nil, { description = "A desert planet." })

				assert.is_true(ok)
				assert.equals(BODY, fs.read(target))
			end)
		end)
	end)

	describe("checkDownloadFile", function()
		local browser, target

		before_each(function()
			browser = new_browser()
			target = dir .. "/Dune.epub"
			http:on(URL, { code = 200, body = BODY })
		end)

		it("tells the user and starts the download a moment later", function()
			local arrived
			DownloadManager.checkDownloadFile(browser, target, URL, "reader", "s3cret", function(path)
				arrived = path
			end)

			assert.same({}, http.requests)
			assert.equals(Constants.UI_TIMING.DOWNLOAD_SCHEDULE_DELAY, ui.scheduled[1].seconds)
			assert.equals("Downloading…", ui:last().text)
			assert.equals(Constants.UI_TIMING.NOTIFICATION_TIMEOUT, ui:last().timeout)

			ui:run_scheduled()

			assert.equals(BODY, fs.read(target))
			assert.equals(target, arrived)
			assert.equals("reader", http.requests[1].user)
		end)

		it("hands the description on to the download", function()
			registry.open_document = function()
				return book_document({ title = "Dune" })
			end

			DownloadManager.checkDownloadFile(browser, target, URL, nil, nil, nil, { description = "A desert planet." })
			ui:run_scheduled()

			assert.same({ description = "A desert planet." }, doc_settings.saved[target].custom_props)
		end)

		it("asks before it overwrites a file that exists", function()
			fs.write(target, "old copy")

			DownloadManager.checkDownloadFile(browser, target, URL)

			local widget = ui:last()
			assert.equals("ConfirmBox", widget.kind)
			assert.equals("The file " .. target .. " already exists. Do you want to overwrite it?", widget.text)
			assert.equals("Overwrite", widget.ok_text)
			assert.same({}, ui.scheduled)

			widget.ok_callback()
			ui:run_scheduled()

			assert.equals(BODY, fs.read(target))
		end)

		it("leaves the file alone when the user does not confirm", function()
			fs.write(target, "old copy")

			DownloadManager.checkDownloadFile(browser, target, URL)
			ui:run_scheduled()

			assert.equals("old copy", fs.read(target))
			assert.same({}, http.requests)
		end)
	end)

	describe("downloadDownloadList", function()
		local browser

		before_each(function()
			browser = new_browser()
		end)

		it("downloads the queue, takes the books that arrived off it and says how many", function()
			browser.downloads = { entry("a.epub"), entry("b.epub") }
			local a, b = browser.downloads[1], browser.downloads[2]

			local count = DownloadManager.downloadDownloadList(browser)

			assert.equals(2, count)
			assert.same({}, browser.downloads)
			assert.equals("contents of a.epub", fs.read(a.file))
			assert.equals("contents of b.epub", fs.read(b.file))
			assert.same({ PROGRESS, "2 books downloaded" }, ui:texts())
			assert.equals(ui.shown[1], ui.closed[1])
			assert.is_true(browser.download_list_updated)
			assert.equals(1, browser.updates)
			assert.equals(1, state.dirty)
		end)

		it("says 'book' for a single one", function()
			browser.downloads = { entry("a.epub") }

			DownloadManager.downloadDownloadList(browser)

			assert.equals("1 book downloaded", ui:last().text)
		end)

		it("keeps the books that failed in the queue", function()
			local failing = entry("b.epub", { code = 404 })
			browser.downloads = { entry("a.epub"), failing }

			local count = DownloadManager.downloadDownloadList(browser)

			assert.equals(1, count)
			assert.same({ failing }, browser.downloads)
		end)

		it("says nothing and leaves the state alone when nothing arrived", function()
			browser.downloads = { entry("a.epub", { code = 500 }) }

			local count = DownloadManager.downloadDownloadList(browser)

			assert.equals(0, count)
			assert.same({ PROGRESS }, ui:texts())
			assert.equals(0, state.dirty)
			assert.equals(0, browser.updates)
			assert.is_nil(browser.download_list_updated)
		end)

		it("downloads each book with its own credentials and description", function()
			registry.open_document = function()
				return book_document({ title = "Dune" })
			end
			local a = entry("a.epub", nil, { username = "ann", password = "secret", info = "About A" })
			browser.downloads = { a, entry("b.epub", nil, { username = "bob", password = "pw" }) }

			DownloadManager.downloadDownloadList(browser)

			assert.equals("ann", http:requests_to(a.url)[1].user)
			assert.equals("secret", http:requests_to(a.url)[1].password)
			assert.equals("bob", http.requests[2].user)
			assert.equals("pw", http.requests[2].password)
			assert.same({ description = "About A" }, doc_settings.saved[a.file].custom_props)
			assert.is_nil(doc_settings.saved[dir .. "/b.epub"])
		end)

		describe("when the user cancels", function()
			before_each(function()
				ui.interrupted = true
			end)

			it("takes the books that reached the disk off the queue", function()
				local missing = entry("b.epub", { code = 404 })
				browser.downloads = { entry("a.epub"), missing }

				local count = DownloadManager.downloadDownloadList(browser)

				assert.equals(1, count)
				assert.same({ missing }, browser.downloads)
				assert.same({}, ui.closed)
			end)

			it("deletes a half-written file and keeps the book queued", function()
				local partial = entry("a.epub", { code = 200, body = "" })
				browser.downloads = { partial }

				local count = DownloadManager.downloadDownloadList(browser)

				assert.equals(0, count)
				assert.same({ partial }, browser.downloads)
				assert.is_false(fs.exists(partial.file))
			end)
		end)
	end)

	describe("downloadPendingSyncs", function()
		local browser

		local function toasts()
			local texts = ui:texts()
			assert.equals(PROGRESS, table.remove(texts, 1))
			return texts
		end

		before_each(function()
			browser = new_browser({ sync = true })
		end)

		it("downloads what is pending for the catalogs being synced", function()
			local list = { entry("a.epub"), entry("b.epub") }
			local a, b = list[1], list[2]

			local duplicates = DownloadManager.downloadPendingSyncs(browser, list)

			assert.same({}, duplicates)
			assert.same({}, list)
			assert.equals("contents of a.epub", fs.read(a.file))
			assert.equals("contents of b.epub", fs.read(b.file))
			assert.same({ "2 books downloaded" }, toasts())
			assert.equals(1, state.dirty)
		end)

		it("leaves books of other catalogs pending", function()
			local other = entry("a.epub", nil, { catalog = "https://elsewhere.example.net/opds" })
			local list = { other }

			DownloadManager.downloadPendingSyncs(browser, list)

			assert.same({ other }, list)
			assert.same({}, http.requests)
			assert.same({}, toasts())
		end)

		it("hands back the books already on the device instead of downloading them", function()
			local mine = entry("a.epub")
			fs.write(mine.file, "my copy")
			local list = { mine, entry("b.epub") }

			local duplicates = DownloadManager.downloadPendingSyncs(browser, list)

			assert.same({ mine }, duplicates)
			assert.equals("my copy", fs.read(mine.file))
			assert.same({}, http:requests_to(mine.url))
			-- The sync manager puts the duplicates back on the list if the user chooses to download them
			assert.same({}, list)
		end)

		it("downloads over the books on the device when forced", function()
			local mine = entry("a.epub")
			fs.write(mine.file, "my copy")
			browser.sync_force = true

			local duplicates = DownloadManager.downloadPendingSyncs(browser, { mine })

			assert.same({}, duplicates)
			assert.equals("contents of a.epub", fs.read(mine.file))
		end)

		it("counts the books it downloaded, not the ones that were already there", function()
			local list = { entry("a.epub"), entry("b.epub"), entry("c.epub"), entry("old-1.epub"), entry("old-2.epub") }
			for _, name in ipairs({ "old-1.epub", "old-2.epub" }) do
				age(fs.write(dir .. "/" .. name, "mine"), 86400)
			end

			DownloadManager.downloadPendingSyncs(browser, list)

			assert.same({ "3 books downloaded" }, toasts())
		end)

		it("does not count a book that was already there, even when its file is recent", function()
			local list = { entry("a.epub"), entry("b.epub"), entry("old.epub"), entry("recent.epub") }
			age(fs.write(dir .. "/old.epub", "mine"), 86400)
			fs.write(dir .. "/recent.epub", "mine")

			DownloadManager.downloadPendingSyncs(browser, list)

			assert.same({ "2 books downloaded" }, toasts())
		end)

		it("says nothing when every book was already there", function()
			local list = { entry("a.epub"), entry("b.epub") }
			fs.write(dir .. "/a.epub", "mine")
			fs.write(dir .. "/b.epub", "mine")

			local duplicates = DownloadManager.downloadPendingSyncs(browser, list)

			assert.equals(2, #duplicates)
			assert.same({}, toasts())
		end)

		it("lets the notice time out when there are duplicates to ask about, so it does not cover the question", function()
			local list = { entry("a.epub"), entry("b.epub") }
			fs.write(dir .. "/b.epub", "mine")

			DownloadManager.downloadPendingSyncs(browser, list)

			assert.equals(Constants.UI_TIMING.DUPLICATE_NOTIFICATION_TIMEOUT, ui:last().timeout)
		end)

		it("keeps the notice until it is dismissed when there are none", function()
			DownloadManager.downloadPendingSyncs(browser, { entry("a.epub") })

			assert.is_nil(ui:last().timeout)
		end)

		it("passes each book's credentials and description on", function()
			registry.open_document = function()
				return book_document({ title = "Dune" })
			end
			local a = entry("a.epub", nil, { username = "ann", password = "secret", info = "About A" })

			DownloadManager.downloadPendingSyncs(browser, { a })

			assert.equals("ann", http.requests[1].user)
			assert.same({ description = "About A" }, doc_settings.saved[a.file].custom_props)
		end)

		describe("when the user cancels", function()
			before_each(function()
				ui.interrupted = true
			end)

			it("takes the books that reached the disk off the list and counts the new ones", function()
				local list = { entry("a.epub"), entry("b.epub", { code = 404 }), entry("old.epub") }
				age(fs.write(dir .. "/old.epub", "mine"), 86400)

				local duplicates = DownloadManager.downloadPendingSyncs(browser, list)

				assert.is_nil(duplicates)
				assert.equals(1, #list)
				assert.equals(dir .. "/b.epub", list[1].file)
				assert.same({ "1 book downloaded" }, toasts())
				assert.same({}, ui.closed)
			end)

			it("deletes a half-written file and keeps the book pending", function()
				local partial = entry("a.epub", { code = 200, body = "" })
				local list = { partial }

				DownloadManager.downloadPendingSyncs(browser, list)

				assert.same({ partial }, list)
				assert.is_false(fs.exists(partial.file))
			end)
		end)
	end)

	describe("the download queue", function()
		it("adds an item at the end and marks the state dirty", function()
			local browser = new_browser()
			browser.downloads = { { file = "/books/a.epub" } }

			DownloadManager.addToDownloadQueue(browser, { file = "/books/b.epub" })

			assert.same({ { file = "/books/a.epub" }, { file = "/books/b.epub" } }, browser.downloads)
			assert.equals(1, state.dirty)
		end)

		it("removes the item at an index and marks the state dirty", function()
			local browser = new_browser()
			browser.downloads = { { file = "a" }, { file = "b" }, { file = "c" } }

			DownloadManager.removeFromDownloadQueue(browser, 2)

			assert.same({ { file = "a" }, { file = "c" } }, browser.downloads)
			assert.equals(1, state.dirty)
		end)

		it("clears the queue in place, so whoever holds it sees it empty", function()
			local browser = new_browser()
			browser.downloads = { { file = "a" }, { file = "b" } }
			local same_table = browser.downloads

			DownloadManager.clearDownloadQueue(browser)

			assert.equals(0, #same_table)
			assert.is_true(browser.download_list_updated)
			assert.equals(1, state.dirty)
		end)
	end)
end)
