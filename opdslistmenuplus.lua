local UIUtils = require("ui.utils")
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
local Menu = require("ui/widget/menu")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Screen = Device.screen
local logger = require("logger")
local _ = require("gettext")

-- ============================================
-- CONFIGURATION - Can be overridden by settings
-- ============================================
local COVER_CONFIG = {
    -- These will be used to calculate optimal cover sizes
    size_presets = {
        ["Compact"] = { target_items = 8, description = "More books per page" },
        ["Regular"] = { target_items = 6, description = "Balanced view" },
        ["Large"] = { target_items = 4, description = "Larger covers" },
        ["Extra Large"] = { target_items = 3, description = "Maximum detail" },
    },

    -- Minimum and maximum cover dimensions (in pixels)
    min_cover_height = 48,
    max_cover_height = 300,

    -- Standard book aspect ratio (portrait orientation)
    book_aspect_ratio = 2 / 3,

    -- Spacing and padding
    item_top_padding = 6,
    item_bottom_padding = 6,
    cover_left_margin = 6,
    cover_right_margin = 8,
}

-- Calculate optimal cover size based on available space and target items
local function calculateOptimalCoverSize(available_height, target_items, min_height, max_height)
    -- Account for padding in each item
    local padding_per_item = COVER_CONFIG.item_top_padding + COVER_CONFIG.item_bottom_padding

    -- Calculate ideal cover height to fit target items
    local ideal_height = math.floor((available_height - (padding_per_item * target_items)) / target_items)

    -- Clamp to min/max
    local cover_height = math.max(min_height, math.min(max_height, ideal_height))

    -- Calculate how many items actually fit with this size
    local item_height = cover_height + padding_per_item
    local actual_items = math.floor(available_height / item_height)

    -- If we can fit more items by making covers slightly smaller, do it
    if actual_items < target_items then
        -- Try to squeeze one more item in
        local adjusted_height = math.floor((available_height - (padding_per_item * (actual_items + 1))) /
            (actual_items + 1))
        if adjusted_height >= min_height then
            cover_height = adjusted_height
            actual_items = actual_items + 1
        end
    end

    local cover_width = math.floor(cover_height * COVER_CONFIG.book_aspect_ratio)

    return cover_width, cover_height, actual_items
end

-- ============================================

-- This is a simplified menu that displays OPDS catalog items with cover images
local OPDSListMenuItem = InputContainer:extend {
    entry = nil,
    cover_width = nil,
    cover_height = nil,
    width = nil,
    height = nil,
    show_parent = nil,
    menu = nil,          -- Reference to parent menu
    font_settings = nil, -- Table with all font settings
}

