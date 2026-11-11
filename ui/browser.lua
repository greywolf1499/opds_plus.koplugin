local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

-- Import the custom cover menu for displaying book covers
local OPDSCoverMenu = require("ui.menus.cover_menu")

-- Import constants and utilities
local Constants = require("models.constants")

-- Import the OPDS menu builder
local OPDSMenuBuilder = require("ui.dialogs.menu_builder")

-- Import the download manager
local DownloadManager = require("core.download_manager")
local DownloadDialogBuilder = require("ui.dialogs.download_builder")

-- Import the book info dialog
local BookInfoDialog = require("ui.dialogs.book_info_dialog")

-- Import the feed fetcher
local FeedFetcher = require("core.feed_fetcher")

-- Import the HTTP client
local HttpClient = require("services.http_client")
local CatalogLoader = require("services.catalog_loader")
local CoverLoader = require("services.cover_loader")

-- Import the catalog manager
local CatalogManager = require("core.catalog_manager")

-- Import the catalog utilities
local CatalogUtils = require("utils.catalog_utils")
local RequestHeaders = require("utils.request_headers")

-- Import the navigation handler
local NavigationHandler = require("core.navigation_handler")

-- Import the browser context factory
local BrowserContext = require("core.browser_context")

-- Import the sync manager
local SyncManager = require("core.sync_manager")

-- Import the state manager
local StateManager = require("core.state_manager")

-- Import the debug utility
local Debug = require("utils.debug")

-- Changed from Menu:extend to OPDSCoverMenu:extend to support cover images
local OPDSBrowser = OPDSCoverMenu:extend {
    catalog_type             = Constants.CATALOG_TYPE,
    search_type              = Constants.SEARCH_TYPE,
    search_template_type     = Constants.SEARCH_TEMPLATE_TYPE,
    acquisition_rel          = Constants.ACQUISITION_REL,
    borrow_rel               = Constants.BORROW_REL,
    stream_rel               = Constants.STREAM_REL,
    facet_rel                = Constants.FACET_REL,
    catalog_rel              = Constants.CATALOG_REL,
    image_rel                = Constants.IMAGE_REL,
    thumbnail_rel            = Constants.THUMBNAIL_REL,

    root_catalog_title       = nil,
    root_catalog_username    = nil,
    root_catalog_password    = nil,
    facet_groups             = nil,

    title_shrink_font_to_fit = true,
}

function OPDSBrowser:init()
    self:cancelCatalogLoad()
    -- Every browser shares the same live list of catalogs, which holds their custom HTTP headers
    HttpClient.setCatalogs(self.servers)
    self.item_table = self:genItemTableFromRoot()
    self.catalog_title = nil
    self.title_bar_left_icon = Constants.ICONS.MENU
    self.onLeftButtonTap = function()
        self:showOPDSMenu()
    end

    self.title_bar_right_icon = nil
    self.facet_groups = nil
    OPDSCoverMenu.init(self)

    -- Menu maps the back key to Close; walk up the catalog instead, and leave Home to close.
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
        self.key_events.Close = { { "Home" } }
    end
end

function OPDSBrowser:onBack()
    if self.paths and #self.paths > 0 then
        return self:onReturn()
    end
    return self:onClose()
end

function OPDSBrowser:_debugLog(...)
    Debug.log("Browser:", ...)
end

function OPDSBrowser:toggleViewMode()
    self:cancelCatalogLoad()
    -- Get current mode using StateManager
    local state = StateManager.getInstance()
    local current_mode = state:getDisplayMode()

    -- Toggle to opposite mode
    local new_mode = (current_mode == "list") and "grid" or "list"

    -- Save new mode via StateManager (handles persistence)
    state:setDisplayMode(new_mode)

    self:_debugLog("Toggling view mode from", current_mode, "to", new_mode)

    -- Show notification
    local mode_text = new_mode == "grid" and _("Grid View") or _("List View")
    UIManager:show(InfoMessage:new {
        text = T(_("Switched to %1"), mode_text),
        timeout = 1,
    })

    -- The views hold a different number of items per page, so remember the item, not the page.
    local itemnumber = self:getFocusedItemNumber()

    self:switchItemTable(self.catalog_title, self.item_table, itemnumber)

    -- switchItemTable paged with the old view's perpage and focused the first item.
    local page = self:getPageNumber(itemnumber)
    local select_number = itemnumber - ((page - 1) * self.perpage)
    if page ~= self.page or select_number ~= 1 then
        self.page = page
        self:updateItems(select_number)
    end
