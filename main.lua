local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local OPDSBrowser = require("opdsbrowser")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDS = WidgetContainer:extend{
    name = "opdsplus",
    opds_settings_file = DataStorage:getSettingsDir() .. "/opdsplus.lua",
    settings = nil,
    servers = nil,
    downloads = nil,
    default_servers = {
        {
            title = "Project Gutenberg",
            url = "https://m.gutenberg.org/ebooks.opds/?format=opds",
        },
        {
            title = "Standard Ebooks",
            url = "https://standardebooks.org/feeds/opds",
        },
        {
            title = "ManyBooks",
            url = "http://manybooks.net/opds/index.php",
        },
        {
            title = "Internet Archive",
            url = "https://bookserver.archive.org/",
        },
        {
            title = "textos.info (Spanish)",
            url = "https://www.textos.info/catalogo.atom",
        },
        {
            title = "Gallica (French)",
            url = "https://gallica.bnf.fr/opds",
        },
    },
    -- Cover size presets
    cover_size_presets = {
        {
            name = "Compact",
            description = "Small covers, more books per page",
            ratio = 0.08,  -- 8% of screen height
        },
        {
            name = "Regular",
            description = "Balanced size, good readability",
            ratio = 0.10,  -- 10% of screen height (default)
        },
        {
            name = "Large",
            description = "Larger covers, easier to see details",
            ratio = 0.15,  -- 15% of screen height
        },
        {
            name = "Extra Large",
            description = "Very large covers, fewer books per page",
            ratio = 0.20,  -- 20% of screen height
        },
    },
    -- Default font settings
    default_font_settings = {
        title_font = "smallinfofont",
        title_size = 16,
        title_bold = true,
        info_font = "smallinfofont",
        info_size = 14,
        info_bold = false,
        info_color = "dark_gray",  -- dark_gray or black
        use_same_font = true,  -- Use same font for title and info
    },
}

function OPDS:init()
    self.opds_settings = LuaSettings:open(self.opds_settings_file)
    if next(self.opds_settings.data) == nil then
        self.updated = true -- first run, force flush
    end
    self.servers = self.opds_settings:readSetting("servers", self.default_servers)
    self.downloads = self.opds_settings:readSetting("downloads", {})
    self.settings = self.opds_settings:readSetting("settings", {})
    self.pending_syncs = self.opds_settings:readSetting("pending_syncs", {})

    -- Initialize cover settings with defaults if not present
    if not self.settings.cover_height_ratio then
        self.settings.cover_height_ratio = 0.10  -- Regular (10% default)
    end
    if not self.settings.cover_size_preset then
        self.settings.cover_size_preset = "Regular"
    end

    -- Initialize font settings with defaults
    for key, default_value in pairs(self.default_font_settings) do
        if self.settings[key] == nil then
            self.settings[key] = default_value
        end
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function OPDS:getCoverHeightRatio()
    return self.settings.cover_height_ratio or 0.10
end

function OPDS:setCoverHeightRatio(ratio, preset_name)
    self.settings.cover_height_ratio = ratio
    self.settings.cover_size_preset = preset_name or "Custom"
    self.opds_settings:saveSetting("settings", self.settings)
    self.opds_settings:flush()
end

function OPDS:getCurrentPresetName()
    return self.settings.cover_size_preset or "Regular"
end

function OPDS:saveSetting(key, value)
    self.settings[key] = value
    self.opds_settings:saveSetting("settings", self.settings)
    self.opds_settings:flush()
end

function OPDS:getSetting(key)
    if self.settings[key] ~= nil then
        return self.settings[key]
    end
    return self.default_font_settings[key]
end

