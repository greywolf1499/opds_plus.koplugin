local Menu = require("ui/widget/menu")
local OPDSListMenu = require("ui.menus.list_menu")
local OPDSGridMenu = require("ui.menus.grid_menu")
local Debug = require("utils.debug")
local StateManager = require("core.state_manager")
local CoverLoader = require("services.cover_loader")

local OPDSCoverMenu = Menu:extend {
    title_shrink_font_to_fit = true,
    _last_mode_had_covers = nil,
    _last_display_mode = nil,
}

function OPDSCoverMenu:init()
    Menu.init(self)
end

function OPDSCoverMenu:_debugLog(...)
    Debug.log("CoverMenu:", ...)
end

function OPDSCoverMenu:handleEvent(event)
    if event.handler == "onKeyPress" or event.handler == "onKeyRepeat"
        or event.handler == "onGesture" or event.handler == "onFocusMove" then
        CoverLoader.defer(self)
    end
    return Menu.handleEvent(self, event)
end

function OPDSCoverMenu:updateItems(select_number)
    CoverLoader.stopLoading(self)
    if self._cover_memory and self._cover_item_table ~= self.item_table then
        self._cover_memory:clear()
    end
    self._cover_item_table = self.item_table

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

    -- Get display mode setting via StateManager
    local display_mode = StateManager.getInstance():getDisplayMode()

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
    CoverLoader.cleanup(self)
    Menu.onCloseWidget(self)
end

return OPDSCoverMenu
