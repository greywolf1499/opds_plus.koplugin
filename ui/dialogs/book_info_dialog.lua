-- Book Info Dialog Builder for OPDS Browser
-- Displays book information with download/queue actions

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Constants = require("models.constants")
local OPDSPSE = require("services.kavita")

local BookInfoDialog = {}

--- Format available download formats as a string
-- @param acquisitions table List of acquisition links
-- @param DownloadManager table DownloadManager module
-- @return string Formatted list of available formats
local function formatAvailableFormats(acquisitions, DownloadManager)
	local formats = {}
	for _, acquisition in ipairs(acquisitions) do
		if acquisition.count then
			-- PSE streaming
			table.insert(formats, _("Stream") .. " (" .. acquisition.count .. " " .. _("pages") .. ")")
		elseif acquisition.type == "borrow" then
			table.insert(formats, _("Borrow"))
		else
			local filetype = DownloadManager.getFiletype(acquisition)
			if filetype then
				table.insert(formats, string.upper(filetype))
			end
		end
	end
	if #formats == 0 then
		return _("None available")
	end
	return table.concat(formats, ", ")
end

--- Build the book information text with formatting
-- @param item table Book item
-- @param DownloadManager table DownloadManager module
-- @return string Formatted book information text
local function buildBookInfoText(item, DownloadManager)
	local parts = { TextBoxWidget.PTF_HEADER }

	-- Author (if available and different from title display)
	if item.author then
		table.insert(parts, TextBoxWidget.PTF_BOLD_START)
		table.insert(parts, _("Author"))
		table.insert(parts, TextBoxWidget.PTF_BOLD_END)
		table.insert(parts, "\n")
		table.insert(parts, item.author)
		table.insert(parts, "\n\n")
	end

	-- Available formats
	table.insert(parts, TextBoxWidget.PTF_BOLD_START)
	table.insert(parts, _("Available Formats"))
	table.insert(parts, TextBoxWidget.PTF_BOLD_END)
	table.insert(parts, "\n")
	table.insert(parts, formatAvailableFormats(item.acquisitions, DownloadManager))
	table.insert(parts, "\n\n")

	-- Description/Summary
	if item.content and type(item.content) == "string" then
		table.insert(parts, TextBoxWidget.PTF_BOLD_START)
		table.insert(parts, _("Description"))
		table.insert(parts, TextBoxWidget.PTF_BOLD_END)
		table.insert(parts, "\n")
		table.insert(parts, util.htmlToPlainTextIfHtml(item.content))
	else
		table.insert(parts, _("No description available."))
	end

	return table.concat(parts)
end

--- Check if item has PSE streaming available
-- @param acquisitions table List of acquisitions
-- @return table|nil PSE acquisition or nil
local function getPSEAcquisition(acquisitions)
	for _, acquisition in ipairs(acquisitions) do
		if acquisition.count then
			return acquisition
		end
	end
	return nil
end

--- Get downloadable acquisitions (non-PSE, non-borrow)
-- @param acquisitions table List of acquisitions
-- @param DownloadManager table DownloadManager module
-- @return table List of downloadable acquisitions with filetype
local function getDownloadableAcquisitions(acquisitions, DownloadManager)
	local downloadable = {}
	for _, acquisition in ipairs(acquisitions) do
		if not acquisition.count and acquisition.type ~= "borrow" then
			local filetype = DownloadManager.getFiletype(acquisition)
			if filetype then
				table.insert(downloadable, {
					acquisition = acquisition,
					filetype = filetype,
				})
			end
		end
	end
	return downloadable
end