function OPDS:getAvailableFonts()
    local fonts = {}

    -- Add KOReader's built-in UI fonts first
    table.insert(fonts, {name = "Default UI (Noto Sans)", value = "smallinfofont"})
    table.insert(fonts, {name = "Alternative UI", value = "infofont"})

    -- Scan font directories for available fonts
    local font_dirs = {
        "./fonts",  -- KOReader's font directory
    }

    -- Add user's font directory if it exists
    local user_font_dir = DataStorage:getDataDir() .. "/fonts"
    if lfs.attributes(user_font_dir, "mode") == "directory" then
        table.insert(font_dirs, user_font_dir)
    end

    local font_extensions = {
        [".ttf"] = true,
        [".otf"] = true,
        [".ttc"] = true,
    }

    -- Scan directories for font files
    local seen_fonts = {}
    for i, font_dir in ipairs(font_dirs) do
        if lfs.attributes(font_dir, "mode") == "directory" then
            for entry in lfs.dir(font_dir) do
                if entry ~= "." and entry ~= ".." then
                    local path = font_dir .. "/" .. entry
                    local mode = lfs.attributes(path, "mode")

                    -- Check if it's a font file
                    if mode == "file" then
                        local ext = entry:match("%.([^.]+)$")
                        if ext then
                            ext = "." .. ext:lower()
                            if font_extensions[ext] then
                                local font_name = entry:match("^(.+)%.")
                                if font_name and not seen_fonts[font_name] then
                                    seen_fonts[font_name] = true
                                    local display_name = font_name:gsub("%-", " "):gsub("_", " ")
                                    table.insert(fonts, {
                                        name = display_name,
                                        value = font_name,
                                    })
                                end
                            end
                        end
                    -- Also check subdirectories
                    elseif mode == "directory" then
                        local subdir_path = path
                        for subentry in lfs.dir(subdir_path) do
                            if subentry ~= "." and subentry ~= ".." then
                                local subpath = subdir_path .. "/" .. subentry
                                if lfs.attributes(subpath, "mode") == "file" then
                                    local ext = subentry:match("%.([^.]+)$")
                                    if ext then
                                        ext = "." .. ext:lower()
                                        if font_extensions[ext] then
                                            local font_name = subentry:match("^(.+)%.")
                                            if font_name and not seen_fonts[font_name] then
                                                seen_fonts[font_name] = true
                                                local display_name = font_name:gsub("%-", " "):gsub("_", " ")
                                                table.insert(fonts, {
                                                    name = display_name,
                                                    value = font_name,
                                                })
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sort alphabetically by display name
    table.sort(fonts, function(a, b) return a.name < b.name end)

    return fonts
end

function OPDS:onDispatcherRegisterActions()
    Dispatcher:registerAction("opdsplus_show_catalog",
        {category="none", event="ShowOPDSPlusCatalog", title=_("OPDS Plus Catalog"), filemanager=true,}
    )
end

