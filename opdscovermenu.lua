local Menu = require("ui/widget/menu")
local OPDSListMenu = require("opdslistmenu")
local logger = require("logger")

logger.warn("========================================")
logger.warn("OPDS+ opdscovermenu.lua IS LOADING")
logger.warn("========================================")

local OPDSCoverMenu = Menu:extend{
    title_shrink_font_to_fit = true,
    _opds_cover_mode = false,  -- Track if we're in cover mode
}

function OPDSCoverMenu:init()
    logger.warn("OPDS+: OPDSCoverMenu:init() called")
    -- Just call Menu init, we'll check for covers in updateItems
    Menu.init(self)
end

function OPDSCoverMenu:updateItems(select_number)
    logger.warn("========================================")
    logger.warn("OPDS+: OPDSCoverMenu:updateItems() called")
    logger.warn("OPDS+: item_table exists:", self.item_table ~= nil)

    -- Check if any items have cover URLs
    local has_covers = false
    local cover_count = 0
    if self.item_table then
        logger.warn("OPDS+: Checking", #self.item_table, "items for covers")
        for i, item in ipairs(self.item_table) do
            if item.cover_url then
                has_covers = true
                cover_count = cover_count + 1
                logger.warn("OPDS+: Item", i, "has cover_url:", item.cover_url:sub(1, 60))
            end
        end
    end

    logger.warn("OPDS+: Found", cover_count, "items with covers")
    logger.warn("OPDS+: has_covers =", has_covers)

    if has_covers and not self._opds_cover_mode then
        -- Switch to cover mode
        logger.warn("OPDS+: SWITCHING TO OPDSListMenu mode!")
        self._opds_cover_mode = true

        -- Replace methods with OPDSListMenu versions
        self.updateItems = OPDSListMenu.updateItems
        self.onCloseWidget = OPDSListMenu.onCloseWidget
        self._loadVisibleCovers = OPDSListMenu._loadVisibleCovers
        self._updateItemsBuildUI = OPDSListMenu._updateItemsBuildUI

        -- Set OPDSListMenu properties
        self.cover_width = OPDSListMenu.cover_width
        self.cover_height = OPDSListMenu.cover_height
        self._items_to_update = {}

        -- Call OPDSListMenu updateItems
        return OPDSListMenu.updateItems(self, select_number)

    elseif has_covers and self._opds_cover_mode then
        -- Already in cover mode, use OPDSListMenu
        logger.warn("OPDS+: Using OPDSListMenu (already in cover mode)")
        return OPDSListMenu.updateItems(self, select_number)

    else
        -- No covers, use standard Menu
        logger.warn("OPDS+: Using standard Menu (no covers)")
        self._opds_cover_mode = false
        return Menu.updateItems(self, select_number)
    end
end

function OPDSCoverMenu:onCloseWidget()
    logger.warn("OPDS+: OPDSCoverMenu:onCloseWidget()")
    if self._opds_cover_mode then
        OPDSListMenu.onCloseWidget(self)
    else
        Menu.onCloseWidget(self)
    end
end

logger.warn("OPDS+: opdscovermenu.lua LOADED SUCCESSFULLY")

return OPDSCoverMenu