--- Show format selection dialog for download
-- @param browser table OPDSBrowser instance
-- @param item table Book item
-- @param downloadable table List of downloadable acquisitions
-- @param filename string Filename to use
-- @param add_to_queue boolean If true, add to queue instead of download
-- @param parent_dialog table Parent dialog to close
local function showFormatSelectionDialog(browser, item, downloadable, filename, add_to_queue, parent_dialog)
	local DownloadManager = require("core.download_manager")
	local buttons = {}

	for _, dl in ipairs(downloadable) do
		local text = url.unescape(dl.acquisition.title or string.upper(dl.filetype))
		table.insert(buttons, {
			{
				text = text,
				callback = function()
					UIManager:close(browser.format_dialog)
					if parent_dialog then
						UIManager:close(parent_dialog)
					end

					local local_path = DownloadManager.getLocalDownloadPath(
						browser, filename, dl.filetype, dl.acquisition.href)

					if add_to_queue then
						DownloadManager.addToDownloadQueue(browser, {
							file     = local_path,
							url      = dl.acquisition.href,
							info     = type(item.content) == "string" and util.htmlToPlainTextIfHtml(item.content) or "",
							catalog  = browser.root_catalog_title,
							username = browser.root_catalog_username,
							password = browser.root_catalog_password,
						})
					else
						DownloadManager.checkDownloadFile(browser, local_path, dl.acquisition.href,
							browser.root_catalog_username, browser.root_catalog_password,
							browser.file_downloaded_callback)
					end
				end,
			},
		})
	end

	-- Add cancel button
	table.insert(buttons, {})
	table.insert(buttons, {
		{
			text = _("Cancel"),
			callback = function()
				UIManager:close(browser.format_dialog)
			end,
		},
	})

	local title = add_to_queue and _("Select format to queue") or _("Select format to download")

	browser.format_dialog = ButtonDialog:new {
		title = title,
		buttons = buttons,
	}
	UIManager:show(browser.format_dialog)
end

--- Build the book info dialog
-- Shows book information with action buttons
-- @param browser table OPDSBrowser instance
-- @param item table Book item with acquisitions
-- @return table TextViewer widget
function BookInfoDialog.build(browser, item)
	local DownloadManager = require("core.download_manager")

	-- Generate filename
	local filename = item.title
	if item.author then
		filename = item.author .. " - " .. filename
	end
	if browser.root_catalog_raw_names then
		filename = nil
	else
		filename = util.replaceAllInvalidChars(filename)
	end

	-- Build info text
	local info_text = buildBookInfoText(item, DownloadManager)

	-- Get PSE and downloadable acquisitions
	local pse_acquisition = getPSEAcquisition(item.acquisitions)
	local downloadable = getDownloadableAcquisitions(item.acquisitions, DownloadManager)

	-- Build buttons
	local buttons_table = {}

	-- Row 1: Stream buttons (if PSE available)
	if pse_acquisition then
		local stream_row = {
			{
				text = Constants.ICONS.STREAM_START .. " " .. _("Stream"),
				callback = function()
					UIManager:close(browser.book_info_dialog)
					OPDSPSE:streamPages(pse_acquisition.href, pse_acquisition.count, false,
						browser.root_catalog_username, browser.root_catalog_password)
				end,
			},
		}

		if pse_acquisition.last_read then
			table.insert(stream_row, {
				text = Constants.ICONS.STREAM_RESUME .. " " .. _("Resume") .. " (" .. pse_acquisition.last_read .. ")",
				callback = function()
					UIManager:close(browser.book_info_dialog)
					OPDSPSE:streamPages(pse_acquisition.href, pse_acquisition.count, false,
						browser.root_catalog_username, browser.root_catalog_password,
						pse_acquisition.last_read)
				end,
			})
		end

		table.insert(buttons_table, stream_row)
		table.insert(buttons_table, {}) -- separator
	end

	-- Row 2: Download and Queue buttons
	if #downloadable > 0 then
		local action_row = {}

		-- Download button
		if #downloadable == 1 then
			-- Single format - download directly
			local dl = downloadable[1]
			table.insert(action_row, {
				text = Constants.ICONS.DOWNLOAD .. " " .. _("Download") .. " (" .. string.upper(dl.filetype) .. ")",
				callback = function()
					UIManager:close(browser.book_info_dialog)
					local local_path = DownloadManager.getLocalDownloadPath(
						browser, filename, dl.filetype, dl.acquisition.href)
					DownloadManager.checkDownloadFile(browser, local_path, dl.acquisition.href,
						browser.root_catalog_username, browser.root_catalog_password,
						browser.file_downloaded_callback)
				end,
			})
		else
			-- Multiple formats - show selection
			table.insert(action_row, {
				text = Constants.ICONS.DOWNLOAD .. " " .. _("Download…"),
				callback = function()
					showFormatSelectionDialog(browser, item, downloadable, filename, false, browser.book_info_dialog)
				end,
			})
		end

		-- Add to queue button
		if #downloadable == 1 then
			local dl = downloadable[1]
			table.insert(action_row, {
				text = "+" .. " " .. _("Add to Queue"),
				callback = function()
					UIManager:close(browser.book_info_dialog)
					local local_path = DownloadManager.getLocalDownloadPath(
						browser, filename, dl.filetype, dl.acquisition.href)
					DownloadManager.addToDownloadQueue(browser, {
						file     = local_path,
						url      = dl.acquisition.href,
						info     = type(item.content) == "string" and util.htmlToPlainTextIfHtml(item.content) or "",
						catalog  = browser.root_catalog_title,
						username = browser.root_catalog_username,
						password = browser.root_catalog_password,
					})
				end,
			})
		else
			table.insert(action_row, {
				text = "+" .. " " .. _("Add to Queue…"),
				callback = function()
					showFormatSelectionDialog(browser, item, downloadable, filename, true, browser.book_info_dialog)
				end,
			})
		end

		table.insert(buttons_table, action_row)
	end

	-- Row 3: Additional options
	local options_row = {}

	-- View full cover button
	local cover_link = item.image or item.thumbnail
	if cover_link then
		table.insert(options_row, {
			text = _("View Cover"),
			callback = function()
				OPDSPSE:streamPages(cover_link, 1, false,
					browser.root_catalog_username, browser.root_catalog_password)
			end,
		})
	end

	-- Download options button (folder/filename)
	table.insert(options_row, {
		text = _("Options…"),
		callback = function()
			BookInfoDialog.showDownloadOptionsDialog(browser, item, filename)
		end,
	})

	if #options_row > 0 then
		table.insert(buttons_table, {}) -- separator
		table.insert(buttons_table, options_row)
	end

	-- Create the dialog
	browser.book_info_dialog = TextViewer:new {
		title = item.title or _("Book Information"),
		title_multilines = true,
		text = info_text,
		text_type = "book_info",
		buttons_table = buttons_table,
	}

	return browser.book_info_dialog
