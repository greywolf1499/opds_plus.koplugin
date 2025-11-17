local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local OPDSBrowser = require("opdsbrowser")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")  -- Keep this as is - it works fine here
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
                    callback = function()
                        self:showSettingsMenu()
                    end,
                },
            },
        }
    end
end

function OPDS:showSettingsMenu()
    local current_preset = self:getCurrentPresetName()
    local current_ratio = self:getCoverHeightRatio()

    -- Build button list with presets
    local buttons = {}

    -- Add preset buttons
    -- Use a different loop variable name to avoid shadowing _
    for i = 1, #self.cover_size_presets do
        local preset = self.cover_size_presets[i]
        local is_current = (current_preset == preset.name)
        local button_text = preset.name
        if is_current then
            button_text = "✓ " .. button_text  -- Checkmark for current selection
        end

        table.insert(buttons, {
            {
                text = button_text,
                callback = function()
                    UIManager:close(self.settings_dialog)
                    self:setCoverHeightRatio(preset.ratio, preset.name)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Cover size set to %1 (%2%).\n\n%3\n\nChanges will apply when you next browse a catalog."),
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
                UIManager:close(self.settings_dialog)
                self:showCustomSizeDialog()
            end,
        },
    })

    -- Create and show dialog
    self.settings_dialog = ButtonDialog:new{
        title = _("Cover Size Settings\n\nSelect a preset or choose custom size"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.settings_dialog)
end

function OPDS:showCustomSizeDialog()
    local current_ratio = self:getCoverHeightRatio()
    local current_percent = math.floor(current_ratio * 100)

    local spin_widget = SpinWidget:new{
        title_text = _("Custom Cover Size"),
        info_text = _("Adjust the size of book covers as a percentage of screen height.\n\n• Smaller values = more books per page\n• Larger values = bigger covers, fewer books per page\n\nRecommended range: 8% to 20%"),
        value = current_percent,
        value_min = 5,   -- 5% minimum
        value_max = 25,  -- 25% maximum
        value_step = 1,
        value_hold_step = 5,
        unit = "%",
        ok_text = _("Apply"),
        default_value = 10,  -- 10% default
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
            self:showSettingsMenu()
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
        show_covers = true, -- Enable cover display
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
