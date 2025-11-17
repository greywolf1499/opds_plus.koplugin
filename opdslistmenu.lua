local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")
local _ = require("gettext")

logger.warn("========================================")
logger.warn("OPDS+ opdslistmenu.lua IS LOADING")
logger.warn("========================================")

-- ============================================
-- CONFIGURATION - Can be overridden by settings
-- ============================================
local COVER_CONFIG = {
    -- Cover height as a fraction of screen height
    -- This is the DEFAULT value - actual value comes from settings
    cover_height_ratio = 0.10,  -- 10% of screen height (default)

    -- Minimum and maximum cover dimensions (in pixels)
    min_cover_height = 48,
    max_cover_height = 200,

    -- Standard book aspect ratio (portrait orientation)
    -- Most books are roughly 2:3 (width:height)
    book_aspect_ratio = 2/3,  -- 0.666... (width is 66% of height)

    -- Spacing and padding
    item_top_padding = 6,     -- Padding above each item
    item_bottom_padding = 6,  -- Padding below each item
    cover_left_margin = 6,    -- Margin to left of cover
    cover_right_margin = 8,   -- Margin between cover and text
}

-- Calculate cover dimensions based on screen and settings
local function calculateCoverDimensions(custom_ratio)
    local screen_height = Screen:getHeight()

    -- Use custom ratio if provided, otherwise use default
    local ratio = custom_ratio or COVER_CONFIG.cover_height_ratio

    -- Calculate desired cover height
    local cover_height = math.floor(screen_height * ratio)

    -- Clamp to min/max values
    cover_height = math.max(COVER_CONFIG.min_cover_height, cover_height)
    cover_height = math.min(COVER_CONFIG.max_cover_height, cover_height)

    -- Calculate width maintaining aspect ratio
    local cover_width = math.floor(cover_height * COVER_CONFIG.book_aspect_ratio)

    logger.dbg("OPDS+: Cover dimensions:", cover_width, "x", cover_height, "at", (ratio * 100) .. "%")

    return cover_width, cover_height
end

-- ============================================

-- Get the plugin directory path
local function getPluginPath()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("@(.*/)")
    return path
end

-- Load placeholder cover image from file
local placeholder_cover_bb = nil
local function getPlaceholderCover(width, height)
    if placeholder_cover_bb then
        return placeholder_cover_bb
    end

    -- Try to load placeholder.png from plugin directory
    local plugin_path = getPluginPath()
    local placeholder_path = plugin_path .. "placeholder.png"

    logger.dbg("OPDS+: Looking for placeholder at:", placeholder_path)

    -- Check if file exists
    local f = io.open(placeholder_path, "r")
    if f then
        f:close()
        logger.dbg("OPDS+: Found placeholder file, loading...")

        -- Load and render the image
        local ok, image = pcall(function()
            return RenderImage:renderImageFile(placeholder_path, width, height)
        end)

        if ok and image then
            logger.dbg("OPDS+: Successfully loaded placeholder image")
            placeholder_cover_bb = image
            return placeholder_cover_bb
        else
            logger.warn("OPDS+: Failed to load placeholder image:", tostring(image))
        end
    else
        logger.dbg("OPDS+: Placeholder file not found at:", placeholder_path)
    end

    -- Fallback: create a simple solid color placeholder
    logger.dbg("OPDS+: Creating simple fallback placeholder")
    local bb = Blitbuffer.new(width, height, Blitbuffer.TYPE_BB8)

    -- Fill with gray (value between 0-255, where 255 is white)
    local gray_value = 200  -- Light gray
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            bb:setPixel(x, y, gray_value)
        end
    end

    -- Draw a border (black = 0)
    for x = 0, width - 1 do
        bb:setPixel(x, 0, 0)
        bb:setPixel(x, height - 1, 0)
        bb:setPixel(x, 1, 0)
        bb:setPixel(x, height - 2, 0)
    end
    for y = 0, height - 1 do
        bb:setPixel(0, y, 0)
        bb:setPixel(width - 1, y, 0)
        bb:setPixel(1, y, 0)
        bb:setPixel(width - 2, y, 0)
    end

    placeholder_cover_bb = bb

    logger.dbg("OPDS+: Created fallback placeholder", width, "x", height)
    return placeholder_cover_bb
end

-- Parse title and author from combined text field
-- OPDS provides title and author separately, but sometimes they're combined in text
local function parseTitleAuthor(entry)
    local title = entry.title  -- Try dedicated title field first
    local author = entry.author  -- Try dedicated author field

    -- If we don't have a separate title, try to parse from text
    if not title or title == "" then
        if entry.text then
            -- Try to split "Title - Author" format
            local title_part, author_part = entry.text:match("^(.+)%s*%-%s*(.+)$")
            if title_part and author_part then
                title = title_part
                -- Only use parsed author if we don't already have one
                if not author or author == "" then
                    author = author_part
                end
            else
                -- Couldn't split, use text as title
                title = entry.text
            end
        end
    end

    return title or _("Unknown"), author
