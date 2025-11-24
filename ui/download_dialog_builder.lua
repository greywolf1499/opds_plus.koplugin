-- Download Dialog Builder for OPDS Browser
-- Handles construction of download-related dialogs

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")

local Constants = require("models.constants")
local OPDSPSE = require("opdspse")

local DownloadDialogBuilder = {}

-- Build the download/stream selection dialog for a book
-- @param browser table OPDSBrowser instance
-- @param item table Book item with acquisitions
-- @param filename string Suggested filename
-- @param createTitle function Function to create dialog title
-- @return table ButtonDialog widget
function DownloadDialogBuilder.buildDownloadDialog(browser, item, filename, createTitle)
	local acquisitions = item.acquisitions
	local buttons = {}
	local stream_buttons
	local download_buttons = {}
	local DownloadManager = require("download_manager")

	-- Track the original filename for reset
	local filename_orig = filename

	for i, acquisition in ipairs(acquisitions) do
		if acquisition.count then
			-- PSE Stream buttons
			stream_buttons = {
				{
					{
						text = Constants.ICONS.STREAM_START .. " " .. _("Page stream"),
						callback = function()
							OPDSPSE:streamPages(acquisition.href, acquisition.count, false,
								browser.root_catalog_username, browser.root_catalog_password)
							UIManager:close(browser.download_dialog)
						end,
					},
					{
						text = _("Stream from page") .. " " .. Constants.ICONS.STREAM_NEXT,
						callback = function()
							OPDSPSE:streamPages(acquisition.href, acquisition.count, true,
								browser.root_catalog_username, browser.root_catalog_password)
							UIManager:close(browser.download_dialog)
						end,
					},
				},
			}

			if acquisition.last_read then
				table.insert(stream_buttons, {
					{
						text = Constants.ICONS.STREAM_RESUME .. " " ..
							_("Resume stream from page") .. " " .. acquisition.last_read,
						callback = function()
							OPDSPSE:streamPages(acquisition.href, acquisition.count, false,
								browser.root_catalog_username, browser.root_catalog_password,
								acquisition.last_read)
							UIManager:close(browser.download_dialog)
						end,
					},
				})
			end
		elseif acquisition.type == "borrow" then
			table.insert(download_buttons, {
				text = _("Borrow"),
				enabled = false,
			})
		else
			local filetype = DownloadManager.getFiletype(acquisition)
			if filetype then
				local text = url.unescape(acquisition.title or string.upper(filetype))
				table.insert(download_buttons, {
					text = text .. Constants.ICONS.DOWNLOAD,
					callback = function()
						UIManager:close(browser.download_dialog)
						local local_path = DownloadManager.getLocalDownloadPath(
							browser, filename, filetype, acquisition.href)
						DownloadManager.checkDownloadFile(browser, local_path, acquisition.href,
							browser.root_catalog_username, browser.root_catalog_password,
							browser.file_downloaded_callback)
					end,
					hold_callback = function()
						UIManager:close(browser.download_dialog)
						local local_path = DownloadManager.getLocalDownloadPath(
							browser, filename, filetype, acquisition.href)
						DownloadManager.addToDownloadQueue(browser, {
							file     = local_path,
							url      = acquisition.href,
							info     = type(item.content) == "string" and util.htmlToPlainTextIfHtml(item.content) or "",
							catalog  = browser.root_catalog_title,
							username = browser.root_catalog_username,
							password = browser.root_catalog_password,
						})
					end,
				})
			end
		end
	end

	-- Build final button array
	if stream_buttons then
		for _, button_row in ipairs(stream_buttons) do
			table.insert(buttons, button_row)
		end
		if #download_buttons > 0 then
			table.insert(buttons, {})
		end
	end
	for _, button in ipairs(download_buttons) do
		table.insert(buttons, { button })
	end

	-- Add static options (Choose Folder, Change Filename, Book Cover, Book Information)
	table.insert(buttons, {})
	table.insert(buttons, {
		{
			text = _("Choose folder"),
			callback = function()
				require("ui/downloadmgr"):new {
					onConfirm = function(path)
						logger.dbg("Download folder set to", path)
						G_reader_settings:saveSetting("download_dir", path)
						browser.download_dialog:setTitle(createTitle(path, filename))
					end,
				}:chooseDir(DownloadManager.getCurrentDownloadDir(browser))
			end,
		},
		{
			text = _("Change filename"),
			callback = function()
				local dialog
				dialog = InputDialog:new {
					title = _("Enter filename"),
					input = filename or filename_orig,
					input_hint = filename_orig,
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
								text = _("Set filename"),
								is_enter_default = true,
								callback = function()
									filename = dialog:getInputValue()
									if filename == "" then
										filename = filename_orig
									end
									UIManager:close(dialog)
									browser.download_dialog:setTitle(createTitle(
										DownloadManager.getCurrentDownloadDir(browser), filename))
								end,
							},
						}
					},
				}
				UIManager:show(dialog)
				dialog:onShowKeyboard()
			end,
		},
	})

	-- Get cover link (prefer full image over thumbnail for viewing)
	local cover_link = item.image or item.thumbnail

	table.insert(buttons, {
		{
			text = _("Book cover"),
			enabled = cover_link and true or false,
			callback = function()
				-- Use PSE streaming to view the cover as a single page
				OPDSPSE:streamPages(cover_link, 1, false,
					browser.root_catalog_username, browser.root_catalog_password)
			end,
		},
		{
			text = _("Book information"),
			enabled = type(item.content) == "string",
			callback = function()
				UIManager:show(TextViewer:new {
					title = item.text,
					title_multilines = true,
					text = util.htmlToPlainTextIfHtml(item.content),
					text_type = "book_info",
				})
			end,
		},
	})

	return ButtonDialog:new {
		title = createTitle(DownloadManager.getCurrentDownloadDir(browser), filename),
		buttons = buttons,
	}
