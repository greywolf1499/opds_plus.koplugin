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

logger.warn("========================================")
logger.warn("OPDS+ opdsgridmenu.lua IS LOADING")
logger.warn("========================================")

-- ============================================
-- GRID CONFIGURATION
-- ============================================
local GRID_CONFIG = {
    -- Grid layout
    default_columns = 3,
    min_columns = 2,
    max_columns = 4,

    -- Cover dimensions limits (will be calculated based on columns)
    min_cover_height = 100,
    max_cover_height = 400,

    -- Standard book aspect ratio
    book_aspect_ratio = 2/3,

    -- Spacing (reduced for better space utilization)
    cell_padding = 6,        -- Padding inside each cell
    cell_margin = 10,        -- Gap between cells (reduced from 12)
    row_spacing = 12,        -- Space between rows (reduced from 16)
    top_margin = 6,          -- Top margin of grid (reduced from 8)
    bottom_margin = 6,       -- Bottom margin of grid (reduced from 8)
    side_margin = 10,        -- Left/right margins (reduced from 12)

    -- Text
    title_lines_max = 2,     -- Maximum lines for title
    show_author = true,      -- Show author below title
}

-- Calculate cover dimensions for grid view
local function calculateGridCoverDimensions(custom_ratio)
    local screen_height = Screen:getHeight()

    local ratio = custom_ratio or GRID_CONFIG.cover_height_ratio
    local cover_height = math.floor(screen_height * ratio)

    -- Clamp to min/max
    cover_height = math.max(GRID_CONFIG.min_cover_height, cover_height)
    cover_height = math.min(GRID_CONFIG.max_cover_height, cover_height)

    local cover_width = math.floor(cover_height * GRID_CONFIG.book_aspect_ratio)

    logger.dbg("OPDS+ Grid: Cover dimensions:", cover_width, "x", cover_height)

    return cover_width, cover_height
end

-- Create placeholder cover for grid
local function createGridPlaceholder(width, height, status)
    local placeholder_bg_color = Blitbuffer.COLOR_LIGHT_GRAY
    local text_color = Blitbuffer.COLOR_DARK_GRAY

    local display_text = ""
    local icon = ""

    if status == "loading" then
        icon = "⏳"
        display_text = _("Loading...")
    elseif status == "error" then
        icon = "⚠"
        display_text = _("Failed")
    else
        icon = "📖"
        display_text = _("No Cover")
    end

    local font_size = math.floor(height / 10)
    if font_size < 10 then font_size = 10 end
    if font_size > 14 then font_size = 14 end

    local icon_widget = TextWidget:new{
        text = icon,
        face = Font:getFace("infofont", font_size * 2),
        fgcolor = text_color,
    }

    local text_widget = TextWidget:new{
        text = display_text,
        face = Font:getFace("smallinfofont", font_size),
        fgcolor = text_color,
    }

    local placeholder = FrameContainer:new{
        width = width,
        height = height,
        padding = 0,
        margin = 0,
        bordersize = Size.border.default or 2,
        background = placeholder_bg_color,
        CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = height,
            },
            VerticalGroup:new{
                align = "center",
                icon_widget,
                VerticalSpan:new{ width = font_size / 2 },
                text_widget,
            },
        },
    }

    return placeholder
end

-- Parse title and author (reuse from list view logic)
local function parseTitleAuthor(entry)
    local title = entry.title
    local author = entry.author

    if not title or title == "" then
        if entry.text then
            local title_part, author_part = entry.text:match("^(.+)%s*%-%s*(.+)$")
            if title_part and author_part then
                title = title_part
                if not author or author == "" then
                    author = author_part
                end
            else
                title = entry.text
            end
        end
    end

    return title or _("Unknown"), author
end

-- ============================================
-- GRID CELL WIDGET
-- ============================================
local OPDSGridCell = InputContainer:extend{
    entry = nil,
    cover_width = nil,
    cover_height = nil,
    cell_width = nil,
    cell_height = nil,
    show_parent = nil,
    menu = nil,
    font_settings = nil,
}

