local Menu = require("ui/widget/menu")
local OPDSListMenu = require("opdslistmenuplus")
local OPDSGridMenu = require("opdsgridmenuplus")  -- NEW: Add grid menu
local UIManager = require("ui/uimanager")
local logger = require("logger")

logger.warn("========================================")
logger.warn("OPDS+ opdscovermenu.lua IS LOADING")
logger.warn("========================================")

local OPDSCoverMenu = Menu:extend{
    title_shrink_font_to_fit = true,
    _last_mode_had_covers = nil,
    _last_display_mode = nil,  -- NEW: Track display mode
}

function OPDSCoverMenu:init()
    logger.warn("OPDS+: OPDSCoverMenu:init() called")
    Menu.init(self)
end

function OPDSCoverMenu:updateItems(select_number)
    logger.warn("========================================")
    logger.warn("OPDS+: OPDSCoverMenu:updateItems() called")
    logger.warn("OPDS+: item_table exists:", self.item_table ~= nil)

    -- Debug: Check if we have manager and settings
    if self._manager then
        logger.warn("OPDS+: _manager exists:", self._manager ~= nil)
        if self._manager.settings then
            logger.warn("OPDS+: settings exists:", self._manager.settings ~= nil)
            logger.warn("OPDS+: cover_height_ratio:", self._manager.settings.cover_height_ratio)
            logger.warn("OPDS+: display_mode:", self._manager.settings.display_mode)  -- NEW
        else
            logger.warn("OPDS+: WARNING - No settings found in _manager")
        end
    else
        logger.warn("OPDS+: WARNING - No _manager reference found!")
    end

    -- Cancel any scheduled cover loading from previous page
    if self._scheduled_cover_load then
        logger.warn("OPDS+: Cancelling scheduled cover load from previous page")
        UIManager:unschedule(self._scheduled_cover_load)
        self._scheduled_cover_load = nil
    end

    -- Cancel any ongoing image loading
    if self.halt_image_loading then
        logger.warn("OPDS+: Halting ongoing image loading")
        self.halt_image_loading()
        self.halt_image_loading = nil
    end

    -- Check if any items have cover URLs
    local has_covers = false
    local cover_count = 0
    if self.item_table then
        logger.warn("OPDS+: Checking", #self.item_table, "items for covers")
        for i, item in ipairs(self.item_table) do
            if item.cover_url then
                has_covers = true
                cover_count = cover_count + 1
            end
        end
    end

    logger.warn("OPDS+: Found", cover_count, "items with covers")
    logger.warn("OPDS+: has_covers =", has_covers)
    logger.warn("OPDS+: _last_mode_had_covers =", self._last_mode_had_covers)

    -- NEW: Get display mode setting (default to "list")
    local display_mode = "list"  -- Default
    if self._manager and self._manager.settings and self._manager.settings.display_mode then
        display_mode = self._manager.settings.display_mode
    end
    logger.warn("OPDS+: display_mode =", display_mode)

    -- Check if we're switching modes
    local mode_changed = (self._last_mode_had_covers ~= nil) and (self._last_mode_had_covers ~= has_covers)
    local display_mode_changed = (self._last_display_mode ~= nil) and (self._last_display_mode ~= display_mode)

    if mode_changed then
        logger.warn("OPDS+: !!! MODE CHANGED - was", self._last_mode_had_covers and "covers" or "no covers",
                    "now", has_covers and "covers" or "no covers")
    end

    if display_mode_changed then
        logger.warn("OPDS+: !!! DISPLAY MODE CHANGED - was", self._last_display_mode, "now", display_mode)
    end

    if has_covers then
        -- NEW: Choose between list and grid based on setting
        if display_mode == "grid" then
            logger.warn("OPDS+: Using OPDSGridMenu (grid mode)")

            -- Clear any previous dimensions
            self.cover_width = nil
            self.cover_height = nil
            self.cell_width = nil
            self.cell_height = nil

            -- Set up grid methods
            self.setGridDimensions = OPDSGridMenu.setGridDimensions
            self:setGridDimensions()

            self._items_to_update = {}
            self._loadVisibleCovers = OPDSGridMenu._loadVisibleCovers
            self._recalculateDimen = OPDSGridMenu._recalculateDimen

            self._last_mode_had_covers = true
            self._last_display_mode = "grid"

            return OPDSGridMenu.updateItems(self, select_number)
        else
            -- Use list view (existing code)
            logger.warn("OPDS+: Using OPDSListMenu (list mode)")

            -- IMPORTANT: Clear any previously calculated dimensions
            self.cover_width = nil
            self.cover_height = nil

            -- Set up cover properties and methods
            self.setCoverDimensions = OPDSListMenu.setCoverDimensions

            -- Calculate dimensions with current settings
            logger.warn("OPDS+: Calculating cover dimensions...")
            self:setCoverDimensions()
            logger.warn("OPDS+: Calculated dimensions:", self.cover_width, "x", self.cover_height)

            self._items_to_update = {}

            -- Make sure we have the necessary methods
            self._loadVisibleCovers = OPDSListMenu._loadVisibleCovers
            self._recalculateDimen = OPDSListMenu._recalculateDimen

            -- Remember we're in cover mode
            self._last_mode_had_covers = true
            self._last_display_mode = "list"

            -- Call OPDSListMenu's updateItems directly
            return OPDSListMenu.updateItems(self, select_number)
        end
    else
        -- Use standard Menu for items without covers
        logger.warn("OPDS+: Using standard Menu (no covers)")

        -- Clean up any cover-related properties and methods
        self.cover_width = nil
        self.cover_height = nil
        self.cell_width = nil
        self.cell_height = nil
        self._items_to_update = nil
        self._loadVisibleCovers = nil
        self._recalculateDimen = nil
        self.setCoverDimensions = nil
        self.setGridDimensions = nil

        -- Remember we're in standard mode
        self._last_mode_had_covers = false
        self._last_display_mode = nil

        -- Call standard Menu's updateItems directly
        return Menu.updateItems(self, select_number)
    end
end

function OPDSCoverMenu:onCloseWidget()
    logger.warn("OPDS+: OPDSCoverMenu:onCloseWidget()")

    -- Cancel any scheduled cover loading
    if self._scheduled_cover_load then
        UIManager:unschedule(self._scheduled_cover_load)
        self._scheduled_cover_load = nil
    end

    -- Clean up image loading
    if self.halt_image_loading then
        self.halt_image_loading()
        self.halt_image_loading = nil
    end

    -- Check if we have cover-related items
    local has_cover_items = false
    if self.item_table then
        for _, item in ipairs(self.item_table) do
            if item.cover_url then
                has_cover_items = true
                break
            end
        end
    end

    if has_cover_items then
        -- NEW: Check which mode we're in
        local display_mode = "list"
        if self._manager and self._manager.settings and self._manager.settings.display_mode then
            display_mode = self._manager.settings.display_mode
        end

        if display_mode == "grid" then
            OPDSGridMenu.onCloseWidget(self)
        else
            OPDSListMenu.onCloseWidget(self)
        end
    else
        Menu.onCloseWidget(self)
    end
end

logger.warn("OPDS+: opdscovermenu.lua LOADED SUCCESSFULLY")

return OPDSCoverMenu
