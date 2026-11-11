local helper = require("helper")
local ui_stub = require("support.ui")

describe("CatalogLoader", function()
	local Loader, ui, co, work, mode, applied, prepared, replies, fail_mapping

	local function start()
		return Loader.start("https://catalog.example/feed", {}, function(packet, cancelled)
			replies[#replies + 1] = { packet = packet, cancelled = cancelled }
		end)
	end

	local function finish(packet)
		local ok, err = coroutine.resume(co, true, packet)
		assert(ok, err)
	end

	before_each(function()
		helper.reset()
		ui = ui_stub.new()
		mode, applied, prepared, replies, fail_mapping = "async", {}, 0, {}, false
		local trap = {
			new = function(_self, options)
				options.dismiss_callback = function() end
				return options
			end,
			onCloseWidget = function() end,
		}
		ui.stubs["ui/widget/trapwidget"] = trap
		ui.stubs["ui/trapper"] = {
			wrap = function(_self, run)
				co = coroutine.create(run)
				local ok, err = coroutine.resume(co)
				assert(ok, err)
			end,
			dismissableRunInSubprocess = function(_self, run, widget)
				if mode == "unavailable" then return false end
				work = run
				widget.dismiss_callback = function()
					local ok, err = coroutine.resume(co, false)
					assert(ok, err)
				end
				return coroutine.yield()
			end,
		}
		ui.stubs["core.feed_fetcher"] = {
			newRequestState = function() return { errors = {} } end,
			applyRequestState = function(state) applied[#applied + 1] = state end,
			genItemTableFromURL = function(url, _user, _pass, _debug, map)
				prepared = prepared + 1
				return map({ feed = {} }, url)
			end,
		}
		ui.stubs["core.navigation_handler"] = {
			genItemTableFromCatalog = function()
				if fail_mapping then error("injected mapping failure") end
				return { { title = "Book" }, hrefs = { next = "/page2" } }, { Genre = {} }, "/search"
			end,
		}
		Loader = helper.load("services.catalog_loader", ui.stubs)
	end)

	after_each(helper.reset)

	it("delivers plain catalog metadata and parent-side state only after completion", function()
		start()
		assert.same({}, replies)
		assert.same({}, applied)
		local packet = work()
		finish(packet)
		assert.same({ packet.state }, applied)
		assert.equals("Book", replies[1].packet.items[1].title)
		assert.equals("/page2", replies[1].packet.items.hrefs.next)
		assert.equals("/search", replies[1].packet.search)
		assert.same({ Genre = {} }, replies[1].packet.facets)
	end)

	it("cancels the worker without publishing state or a failure message", function()
		local job = start()
		job.widget:onAnyKeyPressed()
		job:cancel()
		assert.same({ { cancelled = true } }, replies)
		assert.same({}, applied)
		assert.equals(1, #ui.shown)
		assert.is_false(job.running)
	end)

	it("reports missing or failed worker output instead of treating it as an empty catalog", function()
		start()
		finish(nil)
		assert.matches("Catalog loading failed", ui:last().text)
		assert.is_nil(replies[1].packet)
		assert.same({}, applied)
		start()
		fail_mapping = true
		finish(work())
		assert.matches("Catalog loading failed", ui:last().text)
		assert.is_nil(replies[2].packet)
		assert.is_true(require("logger").logged("warn", "injected mapping failure"))
	end)

	it("asks before a blocking fallback and never starts it after cancellation", function()
		mode = "unavailable"
		local cancelled = start()
		local stale_prompt = ui:last()
		assert.equals(0, prepared)
		cancelled:cancel()
		stale_prompt.ok_callback()
		assert.equals(0, prepared)
		start()
		ui:last().ok_callback()
		assert.equals(1, prepared)
		assert.equals("Book", replies[1].packet.items[1].title)
	end)
end)