end

--- Show download options dialog (folder and filename)
-- @param browser table OPDSBrowser instance
-- @param item table Book item
-- @param filename string Current filename
function BookInfoDialog.showDownloadOptionsDialog(browser, item, filename)
	local DownloadManager = require("core.download_manager")

	-- Generate original filename for reset
	local filename_orig = item.title
	if item.author then
		filename_orig = item.author .. " - " .. filename_orig
	end
	filename_orig = util.replaceAllInvalidChars(filename_orig)

	local buttons = {
		{
			{
				text = _("Choose folder"),
				callback = function()
					UIManager:close(browser.options_dialog)
					require("ui/downloadmgr"):new {
						onConfirm = function(path)
							logger.dbg("Download folder set to", path)
							G_reader_settings:saveSetting("download_dir", path)
						end,
					}:chooseDir(DownloadManager.getCurrentDownloadDir(browser))
				end,
			},
		},
		{
			{
				text = _("Change filename"),
				callback = function()
					UIManager:close(browser.options_dialog)
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
										-- Note: filename changes won't persist in the current implementation
										-- This is a limitation we can address later
										UIManager:close(dialog)
									end,
								},
							}
						},
					}
					UIManager:show(dialog)
					dialog:onShowKeyboard()
				end,
			},
		},
		{}, -- separator
		{
			{
				text = _("Close"),
				callback = function()
					UIManager:close(browser.options_dialog)
				end,
			},
		},
	}

	local current_dir = DownloadManager.getCurrentDownloadDir(browser)

	browser.options_dialog = ButtonDialog:new {
		title = T(_("Download Options\n\nCurrent folder:\n%1"), BD.dirpath(current_dir)),
		buttons = buttons,
	}
	UIManager:show(browser.options_dialog)
end

--- Show the book info dialog
-- Convenience function to build and display the dialog
-- @param browser table OPDSBrowser instance
-- @param item table Book item
function BookInfoDialog.show(browser, item)
	local dialog = BookInfoDialog.build(browser, item)
	UIManager:show(dialog)
end

return BookInfoDialog
