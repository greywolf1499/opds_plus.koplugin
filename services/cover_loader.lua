-- Cover Loader Service for OPDS Menus
-- Handles asynchronous loading, rendering, and cleanup of cover images
-- Shared between list_menu.lua and grid_menu.lua to eliminate duplication

local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local ImageLoader = require("services.image_loader")
local Debug = require("utils.debug")
local Constants = require("models.constants")
local CoverMemory = require("services.cover_memory")

local CoverLoader = {}

function CoverLoader.getMemory(menu)
	menu._cover_memory = menu._cover_memory or CoverMemory:new()
	return menu._cover_memory
end

function CoverLoader.pinWidget(memory, widget)
	local ImageWidget = require("ui/widget/imagewidget")
	local release = memory:pin(widget.image)
	function widget:free()
		ImageWidget.free(self)
		self.image = nil
		release()
	end
	return widget
end

--- Extract unique URLs from items pending cover load
-- @param items_to_update table Array of {entry, widget} items
-- @return table urls Array of unique URLs
-- @return table items_by_url Map of URL -> array of item_data
function CoverLoader.extractUniqueUrls(items_to_update)
	local urls = {}
	local items_by_url = {}

	for _, item_data in ipairs(items_to_update) do
		local url = item_data.entry.cover_url
		if url and not items_by_url[url] then
			table.insert(urls, url)
			items_by_url[url] = { item_data }
		elseif url then
			table.insert(items_by_url[url], item_data)
		end
	end

	return urls, items_by_url
end

--- Create a cover render callback for image loading
-- @param items_by_url table Map of URL -> array of item_data
-- @param cover_width number Target cover width
-- @param cover_height number Target cover height
-- @param is_current function|nil Guard rejecting callbacks from an old menu generation
-- @param memory table Decoded buffer owner
-- @return function Callback for ImageLoader, returning a continuation for duplicate covers
function CoverLoader.createRenderCallback(items_by_url, cover_width, cover_height, is_current, memory)
	return function(url, content)
		local items = items_by_url[url]
		if not items then
			Debug.error("CoverLoader:", "No items for URL:", url)
			return
		end

		local index = 0
		local render_next
		render_next = function()
			if is_current and not is_current() then
				return
			end
			index = index + 1
			local item_data = items[index]
			local entry = item_data.entry
			local widget = item_data.widget

			-- Render the cover image maintaining aspect ratio
			local ok, cover_bb = pcall(function()
				return RenderImage:renderImageData(
					content,
					#content,
					false,
					cover_width,
					cover_height
				)
			end)

			if is_current and not is_current() then
				if ok and cover_bb then cover_bb:free() end
				return
			end
			entry.lazy_load_cover = false
			local release
			if ok and cover_bb then
				release = memory:add(entry, cover_bb)
				entry.cover_failed = false
			else
				Debug.error("CoverLoader:", "Failed to render cover:", tostring(cover_bb))
				entry.cover_failed = true
			end

			-- Update the widget to show the new cover (or error state)
			widget.entry = entry
			widget:update()
			if release then release() end
			if index < #items then
				return render_next
			end
		end
		return render_next()
	end
end

function CoverLoader.defer(menu)
	menu._cover_pause_until = time.now() + time.s(Constants.IMAGE_LOADER.INPUT_QUIET_TIME)
	if menu._cover_batch then
		menu._cover_batch:defer()
	end
	if menu._cover_prefetch_batch then
		menu._cover_prefetch_batch:defer()
	end
	if UIManager:getTopmostVisibleWidget() == menu then
		CoverLoader.schedulePrefetch(menu)
	end
end

function CoverLoader.stopPrefetch(menu)
	if menu._scheduled_cover_prefetch then
		UIManager:unschedule(menu._scheduled_cover_prefetch)
		menu._scheduled_cover_prefetch = nil
	end
	if menu._halt_cover_prefetch then
		menu._halt_cover_prefetch()
		menu._halt_cover_prefetch = nil
	end
	menu._cover_prefetch_batch = nil
end

local function prefetchEnabled(menu)
	local settings = menu.settings
	return settings and settings.cover_prefetch_enabled == true
		and settings.cover_cache_enabled ~= false and settings.cover_parallel_downloads ~= false
end