function OPDSListMenuItem:init()
    self.dimen = Geom:new {
        w = self.width,
        h = self.height,
    }

    -- Set up gesture events for tap and hold
    self.ges_events = {
        TapSelect = {
            GestureRange:new {
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new {
                ges = "hold",
                range = self.dimen,
            },
        },
    }

    local inner_cover_widget

    -- Check if we should use real cover or placeholder
    if self.entry.cover_bb then
        inner_cover_widget = ImageWidget:new {
            image = self.entry.cover_bb,
            width = self.cover_width,
            height = self.cover_height,
            alpha = true,
        }
    elseif self.entry.cover_url and self.entry.lazy_load_cover then
        inner_cover_widget = UIUtils.createPlaceholderCover(self.cover_width, self.cover_height, "loading")
    elseif self.entry.cover_url and self.entry.cover_failed then
        inner_cover_widget = UIUtils.createPlaceholderCover(self.cover_width, self.cover_height, "error")
    else
        inner_cover_widget = UIUtils.createPlaceholderCover(self.cover_width, self.cover_height, "no_cover")
    end

    -- Wrap in a fixed container to prevent layout shifting during updates
    local cover_widget = CenterContainer:new {
        dimen = Geom:new {
            w = self.cover_width,
            h = self.cover_height,
        },
        inner_cover_widget
    }

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
    local title, author = UIUtils.parseTitleAuthor(self.entry)

    -- Get font settings from font_settings table
    local title_font = (self.font_settings and self.font_settings.title_font) or "smallinfofont"
    local title_size = (self.font_settings and self.font_settings.title_size) or 16
    local title_bold = (self.font_settings and self.font_settings.title_bold)
    if title_bold == nil then title_bold = true end

    local info_font = title_font -- Default to same as title
    if self.font_settings and not self.font_settings.use_same_font then
        info_font = self.font_settings.info_font or "smallinfofont"
    end
    local info_size = (self.font_settings and self.font_settings.info_size) or 14
    local info_bold = (self.font_settings and self.font_settings.info_bold) or false
    local info_color_name = (self.font_settings and self.font_settings.info_color) or "dark_gray"

    -- Convert color name to Blitbuffer color
    local info_color = Blitbuffer.COLOR_DARK_GRAY
    if info_color_name == "black" then
        info_color = Blitbuffer.COLOR_BLACK
    end

    -- Build text information widgets
    local text_group = VerticalGroup:new {
        align = "left",
    }

    -- Title
    local title_face = Font:getFace(title_font, title_size)
    local title_text = UIUtils.truncateText(title, title_face, text_width * 2)

    local title_widget = TextBoxWidget:new {
        text = title_text,
        face = Font:getFace(title_font, title_size),
        width = text_width,
        alignment = "left",
        bold = title_bold,
    }
    table.insert(text_group, title_widget)

    -- Author (if available)
    if author and author ~= "" then
        table.insert(text_group, VerticalSpan:new { width = text_padding })

        local author_face = Font:getFace(info_font, info_size)
        local author_text = UIUtils.truncateText(author, author_face, text_width)

        table.insert(text_group, TextWidget:new {
            text = author_text,
            face = author_face,
            max_width = text_width,
            fgcolor = info_color,
            bold = info_bold,
        })
    end

    -- Series information (if available and valid)
    local series_text = UIUtils.formatSeriesInfo(self.entry.series, self.entry.series_index)
    if series_text then
        table.insert(text_group, VerticalSpan:new { width = text_padding })

        local series_face = Font:getFace(info_font, info_size - 1)
        local icon = "📚 "
        local full_series = icon .. series_text
        local truncated_series = UIUtils.truncateText(full_series, series_face, text_width)

        table.insert(text_group, TextWidget:new {
            text = truncated_series,
            face = series_face,
            max_width = text_width,
            fgcolor = info_color,
            bold = info_bold,
        })
    end

    -- Mandatory info (file format, etc.) if available
    if self.entry.mandatory then
        table.insert(text_group, VerticalSpan:new { width = text_padding })
        table.insert(text_group, TextWidget:new {
            text = self.entry.mandatory,
            face = Font:getFace(info_font, info_size - 2),
            max_width = text_width,
            fgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
            bold = false,
        })
    end

    -- Assemble the complete item with proper spacing
    local TopContainer = require("ui/widget/container/topcontainer")

    self[1] = FrameContainer:new {
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new {
            align = "left",
            VerticalSpan:new { width = top_padding },
            HorizontalGroup:new {
                align = "top",
                HorizontalSpan:new { width = cover_left_margin },
                cover_widget,
                HorizontalSpan:new { width = cover_right_margin },
                TopContainer:new {
                    dimen = Geom:new {
                        w = text_width,
                        h = text_height,
                    },
                    text_group,
                },
            },
            VerticalSpan:new { width = bottom_padding },
        }
    }

    self.cover_widget = cover_widget
end

function OPDSListMenuItem:update()
    -- Re-initialize with updated entry data
    self:init()
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

-- Handle tap events - delegate to parent menu
function OPDSListMenuItem:onTapSelect(arg, ges)
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
        return true
    end
    return false
end

-- Handle hold events - delegate to parent menu
function OPDSListMenuItem:onHoldSelect(arg, ges)
    if self.menu and self.menu.onMenuHold then
        self.menu:onMenuHold(self.entry)
        return true
    end
    return false
end

function OPDSListMenuItem:free()
    -- Nothing to free for dynamic placeholders
end

-- Main OPDS List Menu that extends the standard Menu
local OPDSListMenu = Menu:extend {
    cover_width = nil,
    cover_height = nil,
    _items_to_update = {},
}

function OPDSListMenu:_debugLog(...)
    if self._manager and self._manager.settings and self._manager.settings.debug_mode then
        logger.dbg("OPDS+ List:", ...)
    end
end

-- Calculate and set cover dimensions based on available space
function OPDSListMenu:setCoverDimensions()
    -- Get the preset/target from settings
    local preset_name = "Regular" -- Default
    if self._manager and self._manager.settings and self._manager.settings.cover_size_preset then
        preset_name = self._manager.settings.cover_size_preset
    end

    -- For custom sizes, we need a different approach
    if preset_name == "Custom" then
        -- Use the stored ratio for custom
        local custom_ratio = 0.10 -- Default fallback
        if self._manager and self._manager.settings and self._manager.settings.cover_height_ratio then
            custom_ratio = self._manager.settings.cover_height_ratio
        end

        local screen_height = Screen:getHeight()
        self.cover_height = math.floor(screen_height * custom_ratio)
        self.cover_height = math.max(COVER_CONFIG.min_cover_height, self.cover_height)
        self.cover_height = math.min(COVER_CONFIG.max_cover_height, self.cover_height)
        self.cover_width = math.floor(self.cover_height * COVER_CONFIG.book_aspect_ratio)

        self:_debugLog("Custom cover size:", self.cover_width, "x", self.cover_height)
        return
    end

    -- Get preset configuration
    local preset = COVER_CONFIG.size_presets[preset_name] or COVER_CONFIG.size_presets["Regular"]

    -- We need to estimate available height
    -- This is approximate since we're called before the menu is fully laid out
    local screen_height = Screen:getHeight()
    local estimated_ui_overhead = 100 -- Title bar + page info + margins
    local available_height = screen_height - estimated_ui_overhead

    -- Calculate optimal size
    self.cover_width, self.cover_height = calculateOptimalCoverSize(
        available_height,
        preset.target_items,
        COVER_CONFIG.min_cover_height,
        COVER_CONFIG.max_cover_height
    )

    self:_debugLog("Preset:", preset_name, "Target items:", preset.target_items, "Cover size:", self.cover_width, "x",
        self.cover_height)
end

-- Override _recalculateDimen with improved space utilization
function OPDSListMenu:_recalculateDimen()
    -- Make sure we have cover dimensions
    if not self.cover_width or not self.cover_height then
        self:setCoverDimensions()
    end

    -- Calculate ACTUAL available height for menu items
    local available_height = self.inner_dimen.h

    -- Subtract height of other UI elements
    if not self.is_borderless then
        available_height = available_height - 2 -- borders
    end
    if not self.no_title and self.title_bar then
        available_height = available_height - self.title_bar.dimen.h
    end
    if self.page_info then
        available_height = available_height - self.page_info:getSize().h
    end

    -- Each item height
    self.item_height = self.cover_height + COVER_CONFIG.item_top_padding + COVER_CONFIG.item_bottom_padding

    -- Calculate how many items fit
    self.perpage = math.floor(available_height / self.item_height)

    -- Make sure we have at least 1 item per page
    if self.perpage < 1 then
        self.perpage = 1
    end

    -- Check if we have significant whitespace and can fit more items by shrinking slightly
    local used_height = self.perpage * self.item_height
    local remaining_space = available_height - used_height

    if remaining_space > self.item_height * 0.7 then
        -- We have space for another item if we shrink covers slightly
        local new_items = self.perpage + 1
        local new_item_height = math.floor(available_height / new_items)
        local new_cover_height = new_item_height - COVER_CONFIG.item_top_padding - COVER_CONFIG.item_bottom_padding

        if new_cover_height >= COVER_CONFIG.min_cover_height then
            self.cover_height = new_cover_height
            self.cover_width = math.floor(self.cover_height * COVER_CONFIG.book_aspect_ratio)
            self.item_height = new_item_height
            self.perpage = new_items

            self:_debugLog("Optimized: Adjusted cover to fit", self.perpage, "items (was wasting",
                math.floor(remaining_space), "px)")
        end
    end

    self:_debugLog("Final layout - Items per page:", self.perpage, "Whitespace:",
        math.floor(available_height - (self.perpage * self.item_height)), "px")

    -- Calculate total pages
    self.page_num = math.ceil(#self.item_table / self.perpage)

    -- Fix current page if out of range
    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    -- Set item width and dimensions
    self.item_width = self.inner_dimen.w
    self.item_dimen = Geom:new {
        x = 0,
        y = 0,
        w = self.item_width,
        h = self.item_height
    }
end

function OPDSListMenu:updateItems(select_number)
    -- Cancel any previous image loading
    if self.halt_image_loading then
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

    -- Get font settings
    local font_settings = {}
    if self._manager and self._manager.settings then
        font_settings = {
            title_font = self._manager.settings.title_font or "smallinfofont",
            title_size = self._manager.settings.title_size or 16,
            title_bold = self._manager.settings.title_bold,
            info_font = self._manager.settings.info_font or "smallinfofont",
            info_size = self._manager.settings.info_size or 14,
            info_bold = self._manager.settings.info_bold or false,
            info_color = self._manager.settings.info_color or "dark_gray",
            use_same_font = self._manager.settings.use_same_font,
        }
    elseif self.settings then
        font_settings = {
            title_font = self.settings.title_font or "smallinfofont",
            title_size = self.settings.title_size or 16,
            title_bold = self.settings.title_bold,
            info_font = self.settings.info_font or "smallinfofont",
            info_size = self.settings.info_size or 14,
            info_bold = self.settings.info_bold or false,
            info_color = self.settings.info_color or "dark_gray",
            use_same_font = self.settings.use_same_font,
        }
    end

    -- Handle defaults
    if font_settings.title_bold == nil then
        font_settings.title_bold = true
    end
    if font_settings.use_same_font == nil then
        font_settings.use_same_font = true
    end

    -- Build items for current page
    self._items_to_update = {}
    local idx_offset = (self.page - 1) * self.perpage

    for i = 1, self.perpage do
        local entry_idx = idx_offset + i
        local entry = self.item_table[entry_idx]

        if entry then
            local item_width = self.content_width or Screen:getWidth()
            local item_height = self.item_height

            local item = OPDSListMenuItem:new {
                entry = entry,
                width = item_width,
                height = item_height,
                cover_width = self.cover_width,
                cover_height = self.cover_height,
                show_parent = self.show_parent,
                menu = self,
                font_settings = font_settings,
            }

            table.insert(self.item_group, item)

            -- Add separator line between items (but not after the last one)
            if i < self.perpage and entry_idx < #self.item_table then
                local LineWidget = require("ui/widget/linewidget")
                table.insert(self.item_group, LineWidget:new {
                    dimen = Geom:new { w = item_width, h = Size.line.thin },
                    background = Blitbuffer.COLOR_DARK_GRAY,
                })
            end

            table.insert(self.layout, { item }) -- Wrap in table for focus manager

            -- Track items that need cover loading
            if entry.cover_url and entry.lazy_load_cover and not entry.cover_bb then
                table.insert(self._items_to_update, {
                    entry = entry,
                    widget = item,
                })
            end
        end
    end

    -- Update page info
    self:updatePageInfo(select_number)

    -- Refresh display
    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)

    -- Update page info with custom text
    if self.page_info then
        local custom_text = "≡ " .. self.page .. "/" .. self.page_num .. " (" .. self.perpage .. " items)"

        -- Find and replace the text widget
        for i = 1, 10 do
            if self.page_info[i] and type(self.page_info[i]) == "table" and self.page_info[i].text then
                -- Get the original widget's properties (with fallbacks)
                local old_widget = self.page_info[i]
                local face = old_widget.face or Font:getFace("smallinfofont")
                local fgcolor = old_widget.fgcolor or Blitbuffer.COLOR_BLACK

                -- Free the old widget
                if old_widget.free then
                    old_widget:free()
                end

                -- Create new TextWidget with updated text
                self.page_info[i] = TextWidget:new {
                    text = custom_text,
                    face = face,
                    fgcolor = fgcolor,
                }

                -- Mark dirty for full refresh
                UIManager:setDirty(self.show_parent, "ui")

                break
            end
        end
    end

    -- Schedule cover loading
    if #self._items_to_update > 0 then
        self:_debugLog("Scheduling cover loading for", #self._items_to_update, "items")

        -- Store the scheduled function so it can be cancelled if needed
        self._scheduled_cover_load = function()
            if self._loadVisibleCovers then
                self:_loadVisibleCovers()
            end
        end

        UIManager:scheduleIn(1, self._scheduled_cover_load)
    end
end

-- Override page info to show mode indicator
function OPDSListMenu:getPageInfo()
    return "≡ " .. self.page .. " / " .. self.page_num .. " (" .. self.perpage .. " items)"
end

function OPDSListMenu:_loadVisibleCovers()
    if #self._items_to_update == 0 then
        return
    end

    -- Extract unique cover URLs
    local urls = {}
    local items_by_url = {}

    for i, item_data in ipairs(self._items_to_update) do
        local url = item_data.entry.cover_url
        if url and not items_by_url[url] then
            table.insert(urls, url)
            items_by_url[url] = { item_data }
        elseif url then
            table.insert(items_by_url[url], item_data)
        end
    end

    if #urls == 0 then
        return
    end

    self:_debugLog("Loading", #urls, "unique cover URLs")

    -- Load covers asynchronously
    local ImageLoader = require("image_loader")

    -- Get credentials from the menu (these are set in OPDSBrowser)
    local username = self.root_catalog_username
    local password = self.root_catalog_password

    -- Get debug mode setting
    local debug_mode = self._manager and self._manager.settings and self._manager.settings.debug_mode

    local _, halt = ImageLoader:loadImages(urls, function(url, content)
        local items = items_by_url[url]
        if not items then
            logger.warn("OPDS+: ERROR - No items for URL:", url)
            return
        end

        for j, item_data in ipairs(items) do
            local entry = item_data.entry
            local widget = item_data.widget

            entry.lazy_load_cover = false

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
                entry.cover_bb = cover_bb
                entry.cover_failed = false

                -- Update the widget to show the new cover
                widget.entry = entry
                widget:update()
            else
                logger.warn("OPDS+: Failed to render cover:", tostring(cover_bb))
                entry.cover_failed = true

                -- Update the widget to show error placeholder
                widget.entry = entry
                widget:update()
            end
        end
    end, username, password, debug_mode)

    self.halt_image_loading = halt
    self._items_to_update = {}
end

function OPDSListMenu:onCloseWidget()
    -- Clean up image loading
    if self.halt_image_loading then
        self.halt_image_loading()
        self.halt_image_loading = nil
    end

    -- Free cover images (but no need to free dynamic placeholders)
    if self.item_table then
        for k, entry in ipairs(self.item_table) do
            if entry.cover_bb then
                entry.cover_bb:free()
                entry.cover_bb = nil
            end
        end
    end

    -- Call parent cleanup
    Menu.onCloseWidget(self)
end

return OPDSListMenu