end

-- Format series information for display
local function formatSeriesInfo(series, series_index)
    -- Only show if we have a non-empty series name
    if not series or series == "" then
        return nil
    end

    -- If we have both series and index
    if series_index and series_index ~= "" then
        return series .. " #" .. series_index
    end

    -- Just series name
    return series
end

-- This is a simplified menu that displays OPDS catalog items with cover images
local OPDSListMenuItem = InputContainer:extend{
    entry = nil,
    cover_width = nil,
    cover_height = nil,
    width = nil,
    height = nil,
    show_parent = nil,
    menu = nil,  -- Reference to parent menu
}

function OPDSListMenuItem:init()
    logger.dbg("OPDS+: OPDSListMenuItem:init() called for:", self.entry.text or "unknown")

    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }

    -- Set up gesture events for tap and hold
    self.ges_events = {
        TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            },
        },
    }

    local cover_widget

    -- Check if we should use real cover or placeholder
    if self.entry.cover_bb then
        -- Cover has been loaded - use it!
        logger.dbg("OPDS+: Displaying LOADED cover for:", self.entry.text)
        cover_widget = ImageWidget:new{
            image = self.entry.cover_bb,
            width = self.cover_width,
            height = self.cover_height,
            alpha = true,
        }
    else
        -- Use placeholder cover
        logger.dbg("OPDS+: Using PLACEHOLDER for:", self.entry.text)
        local placeholder_bb = getPlaceholderCover(self.cover_width, self.cover_height)
        cover_widget = ImageWidget:new{
            image = placeholder_bb,
            width = self.cover_width,
            height = self.cover_height,
        }
    end

    -- Calculate spacing and dimensions
    local top_padding = COVER_CONFIG.item_top_padding
    local bottom_padding = COVER_CONFIG.item_bottom_padding
    local cover_left_margin = COVER_CONFIG.cover_left_margin
    local cover_right_margin = COVER_CONFIG.cover_right_margin
    local text_padding = Size.padding.tiny or 2

    -- Available space for text
    local text_width = self.width - self.cover_width - cover_left_margin - cover_right_margin
    local text_height = self.height - top_padding - bottom_padding

    if text_width <= 0 or text_height <= 0 then
        text_width = math.max(text_width, 100)
        text_height = math.max(text_height, 50)
    end

    -- Parse title and author from entry
    local title, author = parseTitleAuthor(self.entry)

    logger.dbg("OPDS+: Parsed - Title:", title, "Author:", author)

    -- Build text information widgets
    local text_group = VerticalGroup:new{
        align = "left",
    }

    -- Title (bold, larger)
    local title_widget = TextBoxWidget:new{
        text = title,
        face = Font:getFace("smallinfofont", 16),
        width = text_width,
        alignment = "left",
        bold = true,
    }
    table.insert(text_group, title_widget)

    -- Author (if available)
    if author and author ~= "" then
        table.insert(text_group, VerticalSpan:new{ width = text_padding })
        table.insert(text_group, TextWidget:new{
            text = author,
            face = Font:getFace("smallinfofont", 14),
            max_width = text_width,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    -- Series information (if available and valid)
    local series_text = formatSeriesInfo(self.entry.series, self.entry.series_index)
    if series_text then
        table.insert(text_group, VerticalSpan:new{ width = text_padding })
        table.insert(text_group, TextWidget:new{
            text = "📚 " .. series_text,  -- Book emoji prefix
            face = Font:getFace("smallinfofont", 13),
            max_width = text_width,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    -- Mandatory info (file format, etc.) if available
    if self.entry.mandatory then
        table.insert(text_group, VerticalSpan:new{ width = text_padding })
        table.insert(text_group, TextWidget:new{
            text = self.entry.mandatory,
            face = Font:getFace("smallinfofont", 12),
            max_width = text_width,
            fgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        })
    end

    -- Assemble the complete item with proper spacing
    -- KEY CHANGE: Use TopContainer instead of default (center) alignment for text
    local TopContainer = require("ui/widget/container/topcontainer")

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            -- Top padding
            VerticalSpan:new{ width = top_padding },
            -- Main content
            HorizontalGroup:new{
                align = "top",  -- This aligns cover and text to top
                HorizontalSpan:new{ width = cover_left_margin },
                cover_widget,
                HorizontalSpan:new{ width = cover_right_margin },
                -- Use TopContainer to align text content to top
                TopContainer:new{
                    dimen = Geom:new{
                        w = text_width,
                        h = text_height,
                    },
                    text_group,
                },
            },
            -- Bottom padding
            VerticalSpan:new{ width = bottom_padding },
        }
    }

    self.cover_widget = cover_widget
end

function OPDSListMenuItem:update()
    logger.dbg("OPDS+: OPDSListMenuItem:update() - refreshing with new cover")
    -- Re-initialize with updated entry data
    self:init()
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

-- Handle tap events - delegate to parent menu
function OPDSListMenuItem:onTapSelect(arg, ges)
    logger.dbg("OPDS+: OPDSListMenuItem:onTapSelect called for:", self.entry.text)
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
        return true
    end
    return false
end

-- Handle hold events - delegate to parent menu
function OPDSListMenuItem:onHoldSelect(arg, ges)
    logger.dbg("OPDS+: OPDSListMenuItem:onHoldSelect called for:", self.entry.text)
    if self.menu and self.menu.onMenuHold then
        self.menu:onMenuHold(self.entry)
        return true
    end
    return false
end

function OPDSListMenuItem:free()
    -- Nothing to free since we use shared placeholder
end

-- Main OPDS List Menu that extends the standard Menu
local OPDSListMenu = Menu:extend{
    cover_width = nil,   -- Will be calculated
    cover_height = nil,  -- Will be calculated
    _items_to_update = {},
}

-- Calculate and set cover dimensions
function OPDSListMenu:setCoverDimensions()
    local custom_ratio = nil

    logger.dbg("OPDS+: setCoverDimensions called")

    -- Try to get ratio from multiple possible locations
    if self._manager and self._manager.settings and self._manager.settings.cover_height_ratio then
        custom_ratio = self._manager.settings.cover_height_ratio
        logger.dbg("OPDS+: Got ratio from settings:", custom_ratio)
    elseif self.settings and self.settings.cover_height_ratio then
        custom_ratio = self.settings.cover_height_ratio
        logger.dbg("OPDS+: Got ratio from self.settings:", custom_ratio)
    else
        logger.dbg("OPDS+: No custom ratio found, using default")
    end

    self.cover_width, self.cover_height = calculateCoverDimensions(custom_ratio)
    logger.dbg("OPDS+: Set cover dimensions to", self.cover_width, "x", self.cover_height)
end

-- Override _recalculateDimen to properly calculate items per page with cover heights
function OPDSListMenu:_recalculateDimen()
    logger.dbg("OPDS+: OPDSListMenu:_recalculateDimen() called")

    -- Make sure we have cover dimensions
    if not self.cover_width or not self.cover_height then
        self:setCoverDimensions()
    end

    -- Calculate available height for menu items
    local available_height = self.inner_dimen.h

    -- Subtract height of other UI elements
    if not self.is_borderless then
        available_height = available_height - 2  -- borders
    end
    if not self.no_title and self.title_bar then
        available_height = available_height - self.title_bar.dimen.h
    end
    if self.page_info then
        available_height = available_height - self.page_info:getSize().h
    end

    -- Each item height = cover height + top padding + bottom padding + separator line
    self.item_height = self.cover_height + COVER_CONFIG.item_top_padding + COVER_CONFIG.item_bottom_padding

    -- Calculate how many items fit in available height
    self.perpage = math.floor(available_height / self.item_height)

    -- Make sure we have at least 1 item per page
    if self.perpage < 1 then
        self.perpage = 1
    end

    logger.dbg("OPDS+: Available height:", available_height)
    logger.dbg("OPDS+: Item height:", self.item_height)
    logger.dbg("OPDS+: Items per page:", self.perpage)

    -- Calculate total pages
    self.page_num = math.ceil(#self.item_table / self.perpage)

    -- Fix current page if out of range
    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    -- Set item width and dimensions
    self.item_width = self.inner_dimen.w
    self.item_dimen = Geom:new{
        x = 0,
        y = 0,
        w = self.item_width,
        h = self.item_height
    }
end

function OPDSListMenu:updateItems(select_number)
    logger.dbg("OPDS+: OPDSListMenu:updateItems() called")

    -- Cancel any previous image loading
    if self.halt_image_loading then
        logger.dbg("OPDS+: Cancelling previous image loading")
        self.halt_image_loading()
        self.halt_image_loading = nil
    end

    -- Clear old items
    self.layout = {}
    self.item_group:clear()

    local old_dimen = self.dimen and self.dimen:copy()

    self:_recalculateDimen()
    self.page_info:resetLayout()
    self.return_button:resetLayout()

    -- Build items for current page
    self._items_to_update = {}
    local idx_offset = (self.page - 1) * self.perpage

    logger.dbg("OPDS+: Building page", self.page, "with", self.perpage, "items per page")

    for i = 1, self.perpage do
        local entry_idx = idx_offset + i
        local entry = self.item_table[entry_idx]

        if entry then
            local item_width = self.content_width or Screen:getWidth()
            local item_height = self.item_height

            local item = OPDSListMenuItem:new{
                entry = entry,
                width = item_width,
                height = item_height,
                cover_width = self.cover_width,
                cover_height = self.cover_height,
                show_parent = self.show_parent,
                menu = self,  -- Pass reference to parent menu so tap events work
            }

            table.insert(self.item_group, item)

            -- Add separator line between items (but not after the last one)
            if i < self.perpage and entry_idx < #self.item_table then
                local LineWidget = require("ui/widget/linewidget")
                table.insert(self.item_group, LineWidget:new{
                    dimen = Geom:new{ w = item_width, h = Size.line.thin },
                    background = Blitbuffer.COLOR_DARK_GRAY,
                })
            end

            table.insert(self.layout, {item})  -- Wrap in table for focus manager

            -- Track items that need cover loading
            if entry.cover_url and entry.lazy_load_cover and not entry.cover_bb then
                logger.dbg("OPDS+: Queued for loading:", entry.text:sub(1, 40))
                table.insert(self._items_to_update, {
                    entry = entry,
                    widget = item,
                })
            end
        end
    end

    logger.dbg("OPDS+: Built", #self.item_group, "items,", #self._items_to_update, "need covers")

    -- Update page info
    self:updatePageInfo(select_number)

    -- Refresh display
    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)

    -- Schedule cover loading
    if #self._items_to_update > 0 then
        logger.dbg("OPDS+: Scheduling cover loading in 1 second...")

        -- Store the scheduled function so it can be cancelled if needed
        self._scheduled_cover_load = function()
            if self._loadVisibleCovers then
                self:_loadVisibleCovers()
            end
        end

        UIManager:scheduleIn(1, self._scheduled_cover_load)
    end
end

function OPDSListMenu:_loadVisibleCovers()
    logger.dbg("OPDS+: _loadVisibleCovers() starting")

    if #self._items_to_update == 0 then
        return
    end

    -- Extract unique cover URLs
    local urls = {}
    local items_by_url = {}

    for _, item_data in ipairs(self._items_to_update) do
        local url = item_data.entry.cover_url
        if url and not items_by_url[url] then
            table.insert(urls, url)
            items_by_url[url] = {item_data}
            logger.dbg("OPDS+: Will load:", url)
        elseif url then
            table.insert(items_by_url[url], item_data)
        end
    end

    if #urls == 0 then
        logger.dbg("OPDS+: No valid URLs to load!")
        return
    end

    logger.dbg("OPDS+: Loading", #urls, "unique cover URLs")

    -- Load covers asynchronously
    local ImageLoader = require("image_loader")

    -- Get credentials from the menu (these are set in OPDSBrowser)
    local username = self.root_catalog_username
    local password = self.root_catalog_password

    logger.dbg("OPDS+: Using credentials:", username and "yes" or "no")

    local batch, halt = ImageLoader:loadImages(urls, function(url, content)
        logger.dbg("OPDS+: Cover downloaded from:", url)

        local items = items_by_url[url]
        if not items then
            logger.warn("OPDS+: ERROR - No items for URL:", url)
            return
        end

        for _, item_data in ipairs(items) do
            local entry = item_data.entry
            local widget = item_data.widget

            entry.lazy_load_cover = false

            logger.dbg("OPDS+: Rendering cover for:", entry.text:sub(1, 40))

            -- Render the cover image maintaining aspect ratio
            local ok, cover_bb = pcall(function()
                return RenderImage:renderImageData(
                    content,
                    #content,
                    false,
                    self.cover_width,
                    self.cover_height
                )
            end)

            if ok and cover_bb then
                logger.dbg("OPDS+: ✓ Cover rendered successfully!")
                entry.cover_bb = cover_bb

                -- Update the widget to show the new cover
                widget.entry = entry
                widget:update()
            else
                logger.warn("OPDS+: ✗ Failed to render cover:", tostring(cover_bb))
            end
        end
    end, username, password)

    logger.dbg("OPDS+: ImageLoader started")

    self.halt_image_loading = halt
    self._items_to_update = {}
end

function OPDSListMenu:onCloseWidget()
    logger.dbg("OPDS+: OPDSListMenu:onCloseWidget()")

    -- Clean up image loading
    if self.halt_image_loading then
        self.halt_image_loading()
        self.halt_image_loading = nil
    end

    -- Free cover images
    if self.item_table then
        for _, entry in ipairs(self.item_table) do
            if entry.cover_bb then
                entry.cover_bb:free()
                entry.cover_bb = nil
            end
        end
    end

    -- Free shared placeholder
    if placeholder_cover_bb then
        placeholder_cover_bb:free()
        placeholder_cover_bb = nil
    end

    -- Call parent cleanup
    Menu.onCloseWidget(self)
end

logger.warn("OPDS+: opdslistmenu.lua LOADED SUCCESSFULLY")

return OPDSListMenu