end

--- Number of the item that has to stay on screen when the view changes.
-- Menu only refocuses on devices with a D-pad, and every plain (cover-less) page adds the title bar rows to
-- self.selected. Without a D-pad that makes it point at an arbitrary item, so use the first item of the page.
function OPDSBrowser:getFocusedItemNumber()
    local selected = self.selected
    local first_of_page = ((self.page or 1) - 1) * (self.perpage or 0) + 1
    if not Device:hasDPad() or not selected or not self.perpage then
        return first_of_page
    end
    local columns = (self.layout and self.layout[1]) and #self.layout[1] or 1
    local in_page = ((selected.y - 1) * columns) + selected.x
    return ((self.page - 1) * self.perpage) + in_page
end

function OPDSBrowser:showOPDSMenu()
    local dialog = OPDSMenuBuilder.buildOPDSMenu(self)
    UIManager:show(dialog)
end

-- Shows facet menu for OPDS catalogs with facets/search support
function OPDSBrowser:showFacetMenu()
    local catalog_url = self.paths[#self.paths].url
    local has_covers = OPDSMenuBuilder.hasCovers(self.item_table)

    local dialog = OPDSMenuBuilder.buildFacetMenu(self, catalog_url, has_covers)
    UIManager:show(dialog)
end

-- Shows menu for catalogs without facets but with covers (for view toggle)
function OPDSBrowser:showCatalogMenu()
    local catalog_url = self.paths[#self.paths].url
    local has_covers = OPDSMenuBuilder.hasCovers(self.item_table)

    local dialog = OPDSMenuBuilder.buildCatalogMenu(self, catalog_url, has_covers)
    UIManager:show(dialog)
end

function OPDSBrowser:genItemTableFromRoot()
    return CatalogManager.genItemTableFromRoot(self.servers, self.downloads, _)
end

function OPDSBrowser:addEditCatalog(item)
    local dialog = OPDSMenuBuilder.buildCatalogEditDialog(self, item)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OPDSBrowser:addSubCatalog(item_url)
    local dialog = OPDSMenuBuilder.buildSubCatalogDialog(self, item_url)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OPDSBrowser:editCatalogFromInput(fields, item, no_refresh)
    -- luacheck: ignore new_idx
    local new_idx, itemnumber, should_refresh = CatalogManager.editCatalogFromInput(
        self.servers, self.item_table, fields, item, no_refresh)

    if should_refresh then
        self:switchItemTable(nil, self.item_table, itemnumber)
    end
    StateManager.getInstance():markDirty()
end

function OPDSBrowser:deleteCatalog(item)
    self.item_table = CatalogManager.deleteCatalog(self.servers, self.item_table, item)
    self:switchItemTable(nil, self.item_table, -1)
    StateManager.getInstance():markDirty()
end

function OPDSBrowser:fetchFeed(item_url, headers_only)
    return FeedFetcher.fetchFeed(item_url, headers_only,
        self.root_catalog_username, self.root_catalog_password, nil, nil, self.root_catalog_url or false)
end

function OPDSBrowser:parseFeed(item_url)
    return FeedFetcher.parseFeed(item_url,
        self.root_catalog_username, self.root_catalog_password,
        function(...) self:_debugLog(...) end, nil, self.root_catalog_url or false)
end

function OPDSBrowser:getServerFileName(item_url, filetype)
    return FeedFetcher.getServerFileName(item_url, filetype,
        self.root_catalog_username, self.root_catalog_password, self.root_catalog_url or false)
end

function OPDSBrowser:getSearchTemplate(osd_url)
    return FeedFetcher.getSearchTemplate(osd_url, self.search_template_type,
        self.root_catalog_username, self.root_catalog_password,
        function(...) self:_debugLog(...) end, nil, self.root_catalog_url or false)
end

function OPDSBrowser:genItemTableFromURL(item_url)
    return FeedFetcher.genItemTableFromURL(item_url,
        self.root_catalog_username, self.root_catalog_password,
        function(...) self:_debugLog(...) end,
        function(catalog, catalog_url)
            return self:genItemTableFromCatalog(catalog, catalog_url)
        end, nil, self.root_catalog_url or false)
end

function OPDSBrowser:genItemTableFromCatalog(catalog, item_url)
    local context = BrowserContext.fromBrowser(self)

    local item_table, facet_groups, search_url = NavigationHandler.genItemTableFromCatalog(
        catalog, item_url, context,
        function(...) self:_debugLog(...) end)

    self.facet_groups = facet_groups
    self.search_url = search_url

    return item_table
end

function OPDSBrowser:cancelCatalogLoad()
    self._catalog_generation = (self._catalog_generation or 0) + 1
    local job = self._catalog_job
    self._catalog_job = nil
    if job and job.worker then job.worker:cancel() end
end

function OPDSBrowser:onCloseWidget()
    self:cancelCatalogLoad()
    return OPDSCoverMenu.onCloseWidget(self)
end

function OPDSBrowser:loadCatalog(item_url, context, callback)
    self:cancelCatalogLoad()
    CoverLoader.stopPrefetch(self)
    local job = {}
    self._catalog_job = job
    job.worker = CatalogLoader.start(item_url, context, function(packet, cancelled)
        if self._catalog_job ~= job then return end
        self._catalog_job = nil
        callback(packet, cancelled)
    end)
    return true
end

function OPDSBrowser:updateCatalog(item_url, paths_updated, options)
    options = options or {}
    local context = options.context or BrowserContext.fromBrowser(self)
    return self:loadCatalog(item_url, context, function(packet)
        if not packet or (#packet.items == 0 and not packet.facets and not packet.search) then return end
        if options.paths then self.paths = options.paths end
        if options.root then
            self.root_catalog_title = options.root.text
            self.root_catalog_url = options.root.url
            self.root_catalog_username = options.root.username
            self.root_catalog_password = options.root.password
            self.root_catalog_raw_names = options.root.raw_names
        end
        self.catalog_title = options.title or self.catalog_title
        NavigationHandler.applyCatalog(packet.items, packet.facets, packet.search, item_url, self, paths_updated)
    end)
end

function OPDSBrowser:appendCatalog(item_url, done)
    return self:loadCatalog(item_url, BrowserContext.fromBrowser(self), function(packet, cancelled)
        local appended = packet and NavigationHandler.appendItems(packet.items, self, self:getFocusedItemNumber())
        if done then done(appended == true, cancelled) end
    end)
end

function OPDSBrowser:searchCatalog(item_url)
    local dialog = OPDSMenuBuilder.buildSearchDialog(self, item_url)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows dialog to download / stream a book
function OPDSBrowser:showDownloads(item)
    -- luacheck: ignore filename_orig
    local filename, filename_orig = self:getFileName(item)

    local function createTitle(path, file)
        return T(_("Download folder:\n%1\n\nDownload filename:\n%2\n\nDownload file type:"),
            BD.dirpath(path), file or _(Constants.DEFAULT_FILENAME))
    end

    self.download_dialog = DownloadDialogBuilder.buildDownloadDialog(self, item, filename, createTitle)
    UIManager:show(self.download_dialog)
end

-- Returns user selected or last opened folder
function OPDSBrowser:getCurrentDownloadDir()
    return DownloadManager.getCurrentDownloadDir(self)
end

function OPDSBrowser:getLocalDownloadPath(filename, filetype, remote_url)
    return DownloadManager.getLocalDownloadPath(self, filename, filetype, remote_url)
end

-- Menu action on item tap (Download a book / Show subcatalog / Search in catalog)
function OPDSBrowser:onMenuSelect(item)
    self:cancelCatalogLoad()
    if item.acquisitions then
        for i = #item.acquisitions, 1, -1 do
            if item.acquisitions[i].href and not item.acquisitions[i].type then
                table.remove(item.acquisitions, i)
            end
        end
    end
    if item.acquisitions and item.acquisitions[1] then -- book
        logger.dbg("Downloads available:", item)
        -- Show book info dialog first, allowing user to see details before downloading
        local book_info_dialog = BookInfoDialog.build(self, item)
        UIManager:show(book_info_dialog)
    else                         -- catalog or Search item
        if #self.paths == 0 and item.idx == 1 then -- root list, Downloads item
            if #self.downloads > 0 then
                self:showDownloadList()
            end
            return true
        end
        self:openCatalog(item)
    end
    return true
end

--- Show the entries of a catalog, or ask for the terms of a search item.
-- An item of the root list also sets the credentials used for everything below it.
function OPDSBrowser:openCatalog(item)
    self:cancelCatalogLoad()
    local generation = self._catalog_generation
    local root = #self.paths == 0
    local context = BrowserContext.fromBrowser(self)
    if root then
        context.username, context.password = item.username, item.password
        context.basic_auth_origin = RequestHeaders.originKey(item.url) or false
    end
    local connect_callback
    if item.searchable then
        connect_callback = function()
            if self._catalog_generation ~= generation then return end
            if root then
                self.root_catalog_title = item.text
                self.root_catalog_url = item.url
                self.root_catalog_username = item.username
                self.root_catalog_password = item.password
                self.root_catalog_raw_names = item.raw_names
            end
            self:searchCatalog(item.url)
        end
    else
        connect_callback = function()
            if self._catalog_generation ~= generation then return end
            self:updateCatalog(item.url, false, {
                context = context,
                title = item.text or self.catalog_title or self.root_catalog_title,
                root = root and item or nil,
            })
        end
    end
    NetworkMgr:runWhenConnected(connect_callback)
end

--- Open the catalog chosen as default in the settings, if any.
-- It opens on top of the root list, so Back returns to the list of catalogs.
function OPDSBrowser:openDefaultCatalog()
    if #self.paths > 0 then return end
    local server = CatalogManager.findDefaultCatalog(self.servers)
    if server then
        self:openCatalog(CatalogUtils.buildRootEntry(server))
    end
end

-- Menu action on item long-press (dialog Edit / Delete catalog)
function OPDSBrowser:onMenuHold(item)
    if #self.paths > 0 or item.idx == 1 then return true end -- not root list or Downloads item
    local dialog
    dialog = ButtonDialog:new {
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Force sync"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self.sync_force = true
                            self:checkSyncDownload(item.idx)
                        end)
                    end,
                },
                {
                    text = _("Sync"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self.sync_force = false
                            self:checkSyncDownload(item.idx)
                        end)
                    end,
                },
            },
            {},
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new {
                            text = _("Delete OPDS catalog?"),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                UIManager:close(dialog)
                                self:deleteCatalog(item)
                            end,
                        })
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:addEditCatalog(item)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- Menu action on return-arrow tap (go to one-level upper catalog)
function OPDSBrowser:onReturn()
    if self._catalog_job then
        self:cancelCatalogLoad()
        return true
    end
    local path = self.paths[#self.paths - 1]
    if path then
        local paths = {}
        for index = 1, #self.paths - 1 do paths[index] = self.paths[index] end
        self:updateCatalog(path.url, true, { paths = paths, title = path.title })
    else
        -- return to root path, we simply reinit opdsbrowser
        self:init()
    end
    return true
end

-- Menu action on return-arrow long-press (return to root path)
function OPDSBrowser:onHoldReturn()
    self:init()
    return true
end

-- Fetch feed pages sequentially until the requested display page has room ahead.
function OPDSBrowser:fetchAhead(page, done)
    page = page or self.page
    local hrefs = self.item_table.hrefs
    if page + 2 > self.page_num and hrefs and hrefs.next then
        self:appendCatalog(hrefs.next, function(appended, cancelled)
            if appended then
                self:fetchAhead(page, done)
            elseif done then
                done(not cancelled)
            end
        end)
    elseif done then
        done(true)
    end
end

-- Menu action on next-page chevron tap (request and show more catalog entries)
function OPDSBrowser:onNextPage(fill_only)
    self:cancelCatalogLoad()
    self:fetchAhead(nil, function(proceed)
        if proceed and not fill_only then OPDSCoverMenu.onNextPage(self) end
    end)
    return true
end

-- The last-page chevron and the page number dialog land on the last page fetched so far. Fetch ahead
-- for them too, or the next-page chevron stays disabled and the rest of the feed is out of reach.
function OPDSBrowser:onGotoPage(page)
    self:cancelCatalogLoad()
    if page >= self.page_num then
        self:fetchAhead(page, function(proceed)
            if proceed then OPDSCoverMenu.onGotoPage(self, page) end
        end)
        return true
    end
    return OPDSCoverMenu.onGotoPage(self, page)
end

function OPDSBrowser:showDownloadList()
    self.download_list = Menu:new {
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = self.showDownloadListItemDialog,
        _manager = self,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = self.showDownloadListMenu
    }
    self.download_list.close_callback = function()
        UIManager:close(self.download_list)
        self.download_list = nil
        if self.download_list_updated then
            self.download_list_updated = nil
            self.item_table[1].mandatory = #self.downloads
            self:updateItems(1, true)
        end
    end
    self:updateDownloadListItemTable()
    UIManager:show(self.download_list)
end

function OPDSBrowser:showDownloadListMenu()
    local dialog = DownloadDialogBuilder.buildDownloadListMenu(self)
    UIManager:show(dialog)
end

function OPDSBrowser:updateDownloadListItemTable(item_table)
    if item_table == nil then
        item_table = {}
        for i, item in ipairs(self.downloads) do
            item_table[i] = {
                text      = item.file:gsub(".*/", ""),
                mandatory = item.catalog,
            }
        end
    end
    local title = T(_("Downloads (%1)"), #item_table)
    self.download_list:switchItemTable(title, item_table)
end

function OPDSBrowser:confirmDownloadDownloadList()
    local dialog = DownloadDialogBuilder.buildDownloadAllConfirmation(self)
    UIManager:show(dialog)
end

function OPDSBrowser:confirmClearDownloadList()
    local dialog = DownloadDialogBuilder.buildClearQueueConfirmation(self)
    UIManager:show(dialog)
end

function OPDSBrowser:showDownloadListItemDialog(item)
    return DownloadDialogBuilder.buildDownloadListItemDialog(self, item)
end

-- Download whole download list
function OPDSBrowser:downloadDownloadList()
    return DownloadManager.downloadDownloadList(self)
end

function OPDSBrowser:setMaxSyncDownload()
    SyncManager.showMaxSyncDialog(self)
end

function OPDSBrowser:setSyncDir()
    SyncManager.showSyncDirChooser(self)
end

function OPDSBrowser:setSyncFiletypes()
    SyncManager.showFiletypesDialog(self)
end

-- Helper function to get filename and set nil if using raw names
function OPDSBrowser:getFileName(item)
    local filename = item.title
    if item.author then
        filename = item.author .. " - " .. filename
    end
    local filename_orig = filename
    if self.root_catalog_raw_names then
        filename = nil
    end
    return util.replaceAllInvalidChars(filename), util.replaceAllInvalidChars(filename_orig)
end

function OPDSBrowser:updateFieldInCatalog(item, name, value)
    CatalogManager.updateCatalogField(item, name, value)
    StateManager.getInstance():markDirty()
end

function OPDSBrowser:checkSyncDownload(idx)
    SyncManager.checkAndStartSync(self, idx)
end

return OPDSBrowser
