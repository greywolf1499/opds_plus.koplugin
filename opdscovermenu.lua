local Menu = require("ui/widget/menu")
local ListMenu = require("listmenu")  -- from vendor
local CoverMenu = require("covermenu")  -- from vendor

local OPDSCoverMenu = Menu:extend {
    title_shrink_font_to_fit = true,
}

-- Use CoverMenu methods for cover handling
OPDSCoverMenu.updateItems = CoverMenu.updateItems
OPDSCoverMenu.updateCache = CoverMenu.updateCache
OPDSCoverMenu.onCloseWidget = CoverMenu.onCloseWidget

-- Use ListMenu methods for layout
OPDSCoverMenu._recalculateDimen = ListMenu._recalculateDimen
OPDSCoverMenu._updateItemsBuildUI = ListMenu._updateItemsBuildUI

-- Enable cover images
OPDSCoverMenu._do_cover_images = true
OPDSCoverMenu._do_filename_only = false
OPDSCoverMenu._do_hint_opened = false

return OPDSCoverMenu
