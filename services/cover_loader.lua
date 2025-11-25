-- Cover Loader Service for OPDS Menus
-- Handles asynchronous loading, rendering, and cleanup of cover images
-- Shared between list_menu.lua and grid_menu.lua to eliminate duplication

local RenderImage = require("ui/renderimage")
local logger = require("logger")

local ImageLoader = require("services.image_loader")
local StateManager = require("core.state_manager")

local CoverLoader = {}

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
-- @param debug_log function|nil Optional debug logging function
-- @return function Callback for ImageLoader
function CoverLoader.createRenderCallback(items_by_url, cover_width, cover_height, debug_log)
	return function(url, content)
		local items = items_by_url[url]
		if not items then
			logger.warn("OPDS+: ERROR - No items for URL:", url)
			return
		end

		for _, item_data in ipairs(items) do
			local entry = item_data.entry
			local widget = item_data.widget

			entry.lazy_load_cover = false

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

			if ok and cover_bb then
				entry.cover_bb = cover_bb
				entry.cover_failed = false
			else
				if debug_log then
					debug_log("Failed to render cover:", tostring(cover_bb))
				else
					logger.warn("OPDS+: Failed to render cover:", tostring(cover_bb))
				end
				entry.cover_failed = true
			end

			-- Update the widget to show the new cover (or error state)
			widget.entry = entry
			widget:update()
		end
	end
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

	if debug_log then
		debug_log("Loading", #urls, "unique cover URLs")
	end

	-- Get credentials from the menu
	local username = menu.root_catalog_username
	local password = menu.root_catalog_password

	-- Get debug mode from StateManager
	local debug_mode = StateManager.getInstance():isDebugMode()

	-- Create render callback
	local render_callback = CoverLoader.createRenderCallback(
		items_by_url,
		menu.cover_width,
		menu.cover_height,
		debug_log
	)

	-- Load covers asynchronously
	local _, halt = ImageLoader:loadImages(urls, render_callback, username, password, debug_mode)

	-- Clear the pending items
	menu._items_to_update = {}

	return halt
end

--- Clean up cover loading and free resources
-- @param menu table Menu instance with halt_image_loading and item_table
function CoverLoader.cleanup(menu)
	-- Cancel any in-progress image loading
	if menu.halt_image_loading then
		menu.halt_image_loading()
		menu.halt_image_loading = nil
	end

	-- Free cover image blitbuffers
	if menu.item_table then
		for _, entry in ipairs(menu.item_table) do
			if entry.cover_bb then
				entry.cover_bb:free()
				entry.cover_bb = nil
			end
		end
	end
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
