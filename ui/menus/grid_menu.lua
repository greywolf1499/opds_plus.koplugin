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
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local LineWidget = require("ui/widget/linewidget")
local Screen = Device.screen
local logger = require("logger")
local _ = require("gettext")

-- ============================================
-- GRID CONFIGURATION
-- ============================================
local GRID_CONFIG = {
    -- Grid layout presets - now defined by rows target
    size_presets = {
        ["Compact"] = { columns = 4, target_rows = 3, description = "More books visible" },
        ["Balanced"] = { columns = 3, target_rows = 2, description = "Good balance" },
        ["Spacious"] = { columns = 2, target_rows = 2, description = "Larger covers" },
    },

    -- Fallback defaults
    default_columns = 3,
    min_columns = 2,
    max_columns = 4,

    -- Cover dimensions limits
    min_cover_height = 80,
    max_cover_height = 400,

    -- Standard book aspect ratio
    book_aspect_ratio = 2 / 3,

    -- Spacing
    cell_padding = 6,
    cell_margin = 10,
    row_spacing = 12,
    top_margin = 6,
    bottom_margin = 6,
    side_margin = 10,

    -- Text
    title_lines_max = 2,
    show_author = true,
}

-- Helper function to get border color
local function getBorderColor(color_name)
    if color_name == "black" then
        return Blitbuffer.COLOR_BLACK
    elseif color_name == "light_gray" then
        return Blitbuffer.COLOR_LIGHT_GRAY
    else -- "dark_gray" or default
        return Blitbuffer.COLOR_DARK_GRAY
    end
end

-- ============================================
-- GRID CELL WIDGET
-- ============================================
local OPDSGridCell = InputContainer:extend {
    entry = nil,
    cover_width = nil,
    cover_height = nil,
    cell_width = nil,
    cell_height = nil,
    show_parent = nil,
    menu = nil,
    font_settings = nil,
    border_settings = nil,
}