function OPDSGridCell:init()
    logger.dbg("OPDS+ Grid: GridCell:init() for:", self.entry.text or "unknown")

    self.dimen = Geom:new{
        w = self.cell_width,
        h = self.cell_height,
    }

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

    -- Create cover widget
    local cover_widget
    if self.entry.cover_bb then
        logger.dbg("OPDS+ Grid: Using loaded cover")
        cover_widget = ImageWidget:new{
            image = self.entry.cover_bb,
            width = self.cover_width,
            height = self.cover_height,
            alpha = true,
        }
    elseif self.entry.cover_url and self.entry.lazy_load_cover then
        logger.dbg("OPDS+ Grid: Showing loading placeholder")
        cover_widget = createGridPlaceholder(self.cover_width, self.cover_height, "loading")
    elseif self.entry.cover_url and self.entry.cover_failed then
        logger.dbg("OPDS+ Grid: Showing error placeholder")
        cover_widget = createGridPlaceholder(self.cover_width, self.cover_height, "error")
    else
        logger.dbg("OPDS+ Grid: Showing no cover placeholder")
        cover_widget = createGridPlaceholder(self.cover_width, self.cover_height, "no_cover")
    end

    -- Parse title and author
    local title, author = parseTitleAuthor(self.entry)

        -- Get font settings
    local title_font = (self.font_settings and self.font_settings.title_font) or "smallinfofont"
    local title_size = (self.font_settings and self.font_settings.title_size) or 14
    local title_bold = (self.font_settings and self.font_settings.title_bold)
    if title_bold == nil then title_bold = true end

    local info_font = title_font
    if self.font_settings and not self.font_settings.use_same_font then
        info_font = self.font_settings.info_font or "smallinfofont"
    end
    local info_size = (self.font_settings and self.font_settings.info_size) or 12
    local info_color_name = (self.font_settings and self.font_settings.info_color) or "dark_gray"

    local info_color = Blitbuffer.COLOR_DARK_GRAY
    if info_color_name == "black" then
        info_color = Blitbuffer.COLOR_BLACK
    end

    -- Calculate text area width (should match cover width for alignment)
    local text_width = self.cover_width

    -- Calculate FIXED heights for uniform alignment across all cells
    -- Title: strictly 2 lines maximum
    local title_line_height = math.ceil(title_size * 1.3)
    local title_fixed_height = title_line_height * 2

    -- Author: strictly 1 line
    local author_line_height = math.ceil(info_size * 1.2)
    local author_fixed_height = GRID_CONFIG.show_author and author_line_height or 0

    -- Gaps
    local title_author_gap = GRID_CONFIG.show_author and 4 or 0
    local cover_text_gap = 6

    -- Total fixed text area height
    local text_area_height = title_fixed_height + title_author_gap + author_fixed_height + cover_text_gap

    -- Ensure it doesn't exceed what was calculated in setGridDimensions
    local max_text_area = self.cell_height - self.cover_height - (GRID_CONFIG.cell_padding * 2)
    text_area_height = math.min(text_area_height, max_text_area)

    -- Build text group with FIXED heights for each element
    local text_group = VerticalGroup:new{
        align = "center",
    }

    -- Title - TextBoxWidget with fixed height and truncation
    local title_widget = TextBoxWidget:new{
        text = title,
        face = Font:getFace(title_font, title_size),
        bold = title_bold,
        width = text_width,
        height = title_fixed_height,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
        line_height = 0,  -- Use default line height
        -- This will automatically truncate with "..." if text is too long
    }

    -- Wrap title in fixed container to ensure consistent height even if text is short
    local title_container = FrameContainer:new{
        width = text_width,
        height = title_fixed_height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{
                w = text_width,
                h = title_fixed_height,
            },
            title_widget,
        },
    }
    table.insert(text_group, title_container)

    -- Author - FIXED height, single line with truncation
    if GRID_CONFIG.show_author then
        table.insert(text_group, VerticalSpan:new{ width = title_author_gap })

        local author_widget
        if author and author ~= "" then
            -- Single line author with truncation
            author_widget = TextWidget:new{
                text = author,
                face = Font:getFace(info_font, info_size),
                max_width = text_width,
                fgcolor = info_color,
            }
        else
            -- Empty placeholder to maintain spacing
            author_widget = VerticalSpan:new{ width = 0 }
        end

        -- Wrap in fixed-height container
        local author_container = FrameContainer:new{
            width = text_width,
            height = author_fixed_height,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{
                    w = text_width,
                    h = author_fixed_height,
                },
                author_widget,
            },
        }
        table.insert(text_group, author_container)
    end

    -- Wrap entire text group in fixed-height container
    local TopContainer = require("ui/widget/container/topcontainer")
    local text_container = TopContainer:new{
        dimen = Geom:new{
            w = text_width,
            h = text_area_height,
        },
        text_group,
    }

    -- Assemble cell: cover at top, then text
    local CenterContainer = require("ui/widget/container/centercontainer")

    self[1] = FrameContainer:new{
        width = self.cell_width,
        height = self.cell_height,
        padding = GRID_CONFIG.cell_padding,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{
                w = self.cell_width - (GRID_CONFIG.cell_padding * 2),
                h = self.cell_height - (GRID_CONFIG.cell_padding * 2),
            },
            VerticalGroup:new{
                align = "center",
                cover_widget,
                VerticalSpan:new{ width = cover_text_gap },
                text_container,
            },
        },
    }

    self.cover_widget = cover_widget
