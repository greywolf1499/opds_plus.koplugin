local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local OPDSBrowser = require("opdsbrowser")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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
        self.settings.cover_height_ratio = 0.10  -- 10% default
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function OPDS:getCoverHeightRatio()
    return self.settings.cover_height_ratio or 0.10
end

function OPDS:setCoverHeightRatio(ratio)
    self.settings.cover_height_ratio = ratio
    self.opds_settings:saveSetting("settings", self.settings)
    self.opds_settings:flush()
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
    local SpinWidget = require("ui/widget/spinwidget")
    local current_ratio = self:getCoverHeightRatio()

    -- Convert ratio to percentage for display (0.10 -> 10)
    local current_percent = math.floor(current_ratio * 100)

    local spin_widget = SpinWidget:new{
        title_text = _("Cover Size"),
        info_text = _("Adjust the size of book covers as a percentage of screen height.\n\nSmaller values = more books per page\nLarger values = bigger covers, fewer books per page"),
        value = current_percent,
        value_min = 5,   -- 5% minimum
        value_max = 25,  -- 25% maximum
        value_step = 1,
        value_hold_step = 5,
        unit = "%",
        ok_text = _("Apply"),
        default_value = 10,  -- 10% default
        callback = function(spin)
            local new_ratio = spin.value / 100  -- Convert back to ratio (10 -> 0.10)
            self:setCoverHeightRatio(new_ratio)
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Cover size updated. Changes will apply when you next browse a catalog."),
                timeout = 3,
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
