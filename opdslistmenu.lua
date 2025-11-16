local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
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

    logger.warn("OPDS+: Looking for placeholder at:", placeholder_path)

    -- Check if file exists
    local f = io.open(placeholder_path, "r")
    if f then
        f:close()
        logger.warn("OPDS+: Found placeholder file, loading...")

        -- Load and render the image
        local ok, image = pcall(function()
            return RenderImage:renderImageFile(placeholder_path, width, height)
        end)

        if ok and image then
            logger.warn("OPDS+: Successfully loaded placeholder image")
            placeholder_cover_bb = image
            return placeholder_cover_bb
        else
            logger.warn("OPDS+: Failed to load placeholder image:", tostring(image))
        end
    else
        logger.warn("OPDS+: Placeholder file not found at:", placeholder_path)
    end

    -- Fallback: create a simple solid color placeholder
    logger.warn("OPDS+: Creating simple fallback placeholder")
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

    logger.warn("OPDS+: Created fallback placeholder", width, "x", height)
    return placeholder_cover_bb
end

-- This is a simplified menu that displays OPDS catalog items with cover images
local OPDSListMenuItem = InputContainer:extend{
    entry = nil,
    cover_width = Screen:scaleBySize(48),
    cover_height = Screen:scaleBySize(64),
    width = nil,
    height = nil,
    show_parent = nil,
}

function OPDSListMenuItem:init()
    logger.dbg("OPDS+: OPDSListMenuItem:init() called for:", self.entry.text or "unknown")

    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
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

    -- Calculate text area dimensions
    local margin = Size.margin.default or 4
    local padding = Size.padding.tiny or 2

    local text_width = self.width - self.cover_width - (margin * 3)
    local text_height = self.height - (margin * 2)

    if text_width <= 0 or text_height <= 0 then
        text_width = math.max(text_width, 100)
        text_height = math.max(text_height, 50)
    end

    -- Add "[OPDS+]" prefix to make it obvious this is our custom widget
    local display_text = "[OPDS+] " .. (self.entry.text or self.entry.title or _("Unknown"))

    local title_widget = TextBoxWidget:new{
        text = display_text,
        face = Font:getFace("smallinfofont", 16),
        width = text_width,
        alignment = "left",
        bold = true,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        title_widget,
    }

    -- Add author if available
    if self.entry.author then
        table.insert(text_group, VerticalSpan:new{ width = padding })
        table.insert(text_group, TextWidget:new{
            text = self.entry.author,
            face = Font:getFace("smallinfofont", 14),
            max_width = text_width,
        })
    end

    -- Add mandatory info if available
    if self.entry.mandatory then
        table.insert(text_group, VerticalSpan:new{ width = padding })
        table.insert(text_group, TextWidget:new{
            text = self.entry.mandatory,
            face = Font:getFace("smallinfofont", 13),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_width,
        })
    end

    -- Add debug info showing cover status
    local debug_text = "Cover: "
    if self.entry.cover_bb then
        debug_text = debug_text .. "✓ LOADED"
    elseif self.entry.cover_url then
        debug_text = debug_text .. "Loading..."
    else
        debug_text = debug_text .. "NONE"
    end

    table.insert(text_group, VerticalSpan:new{ width = padding })
    table.insert(text_group, TextWidget:new{
        text = debug_text,
        face = Font:getFace("smallinfofont", 11),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = text_width,
    })

    -- Assemble the complete item
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        bordersize = Size.border.thin or 1,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = margin },
            cover_widget,
            HorizontalSpan:new{ width = margin },
            LeftContainer:new{
                dimen = Geom:new{
                    w = text_width,
                    h = text_height,
                },
                text_group,
            },
        }
    }

    self.cover_widget = cover_widget
end

function OPDSListMenuItem:update()
    logger.warn("OPDS+: OPDSListMenuItem:update() - refreshing with new cover")
    -- Re-initialize with updated entry data
    self:init()
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

function OPDSListMenuItem:onTap()
    return false
end

function OPDSListMenuItem:free()
    -- Nothing to free since we use shared placeholder
end