function CoverLoader.schedulePrefetch(menu)
	if not menu._last_mode_had_covers then
		menu._cover_prefetch_context = nil
		return
	end
	local previous = menu._cover_prefetch_context
	local direction = 1
	if previous and previous.items == menu.item_table and previous.perpage == menu.perpage
		and previous.mode == menu._last_display_mode then
		direction = previous.direction
		if menu.page > previous.page then direction = 1 end
		if menu.page < previous.page then direction = -1 end
	end
	menu._cover_prefetch_context = {
		items = menu.item_table, page = menu.page, perpage = menu.perpage,
		mode = menu._last_display_mode, direction = direction,
	}
	if not prefetchEnabled(menu) or menu._scheduled_cover_prefetch
		or (menu._cover_prefetch_batch and not menu._cover_prefetch_batch.cancelled) then
		return
	end
	local neighbor = menu.page + direction
	if neighbor < 1 or neighbor > math.ceil(#menu.item_table / menu.perpage) then return end
	local items = {}
	for index = (neighbor - 1) * menu.perpage + 1, math.min(neighbor * menu.perpage, #menu.item_table) do
		items[#items + 1] = { entry = menu.item_table[index] }
	end
	local urls = CoverLoader.extractUniqueUrls(items)
	if #urls == 0 then return end

	local generation = menu._cover_generation
	local function can_continue()
		return menu._cover_generation == generation and prefetchEnabled(menu)
			and UIManager:getTopmostVisibleWidget() == menu
	end
	local start_when_idle
	start_when_idle = function()
		menu._scheduled_cover_prefetch = nil
		if not can_continue() then return end
		if CoverLoader.hasPendingItems(menu) or (menu._cover_batch and menu._cover_batch.loading)
			or time.now() < (menu._cover_pause_until or 0) then
			menu._scheduled_cover_prefetch = start_when_idle
			UIManager:scheduleIn(Constants.IMAGE_LOADER.INPUT_QUIET_TIME, start_when_idle)
			return
		end
		local settings = menu.settings
		local batch, halt = ImageLoader:prefetch(urls, menu.root_catalog_username, menu.root_catalog_password,
			settings.cover_cache_max_mb, settings.cover_cache_ttl_minutes, can_continue)
		menu._cover_prefetch_batch = batch
		menu._halt_cover_prefetch = halt
	end
	menu._scheduled_cover_prefetch = start_when_idle
	UIManager:scheduleIn(Constants.IMAGE_LOADER.INPUT_QUIET_TIME, start_when_idle)
end

function CoverLoader.stopLoading(menu)
	CoverLoader.stopPrefetch(menu)
	menu._cover_generation = (menu._cover_generation or 0) + 1
	if menu._scheduled_cover_load then
		UIManager:unschedule(menu._scheduled_cover_load)
		menu._scheduled_cover_load = nil
	end
	if menu.halt_image_loading then
		menu.halt_image_loading()
		menu.halt_image_loading = nil
	end
	menu._cover_batch = nil
end

--- Load covers for menu items
-- @param menu table Menu instance with _items_to_update, cover_width, cover_height
-- @param debug_log function|nil Optional debug logging function
-- @return function|nil Halt function to cancel loading, or nil if nothing to load
function CoverLoader.loadVisibleCovers(menu, debug_log)
	if not menu._items_to_update or #menu._items_to_update == 0 then
		return nil
	end

	-- Extract unique cover URLs
	local urls, items_by_url = CoverLoader.extractUniqueUrls(menu._items_to_update)

	if #urls == 0 then
		return nil
	end

	Debug.log("CoverLoader:", "Loading", #urls, "unique cover URLs")

	-- Get credentials from the menu
	local username = menu.root_catalog_username
	local password = menu.root_catalog_password
	local cache_enabled = true
	local cache_max_mb = nil
	local cache_ttl_minutes = nil
	if menu.settings and menu.settings.cover_cache_enabled ~= nil then
		cache_enabled = menu.settings.cover_cache_enabled ~= false
		cache_max_mb = menu.settings.cover_cache_max_mb
		cache_ttl_minutes = menu.settings.cover_cache_ttl_minutes
	end
	local parallel_downloads = not menu.settings or menu.settings.cover_parallel_downloads ~= false

	-- Create render callback
	menu._cover_generation = menu._cover_generation or 0
	local generation = menu._cover_generation
	local render_callback = CoverLoader.createRenderCallback(
		items_by_url,
		menu.cover_width,
		menu.cover_height,
		function() return menu._cover_generation == generation end,
		CoverLoader.getMemory(menu)
	)

	-- Load covers asynchronously
	local batch, halt = ImageLoader:loadImages(
		urls,
		render_callback,
		username,
		password,
		cache_enabled,
		cache_max_mb,
		cache_ttl_minutes,
		parallel_downloads
	)
	batch.pause_until = menu._cover_pause_until
	menu._cover_batch = batch

	-- Clear the pending items
	menu._items_to_update = {}

	return halt
end

--- Clean up cover loading and free resources
-- @param menu table Menu owning the visible widgets and decoded cache
function CoverLoader.cleanup(menu)
	CoverLoader.stopLoading(menu)

	if menu.item_group then menu.item_group:clear() end
	if menu._cover_memory then
		menu._cover_memory:clear()
		menu._cover_memory = nil
	end
	menu._cover_item_table = nil
	menu._cover_prefetch_context = nil
end

--- Initialize cover loading state on a menu
-- Sets up required fields for cover loading
-- @param menu table Menu instance to initialize
function CoverLoader.initMenu(menu)
	menu._items_to_update = menu._items_to_update or {}
	menu.halt_image_loading = nil
end

--- Queue an item for cover loading
-- @param menu table Menu instance
-- @param entry table Entry with cover_url
-- @param widget table Widget to update when cover loads
function CoverLoader.queueItem(menu, entry, widget)
	if not menu._items_to_update then
		menu._items_to_update = {}
	end
	table.insert(menu._items_to_update, { entry = entry, widget = widget })
end

--- Check if there are items pending cover load
-- @param menu table Menu instance
-- @return boolean True if there are pending items
function CoverLoader.hasPendingItems(menu)
	return menu._items_to_update and #menu._items_to_update > 0
end

return CoverLoader
