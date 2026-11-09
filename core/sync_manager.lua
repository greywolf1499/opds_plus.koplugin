-- Sync Manager for OPDS Browser
-- Handles catalog synchronization, sync settings, and batch downloads

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Constants = require("models.constants")
local DownloadManager = require("core.download_manager")
local StateManager = require("core.state_manager")
local CatalogUtils = require("utils.catalog_utils")

local SyncManager = {}

--- Show dialog to set maximum number of files to sync
-- @param browser table OPDSBrowser instance
function SyncManager.showMaxSyncDialog(browser)
	local current_max_dl = browser.settings.sync_max_dl or Constants.SYNC.DEFAULT_MAX_DOWNLOADS
	local spin = SpinWidget:new {
		title_text = _("Set maximum sync size"),
		info_text = _("Set the max number of books to download at a time"),
		value = current_max_dl,
		value_min = 0,
		value_max = Constants.SYNC.MAX_DOWNLOADS_LIMIT,
		value_step = Constants.SYNC.STEP,
		value_hold_step = Constants.SYNC.HOLD_STEP,
		default_value = Constants.SYNC.DEFAULT_MAX_DOWNLOADS,
		wrap = true,
		ok_text = _("Save"),
		callback = function(spin)
			browser.settings.sync_max_dl = spin.value
			StateManager.getInstance():markDirty()
		end,
	}
	UIManager:show(spin)
end

--- Show directory chooser for sync folder
-- @param browser table OPDSBrowser instance
function SyncManager.showSyncDirChooser(browser)
	local force_chooser_dir
	if Device:isAndroid() then
		force_chooser_dir = Device.home_dir
	end

	require("ui/downloadmgr"):new {
		onConfirm = function(inbox)
			logger.info("set opds sync folder", inbox)
			browser.settings.sync_dir = inbox
			StateManager.getInstance():markDirty()
		end,
	}:chooseDir(force_chooser_dir)
end

--- Show dialog to set file types to sync
-- @param browser table OPDSBrowser instance
function SyncManager.showFiletypesDialog(browser)
	local input = browser.settings.filetypes
	local dialog
	dialog = InputDialog:new {
		title = _("File types to sync"),
		description = _("A comma separated list of desired filetypes"),
		input_hint = _("epub, mobi"),
		input = input,
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Save"),
					is_enter_default = true,
					callback = function()
						local str = dialog:getInputText()
						browser.settings.filetypes = str ~= "" and str or nil
						StateManager.getInstance():markDirty()
						UIManager:close(dialog)
					end,
				},
			},
		},
	}
	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

--- Parse filetypes string into a lookup table
-- @param filetypes_str string Comma-separated list of filetypes
-- @return table|nil Lookup table of filetypes, or nil if no filter
function SyncManager.parseFiletypes(filetypes_str)
	if not filetypes_str then
		return nil
	end

	local file_list = {}
	for filetype in util.gsplit(filetypes_str, ",") do
		file_list[util.trim(filetype)] = true
	end
	return file_list
end

--- Check if sync is properly configured and start sync process
-- @param browser table OPDSBrowser instance
-- @param server_idx number|nil Index of specific server to sync (nil for all)
function SyncManager.checkAndStartSync(browser, server_idx)
	if not browser.settings.sync_dir then
		UIManager:show(InfoMessage:new {
			text = _("Please choose a folder for sync downloads first"),
		})
		return
	end

	local servers_to_sync = {}
	if server_idx then
		-- A specific server is synced even when its sync option is off (first item is "Downloads", so subtract 1)
		servers_to_sync[1] = browser.servers[server_idx - 1]
	else
		for _, server in ipairs(browser.servers) do
			if server.sync then
				table.insert(servers_to_sync, server)
			end
		end
	end

	if #servers_to_sync == 0 then
		UIManager:show(InfoMessage:new {
			text = _("No catalogs are set to sync.\n\nLong-press a catalog, tap Edit and tick “Sync catalog”."),
		})
		return
	end

	browser.sync = true
	local info = InfoMessage:new {
		text = _("Synchronizing lists…"),
	}
	UIManager:show(info)
	UIManager:forceRePaint()

	-- A failing feed must not leave the progress message on screen or the browser stuck in sync mode.
	local ok, err = pcall(function()
		for _, server in ipairs(servers_to_sync) do
			SyncManager.fillPendingSyncs(browser, server)
		end
	end)

	UIManager:close(info)
	browser.sync = false

	if not ok then
		logger.err("OPDS Plus: sync failed:", err)
		UIManager:show(InfoMessage:new {
			text = T(_("Sync failed:\n%1"), tostring(err)),
		})
		return
	end

	if #browser.pending_syncs > 0 then
		Trapper:wrap(function()
			SyncManager.downloadPendingSyncs(browser)
		end)
	else
		UIManager:show(InfoMessage:new {
			text = _("Up to date!"),
		})
	end
end