end

function OPDSGridCell:update()
    logger.dbg("OPDS+ Grid: GridCell:update() - refreshing with new cover")
    self:init()
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

function OPDSGridCell:onTapSelect(arg, ges)
    logger.dbg("OPDS+ Grid: GridCell tap:", self.entry.text)
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
        return true
    end
    return false
end

function OPDSGridCell:onHoldSelect(arg, ges)
    logger.dbg("OPDS+ Grid: GridCell hold:", self.entry.text)
    if self.menu and self.menu.onMenuHold then
        self.menu:onMenuHold(self.entry)
        return true
    end
    return false
end

function OPDSGridCell:free()
    -- Nothing to free
end

-- ============================================
-- GRID MENU
-- ============================================
local OPDSGridMenu = Menu:extend{
    cover_width = nil,
    cover_height = nil,
    cell_width = nil,
    cell_height = nil,
    columns = nil,
    _items_to_update = {},
}

function OPDSGridMenu:setGridDimensions()
    logger.dbg("OPDS+ Grid: setGridDimensions called")

    -- Get columns setting
    self.columns = GRID_CONFIG.default_columns
    if self._manager and self._manager.settings and self._manager.settings.grid_columns then
        self.columns = self._manager.settings.grid_columns
        logger.dbg("OPDS+ Grid: Using custom columns:", self.columns)
    end

    -- Get screen dimensions
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    -- Calculate available dimensions
    local available_width = screen_width - (GRID_CONFIG.side_margin * 2)

    -- Estimate available height more accurately
    -- Title bar: ~77px, Page info: ~44px, Margins: 12px = ~133px total
    -- Add 7px buffer for safety
    local estimated_ui_overhead = 140
    local estimated_available_height = screen_height - estimated_ui_overhead

    -- TARGET: At least 2 rows for 3 columns on typical e-reader screens
    local min_rows_target = 2

    -- Account for row spacing in target calculation
    -- For 2 rows: we need 1 gap of row_spacing between them
    local row_spacing_total = (min_rows_target - 1) * GRID_CONFIG.row_spacing

    -- Max row height = (available - spacing) / rows
    local max_row_height = math.floor((estimated_available_height - row_spacing_total) / min_rows_target)

    logger.dbg("OPDS+ Grid: Screen:", screen_width, "x", screen_height)
    logger.dbg("OPDS+ Grid: Estimated available height:", estimated_available_height)
    logger.dbg("OPDS+ Grid: Target rows:", min_rows_target, "with spacing:", row_spacing_total)
    logger.dbg("OPDS+ Grid: Max row height (cell only):", max_row_height)

    -- Calculate cell width based on columns
    local total_gap_width = GRID_CONFIG.cell_margin * (self.columns - 1)
    local available_for_cells = available_width - total_gap_width
    self.cell_width = math.floor(available_for_cells / self.columns)

    -- Cover width should fit in cell with padding
    local max_cover_width = self.cell_width - (GRID_CONFIG.cell_padding * 2)

    -- Calculate cover height from width maintaining aspect ratio
    local cover_height_from_width = math.floor(max_cover_width / GRID_CONFIG.book_aspect_ratio)

    -- Get font settings for text height calculation
    local title_size = 14
    local info_size = 12
    if self._manager and self._manager.settings then
        title_size = self._manager.settings.title_size or 14
        info_size = self._manager.settings.info_size or 12
    end

    -- Calculate minimum text area needed
    local title_height = math.ceil(title_size * 2 * 1.3)  -- 2 lines max
    local author_height = GRID_CONFIG.show_author and math.ceil(info_size * 1.2) or 0
    local cover_text_gap = 6
    local text_buffer = 8
    local min_text_area = title_height + author_height + cover_text_gap + text_buffer

    -- Calculate maximum cover height that fits in our row budget
    -- max_row_height is just the CELL height (not including spacing between rows)
    local max_cover_height_for_rows = max_row_height - min_text_area - (GRID_CONFIG.cell_padding * 2)

    -- Use the smaller of the two: width-based or height-based
    self.cover_height = math.min(cover_height_from_width, max_cover_height_for_rows)

    -- Clamp to absolute limits
    self.cover_height = math.max(GRID_CONFIG.min_cover_height, self.cover_height)
    self.cover_height = math.min(GRID_CONFIG.max_cover_height, self.cover_height)

    -- Recalculate cover width from final height
    self.cover_width = math.floor(self.cover_height * GRID_CONFIG.book_aspect_ratio)

    -- Calculate final cell height
    local text_area_height = min_text_area
    self.cell_height = self.cover_height + text_area_height + (GRID_CONFIG.cell_padding * 2)

    logger.dbg("OPDS+ Grid: Dimensions - Columns:", self.columns)
    logger.dbg("OPDS+ Grid: Dimensions - Available width:", available_width)
    logger.dbg("OPDS+ Grid: Dimensions - Max cover for rows:", max_cover_height_for_rows)
    logger.dbg("OPDS+ Grid: Dimensions - Cover from width:", cover_height_from_width)
    logger.dbg("OPDS+ Grid: Dimensions - Cell:", self.cell_width, "x", self.cell_height)
    logger.dbg("OPDS+ Grid: Dimensions - Cover:", self.cover_width, "x", self.cover_height)
    logger.dbg("OPDS+ Grid: Dimensions - Text area:", text_area_height)
    logger.dbg("OPDS+ Grid: Dimensions - Cover limited by:",
        self.cover_height == max_cover_height_for_rows and "HEIGHT (rows)" or "WIDTH (columns)")