function OPDSGridCell:init()
    self.dimen = Geom:new {
        w = self.cell_width,
        h = self.cell_height,
    }

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

    -- Create cover widget
    local inner_cover_widget
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

    local cover_widget = CenterContainer:new {
        dimen = Geom:new {
            w = self.cover_width,
            h = self.cover_height,
        },
        inner_cover_widget
    }

    -- Parse title and author
    local title, author = UIUtils.parseTitleAuthor(self.entry)

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
    local title_line_height = math.ceil(title_size * 1.3)
    local title_fixed_height = title_line_height * 2

    local author_line_height = math.ceil(info_size * 1.2)
    local author_fixed_height = GRID_CONFIG.show_author and author_line_height or 0

    local title_author_gap = GRID_CONFIG.show_author and 4 or 0
    local cover_text_gap = 6

    local text_area_height = title_fixed_height + title_author_gap + author_fixed_height + cover_text_gap

    local max_text_area = self.cell_height - self.cover_height - (GRID_CONFIG.cell_padding * 2)
    text_area_height = math.min(text_area_height, max_text_area)

    -- Build text group with FIXED heights for each element
    local text_group = VerticalGroup:new {
        align = "center",
    }

    -- Title
    local title_face = Font:getFace(title_font, title_size)
    local title_text = UIUtils.truncateText(title, title_face, text_width * 2)

    local title_widget = TextBoxWidget:new {
        text = title_text,
        face = Font:getFace(title_font, title_size),
        bold = title_bold,
        width = text_width,
        height = title_fixed_height,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
        line_height = 0,
    }

    local title_container = FrameContainer:new {
        width = text_width,
        height = title_fixed_height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new {
            dimen = Geom:new {
                w = text_width,
                h = title_fixed_height,
            },
            title_widget,
        },
    }
    table.insert(text_group, title_container)

    -- Author - with truncation
    if GRID_CONFIG.show_author then
        table.insert(text_group, VerticalSpan:new { width = title_author_gap })

        local author_widget
        if author and author ~= "" then
            local author_face = Font:getFace(info_font, info_size)
            local author_text = UIUtils.truncateText(author, author_face, text_width)

            author_widget = TextWidget:new {
                text = author_text,
                face = author_face,
                max_width = text_width,
                fgcolor = info_color,
            }
        else
            author_widget = VerticalSpan:new { width = 0 }
        end

        local author_container = FrameContainer:new {
            width = text_width,
            height = author_fixed_height,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new {
                dimen = Geom:new {
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
    local text_container = TopContainer:new {
        dimen = Geom:new {
            w = text_width,
            h = text_area_height,
        },
        text_group,
    }

    local border_style = (self.border_settings and self.border_settings.style) or "none"
    local border_size = (self.border_settings and self.border_settings.size) or 2
    local border_color_name = (self.border_settings and self.border_settings.color) or "dark_gray"
    local border_color = getBorderColor(border_color_name)

    local cell_bordersize = 0
    if border_style == "individual" then
        cell_bordersize = border_size
    end

    local inner_width = self.cell_width - (GRID_CONFIG.cell_padding * 2) - (cell_bordersize * 2)
    local inner_height = self.cell_height - (GRID_CONFIG.cell_padding * 2) - (cell_bordersize * 2)

    self[1] = FrameContainer:new {
        width = self.cell_width,
        height = self.cell_height,
        padding = GRID_CONFIG.cell_padding,
        margin = 0,
        bordersize = cell_bordersize,
        color = border_color,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new {
            dimen = Geom:new {
                w = inner_width,
                h = inner_height,
            },
            VerticalGroup:new {
                align = "center",
                cover_widget,
                VerticalSpan:new { width = cover_text_gap },
                text_container,
            },
        },
    }

    self.cover_widget = cover_widget
end

function OPDSGridCell:update()
    self:init()
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

function OPDSGridCell:onTapSelect(arg, ges)
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
        return true
    end
    return false
end

function OPDSGridCell:onHoldSelect(arg, ges)
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
local OPDSGridMenu = Menu:extend {
    cover_width = nil,
    cover_height = nil,
    cell_width = nil,
    cell_height = nil,
    columns = nil,
    _items_to_update = {},
}

function OPDSGridMenu:_debugLog(...)
    if self._manager and self._manager.settings and self._manager.settings.debug_mode then
        logger.dbg("OPDS+ Grid:", ...)
    end
end

function OPDSGridMenu:setGridDimensions()
    -- Get preset or custom column setting
    local preset_name = "Balanced"
    local columns = GRID_CONFIG.default_columns
    local target_rows = 2

    if self._manager and self._manager.settings then
        preset_name = self._manager.settings.grid_size_preset or "Balanced"

        if preset_name ~= "Custom" then
            local preset = GRID_CONFIG.size_presets[preset_name]
            if preset then
                columns = preset.columns
                target_rows = preset.target_rows
            end
        else
            -- Custom columns
            columns = self._manager.settings.grid_columns or GRID_CONFIG.default_columns
            target_rows = 2 -- Default target for custom
        end
    end

    self.columns = columns

    -- Get screen dimensions
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    -- Calculate available dimensions
    local available_width = screen_width - (GRID_CONFIG.side_margin * 2)

    -- Estimate available height (will be refined in _recalculateDimen)
    local estimated_ui_overhead = 100
    local available_height = screen_height - estimated_ui_overhead - GRID_CONFIG.top_margin - GRID_CONFIG.bottom_margin

    -- [Get settings for borders]
    local border_style = "none"
    local border_size = 2
    if self._manager and self._manager.settings then
        border_style = self._manager.settings.grid_border_style or "none"
        border_size = self._manager.settings.grid_border_size or 2
    end

    -- Calculate effective border deduction for "individual" style
    local border_deduction = 0
    if border_style == "individual" then
        border_deduction = border_size * 2
    end

    -- Calculate cell width based on columns
    local total_gap_width = GRID_CONFIG.cell_margin * (self.columns - 1)
    local available_for_cells = available_width - total_gap_width
    self.cell_width = math.floor(available_for_cells / self.columns)

    -- Cover width should fit in cell with padding
    local max_cover_width = self.cell_width - (GRID_CONFIG.cell_padding * 2) - border_deduction

    -- Calculate cover height from width maintaining aspect ratio
    local cover_height_from_width = math.floor(max_cover_width / GRID_CONFIG.book_aspect_ratio)

    -- Get font settings for text height calculation
    local title_size = 14
    local info_size = 12
    if self._manager and self._manager.settings then
        title_size = self._manager.settings.title_size or 14
        info_size = self._manager.settings.info_size or 12
    end

    -- Calculate text area needed
    local title_height = math.ceil(title_size * 2 * 1.3)
    local author_height = GRID_CONFIG.show_author and math.ceil(info_size * 1.2) or 0
    local cover_text_gap = 6
    local text_area_height = title_height + author_height + cover_text_gap

    -- Calculate how much height we need per row
    local spacing_between_rows = (target_rows - 1) * GRID_CONFIG.row_spacing
    local available_for_rows = available_height - spacing_between_rows
    local target_row_height = math.floor(available_for_rows / target_rows)

    -- Calculate max cover height that fits in target row height
    local max_cover_from_rows = target_row_height - text_area_height - (GRID_CONFIG.cell_padding * 2) - border_deduction

    -- Use the more restrictive constraint
    self.cover_height = math.min(cover_height_from_width, max_cover_from_rows)

    -- Clamp to absolute limits
    self.cover_height = math.max(GRID_CONFIG.min_cover_height, self.cover_height)
    self.cover_height = math.min(GRID_CONFIG.max_cover_height, self.cover_height)

    -- Recalculate cover width from final height
    self.cover_width = math.floor(self.cover_height * GRID_CONFIG.book_aspect_ratio)

    -- Calculate final cell height
    self.cell_height = self.cover_height + text_area_height + (GRID_CONFIG.cell_padding * 2) + border_deduction

    self:_debugLog("Grid preset:", preset_name, "Columns:", columns, "Target rows:", target_rows)
    self:_debugLog("Grid preset:", preset_name, "Border:", border_style, border_size .. "px")
    self:_debugLog("Cell:", self.cell_width, "x", self.cell_height, "Cover:", self.cover_width, "x", self.cover_height)
end

function OPDSGridMenu:_recalculateDimen()
    if not self.cover_width or not self.cover_height then
        self:setGridDimensions()
    end

    -- Calculate ACTUAL available space
    local available_width = self.inner_dimen.w - (GRID_CONFIG.side_margin * 2)
    local available_height = self.inner_dimen.h

    -- Subtract UI elements
    if not self.is_borderless then
        available_height = available_height - 2
    end
    if not self.no_title and self.title_bar then
        available_height = available_height - self.title_bar.dimen.h
    end
    if self.page_info then
        available_height = available_height - self.page_info:getSize().h
    end

    available_height = available_height - GRID_CONFIG.top_margin - GRID_CONFIG.bottom_margin

    -- [Get border settings again for optimization logic]
    local border_style = "none"
    local border_size = 2
    if self._manager and self._manager.settings then
        border_style = self._manager.settings.grid_border_style or "none"
        border_size = self._manager.settings.grid_border_size or 2
    end
    local border_deduction = (border_style == "individual") and (border_size * 2) or 0

    -- Calculate rows per page
    local row_height = self.cell_height + GRID_CONFIG.row_spacing
    local rows_per_page = math.floor((available_height + GRID_CONFIG.row_spacing) / row_height)
    if rows_per_page < 1 then rows_per_page = 1 end

    -- Check if we can fit more rows by adjusting cell height slightly
    local used_height = (rows_per_page * self.cell_height) + ((rows_per_page - 1) * GRID_CONFIG.row_spacing)
    local remaining_space = available_height - used_height

    if remaining_space > self.cell_height * 0.6 then
        -- Try to fit one more row
        local new_rows = rows_per_page + 1
        local total_spacing = (new_rows - 1) * GRID_CONFIG.row_spacing
        local new_cell_height = math.floor((available_height - total_spacing) / new_rows)

        -- Calculate new cover height
        local title_size = 14
        local info_size = 12
        if self._manager and self._manager.settings then
            title_size = self._manager.settings.title_size or 14
            info_size = self._manager.settings.info_size or 12
        end

        local title_height = math.ceil(title_size * 2 * 1.3)
        local author_height = GRID_CONFIG.show_author and math.ceil(info_size * 1.2) or 0
        local cover_text_gap = 6
        local text_area_height = title_height + author_height + cover_text_gap

        local new_cover_height = new_cell_height - text_area_height - (GRID_CONFIG.cell_padding * 2) - border_deduction

        if new_cover_height >= GRID_CONFIG.min_cover_height then
            self.cover_height = new_cover_height
            self.cover_width = math.floor(self.cover_height * GRID_CONFIG.book_aspect_ratio)
            self.cell_height = new_cell_height
            rows_per_page = new_rows

            self:_debugLog("Optimized: Adjusted to fit", rows_per_page, "rows (was wasting",
                math.floor(remaining_space), "px)")
        end
    end

    self.perpage = rows_per_page * self.columns
    if self.perpage < 1 then self.perpage = 1 end

    self:_debugLog("Final grid - Rows:", rows_per_page, "Items:", self.perpage,
        "Whitespace:", math.floor(available_height - used_height), "px")

    -- Calculate total pages
    self.page_num = math.ceil(#self.item_table / self.perpage)

    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    self.item_width = available_width
    self.item_dimen = Geom:new {
        x = 0,
        y = 0,
        w = self.item_width,
        h = row_height,
    }
end

function OPDSGridMenu:updateItems(select_number)
    -- Cancel previous image loading
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

    -- Get border settings
    local border_settings = {
        style = "none",
        size = 2,
        color = "dark_gray",
    }
    if self._manager and self._manager.settings then
        border_settings.style = self._manager.settings.grid_border_style or "none"
        border_settings.size = self._manager.settings.grid_border_size or 2
        border_settings.color = self._manager.settings.grid_border_color or "dark_gray"
    end

    -- Build grid
    self._items_to_update = {}
    local idx_offset = (self.page - 1) * self.perpage

    -- Calculate rows for this page
    local rows_per_page = math.ceil(self.perpage / self.columns)

    -- Calculate centering
    local total_cells_width = (self.cell_width * self.columns) + (GRID_CONFIG.cell_margin * (self.columns - 1))
    local available_width = self.inner_dimen.w
    local centering_offset = math.floor((available_width - total_cells_width) / 2)

    -- Hash border implementation
    if border_settings.style == "hash" then
        local border_color = getBorderColor(border_settings.color)
        local border_size = border_settings.size

        -- Create complete grid with hash borders
        for row = 1, rows_per_page do
            local row_group = HorizontalGroup:new { align = "top" }

            if centering_offset > 0 then
                table.insert(row_group, HorizontalSpan:new { width = centering_offset })
            end

            for col = 1, self.columns do
                local entry_idx = idx_offset + ((row - 1) * self.columns) + col
                local entry = self.item_table[entry_idx]

                if entry then
                    local cell = OPDSGridCell:new {
                        entry = entry,
                        cell_width = self.cell_width,
                        cell_height = self.cell_height,
                        cover_width = self.cover_width,
                        cover_height = self.cover_height,
                        show_parent = self.show_parent,
                        menu = self,
                        font_settings = font_settings,
                        border_settings = { style = "none" }, -- No individual borders for hash
                    }

                    table.insert(row_group, cell)

                    if entry.cover_url and entry.lazy_load_cover and not entry.cover_bb then
                        table.insert(self._items_to_update, { entry = entry, widget = cell })
                    end
                else
                    table.insert(row_group, HorizontalSpan:new { width = self.cell_width })
                end

                -- Add vertical line between columns (but not after last)
                if col < self.columns then
                    -- Calculate spacing around the line
                    local total_gap = GRID_CONFIG.cell_margin
                    local line_width = border_size
                    local space_side = math.floor((total_gap - line_width) / 2)

                    -- 1. Left spacing
                    if space_side > 0 then
                        table.insert(row_group, HorizontalSpan:new { width = space_side })
                    end

                    -- 2. The Line itself
                    local line = LineWidget:new {
                        dimen = Geom:new {
                            w = border_size,
                            h = self.cell_height,
                        },
                        background = border_color,
                    }
                    table.insert(row_group, line)

                    -- 3. Right spacing (ensure total adds up to cell_margin)
                    local remaining = total_gap - line_width - space_side
                    if remaining > 0 then
                        table.insert(row_group, HorizontalSpan:new { width = remaining })
                    end
                end
            end

            if centering_offset > 0 then
                table.insert(row_group, HorizontalSpan:new { width = centering_offset })
            end

            table.insert(self.item_group, row_group)
            table.insert(self.layout, { row_group })

            -- Add horizontal line between rows (but not after last)
            if row < rows_per_page then
                local h_line_width = total_cells_width + (border_size * (self.columns - 1))
                local h_line_group = HorizontalGroup:new {}

                if centering_offset > 0 then
                    table.insert(h_line_group, HorizontalSpan:new { width = centering_offset })
                end

                local line = LineWidget:new {
                    dimen = Geom:new {
                        w = h_line_width,
                        h = border_size,
                    },
                    background = border_color,
                }
                table.insert(h_line_group, line)

                if centering_offset > 0 then
                    table.insert(h_line_group, HorizontalSpan:new { width = centering_offset })
                end

                table.insert(self.item_group, h_line_group)
            end
        end
    else
        -- Standard grid (none or individual borders)
        for row = 1, rows_per_page do
            local row_group = HorizontalGroup:new { align = "top" }

            if centering_offset > 0 then
                table.insert(row_group, HorizontalSpan:new { width = centering_offset })
            end

            for col = 1, self.columns do
                local entry_idx = idx_offset + ((row - 1) * self.columns) + col
                local entry = self.item_table[entry_idx]

                if entry then
                    local cell = OPDSGridCell:new {
                        entry = entry,
                        cell_width = self.cell_width,
                        cell_height = self.cell_height,
                        cover_width = self.cover_width,
                        cover_height = self.cover_height,
                        show_parent = self.show_parent,
                        menu = self,
                        font_settings = font_settings,
                        border_settings = border_settings,
                    }

                    table.insert(row_group, cell)

                    if entry.cover_url and entry.lazy_load_cover and not entry.cover_bb then
                        table.insert(self._items_to_update, { entry = entry, widget = cell })
                    end
                else
                    table.insert(row_group, HorizontalSpan:new { width = self.cell_width })
                end

                if col < self.columns then
                    table.insert(row_group, HorizontalSpan:new { width = GRID_CONFIG.cell_margin })
                end
            end

            if centering_offset > 0 then
                table.insert(row_group, HorizontalSpan:new { width = centering_offset })
            end

            table.insert(self.item_group, row_group)
            table.insert(self.layout, { row_group })

            if row < rows_per_page then
                table.insert(self.item_group, VerticalSpan:new { width = GRID_CONFIG.row_spacing })
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

    -- Custom page info
    if self.page_info then
        local custom_text = "▦ " .. self.page .. "/" .. self.page_num .. " (" .. self.perpage .. " items)"

        for i = 1, 10 do
            if self.page_info[i] and type(self.page_info[i]) == "table" and self.page_info[i].text then
                local old_widget = self.page_info[i]
                local face = old_widget.face or Font:getFace("smallinfofont")
                local fgcolor = old_widget.fgcolor or Blitbuffer.COLOR_BLACK

                if old_widget.free then
                    old_widget:free()
                end

                self.page_info[i] = TextWidget:new {
                    text = custom_text,
                    face = face,
                    fgcolor = fgcolor,
                }

                UIManager:setDirty(self.show_parent, "ui")
                break
            end
        end
    end

    -- Schedule cover loading
    if #self._items_to_update > 0 then
        self:_debugLog("Scheduling cover loading for", #self._items_to_update, "items")

        self._scheduled_cover_load = function()
            if self._loadVisibleCovers then
                self:_loadVisibleCovers()
            end
        end
        UIManager:scheduleIn(1, self._scheduled_cover_load)
    end
end

-- Override page info
function OPDSGridMenu:getPageInfo()
    local columns = self.columns or 3
    return "▦ " .. self.page .. " / " .. self.page_num .. " (" .. self.perpage .. " items, " .. columns .. " cols)"
end

-- Reuse cover loading logic
function OPDSGridMenu:_loadVisibleCovers()
    if #self._items_to_update == 0 then
        return
    end

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

    self:_debugLog("Loading", #urls, "covers")

    local ImageLoader = require("services.image_loader")
    local username = self.root_catalog_username
    local password = self.root_catalog_password

    -- Get debug mode setting
    local debug_mode = self._manager and self._manager.settings and self._manager.settings.debug_mode

    local _, halt = ImageLoader:loadImages(urls, function(url, content)
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
                entry.cover_bb = cover_bb
                entry.cover_failed = false
                widget.entry = entry
                widget:update()
            else
                entry.cover_failed = true
                widget.entry = entry
                widget:update()
            end
        end
    end, username, password, debug_mode)

    self.halt_image_loading = halt
    self._items_to_update = {}
end

function OPDSGridMenu:onCloseWidget()
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

return OPDSGridMenu
