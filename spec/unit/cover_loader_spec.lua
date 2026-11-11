local helper = require("helper")
local ui_stub = require("support.ui")

describe("neighbor cover scheduling", function()
	local CoverLoader, ui, menu, top, clock, calls, halted

	local function step()
		local task = table.remove(ui.scheduled, 1)
		assert(task, "no scheduled task")
		clock = clock + task.seconds
		task.callback()
	end

	before_each(function()
		helper.reset()
		ui = ui_stub.new()
		clock, halted, calls = 0, 0, {}
		menu = {
			page = 1, perpage = 2, _cover_generation = 1, _items_to_update = {},
			_last_mode_had_covers = true, _last_display_mode = "grid",
			settings = { cover_prefetch_enabled = true },
			item_table = {
				{ cover_url = "A" }, { cover_url = "B" }, { cover_url = "C" }, { cover_url = "C" },
				{ cover_url = "E" }, { cover_url = "F" }, { cover_url = "G" }, { cover_url = "H" },
			},
		}
		top = menu
		ui.UIManager.getTopmostVisibleWidget = function() return top end
		CoverLoader = helper.load("services.cover_loader", {
			["ui/uimanager"] = ui.UIManager,
			["ui/time"] = {
				now = function() return clock end,
				s = function(seconds) return seconds end,
			},
			["ui/renderimage"] = {},
			["services.image_loader"] = {
				prefetch = function(_self, urls, _user, _pass, _max, _ttl, can_continue)
					calls[#calls + 1] = { urls = urls, can_continue = can_continue }
					local batch = { loading = true }
					function batch:defer() self.deferred = true end
					return batch, function()
						halted = halted + 1
						batch.cancelled, batch.loading = true, false
					end
				end,
			},
		})
	end)

	after_each(helper.reset)

	it("does nothing without opt-in, disk cache and parallel downloading", function()
		for _, setting in ipairs({ "cover_prefetch_enabled", "cover_cache_enabled", "cover_parallel_downloads" }) do
			menu.settings[setting] = false
			CoverLoader.schedulePrefetch(menu)
			assert.same({}, ui.scheduled)
			assert.same({}, calls)
			menu.settings[setting] = true
		end
		menu.settings.cover_prefetch_enabled = nil
		CoverLoader.schedulePrefetch(menu)
		assert.same({}, ui.scheduled)
	end)

	it("waits for visible covers and quiet input, then deduplicates one neighboring page", function()
		menu._items_to_update = { { entry = menu.item_table[1] } }
		CoverLoader.schedulePrefetch(menu)
		step()
		assert.same({}, calls)
		menu._items_to_update = {}
		menu._cover_batch = { loading = true, defer = function() end }
		step()
		assert.same({}, calls)
		menu._cover_batch.loading = false
		menu._cover_pause_until = clock + 1
		step()
		assert.same({}, calls)
		for _ = 1, 4 do
			if #calls > 0 then break end
			step()
		end
		assert.same({ "C" }, calls[1].urls)
		assert.equals(1, #calls)
		assert.is_true(calls[1].can_continue())
		assert.same({}, ui.scheduled)
		CoverLoader.defer(menu)
		assert.is_true(menu._cover_prefetch_batch.deferred)
		assert.same({}, ui.scheduled)
	end)

	it("follows a reversal without requesting both neighbors", function()
		menu.page = 3
		CoverLoader.schedulePrefetch(menu)
		step()
		assert.same({ "G", "H" }, calls[1].urls)
		CoverLoader.stopLoading(menu)
		menu.page = 2
		CoverLoader.schedulePrefetch(menu)
		step()
		assert.same({ "A", "B" }, calls[2].urls)
		assert.equals(1, halted)
		assert.is_false(calls[1].can_continue())
		CoverLoader.stopLoading(menu)
		menu.page = 1
		CoverLoader.schedulePrefetch(menu)
		assert.same({}, ui.scheduled)
		assert.equals(2, #calls)
	end)

	it("resets direction after a layout change and cancels work on close", function()
		menu.page = 3
		CoverLoader.schedulePrefetch(menu)
		CoverLoader.stopLoading(menu)
		menu.page = 2
		CoverLoader.schedulePrefetch(menu)
		CoverLoader.stopLoading(menu)
		menu._last_display_mode = "list"
		CoverLoader.schedulePrefetch(menu)
		step()
		assert.same({ "E", "F" }, calls[1].urls)
		CoverLoader.cleanup(menu)
		assert.equals(1, halted)
		assert.same({}, ui.scheduled)
		assert.is_nil(menu._cover_prefetch_context)
	end)

	it("rejects warming under a modal or after its settings are disabled", function()
		CoverLoader.schedulePrefetch(menu)
		top = {}
		step()
		assert.same({}, calls)
		top = menu
		CoverLoader.defer(menu)
		step()
		assert.equals(1, #calls)
		menu.settings.cover_cache_enabled = false
		assert.is_false(calls[1].can_continue())
		CoverLoader.stopPrefetch(menu)
		assert.equals(1, halted)
		assert.same({}, ui.scheduled)
	end)

	it("keeps completed warming idle but rearms cancelled work on foreground input", function()
		CoverLoader.schedulePrefetch(menu)
		step()
		menu._cover_prefetch_batch.loading = false
		CoverLoader.defer(menu)
		assert.same({}, ui.scheduled)
		assert.equals(1, #calls)
		top = {}
		assert.is_false(calls[1].can_continue())
		menu._cover_prefetch_batch.cancelled = true
		CoverLoader.defer(menu)
		assert.same({}, ui.scheduled)
		top = menu
		CoverLoader.defer(menu)
		step()
		assert.equals(2, #calls)
		assert.same({ "C" }, calls[2].urls)
	end)

	it("resets backward navigation when the catalog or page size changes", function()
		menu.page = 3
		CoverLoader.schedulePrefetch(menu)
		CoverLoader.stopLoading(menu)
		menu.page = 2
		CoverLoader.schedulePrefetch(menu)
		CoverLoader.stopLoading(menu)
		menu.item_table = {
			{ cover_url = "W" }, { cover_url = "X" }, { cover_url = "Y" },
			{ cover_url = "Z" }, { cover_url = "Q" }, { cover_url = "R" },
		}
		menu.page = 1
		CoverLoader.schedulePrefetch(menu)
		step()
		assert.same({ "Y", "Z" }, calls[1].urls)
		CoverLoader.stopLoading(menu)
		menu.perpage = 4
		CoverLoader.schedulePrefetch(menu)
		step()
		assert.same({ "Q", "R" }, calls[2].urls)
	end)
end)
