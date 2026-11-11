local helper = require("helper")
local fake_http = require("support.fake_http")
local socketutil_stub = require("support.socketutil")
local ui_stub = require("support.ui")
local json_shims = require("support.json_shims")

describe("Kavita page streaming", function()
	local OPDSPSE, HttpClient
	local http, ui, viewer

	local SERVER = "https://kavita.example.org"
	local OTHER = "https://cdn.example.net"
	local API_KEY = "KEY-123"
	local STREAM = SERVER .. "/api/opds/" .. API_KEY .. "/image?chapterId=42&pageNumber={pageNumber}&maxWidth={maxWidth}"
	local AUTH = SERVER .. "/api/Plugin/authenticate?apiKey=" .. API_KEY .. "&pluginName=KOReader-OPDS"
	local PROGRESS = SERVER .. "/api/Reader/get-progress?chapterId=42"
	local SIGN_IN = '{"username":"reader","token":"TOKEN-1","refreshToken":"REFRESH-1","apiKey":"KEY-123"}'

	-- The read-only reader endpoint, not the progress-writing OPDS image endpoint.
	local function page_url(number)
		return SERVER .. "/api/Reader/image?chapterId=42&page=" .. number .. "&apiKey=" .. API_KEY .. "&extractPdf=true"
	end

	local function progress_of(number)
		return '{"volumeId":1,"chapterId":42,"pageNum":' .. number .. ',"seriesId":2,"libraryId":1}'
	end

	-- Kavita knows the reader and has them on page `number`
	local function kavita_knows(number)
		http:on(AUTH, { code = 200, body = SIGN_IN })
		http:on(PROGRESS, { code = 200, body = progress_of(number) })
	end

	before_each(function()
		helper.reset()
		http = fake_http.new()
		ui = ui_stub.new()
		viewer = nil

		-- Pages come back as a table saying what they were made of, so a spec can tell them apart
		local render_image = {}
		function render_image:renderImageData(data, size)
			if data == "INVALID" then return nil end
			return { page = data, size = size }
		end
		function render_image:renderImageFile(path)
			return { placeholder = path }
		end

		local image_viewer = {}
		function image_viewer:new(options)
			viewer = setmetatable(options, { __index = self })
			viewer._images_list = options.image
			viewer.image = viewer._images_list[1]
			viewer._images_list_cur = 1
			return viewer
		end
		function image_viewer:switchToImageNum(number)
			self.image = self._images_list[number]
			self._images_list_cur = number
		end
		function image_viewer:update() end
		function image_viewer:paintTo() end
		function image_viewer:onCloseWidget() end

		local stubs = {
			rapidjson = json_shims.rapidjson(),
			["socket.http"] = http,
			socketutil = socketutil_stub.new(),
			device = {
				screen = {
					getWidth = function()
						return 600
					end,
				},
			},
			["ui/renderimage"] = render_image,
			["ui/widget/imageviewer"] = image_viewer,
			["ffi/sha2"] = { sha256 = function(value) return "hash:" .. value end },
		}
		for name, stand_in in pairs(ui.stubs) do
			stubs[name] = stand_in
		end
		OPDSPSE = helper.load("services.kavita", stubs)
		HttpClient = require("services.http_client")
	end)

	after_each(helper.reset)

	describe("getLastPage", function()
		it("skips non-Kavita and empty URLs without sending a request", function()
			assert.equals(0, OPDSPSE:getLastPage(OTHER .. "/stream?page={pageNumber}"))
			assert.equals(0, OPDSPSE:getLastPage(OTHER .. "/stream?next=/api/opds/key/image?chapterId=42"))
			assert.equals(0, OPDSPSE:getLastPage(""))
			assert.same({}, http.requests)
		end)

		it("decodes reordered JSON fields across all response chunks", function()
			http:on(AUTH, function(request)
				request.raw.sink('{\n "refreshToken": "REFRESH-1",')
				request.raw.sink('\n "token": "TOKEN-1" }')
				return { code = 200 }
			end)
			http:on(PROGRESS, { code = 200, body = '{"seriesId":2,\n"pageNum":7}' })

			assert.equals(7, OPDSPSE:getLastPage(STREAM))
			assert.equals("Bearer TOKEN-1", http.requests[2].headers["Authorization"])
		end)

		it("does not request progress when the authentication response has no usable token", function()
			for _, body in ipairs({ "", "{bad", '{"token":null}', '{"token":""}', '{"token":42}' }) do
				http.routes = {}
				http.requests = {}
				http:on(AUTH, { code = 200, body = body })

				assert.equals(0, OPDSPSE:getLastPage(STREAM))
				assert.equals(1, #http.requests)
			end
			assert.is_true(require("logger").logged("warn", "authentication response"))
		end)

		it("rejects malformed, fractional and negative progress with an explicit warning", function()
			for _, body in ipairs({ "{bad", '{"pageNum":"seven"}', '{"pageNum":1.5}', '{"pageNum":-1}' }) do
				http.routes = {}
				http:on(AUTH, { code = 200, body = SIGN_IN })
				http:on(PROGRESS, { code = 200, body = body })

				assert.equals(0, OPDSPSE:getLastPage(STREAM))
			end
			assert.is_true(require("logger").logged("warn", "progress response"))
		end)

		it("signs in with the API key and asks for the progress with the token it gets", function()
			kavita_knows(7)

			local page = OPDSPSE:getLastPage(STREAM, "reader", "s3cret")

			assert.equals(7, tonumber(page))
			assert.equals(2, #http.requests)
			local sign_in, progress = http.requests[1], http.requests[2]
			assert.equals("POST", sign_in.method)
			assert.equals(AUTH, sign_in.url)
			assert.equals(API_KEY, sign_in.headers["Authentication"])
			assert.equals("reader", sign_in.user)
			assert.equals("s3cret", sign_in.password)
			assert.equals("GET", progress.method)
			assert.equals(PROGRESS, progress.url)
			assert.equals("Bearer TOKEN-1", progress.headers["Authorization"])
			assert.equals("identity", progress.headers["Accept-Encoding"])
			assert.equals("reader", progress.user)
			assert.equals("s3cret", progress.password)
		end)

		it("starts from the first page when Kavita refuses the sign-in", function()
			http:on(AUTH, { code = 401 })

			assert.equals(0, OPDSPSE:getLastPage(STREAM, "reader", "s3cret"))
			assert.equals(1, #http.requests)
		end)

		it("starts from the first page when the progress can't be read", function()
			http:on(AUTH, { code = 200, body = SIGN_IN })
			http:on(PROGRESS, { code = 404 })

			assert.equals(0, OPDSPSE:getLastPage(STREAM, "reader", "s3cret"))
		end)

		it("starts from the first page when the progress says no page", function()
			http:on(AUTH, { code = 200, body = SIGN_IN })
			http:on(PROGRESS, { code = 200, body = "{}" })

			assert.equals(0, OPDSPSE:getLastPage(STREAM, "reader", "s3cret"))
		end)

		it("sends the custom headers of the catalog with both requests", function()
			HttpClient.setCatalogs({
				{ url = SERVER .. "/opds", headers = { { name = "X-Api-Key", value = "abc" } } },
			})
			kavita_knows(7)

			OPDSPSE:getLastPage(STREAM, "reader", "s3cret")

			assert.equals("abc", http.requests[1].headers["X-Api-Key"])
			assert.equals("abc", http.requests[2].headers["X-Api-Key"])
		end)

		describe("when the progress is redirected", function()
			it("keeps the token and the credentials on the same server", function()
				http:on(AUTH, { code = 200, body = SIGN_IN })
				http:on(PROGRESS, { code = 301, headers = { Location = "/api/Reader/progress?chapterId=42" } })
				http:on(SERVER .. "/api/Reader/progress?chapterId=42", { code = 200, body = progress_of(7) })

				local page = OPDSPSE:getLastPage(STREAM, "reader", "s3cret")

				assert.equals(7, tonumber(page))
				local second = http.requests[3]
				assert.equals("Bearer TOKEN-1", second.headers["Authorization"])
				assert.equals("reader", second.user)
				assert.equals("s3cret", second.password)
			end)

			it("keeps the token, the credentials and the custom headers away from another server", function()
				HttpClient.setCatalogs({
					{ url = SERVER .. "/opds", headers = { { name = "X-Api-Key", value = "abc" } } },
				})
				http:on(AUTH, { code = 200, body = SIGN_IN })
				http:on(PROGRESS, { code = 302, headers = { Location = OTHER .. "/progress" } })
				http:on(OTHER .. "/progress", { code = 200, body = progress_of(7) })

				local page = OPDSPSE:getLastPage(STREAM, "reader", "s3cret")

				assert.equals(7, tonumber(page))
				local second = http.requests[3]
				assert.equals(OTHER .. "/progress", second.url)
				assert.is_nil(second.headers["Authorization"])
				assert.is_nil(second.headers["X-Api-Key"])
				assert.is_nil(second.user)
				assert.is_nil(second.password)
			end)

			it("follows a permanent redirect (308), which LuaSocket leaves alone", function()
				http:on(AUTH, { code = 200, body = SIGN_IN })
				http:on(PROGRESS, { code = 308, headers = { Location = SERVER .. "/api/Reader/progress?chapterId=42" } })
				http:on(SERVER .. "/api/Reader/progress?chapterId=42", { code = 200, body = progress_of(7) })

				assert.equals(7, tonumber(OPDSPSE:getLastPage(STREAM, "reader", "s3cret")))
			end)
		end)
	end)

	describe("streamPages", function()
		it("rejects unusable page counts before HTTP or viewer construction", function()
			for _, count in ipairs({ 0, -1, 1.5, math.huge, "many" }) do
				OPDSPSE:streamPages(STREAM, count, false)
				assert.matches("page count", ui:last().text)
			end
			assert.is_nil(viewer)
			assert.same({}, http.requests)
		end)

		it("uses an explicit PSE position without looking up Kavita progress", function()
			OPDSPSE:streamPages(STREAM, 30, false, nil, nil, 12)
			for _, request in ipairs(http.requests) do
				assert.not_equal(AUTH, request.url)
				assert.not_equal(PROGRESS, request.url)
			end
		end)

		it("does not fetch an initial page before a page-number choice is accepted", function()
			OPDSPSE:streamPages(STREAM, 30, true)
			assert.is_nil(viewer)
			assert.same({}, http.requests)
			assert.equals("InputDialog", ui:last().kind)
		end)

		it("opens only the requested page, clamped to the last available image", function()
			http:on(page_url(29), { code = 200, body = "LAST" })
			OPDSPSE:streamPages(STREAM, 30, false, nil, nil, 99)
			assert.equals(30, viewer._images_list_cur)
			assert.equals("LAST", viewer.image.page)
			assert.equals(1, #http.requests)
			assert.equals(page_url(29), http.requests[1].url)
		end)

		it("rejects fractional and invalid jump input without closing the chooser", function()
			OPDSPSE:streamPages(STREAM, 30, true)
			local dialog = ui:last()
			for _, value in ipairs({ "0", "-1", "1.5", "31", "wrong" }) do
				dialog.typed = value
				ui:press(dialog, "Stream")
				assert.matches("whole page number", ui:last().text)
				assert.is_nil(viewer)
				assert.same({}, http.requests)
				assert.same({}, ui.closed)
			end
			dialog.typed = "8"
			http:on(page_url(7), { code = 200, body = "EIGHT" })
			ui:press(dialog, "Stream")
			assert.equals(8, viewer._images_list_cur)
			assert.equals(1, #http.requests)
		end)

		it("never fetches out-of-bounds indices or treats table metadata as an image", function()
			http:on(page_url(0), { code = 200, body = "ONE" })
			OPDSPSE:streamPages(STREAM, 30, false, nil, nil, 1)
			for _, key in ipairs({ 0, -1, 1.5, 31, "free" }) do
				assert.is_nil(viewer._images_list[key])
			end
			assert.equals(1, #http.requests)
		end)

		it("reports invalid stream URLs without opening the viewer or making a request", function()
			local invalid = { n = 4, nil, "", "http:", "http://" }
			for index = 1, invalid.n do
				OPDSPSE:streamPages(invalid[index], 30, false)
				assert.equals("Invalid stream URL.", ui:last().text)
			end

			assert.is_nil(viewer)
			assert.same({}, http.requests)
		end)

		-- Opens the viewer with no progress known, and gives the pages it was handed
		local function open(last_page_read)
			http:on(AUTH, { code = 401 })
			OPDSPSE:streamPages(STREAM, 30, false, "reader", "s3cret", last_page_read)
			return viewer._images_list
		end

		it("shows the pages in a viewer that starts after the page Kavita says was read", function()
			kavita_knows(7)

			OPDSPSE:streamPages(STREAM, 30, false, "reader", "s3cret")

			assert.equals(viewer, ui:last())
			assert.equals(30, viewer.images_list_nb)
			assert.equals(8, viewer._images_list_cur)
		end)

		it("starts from the first page when Kavita can't say", function()
			open()

			assert.equals(1, viewer._images_list_cur)
		end)

		it("starts from the first page when Kavita's answer says no page", function()
			http:on(AUTH, { code = 200, body = SIGN_IN })
			http:on(PROGRESS, { code = 200, body = "{}" })

			OPDSPSE:streamPages(STREAM, 30, false, "reader", "s3cret")

			assert.equals(1, viewer._images_list_cur)
		end)

		it("starts from the page it was told to", function()
			open(5)

			assert.equals(5, viewer._images_list_cur)
		end)

		it("fetches a zero-based page through Kavita's read-only reader endpoint", function()
			local pages = open()
			http:on(page_url(0), { code = 200, body = "PAGE-0-BYTES" })

			local image = pages[1]

			assert.same({ page = "PAGE-0-BYTES", size = 12 }, image)
			local request = http.requests[#http.requests]
			assert.equals(page_url(0), request.url)
			assert.equals("GET", request.method)
			assert.equals("identity", request.headers["Accept-Encoding"])
			assert.equals("reader", request.user)
			assert.equals("s3cret", request.password)
		end)

		it("sends the custom headers of the catalog with a page", function()
			HttpClient.setCatalogs({
				{ url = SERVER .. "/opds", headers = { { name = "X-Api-Key", value = "abc" } } },
			})
			local pages = open()
			http:on(page_url(0), { code = 200, body = "PAGE-0-BYTES" })

			local _ = pages[1]

			assert.equals("abc", http.requests[#http.requests].headers["X-Api-Key"])
		end)

		it("shows the placeholder when a page can't be fetched", function()
			local pages = open()
			http:on(page_url(1), { code = 404 })

			assert.same({ placeholder = "resources/koreader.png" }, pages[2])
		end)

		describe("when a page is redirected", function()
			it("keeps the credentials on the same server", function()
				local pages = open()
				local before = #http.requests
				http:on(page_url(0), { code = 301, headers = { Location = "/pages/0.jpg" }, body = "<html>moved</html>" })
				http:on(SERVER .. "/pages/0.jpg", { code = 200, body = "PAGE-0-BYTES" })

				local image = pages[1]

				assert.same({ page = "PAGE-0-BYTES", size = 12 }, image)
				local second = http.requests[before + 2]
				assert.equals(SERVER .. "/pages/0.jpg", second.url)
				assert.equals("reader", second.user)
				assert.equals("s3cret", second.password)
			end)

			it("keeps the credentials and the custom headers away from another server", function()
				HttpClient.setCatalogs({
					{ url = SERVER .. "/opds", headers = { { name = "X-Api-Key", value = "abc" } } },
				})
				local pages = open()
				local before = #http.requests
				http:on(page_url(0), { code = 302, headers = { Location = OTHER .. "/0.jpg" } })
				http:on(OTHER .. "/0.jpg", { code = 200, body = "PAGE-0-BYTES" })

				local image = pages[1]

				assert.same({ page = "PAGE-0-BYTES", size = 12 }, image)
				local first, second = http.requests[before + 1], http.requests[before + 2]
				assert.equals("abc", first.headers["X-Api-Key"])
				assert.equals("reader", first.user)
				assert.is_nil(second.headers["X-Api-Key"])
				assert.is_nil(second.user)
				assert.is_nil(second.password)
			end)

			it("follows a permanent redirect (308), which LuaSocket leaves alone", function()
				local pages = open()
				http:on(page_url(0), { code = 308, headers = { Location = SERVER .. "/pages/0.jpg" } })
				http:on(SERVER .. "/pages/0.jpg", { code = 200, body = "PAGE-0-BYTES" })

				assert.same({ page = "PAGE-0-BYTES", size = 12 }, pages[1])
			end)

			it("shows the placeholder when what the redirect leads to is refused", function()
				local pages = open()
				http:on(page_url(0), { code = 302, headers = { Location = OTHER .. "/0.jpg" } })
				http:on(OTHER .. "/0.jpg", { code = 404 })

				assert.same({ placeholder = "resources/koreader.png" }, pages[1])
			end)
		end)
	end)

	describe("local book resume", function()
		local browser, item, acquisition, flushed
		local GENERIC = OTHER .. "/pages/{pageNumber}?width={maxWidth}"

		before_each(function()
			flushed = 0
			browser = {
				settings = {}, root_catalog_url = OTHER .. "/opds", root_catalog_username = "reader",
				_manager = { saveSetting = function() flushed = flushed + 1 end },
			}
			item = { id = "urn:book:42" }
			acquisition = { href = GENERIC, count = 20, last_read = 7 }
			http:on(OTHER .. "/pages/6?width=600", { code = 200, body = "SEVEN" })
			http:on(OTHER .. "/pages/4?width=600", { code = 200, body = "FIVE" })
			http:on(OTHER .. "/pages/10?width=600", { code = 200, body = "ELEVEN" })
		end)

		it("uses generic PSE resume, saves only displayed pages, and preserves a local rewind", function()
			OPDSPSE:openBook(browser, item, acquisition)
			assert.equals(7, viewer._images_list_cur)
			assert.equals(1, #http.requests)
			assert.equals(OTHER .. "/pages/6?width=600", http.requests[1].url)
			assert.is_nil(browser.settings.stream_progress)
			viewer:paintTo()
			local key, saved = next(browser.settings.stream_progress)
			assert(saved)
			assert.equals(7, saved.page)
			local speculative = viewer._images_list[11]
			assert.equals("ELEVEN", speculative.page)
			assert.equals(7, browser.settings.stream_progress[key].page)
			viewer:switchToImageNum(5)
			assert.equals(7, browser.settings.stream_progress[key].page)
			viewer:paintTo()
			assert.equals(5, browser.settings.stream_progress[key].page)
			assert.equals(0, flushed)
			viewer:onSuspend()
			viewer:onCloseWidget()
			assert.equals(1, flushed)
			OPDSPSE:openBook(browser, item, acquisition)
			assert.equals(5, viewer._images_list_cur)
			OPDSPSE:openBook(browser, item, acquisition, false, true)
			assert.equals(7, viewer._images_list_cur)
		end)

		it("keeps an existing position after an HTTP or decode failure", function()
			OPDSPSE:openBook(browser, item, acquisition)
			viewer:paintTo()
			local key = next(browser.settings.stream_progress)
			http.routes = {}
			http:on(OTHER .. "/pages/4?width=600", { code = 200, body = "INVALID" })
			viewer:switchToImageNum(5)
			viewer:paintTo()
			viewer:switchToImageNum(6)
			viewer:paintTo()
			assert.equals(7, browser.settings.stream_progress[key].page)
			ui:run_scheduled()
			assert.matches("progress was not changed", ui:last().text)
		end)

		it("scopes positions to the catalog, account and feed identity", function()
			OPDSPSE:openBook(browser, item, acquisition)
			viewer:paintTo()
			item.id = "urn:book:43"
			OPDSPSE:openBook(browser, item, acquisition)
			viewer:paintTo()
			browser.root_catalog_username = "another"
			OPDSPSE:openBook(browser, item, acquisition)
			viewer:paintTo()
			browser.root_catalog_url = OTHER .. "/another-opds"
			OPDSPSE:openBook(browser, item, acquisition)
			viewer:paintTo()
			local count = 0
			for _ in pairs(browser.settings.stream_progress) do count = count + 1 end
			assert.equals(4, count)
		end)

		it("discards deferred page errors after a newer page or viewer close", function()
			OPDSPSE:openBook(browser, item, acquisition)
			viewer:switchToImageNum(6)
			viewer:switchToImageNum(11)
			ui:run_scheduled()
			assert.same({}, ui:texts())
			viewer:switchToImageNum(6)
			viewer:onCloseWidget()
			ui:run_scheduled()
			assert.same({}, ui:texts())
		end)

		it("bounds remembered books by evicting the oldest record", function()
			local records = {}
			for index = 1, OPDSPSE.MAX_SAVED_STREAMS do
				records["book-" .. index] = { page = 1, updated = index }
			end
			browser.settings.stream_progress = records
			OPDSPSE:openBook(browser, item, acquisition)
			viewer:paintTo()
			assert.is_nil(records["book-1"])
			assert.is_not_nil(records["book-2"])
			local count = 0
			for _ in pairs(records) do count = count + 1 end
			assert.equals(OPDSPSE.MAX_SAVED_STREAMS, count)
		end)
	end)
end)
