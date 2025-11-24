local Menu = require("ui/widget/menu")
local OPDSListMenu = require("opdslistmenuplus")
local OPDSGridMenu = require("opdsgridmenuplus")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Debug = require("utils.debug")

local OPDSCoverMenu = Menu:extend {
    title_shrink_font_to_fit = true,
    _last_mode_had_covers = nil,
    _last_display_mode = nil,
}

function OPDSCoverMenu:init()
    Menu.init(self)
end

function OPDSCoverMenu:_debugLog(...)
    Debug.log(self._manager, "CoverMenu:", ...)
end

function OPDSCoverMenu:updateItems(select_number)
    -- Cancel any scheduled cover loading from previous page
    if self._scheduled_cover_load then
        UIManager:unschedule(self._scheduled_cover_load)
        self._scheduled_cover_load = nil
    end

    -- Cancel any ongoing image loading
    if self.halt_image_loading then
        self.halt_image_loading()
        self.halt_image_loading = nil
    end

    -- Check if any items have cover URLs
    local has_covers = false
    if self.item_table then
        for _, item in ipairs(self.item_table) do
            if item.cover_url then
                has_covers = true
                break
            end
        end
    end

    -- Get display mode setting (default to "list")
    local display_mode = "list"
    if self._manager and self._manager.settings and self._manager.settings.display_mode then
        display_mode = self._manager.settings.display_mode
    end

    self:_debugLog("updateItems - has_covers:", has_covers, "display_mode:", display_mode)

    if has_covers then
        -- Choose between list and grid based on setting
        if display_mode == "grid" then
            self:_debugLog("Using OPDSGridMenu (grid mode)")

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
            -- Use list view
            self:_debugLog("Using OPDSListMenu (list mode)")

            -- Clear any previously calculated dimensions
            self.cover_width = nil
            self.cover_height = nil

            -- Set up cover properties and methods
            self.setCoverDimensions = OPDSListMenu.setCoverDimensions

            -- Calculate dimensions with current settings
            self:setCoverDimensions()

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
        self:_debugLog("Using standard Menu (no covers)")

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
        -- Check which mode we're in
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

return OPDSCoverMenu