end

-- Build the download list menu dialog
-- @param download_list_browser table Download list browser instance (not main browser)
-- @return table ButtonDialog widget
function DownloadDialogBuilder.buildDownloadListMenu(download_list_browser)
	local dialog
	dialog = ButtonDialog:new {
		buttons = {
			{
				{
					text = _("Download all"),
					callback = function()
						UIManager:close(dialog)
						-- Call on the parent manager, not the download list browser
						download_list_browser._manager:confirmDownloadDownloadList()
					end,
				},
			},
			{
				{
					text = _("Remove all"),
					callback = function()
						UIManager:close(dialog)
						-- Call on the parent manager, not the download list browser
						download_list_browser._manager:confirmClearDownloadList()
					end,
				},
			},
		},
		shrink_unneeded_width = true,
		anchor = function()
			return download_list_browser.title_bar.left_button.image.dimen
		end,
	}
	return dialog
end

-- Build dialog for individual download list item
-- @param download_list_browser table Download list browser instance
-- @param item table Download item
-- @return boolean True if dialog was shown
function DownloadDialogBuilder.buildDownloadListItemDialog(download_list_browser, item)
	local dl_item = download_list_browser._manager.downloads[item.idx]
	local textviewer
	local DownloadManager = require("download_manager")

	local function remove_item()
		textviewer:onClose()
		table.remove(download_list_browser._manager.downloads, item.idx)
		table.remove(download_list_browser.item_table, item.idx)
		download_list_browser._manager:updateDownloadListItemTable(download_list_browser.item_table)
		download_list_browser._manager.download_list_updated = true
		download_list_browser._manager._manager.updated = true
	end

	local buttons_table = {
		{
			{
				text = _("Remove"),
				callback = function()
					remove_item()
				end,
			},
			{
				text = _("Download"),
				callback = function()
					local function file_downloaded_callback(local_path)
						remove_item()
						download_list_browser._manager.file_downloaded_callback(local_path)
					end
					NetworkMgr:runWhenConnected(function()
						DownloadManager.checkDownloadFile(download_list_browser._manager, dl_item.file, dl_item.url,
							dl_item.username, dl_item.password, file_downloaded_callback)
					end)
				end,
			},
		},
		{}, -- separator
		{
			{
				text = _("Remove all"),
				callback = function()
					textviewer:onClose()
					download_list_browser._manager:confirmClearDownloadList()
				end,
			},
			{
				text = _("Download all"),
				callback = function()
					textviewer:onClose()
					download_list_browser._manager:confirmDownloadDownloadList()
				end,
			},
		},
	}

	local TextBoxWidget = require("ui/widget/textboxwidget")
	local text = table.concat({
		TextBoxWidget.PTF_HEADER,
		TextBoxWidget.PTF_BOLD_START, _("Folder"), TextBoxWidget.PTF_BOLD_END, "\n",
		util.splitFilePathName(dl_item.file), "\n", "\n",
		TextBoxWidget.PTF_BOLD_START, _("File"), TextBoxWidget.PTF_BOLD_END, "\n",
		item.text, "\n", "\n",
		TextBoxWidget.PTF_BOLD_START, _("Description"), TextBoxWidget.PTF_BOLD_END, "\n",
		dl_item.info,
	})

	textviewer = TextViewer:new {
		title = dl_item.catalog,
		text = text,
		text_type = "book_info",
		buttons_table = buttons_table,
	}
	UIManager:show(textviewer)
	return true
end

-- Build confirmation dialog for downloading all items
-- @param browser table OPDSBrowser instance
-- @return table ConfirmBox widget
function DownloadDialogBuilder.buildDownloadAllConfirmation(browser)
	return ConfirmBox:new {
		text = _("Download all books?\nExisting files will be overwritten."),
		ok_text = _("Download"),
		ok_callback = function()
			NetworkMgr:runWhenConnected(function()
				Trapper:wrap(function()
					local DownloadManager = require("download_manager")
					DownloadManager.downloadDownloadList(browser)
				end)
			end)
		end,
	}
end

-- Build confirmation dialog for clearing download queue
-- @param browser table OPDSBrowser instance
-- @return table ConfirmBox widget
function DownloadDialogBuilder.buildClearQueueConfirmation(browser)
	return ConfirmBox:new {
		text = _("Remove all downloads?"),
		ok_text = _("Remove"),
		ok_callback = function()
			local DownloadManager = require("download_manager")
			DownloadManager.clearDownloadQueue(browser)
			browser.download_list:close_callback()
		end,
	}
end

return DownloadDialogBuilder