end

function OPDSGridMenu:_recalculateDimen()
    logger.dbg("OPDS+ Grid: _recalculateDimen called")

    if not self.cover_width or not self.cover_height then
        self:setGridDimensions()
    end

    -- Calculate available space
    local available_width = self.inner_dimen.w - (GRID_CONFIG.side_margin * 2)
    local available_height = self.inner_dimen.h

    logger.dbg("OPDS+ Grid: Inner dimen:", self.inner_dimen.w, "x", self.inner_dimen.h)

    -- Subtract UI elements
    if not self.is_borderless then
        available_height = available_height - 2
        logger.dbg("OPDS+ Grid: Subtracted border: 2px")
    end
    if not self.no_title and self.title_bar then
        available_height = available_height - self.title_bar.dimen.h
        logger.dbg("OPDS+ Grid: Subtracted title bar:", self.title_bar.dimen.h)
    end
    if self.page_info then
        local page_info_height = self.page_info:getSize().h
        available_height = available_height - page_info_height
        logger.dbg("OPDS+ Grid: Subtracted page info:", page_info_height)
    end

    available_height = available_height - GRID_CONFIG.top_margin - GRID_CONFIG.bottom_margin

    logger.dbg("OPDS+ Grid: Available height after subtractions:", available_height)
    logger.dbg("OPDS+ Grid: Cell height:", self.cell_height)

    -- Calculate how much space each row takes (cell + spacing)
    local row_height = self.cell_height + GRID_CONFIG.row_spacing

    -- Calculate rows per page
    -- We can fit one more row if we have space for the cell itself (spacing only needed between rows)
    local rows_per_page = math.floor((available_height + GRID_CONFIG.row_spacing) / row_height)
    if rows_per_page < 1 then rows_per_page = 1 end

    -- Items per page = rows * columns
    self.perpage = rows_per_page * self.columns
    if self.perpage < 1 then self.perpage = 1 end

    logger.dbg("OPDS+ Grid: Row height (cell + spacing):", row_height)
    logger.dbg("OPDS+ Grid: Rows per page:", rows_per_page)
    logger.dbg("OPDS+ Grid: Items per page:", self.perpage)
    logger.dbg("OPDS+ Grid: Total items:", #self.item_table)

    -- Calculate total pages
    self.page_num = math.ceil(#self.item_table / self.perpage)

    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    self.item_width = available_width
    self.item_dimen = Geom:new{
        x = 0,
        y = 0,
        w = self.item_width,
        h = row_height,
    }
end

function OPDSGridMenu:updateItems(select_number)
    logger.dbg("OPDS+ Grid: updateItems called")

    -- Cancel previous image loading
    if self.halt_image_loading then
        logger.dbg("OPDS+ Grid: Cancelling previous image loading")
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
            title_size = self._manager.settings.title_size or 14,
            title_bold = self._manager.settings.title_bold,
            info_font = self._manager.settings.info_font or "smallinfofont",
            info_size = self._manager.settings.info_size or 12,
            info_bold = self._manager.settings.info_bold or false,
            info_color = self._manager.settings.info_color or "dark_gray",
            use_same_font = self._manager.settings.use_same_font,
        }
    end

    if font_settings.title_bold == nil then
        font_settings.title_bold = true
    end
    if font_settings.use_same_font == nil then
        font_settings.use_same_font = true
    end

    -- Build grid
    self._items_to_update = {}
    local idx_offset = (self.page - 1) * self.perpage

    logger.dbg("OPDS+ Grid: Building page", self.page)

    -- Calculate rows for this page
    local rows_per_page = math.ceil(self.perpage / self.columns)

    -- Calculate total width used by cells
    local total_cells_width = (self.cell_width * self.columns) + (GRID_CONFIG.cell_margin * (self.columns - 1))
    local available_width = self.inner_dimen.w
    local centering_offset = math.floor((available_width - total_cells_width) / 2)

    logger.dbg("OPDS+ Grid: Total cells width:", total_cells_width)
    logger.dbg("OPDS+ Grid: Available width:", available_width)
    logger.dbg("OPDS+ Grid: Centering offset:", centering_offset)

    for row = 1, rows_per_page do
        local row_group = HorizontalGroup:new{
            align = "top",
        }

        -- Add centering offset at the start
        if centering_offset > 0 then
            table.insert(row_group, HorizontalSpan:new{ width = centering_offset })
        end

        for col = 1, self.columns do
            local entry_idx = idx_offset + ((row - 1) * self.columns) + col
            local entry = self.item_table[entry_idx]

            if entry then
                local cell = OPDSGridCell:new{
                    entry = entry,
                    cell_width = self.cell_width,
                    cell_height = self.cell_height,
                    cover_width = self.cover_width,
                    cover_height = self.cover_height,
                    show_parent = self.show_parent,
                    menu = self,
                    font_settings = font_settings,
                }

                table.insert(row_group, cell)

                -- Track for cover loading
                if entry.cover_url and entry.lazy_load_cover and not entry.cover_bb then
                    table.insert(self._items_to_update, {
                        entry = entry,
                        widget = cell,
                    })
                end
            else
                -- Empty cell to maintain grid structure
                table.insert(row_group, HorizontalSpan:new{ width = self.cell_width })
            end

            -- Add gap between cells (but not after last column)
            if col < self.columns then
                table.insert(row_group, HorizontalSpan:new{ width = GRID_CONFIG.cell_margin })
            end
        end

        -- Add centering offset at the end (for symmetry)
        if centering_offset > 0 then
            table.insert(row_group, HorizontalSpan:new{ width = centering_offset })
        end

        -- Add row to item group
        table.insert(self.item_group, row_group)
        table.insert(self.layout, {row_group})

        -- Add row spacing (but not after last row)
        if row < rows_per_page then
            table.insert(self.item_group, VerticalSpan:new{ width = GRID_CONFIG.row_spacing })
        end
    end

    logger.dbg("OPDS+ Grid: Built", rows_per_page, "rows,", #self._items_to_update, "need covers")

    -- Update page info
    self:updatePageInfo(select_number)

    -- Refresh display
    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)

    -- Schedule cover loading
    if #self._items_to_update > 0 then
        logger.dbg("OPDS+ Grid: Scheduling cover loading in 1 second...")

        self._scheduled_cover_load = function()
            if self._loadVisibleCovers then
                self:_loadVisibleCovers()
            end
        end

        UIManager:scheduleIn(1, self._scheduled_cover_load)
    end
end

-- Reuse cover loading logic from list view
function OPDSGridMenu:_loadVisibleCovers()
    logger.dbg("OPDS+ Grid: _loadVisibleCovers starting")

    if #self._items_to_update == 0 then
        return
    end

    local urls = {}
    local items_by_url = {}

    for i, item_data in ipairs(self._items_to_update) do
        local url = item_data.entry.cover_url
        if url and not items_by_url[url] then
            table.insert(urls, url)
            items_by_url[url] = {item_data}
        elseif url then
            table.insert(items_by_url[url], item_data)
        end
    end

    if #urls == 0 then
        return
    end

    logger.dbg("OPDS+ Grid: Loading", #urls, "covers")

    local ImageLoader = require("image_loader")
    local username = self.root_catalog_username
    local password = self.root_catalog_password

    local batch, halt = ImageLoader:loadImages(urls, function(url, content)
        logger.dbg("OPDS+ Grid: Cover downloaded:", url)

        local items = items_by_url[url]
        if not items then return end

        for j, item_data in ipairs(items) do
            local entry = item_data.entry
            local widget = item_data.widget

            entry.lazy_load_cover = false

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
                logger.dbg("OPDS+ Grid: Cover rendered successfully")
                entry.cover_bb = cover_bb
                entry.cover_failed = false
                widget.entry = entry
                widget:update()
            else
                logger.warn("OPDS+ Grid: Failed to render cover")
                entry.cover_failed = true
                widget.entry = entry
                widget:update()
            end
        end
    end, username, password)

    self.halt_image_loading = halt
    self._items_to_update = {}
end

function OPDSGridMenu:onCloseWidget()
    logger.dbg("OPDS+ Grid: onCloseWidget")

    if self.halt_image_loading then
        self.halt_image_loading()
        self.halt_image_loading = nil
    end

    if self.item_table then
        for k, entry in ipairs(self.item_table) do
            if entry.cover_bb then
                entry.cover_bb:free()
                entry.cover_bb = nil
            end
        end
    end

    Menu.onCloseWidget(self)
end

logger.warn("OPDS+ opdsgridmenu.lua LOADED SUCCESSFULLY")

return OPDSGridMenu
