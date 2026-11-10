local helper = require("helper")
local fake_http = require("support.fake_http")
local socketutil_stub = require("support.socketutil")
local ui_stub = require("support.ui")

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

	-- The address of a page, with the screen 600 pixels wide
	local function page_url(number)
		return SERVER .. "/api/opds/" .. API_KEY .. "/image?chapterId=42&pageNumber=" .. number .. "&maxWidth=600"
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
			return { page = data, size = size }
		end
		function render_image:renderImageFile(path)
			return { placeholder = path }
		end

		local image_viewer = {}
		function image_viewer:new(options)
			viewer = options
			function viewer:switchToImageNum(number)
				self.switched_to = number
			end
			return viewer
		end

		local stubs = {
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
		}
		for name, stand_in in pairs(ui.stubs) do
			stubs[name] = stand_in
		end
		OPDSPSE = helper.load("services.kavita", stubs)
		HttpClient = require("services.http_client")
	end)

	after_each(helper.reset)

	describe("getLastPage", function()
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
		-- Opens the viewer with no progress known, and gives the pages it was handed
		local function open(last_page_read)
			http:on(AUTH, { code = 401 })
			OPDSPSE:streamPages(STREAM, 30, false, "reader", "s3cret", last_page_read)
			return viewer.image
		end

		it("shows the pages in a viewer that starts after the page Kavita says was read", function()
			kavita_knows(7)

			OPDSPSE:streamPages(STREAM, 30, false, "reader", "s3cret")

			assert.equals(viewer, ui:last())
			assert.equals(30, viewer.images_list_nb)
			assert.equals(8, viewer.switched_to)
		end)

		it("starts from the first page when Kavita can't say", function()
			open()

			assert.equals(1, viewer.switched_to)
		end)

		it("starts from the first page when Kavita's answer says no page", function()
			http:on(AUTH, { code = 200, body = SIGN_IN })
			http:on(PROGRESS, { code = 200, body = "{}" })

			OPDSPSE:streamPages(STREAM, 30, false, "reader", "s3cret")

			assert.equals(1, viewer.switched_to)
		end)

		it("starts from the page it was told to", function()
			open(5)

			assert.equals(5, viewer.switched_to)
		end)

		it("fetches a page when the viewer asks for it, as wide as the screen", function()
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
end)