function OPDS:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        menu_items.opdsplus = {
            text = _("OPDS Plus Catalog"),
            sub_item_table = {
                {
                    text = _("Browse Catalogs"),
                    callback = function()
                        self:onShowOPDSCatalog()
                    end,
                },
                {
                    text = _("Settings"),
                    sub_item_table = {
                        {
                            text = _("Cover Size"),
                            callback = function()
                                self:showCoverSizeMenu()
                            end,
                        },
                        {
                            text = _("Font & Text"),
                            sub_item_table = {
                                {
                                    text = _("Use Same Font for All"),
                                    checked_func = function()
                                        return self:getSetting("use_same_font")
                                    end,
                                    callback = function()
                                        local current = self:getSetting("use_same_font")
                                        self:saveSetting("use_same_font", not current)
                                        UIManager:show(InfoMessage:new{
                                            text = not current and
                                                _("Now using the same font for title and details.\n\nChanges apply on next catalog browse.") or
                                                _("Now using separate fonts for title and details.\n\nChanges apply on next catalog browse."),
                                            timeout = 2,
                                        })
                                    end,
                                },
                                {
                                    text = _("Title Settings"),
                                    sub_item_table = {
                                        {
                                            text = _("Title Font"),
                                            callback = function()
                                                self:showFontSelectionMenu("title_font", _("Title Font"))
                                            end,
                                        },
                                        {
                                            text = _("Title Size"),
                                            callback = function()
                                                self:showSizeSelectionMenu("title_size", _("Title Font Size"), 12, 24, 16)
                                            end,
                                        },
                                        {
                                            text = _("Title Bold"),
                                            checked_func = function()
                                                return self:getSetting("title_bold")
                                            end,
                                            callback = function()
                                                local current = self:getSetting("title_bold")
                                                self:saveSetting("title_bold", not current)
                                                UIManager:show(InfoMessage:new{
                                                    text = not current and
                                                        _("Title is now bold.") or
                                                        _("Title is now regular weight."),
                                                    timeout = 2,
                                                })
                                            end,
                                        },
                                    },
                                },
                                {
                                    text = _("Information Settings"),
                                    sub_item_table = {
                                        {
                                            text = _("Info Font"),
                                            enabled_func = function()
                                                return not self:getSetting("use_same_font")
                                            end,
                                            callback = function()
                                                self:showFontSelectionMenu("info_font", _("Information Font"))
                                            end,
                                        },
                                        {
                                            text = _("Info Size"),
                                            callback = function()
                                                self:showSizeSelectionMenu("info_size", _("Information Font Size"), 10, 20, 14)
                                            end,
                                        },
                                        {
                                            text = _("Info Bold"),
                                            checked_func = function()
                                                return self:getSetting("info_bold")
                                            end,
                                            callback = function()
                                                local current = self:getSetting("info_bold")
                                                self:saveSetting("info_bold", not current)
                                                UIManager:show(InfoMessage:new{
                                                    text = not current and
                                                        _("Information text is now bold.") or
                                                        _("Information text is now regular weight."),
                                                    timeout = 2,
                                                })
                                            end,
                                        },
                                        {
                                            text = _("Info Color"),
                                            sub_item_table = {
                                                {
                                                    text = _("Dark Gray (Subtle)"),
                                                    checked_func = function()
                                                        return self:getSetting("info_color") == "dark_gray"
                                                    end,
                                                    callback = function()
                                                        self:saveSetting("info_color", "dark_gray")
                                                        UIManager:show(InfoMessage:new{
                                                            text = _("Information text color set to dark gray."),
                                                            timeout = 2,
                                                        })
                                                    end,
                                                },
                                                {
                                                    text = _("Black (High Contrast)"),
                                                    checked_func = function()
                                                        return self:getSetting("info_color") == "black"
                                                    end,
                                                    callback = function()
                                                        self:saveSetting("info_color", "black")
                                                        UIManager:show(InfoMessage:new{
                                                            text = _("Information text color set to black."),
                                                            timeout = 2,
                                                        })
                                                    end,
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        }
    end
end

function OPDS:showCoverSizeMenu()
    local current_preset = self:getCurrentPresetName()
    local current_ratio = self:getCoverHeightRatio()

    -- Build button list with presets
    local buttons = {}

    -- Add preset buttons
    for i = 1, #self.cover_size_presets do
        local preset = self.cover_size_presets[i]
        local is_current = (current_preset == preset.name)
        local button_text = preset.name
        if is_current then
            button_text = "✓ " .. button_text
        end

        table.insert(buttons, {
            {
                text = button_text,
                callback = function()
                    UIManager:close(self.cover_size_dialog)
                    self:setCoverHeightRatio(preset.ratio, preset.name)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Cover size set to %1 (%2%%).\n\n%3\n\nChanges will apply when you next browse a catalog."),
                            preset.name,
                            math.floor(preset.ratio * 100),
                            preset.description),
                        timeout = 3,
                    })
                end,
            },
        })
    end

    -- Add separator
    table.insert(buttons, {})

    -- Add custom option button
    local custom_button_text = "Custom"
    if current_preset == "Custom" then
        custom_button_text = "✓ " .. custom_button_text .. " (" .. math.floor(current_ratio * 100) .. "%)"
    end

    table.insert(buttons, {
        {
            text = custom_button_text,
            callback = function()
                UIManager:close(self.cover_size_dialog)
                self:showCustomSizeDialog()
            end,
        },
    })

    -- Create and show dialog
    self.cover_size_dialog = ButtonDialog:new{
        title = _("Cover Size Settings\n\nSelect a preset or choose custom size"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.cover_size_dialog)
end

function OPDS:showCustomSizeDialog()
    local current_ratio = self:getCoverHeightRatio()
    local current_percent = math.floor(current_ratio * 100)

    local spin_widget = SpinWidget:new{
        title_text = _("Custom Cover Size"),
        info_text = _("Adjust the size of book covers as a percentage of screen height.\n\n• Smaller values = more books per page\n• Larger values = bigger covers, fewer books per page\n\nRecommended range: 8% to 20%"),
        value = current_percent,
        value_min = 5,
        value_max = 25,
        value_step = 1,
        value_hold_step = 5,
        unit = "%",
        ok_text = _("Apply"),
        default_value = 10,
        callback = function(spin)
            local new_ratio = spin.value / 100
            self:setCoverHeightRatio(new_ratio, "Custom")
            UIManager:show(InfoMessage:new{
                text = T(_("Cover size set to Custom (%1%%).\n\nChanges will apply when you next browse a catalog."),
                    spin.value),
                timeout = 3,
            })
        end,
        extra_text = _("Back to Presets"),
        extra_callback = function()
            UIManager:close(spin_widget)
            self:showCoverSizeMenu()
        end,
    }
    UIManager:show(spin_widget)
end

function OPDS:showFontSelectionMenu(setting_key, title)
    local current_font = self:getSetting(setting_key)
    local available_fonts = self:getAvailableFonts()

    -- Build button list with available fonts
    local buttons = {}

    for i = 1, #available_fonts do
        local font_info = available_fonts[i]
        local is_current = (current_font == font_info.value)
        local button_text = font_info.name
        if is_current then
            button_text = "✓ " .. button_text
        end

        table.insert(buttons, {
            {
                text = button_text,
                callback = function()
                    UIManager:close(self.font_dialog)
                    self:saveSetting(setting_key, font_info.value)
                    UIManager:show(InfoMessage:new{
                        text = T(_("%1 set to:\n%2\n\nChanges will apply when you next browse a catalog."),
                            title,
                            font_info.name),
                        timeout = 3,
                    })
                end,
            },
        })

        -- Add separator every 5 items for readability
        if i % 5 == 0 and i < #available_fonts then
            table.insert(buttons, {})
        end
    end

    -- Create and show dialog
    self.font_dialog = ButtonDialog:new{
        title = T(_("%1 Selection\n\nChoose a font"), title),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.font_dialog)
end

function OPDS:showSizeSelectionMenu(setting_key, title, min_size, max_size, default_size)
    local current_size = self:getSetting(setting_key)

    local spin_widget = SpinWidget:new{
        title_text = title,
        info_text = _("Adjust the font size.\n\nChanges will apply when you next browse a catalog."),
        value = current_size,
        value_min = min_size,
        value_max = max_size,
        value_step = 1,
        value_hold_step = 2,
        unit = "pt",
        ok_text = _("Apply"),
        default_value = default_size,
        callback = function(spin)
            self:saveSetting(setting_key, spin.value)
            UIManager:show(InfoMessage:new{
                text = T(_("%1 set to %2pt.\n\nChanges will apply when you next browse a catalog."),
                    title,
                    spin.value),
                timeout = 2,
            })
        end,
    }
    UIManager:show(spin_widget)
end

function OPDS:onShowOPDSCatalog()
    self.opds_browser = OPDSBrowser:new{
        servers = self.servers,
        downloads = self.downloads,
        settings = self.settings,
        pending_syncs = self.pending_syncs,
        title = _("OPDS Plus Catalog"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        show_covers = true,
        _manager = self,
        file_downloaded_callback = function(file)
            self:showFileDownloadedDialog(file)
        end,
        close_callback = function()
            if self.opds_browser.download_list then
                self.opds_browser.download_list.close_callback()
            end
            UIManager:close(self.opds_browser)
            self.opds_browser = nil
            if self.last_downloaded_file then
                if self.ui.file_chooser then
                    local pathname = util.splitFilePathName(self.last_downloaded_file)
                    self.ui.file_chooser:changeToPath(pathname, self.last_downloaded_file)
                end
                self.last_downloaded_file = nil
            end
        end,
    }
    UIManager:show(self.opds_browser)
end

function OPDS:showFileDownloadedDialog(file)
    self.last_downloaded_file = file
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"), BD.filepath(file)),
        ok_text = _("Read now"),
        ok_callback = function()
            self.last_downloaded_file = nil
            self.opds_browser.close_callback()
            if self.ui.document then
                self.ui:switchDocument(file)
            else
                self.ui:openFile(file)
            end
        end,
    })
end

function OPDS:onFlushSettings()
    if self.updated then
        self.opds_settings:flush()
        self.updated = nil
    end
end

return OPDS
