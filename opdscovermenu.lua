local Menu = require("ui/widget/menu")
local OPDSListMenu = require("opdslistmenu")
local UIManager = require("ui/uimanager")
local logger = require("logger")

logger.warn("========================================")
logger.warn("OPDS+ opdscovermenu.lua IS LOADING")
logger.warn("========================================")

local OPDSCoverMenu = Menu:extend{
    title_shrink_font_to_fit = true,
    _last_mode_had_covers = nil,  -- Track what mode we were in last time
}

function OPDSCoverMenu:init()
    logger.warn("OPDS+: OPDSCoverMenu:init() called")
    Menu.init(self)
end

function OPDSCoverMenu:updateItems(select_number)
    logger.warn("========================================")
    logger.warn("OPDS+: OPDSCoverMenu:updateItems() called")
    logger.warn("OPDS+: item_table exists:", self.item_table ~= nil)

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

    -- Check if we're switching modes
    local mode_changed = (self._last_mode_had_covers ~= nil) and (self._last_mode_had_covers ~= has_covers)
    if mode_changed then
        logger.warn("OPDS+: !!! MODE CHANGED - was", self._last_mode_had_covers and "covers" or "no covers",
                    "now", has_covers and "covers" or "no covers")
    end

    if has_covers then
        -- Use OPDSListMenu for items with covers
        logger.warn("OPDS+: Using OPDSListMenu (covers present)")

        -- Set up cover properties and methods
        self.setCoverDimensions = OPDSListMenu.setCoverDimensions
        self:setCoverDimensions()  -- Calculate and set cover dimensions

        self._items_to_update = {}

        -- Make sure we have the necessary methods
        self._loadVisibleCovers = OPDSListMenu._loadVisibleCovers
        self._recalculateDimen = OPDSListMenu._recalculateDimen

        -- Remember we're in cover mode
        self._last_mode_had_covers = true

        -- Call OPDSListMenu's updateItems directly
        return OPDSListMenu.updateItems(self, select_number)
    else
        -- Use standard Menu for items without covers
        logger.warn("OPDS+: Using standard Menu (no covers)")

        -- Clean up any cover-related properties and methods
        self.cover_width = nil
        self.cover_height = nil
        self._items_to_update = nil
        self._loadVisibleCovers = nil
        self._recalculateDimen = nil
        self.setCoverDimensions = nil

        -- Remember we're in standard mode
        self._last_mode_had_covers = false

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
        OPDSListMenu.onCloseWidget(self)
    else
        Menu.onCloseWidget(self)
    end
end

logger.warn("OPDS+: opdscovermenu.lua LOADED SUCCESSFULLY")

return OPDSCoverMenu