-- Main OPDS List Menu that extends the standard Menu
local OPDSListMenu = Menu:extend{
    cover_width = Screen:scaleBySize(48),
    cover_height = Screen:scaleBySize(64),
    _items_to_update = {},
}

function OPDSListMenu:updateItems(select_number)
    logger.warn("========================================")
    logger.warn("OPDS+: OPDSListMenu:updateItems() CALLED")
    logger.warn("========================================")

    -- Cancel any previous image loading
    if self.halt_image_loading then
        logger.warn("OPDS+: Cancelling previous image loading")
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

    logger.warn("OPDS+: Building page", self.page, "with", self.perpage, "items per page")

    for i = 1, self.perpage do
        local entry_idx = idx_offset + i
        local entry = self.item_table[entry_idx]

        if entry then
            local item_width = self.content_width or Screen:getWidth()
            local item_height = self.cover_height + (Size.margin.default or 4) * 2

            local item = OPDSListMenuItem:new{
                entry = entry,
                width = item_width,
                height = item_height,
                cover_width = self.cover_width,
                cover_height = self.cover_height,
                show_parent = self.show_parent,
            }

            -- Set up tap handler
            item.onTap = function()
                logger.warn("OPDS+: Item tapped:", entry.text)
                self:onMenuSelect(entry)
                return true
            end

            table.insert(self.item_group, item)
            table.insert(self.layout, item.dimen)

            -- Track items that need cover loading
            if entry.cover_url and entry.lazy_load_cover and not entry.cover_bb then
                logger.warn("OPDS+: Queued for loading:", entry.text:sub(1, 40))
                table.insert(self._items_to_update, {
                    entry = entry,
                    widget = item,
                })
            end
        end
    end

    logger.warn("OPDS+: Built", #self.item_group, "items,", #self._items_to_update, "need covers")

    -- Update page info
    self:updatePageInfo(select_number)

    -- Refresh display
    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)

    -- Schedule cover loading
    if #self._items_to_update > 0 then
        logger.warn("OPDS+: Scheduling cover loading in 1 second...")
        UIManager:scheduleIn(1, function()
            self:_loadVisibleCovers()
        end)
    end
end

function OPDSListMenu:_loadVisibleCovers()
    logger.warn("========================================")
    logger.warn("OPDS+: _loadVisibleCovers() STARTING")
    logger.warn("OPDS+: Items to load:", #self._items_to_update)
    logger.warn("========================================")

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
            logger.warn("OPDS+: Will load:", url)
        elseif url then
            table.insert(items_by_url[url], item_data)
        end
    end

    if #urls == 0 then
        logger.warn("OPDS+: No valid URLs to load!")
        return
    end

    logger.warn("OPDS+: Loading", #urls, "unique cover URLs")

    -- Load covers asynchronously
    local ImageLoader = require("image_loader")

    local batch, halt = ImageLoader:loadImages(urls, function(url, content)
        logger.warn("========================================")
        logger.warn("OPDS+: Cover downloaded from:", url)
        logger.warn("OPDS+: Size:", #content, "bytes")
        logger.warn("========================================")

        local items = items_by_url[url]
        if not items then
            logger.warn("OPDS+: ERROR - No items for URL:", url)
            return
        end

        for _, item_data in ipairs(items) do
            local entry = item_data.entry
            local widget = item_data.widget

            entry.lazy_load_cover = false

            logger.warn("OPDS+: Rendering cover for:", entry.text:sub(1, 40))

            -- Render the cover image
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
                logger.warn("OPDS+: ✓ Cover rendered successfully!")
                entry.cover_bb = cover_bb

                -- Update the widget to show the new cover
                widget.entry = entry
                widget:update()
            else
                logger.warn("OPDS+: ✗ Failed to render cover:", tostring(cover_bb))
            end
        end
    end)

    logger.warn("OPDS+: ImageLoader started, batch:", batch ~= nil, "halt:", halt ~= nil)

    self.halt_image_loading = halt
    self._items_to_update = {}
end

function OPDSListMenu:onCloseWidget()
    logger.warn("OPDS+: OPDSListMenu:onCloseWidget()")

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
