-- Book Info Dialog Builder for OPDS Browser
-- Displays book information with download/queue actions

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local Constants = require("models.constants")
local OPDSPSE = require("services.kavita")
local HttpClient = require("services.http_client")

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
-- @param add_to_queue boolean If true, add to queue instead of download
-- @param parent_dialog table Parent dialog to close
local function showFormatSelectionDialog(browser, item, downloadable, add_to_queue, parent_dialog)
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

					-- Get the current filename at download time (not dialog creation time)
					local filename = browser._custom_filename
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
-- Shows book information with action buttons and cover image
-- @param browser table OPDSBrowser instance
-- @param item table Book item with acquisitions
-- @return table Dialog widget
function BookInfoDialog.build(browser, item)
	local DownloadManager = require("core.download_manager")
	local ImageLoader = require("services.image_loader")

	-- Store custom filename in the browser context for this item
	-- Initialize with default filename
	local base_filename = item.title
	if item.author then
		base_filename = item.author .. " - " .. base_filename
	end
	if browser.root_catalog_raw_names then
		browser._custom_filename = nil
	else
		browser._custom_filename = browser._custom_filename or util.replaceAllInvalidChars(base_filename)
	end

	-- Get PSE and downloadable acquisitions
	local pse_acquisition = getPSEAcquisition(item.acquisitions)
	local downloadable = getDownloadableAcquisitions(item.acquisitions, DownloadManager)

	-- Dialog dimensions
	local screen_width = Screen:getWidth()
	local screen_height = Screen:getHeight()
	local dialog_width = math.floor(screen_width * 0.9)
	local dialog_height = math.floor(screen_height * 0.85)

	-- Cover image dimensions - larger for the dialog
	local cover_height = math.floor(screen_height * 0.25)
	local cover_width = math.floor(cover_height * (2 / 3)) -- book aspect ratio

	-- Cover link for full view and high-res loading
	local cover_link = item.image or item.thumbnail

	-- Function to show full cover
	local function showFullCover()
		if cover_link then
			OPDSPSE:streamPages(cover_link, 1, false,
				browser.root_catalog_username, browser.root_catalog_password)
		end
	end

	-- Build cover widget - make it tappable
	local cover_container
	local dialog_cover_bb = nil -- Track our high-res cover for cleanup
	local cover_image_widget = nil -- Reference to update later

	if item.cover_bb or cover_link then
		-- Create the image widget (start with low-res if available, or placeholder)
		if item.cover_bb then
			cover_image_widget = ImageWidget:new {
				image = item.cover_bb,
				width = cover_width,
				height = cover_height,
				scale_factor = 0,
				alpha = true,
				image_disposable = false, -- Don't free the menu's cover_bb
			}
		else
			-- Placeholder while loading
			cover_image_widget = CenterContainer:new {
				dimen = Geom:new { w = cover_width, h = cover_height },
				TextWidget:new {
					text = "📖",
					face = Font:getFace("cfont", 48),
				},
			}
		end

		-- Wrap in InputContainer to make it tappable
		cover_container = InputContainer:new {
			dimen = Geom:new { w = cover_width, h = cover_height },
			cover_image_widget,
		}
		cover_container.ges_events = {
			TapCover = {
				GestureRange:new {
					ges = "tap",
					range = cover_container.dimen,
				},
			},
		}
		function cover_container:onTapCover()
			showFullCover()
			return true
		end

		-- Load high-res cover asynchronously if we have a URL
		if cover_link then
			local function updateCoverWidget(content)
				-- Render at higher resolution for the dialog
				local target_height = cover_height * 2 -- 2x resolution
				local target_width = cover_width * 2
				local ok, hi_res_bb = pcall(function()
					return RenderImage:renderImageData(
						content,
						#content,
						false,
						target_width,
						target_height
					)
				end)

				if ok and hi_res_bb then
					-- Store for cleanup
					dialog_cover_bb = hi_res_bb

					-- Create new high-res image widget
					local new_cover_widget = ImageWidget:new {
						image = hi_res_bb,
						width = cover_width,
						height = cover_height,
						scale_factor = 0,
						alpha = true,
						image_disposable = false, -- We'll free it ourselves
					}

					-- Update the container
					cover_container[1] = new_cover_widget
					cover_image_widget = new_cover_widget

					-- Refresh the dialog
					UIManager:setDirty(browser.book_info_dialog, "ui")
				end
			end

			-- Start async load
			ImageLoader:loadImages(
				{ cover_link },
				function(loaded_url, content)
					updateCoverWidget(content)
				end,
				browser.root_catalog_username,
				browser.root_catalog_password
			)
		end
	end

	-- Build info text parts
	local info_parts = {}

	-- Author
	if item.author then
		table.insert(info_parts, {
			label = _("Author"),
			value = item.author,
		})
	end

	-- Available formats
	table.insert(info_parts, {
		label = _("Formats"),
		value = formatAvailableFormats(item.acquisitions, DownloadManager),
	})

	-- Build the text info widget
	local text_width = dialog_width - cover_width - Size.padding.large * 4
	if not cover_container then
		text_width = dialog_width - Size.padding.large * 2
	end

	local info_text_parts = {}
	for _, part in ipairs(info_parts) do
		table.insert(info_text_parts, TextBoxWidget.PTF_BOLD_START .. part.label .. ":" .. TextBoxWidget.PTF_BOLD_END)
		table.insert(info_text_parts, " " .. part.value .. "\n")
	end

	local info_widget = TextBoxWidget:new {
		text = TextBoxWidget.PTF_HEADER .. table.concat(info_text_parts),
		width = text_width,
		face = Font:getFace("x_smallinfofont"),
		alignment = "left",
	}

	-- Header row with cover and info
	local header_content
	if cover_container then
		header_content = HorizontalGroup:new {
			align = "top",
			CenterContainer:new {
				dimen = Geom:new { w = cover_width + Size.padding.default, h = cover_height },
				cover_container,
			},
			HorizontalSpan:new { width = Size.padding.default },
			info_widget,
		}
	else
		header_content = info_widget
	end

	-- Description section
	local description_text = _("No description available.")
	if item.content and type(item.content) == "string" then
		description_text = util.htmlToPlainTextIfHtml(item.content)
	end

	-- Calculate remaining height for description
	local title_bar_height = Size.padding.large * 3 -- approximate
	local header_height = cover_container and cover_height or info_widget:getSize().h
	local button_height = Size.padding.large * 4 -- approximate for buttons
	local description_height = dialog_height - title_bar_height - header_height - button_height - Size.padding.large * 4

	local description_widget = ScrollableContainer:new {
		dimen = Geom:new {
			w = dialog_width - Size.padding.large * 2,
			h = math.max(description_height, 100),
		},
		show_parent = browser,
		VerticalGroup:new {
			align = "left",
			VerticalSpan:new { height = Size.padding.small },
			TextBoxWidget:new {
				text = TextBoxWidget.PTF_HEADER .. TextBoxWidget.PTF_BOLD_START .. _("Description") .. TextBoxWidget.PTF_BOLD_END,
				width = dialog_width - Size.padding.large * 4,
				face = Font:getFace("x_smallinfofont"),
			},
			VerticalSpan:new { height = Size.padding.small },
			TextBoxWidget:new {
				text = description_text,
				width = dialog_width - Size.padding.large * 4,
				face = Font:getFace("x_smallinfofont"),
				alignment = "left",
			},
		},
	}

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
	end

	-- Row 2: Download and Queue buttons
	if #downloadable > 0 then
		local action_row = {}

		-- Download button
		if #downloadable == 1 then
			local dl = downloadable[1]
			table.insert(action_row, {
				text = Constants.ICONS.DOWNLOAD .. " " .. _("Download") .. " (" .. string.upper(dl.filetype) .. ")",
				callback = function()
					UIManager:close(browser.book_info_dialog)
					local local_path = DownloadManager.getLocalDownloadPath(
						browser, browser._custom_filename, dl.filetype, dl.acquisition.href)
					DownloadManager.checkDownloadFile(browser, local_path, dl.acquisition.href,
						browser.root_catalog_username, browser.root_catalog_password,
						browser.file_downloaded_callback)
				end,
			})
		else
			table.insert(action_row, {
				text = Constants.ICONS.DOWNLOAD .. " " .. _("Download…"),
				callback = function()
					showFormatSelectionDialog(browser, item, downloadable, false, browser.book_info_dialog)
				end,
			})
		end

		-- Add to queue button
		if #downloadable == 1 then
			local dl = downloadable[1]
			table.insert(action_row, {
				text = "+" .. " " .. _("Queue"),
				callback = function()
					UIManager:close(browser.book_info_dialog)
					local local_path = DownloadManager.getLocalDownloadPath(
						browser, browser._custom_filename, dl.filetype, dl.acquisition.href)
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
				text = "+" .. " " .. _("Queue…"),
				callback = function()
					showFormatSelectionDialog(browser, item, downloadable, true, browser.book_info_dialog)
				end,
			})
		end

		table.insert(buttons_table, action_row)
	end

	-- Row 3: Additional options
	local options_row = {}

	-- View full cover button (only if cover exists)
	if cover_link then
		table.insert(options_row, {
			text = _("Full Cover"),
			callback = showFullCover,
		})
	end

	-- Download options button
	table.insert(options_row, {
		text = _("Options…"),
		callback = function()
			BookInfoDialog.showDownloadOptionsDialog(browser, item)
		end,
	})

	-- Close button
	table.insert(options_row, {
		text = _("Close"),
		callback = function()
			UIManager:close(browser.book_info_dialog)
		end,
	})

	if #options_row > 0 then
		table.insert(buttons_table, options_row)
	end

	-- Create button table widget
	local button_table = ButtonTable:new {
		width = dialog_width - Size.padding.large * 2,
		buttons = buttons_table,
		zero_sep = true,
		show_parent = browser,
	}

	-- Main content layout
	local content = VerticalGroup:new {
		align = "center",
		VerticalSpan:new { height = Size.padding.default },
		header_content,
		VerticalSpan:new { height = Size.padding.default },
		description_widget,
		VerticalSpan:new { height = Size.padding.default },
		button_table,
	}

	-- Title bar
	local title_bar = TitleBar:new {
		title = item.title or _("Book Information"),
		fullscreen = true,
		width = dialog_width,
		with_bottom_line = true,
		bottom_line_color = Blitbuffer.COLOR_DARK_GRAY,
		bottom_line_h_padding = Size.padding.large,
		close_callback = function()
			UIManager:close(browser.book_info_dialog)
		end,
		show_parent = browser,
	}

	-- Frame the content
	local content_frame = FrameContainer:new {
		padding = Size.padding.default,
		padding_top = 0,
		margin = 0,
		bordersize = 0,
		background = Blitbuffer.COLOR_WHITE,
		content,
	}

	-- Complete dialog layout
	local dialog_frame = FrameContainer:new {
		radius = Size.radius.window,
		bordersize = Size.border.window,
		background = Blitbuffer.COLOR_WHITE,
		padding = 0,
		margin = 0,
		VerticalGroup:new {
			align = "center",
			title_bar,
			content_frame,
		},
	}

	-- Create the dialog as an InputContainer for gesture handling
	browser.book_info_dialog = InputContainer:new {
		ignore_events = { "swipe", "pan", "pan_release" },
	}
	browser.book_info_dialog.dimen = Geom:new {
		w = dialog_width,
		h = dialog_height,
	}
	browser.book_info_dialog.movable = MovableContainer:new {
		dialog_frame,
	}
	browser.book_info_dialog[1] = CenterContainer:new {
		dimen = Geom:new {
			w = screen_width,
			h = screen_height,
		},
		browser.book_info_dialog.movable,
	}

	-- Add close on tap outside
	browser.book_info_dialog.ges_events = {
		TapClose = {
			GestureRange:new {
				ges = "tap",
				range = Geom:new {
					x = 0, y = 0,
					w = screen_width,
					h = screen_height,
				},
			},
		},
	}

	function browser.book_info_dialog:onTapClose(arg, ges)
		if ges.pos:notIntersectWith(self.movable.dimen) then
			UIManager:close(self)
			return true
		end
		return false
	end

	function browser.book_info_dialog:onClose()
		UIManager:close(self)
		return true
	end

	function browser.book_info_dialog:onCloseWidget()
		-- Clean up custom filename when dialog closes
		browser._custom_filename = nil
		-- Clean up our high-res dialog cover if we created one
		if dialog_cover_bb then
			dialog_cover_bb:free()
			dialog_cover_bb = nil
		end
		UIManager:setDirty(nil, "ui")
	end

	return browser.book_info_dialog
end

--- Show download options dialog (folder and filename)
-- @param browser table OPDSBrowser instance
-- @param item table Book item
function BookInfoDialog.showDownloadOptionsDialog(browser, item)
	local DownloadManager = require("core.download_manager")

	-- Generate original filename for reset
	local filename_orig = item.title
	if item.author then
		filename_orig = item.author .. " - " .. filename_orig
	end
	filename_orig = util.replaceAllInvalidChars(filename_orig)

	-- Current custom filename or default
	local current_filename = browser._custom_filename or filename_orig

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
						input = current_filename,
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
									text = _("Reset"),
									callback = function()
										-- Reset to original filename
										browser._custom_filename = filename_orig
										UIManager:close(dialog)
									end,
								},
								{
									text = _("Set"),
									is_enter_default = true,
									callback = function()
										local new_filename = dialog:getInputText()
										if new_filename and new_filename ~= "" then
											-- Sanitize the filename
											browser._custom_filename = util.replaceAllInvalidChars(new_filename)
											logger.dbg("Custom filename set to:", browser._custom_filename)
										end
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
		title = T(_("Download Options\n\nFolder: %1\n\nFilename: %2"), BD.dirpath(current_dir), current_filename),
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