--- Fill pending syncs list for a specific server
-- @param browser table OPDSBrowser instance
-- @param server table Server configuration
function SyncManager.fillPendingSyncs(browser, server)
	-- Set browser context for this server
	browser.root_catalog_password  = server.password
	browser.root_catalog_raw_names = server.raw_names
	browser.root_catalog_username  = server.username
	browser.root_catalog_title     = server.title
	browser.sync_server            = server
	browser.sync_server_list       = browser.sync_server_list or {}
	browser.sync_max_dl            = browser.settings.sync_max_dl or Constants.SYNC.DEFAULT_MAX_DOWNLOADS

	local file_list                = SyncManager.parseFiletypes(browser.settings.filetypes)
	local new_last_download        = nil
	local dl_count                 = 1

	local sync_list                = SyncManager.getSyncDownloadList(browser)
	if sync_list then
		for i, entry in ipairs(sync_list) do
			-- Handle Project Gutenberg style entries
			local sub_table = {}
			local item
			if entry.url then
				sub_table = SyncManager.getSyncDownloadList(browser, entry.url) or {}
			end
			if #sub_table > 0 then
				-- Second element has most options, but a sub-feed may only have one entry
				item = sub_table[2] or sub_table[1]
			else
				item = entry
			end

			for j, link in ipairs(item.acquisitions) do
				-- Only save first link in case of several file types
				if i == 1 and j == 1 then
					new_last_download = link.href
				end
				local filetype = DownloadManager.getFiletype(link)
				if filetype then
					if not file_list or file_list[filetype] then
						local filename = browser:getFileName(entry)
						local download_path = browser:getLocalDownloadPath(filename, filetype, link.href)
						if dl_count <= browser.sync_max_dl then
							table.insert(browser.pending_syncs, {
								file = download_path,
								url = link.href,
								username = browser.root_catalog_username,
								password = browser.root_catalog_password,
								catalog = server.url,
								info = CatalogUtils.getDescription(item),
							})
							dl_count = dl_count + 1
						end
						break
					end
				end
			end
		end
	end

	browser.sync_server_list[server.url] = true
	if new_last_download then
		logger.dbg("Updating opds last download for server", server.title, "to", new_last_download)
		browser:updateFieldInCatalog(server, "last_download", new_last_download)
	end
end

--- Get list of books to download for sync
-- @param browser table OPDSBrowser instance
-- @param url_arg string|nil URL to fetch (nil uses sync_server.url)
-- @return table|nil List of entries to sync, or nil if up to date
function SyncManager.getSyncDownloadList(browser, url_arg)
	local sync_table = {}
	local fetch_url = url_arg or browser.sync_server.url
	local sub_table
	local up_to_date = false

	while #sync_table < browser.sync_max_dl and not up_to_date do
		sub_table = browser:genItemTableFromURL(fetch_url)

		-- Handle timeout
		if #sub_table == 0 then
			return sync_table
		end

		local count = 1
		local acquisitions_empty = false

		-- Handle Project Gutenberg style entries
		-- Entries without links (e.g. a notice at the top of the feed) have no url and no acquisitions
		while #sub_table[count].acquisitions == 0 do
			local entry_url = sub_table[count].url
			if entry_url and util.stringEndsWith(entry_url, ".opds") then
				acquisitions_empty = true
				break
			end
			if count == #sub_table then
				return sync_table
			end
			count = count + 1
		end

		-- First entry in table is the newest
		-- If already downloaded, return
		local first_href
		if acquisitions_empty then
			first_href = sub_table[count].url
		else
			first_href = sub_table[count].acquisitions[1].href
		end

		if first_href == browser.sync_server.last_download and not browser.sync_force then
			return nil
		end

		local href
		for i, entry in ipairs(sub_table) do
			if acquisitions_empty then
				if i >= count then
					href = entry.url
				else
					href = nil
				end
			else
				href = entry.acquisitions[1] and entry.acquisitions[1].href
			end

			if href then
				if href == browser.sync_server.last_download and not browser.sync_force then
					up_to_date = true
					break
				else
					table.insert(sync_table, entry)
				end
			end
		end

		if not sub_table.hrefs.next then
			break
		end
		fetch_url = sub_table.hrefs.next
	end

	return sync_table
end

--- Download all pending sync items and handle duplicates
-- @param browser table OPDSBrowser instance
function SyncManager.downloadPendingSyncs(browser)
	local dl_list = browser.pending_syncs
	local duplicate_list = DownloadManager.downloadPendingSyncs(browser, dl_list)

	if duplicate_list and #duplicate_list > 0 then
		SyncManager.showDuplicateFilesDialog(browser, dl_list, duplicate_list)
	end
end

--- Show dialog for handling duplicate files during sync
-- @param browser table OPDSBrowser instance
-- @param dl_list table Download list
-- @param duplicate_list table List of duplicate files
function SyncManager.showDuplicateFilesDialog(browser, dl_list, duplicate_list)
	local duplicate_files = { _("These files are already on the device:") }
	for _, entry in ipairs(duplicate_list) do
		table.insert(duplicate_files, entry.file)
	end
	local text = table.concat(duplicate_files, "\n")

	local textviewer
	textviewer = TextViewer:new {
		title = _("Duplicate files"),
		text = text,
		buttons_table = {
			{
				{
					text = _("Do nothing"),
					callback = function()
						textviewer:onClose()
					end
				},
				{
					text = _("Overwrite"),
					callback = function()
						browser.sync_force = true
						textviewer:onClose()
						for _, entry in ipairs(duplicate_list) do
							table.insert(dl_list, entry)
						end
						Trapper:wrap(function()
							DownloadManager.downloadPendingSyncs(browser, dl_list)
						end)
					end
				},
				{
					text = _("Download copies"),
					callback = function()
						browser.sync_force = true
						textviewer:onClose()
						local copies_dir = "copies"
						local original_dir = util.splitFilePathName(duplicate_list[1].file)
						local copy_download_dir = original_dir .. copies_dir .. "/"
						util.makePath(copy_download_dir)

						for _, entry in ipairs(duplicate_list) do
							local _, file_name = util.splitFilePathName(entry.file)
							local copy_download_path = copy_download_dir .. file_name
							entry.file = copy_download_path
							table.insert(dl_list, entry)
						end

						Trapper:wrap(function()
							DownloadManager.downloadPendingSyncs(browser, dl_list)
						end)
					end
				},
			},
		},
	}
	UIManager:show(textviewer)
end

return SyncManager
