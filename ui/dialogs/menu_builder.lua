-- UI Menu Builder for OPDS Browser
-- Handles construction of all menu dialogs

local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local CheckButton = require("ui/widget/checkbutton")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local ffiUtil = require("ffi/util")
local url = require("socket.url")
local _ = require("gettext")
local T = ffiUtil.template

local Constants = require("models.constants")
local HttpClient = require("services.http_client")
local RequestHeaders = require("utils.request_headers")
local StateManager = require("core.state_manager")
local UrlUtils = require("utils.url_utils")

local OPDSMenuBuilder = {}

-- Build the main OPDS menu (shown at root level)
-- @param browser table OPDSBrowser instance
-- @return table ButtonDialog widget
function OPDSMenuBuilder.buildOPDSMenu(browser)
	local dialog
	dialog = ButtonDialog:new {
		buttons = {
			{ {
				text = _("Add catalog"),
				callback = function()
					UIManager:close(dialog)
					browser:addEditCatalog()
				end,
				align = "left",
			} },
			{},
			{ {
				text = _("Sync all catalogs"),
				callback = function()
					UIManager:close(dialog)
					NetworkMgr:runWhenConnected(function()
						browser.sync_force = false
						browser:checkSyncDownload()
					end)
				end,
				align = "left",
			} },
			{ {
				text = _("Force sync all catalogs"),
				callback = function()
					UIManager:close(dialog)
					NetworkMgr:runWhenConnected(function()
						browser.sync_force = true
						browser:checkSyncDownload()
					end)
				end,
				align = "left",
			} },
			{ {
				text = _("Set max number of files to sync"),
				callback = function()
					browser:setMaxSyncDownload()
				end,
				align = "left",
			} },
			{ {
				text = _("Set sync folder"),
				callback = function()
					browser:setSyncDir()
				end,
				align = "left",
			} },
			{ {
				text = _("Set file types to sync"),
				callback = function()
					browser:setSyncFiletypes()
				end,
				align = "left",
			} },
		},
		shrink_unneeded_width = true,
		anchor = function()
			return browser.title_bar.left_button.image.dimen
		end,
	}
	return dialog
end

-- Build the facet menu (for catalogs with search/facets)
-- @param browser table OPDSBrowser instance
-- @param catalog_url string Current catalog URL
-- @param has_covers boolean Whether current items have covers
-- @return table ButtonDialog widget
function OPDSMenuBuilder.buildFacetMenu(browser, catalog_url, has_covers)
	local buttons = {}
	local dialog

	-- Add view toggle option FIRST if we have covers
	if has_covers then
		local current_mode = StateManager.getInstance():getDisplayMode()
		local toggle_text
		if current_mode == "list" then
			toggle_text = Constants.ICONS.GRID_VIEW .. " " .. _("Switch to Grid View")
		else
			toggle_text = Constants.ICONS.LIST_VIEW .. " " .. _("Switch to List View")
		end

		table.insert(buttons, { {
			text = toggle_text,
			callback = function()
				UIManager:close(dialog)
				browser:toggleViewMode()
			end,
			align = "left",
		} })
		table.insert(buttons, {})
	end

	-- Add sub-catalog to bookmarks option
	table.insert(buttons, { {
		text = Constants.ICONS.ADD_CATALOG .. " " .. _("Add catalog"),
		callback = function()
			UIManager:close(dialog)
			browser:addSubCatalog(catalog_url)
		end,
		align = "left",
	} })
	table.insert(buttons, {})

	-- Add search option if available
	if browser.search_url then
		table.insert(buttons, { {
			text = Constants.ICONS.SEARCH .. " " .. _("Search"),
			callback = function()
				UIManager:close(dialog)
				browser:searchCatalog(browser.search_url)
			end,
			align = "left",
		} })
		table.insert(buttons, {})
	end

	-- Add facet groups
	if browser.facet_groups then
		for group_name, facets in ffiUtil.orderedPairs(browser.facet_groups) do
			table.insert(buttons, {
				{ text = Constants.ICONS.FILTER .. " " .. group_name, enabled = false, align = "left" }
			})

			for __, link in ipairs(facets) do
				local facet_text = link.title
				if link["thr:count"] then
					facet_text = T(_("%1 (%2)"), facet_text, link["thr:count"])
				end
				if link["opds:activeFacet"] == "true" then
					facet_text = "✓ " .. facet_text
				end
				table.insert(buttons, { {
					text = facet_text,
					callback = function()
						UIManager:close(dialog)
						browser:updateCatalog(url.absolute(catalog_url, link.href))
					end,
					align = "left",
				} })
			end
			table.insert(buttons, {})
		end
	end

	dialog = ButtonDialog:new {
		buttons = buttons,
		shrink_unneeded_width = true,
		anchor = function()
			return browser.title_bar.left_button.image.dimen
		end,
	}

	return dialog
end

-- Build the catalog menu (for catalogs without facets but with covers)
-- @param browser table OPDSBrowser instance
-- @param catalog_url string Current catalog URL
-- @param has_covers boolean Whether current items have covers
-- @return table ButtonDialog widget
function OPDSMenuBuilder.buildCatalogMenu(browser, catalog_url, has_covers)
	local buttons = {}
	local dialog

	-- Add view toggle if we have covers
	if has_covers then
		local current_mode = StateManager.getInstance():getDisplayMode()
		local toggle_text
		if current_mode == "list" then
			toggle_text = Constants.ICONS.GRID_VIEW .. " " .. _("Switch to Grid View")
		else
			toggle_text = Constants.ICONS.LIST_VIEW .. " " .. _("Switch to List View")
		end

		table.insert(buttons, { {
			text = toggle_text,
			callback = function()
				UIManager:close(dialog)
				browser:toggleViewMode()
			end,
			align = "left",
		} })
		table.insert(buttons, {})
	end

	-- Add sub-catalog option
	table.insert(buttons, { {
		text = Constants.ICONS.ADD_CATALOG .. " " .. _("Add catalog"),
		callback = function()
			UIManager:close(dialog)
			browser:addSubCatalog(catalog_url)
		end,
		align = "left",
	} })

	dialog = ButtonDialog:new {
		buttons = buttons,
		shrink_unneeded_width = true,
		anchor = function()
			return browser.title_bar.left_button.image.dimen
		end,
	}

	return dialog
end

-- Explain why a line of custom headers was refused
-- @param line_number number Line of the text that was refused
-- @param reason string Reason given by RequestHeaders.parse
-- @param name string|nil Header name on that line, when it is known
-- @return string Message for the user
local function headerErrorText(line_number, reason, name)
	if reason == "name" then
		return T(_("Line %1: invalid header name"), line_number)
	elseif reason == "reserved" then
		return T(_("Line %1: %2 cannot be set here"), line_number, name)
	elseif reason == "value" then
		return T(_("Line %1: missing or invalid header value"), line_number)
	elseif reason == "duplicate" then
		return T(_("Line %1: %2 is listed more than once"), line_number, name)
	end
	return T(_("Line %1: write the header as Name: value"), line_number)
end

-- Build the add/edit catalog dialog
-- @param browser table OPDSBrowser instance
-- @param item table|nil Catalog item to edit (nil for new catalog)
-- @return table MultiInputDialog widget
function OPDSMenuBuilder.buildCatalogEditDialog(browser, item)
	local CatalogManager = require("core.catalog_manager")
	local InfoMessage = require("ui/widget/infomessage")

	local fields = {
		{
			hint = _("Catalog name"),
		},
		{
			hint = _("Catalog URL"),
		},
		{
			hint = _("Username (optional)"),
		},
		{
			hint = _("Password (optional)"),
			text_type = "password",
		},
	}

	local title
	if item then
		title = _("Edit OPDS catalog")
		fields[1].text = item.text
		fields[2].text = item.url
		fields[3].text = item.username
		fields[4].text = item.password
	else
		title = _("Add OPDS catalog")
	end

	-- Edited here and only kept when the catalog is saved
	local headers = RequestHeaders.copy(item and item.headers) or {}

	local dialog, check_button_raw_names, check_button_sync_catalog, check_button_stream_sync

	-- Kept short: it shares the row with Cancel and Save, and a longer label is cut off once a count is added
	local function headersButtonText()
		if #headers == 0 then
			return _("Headers")
		end
		return T(_("Headers (%1)"), #headers)
	end

	local function editHeaders()
		local headers_dialog
		headers_dialog = InputDialog:new {
			title = _("Custom HTTP headers"),
			description = _("One header per line, as Name: value. They are only sent to this catalog's server."),
			input = RequestHeaders.format(headers),
			input_hint = _("Name: value"),
			allow_newline = true,
			use_available_height = true,
			buttons = {
				{
					{
						text = _("Cancel"),
						id = "close",
						callback = function()
							UIManager:close(headers_dialog)
						end,
					},
					{
						text = _("OK"),
						callback = function()
							local list, line_number, reason, name = RequestHeaders.parse(headers_dialog:getInputText())
							if not list then
								UIManager:show(InfoMessage:new {
									text = headerErrorText(line_number, reason, name),
									timeout = 5,
								})
								return -- Don't close dialog, let user fix it
							end
							headers = list
							UIManager:close(headers_dialog)
							local button = dialog.button_table:getButtonById("headers")
							button:setText(headersButtonText(), button.width)
							UIManager:setDirty(dialog, "ui")
						end,
					},
				},
			},
		}
		UIManager:show(headers_dialog)
		headers_dialog:onShowKeyboard()
	end

	dialog = MultiInputDialog:new {
		title = title,
		fields = fields,
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
					text_func = headersButtonText, -- evaluated again whenever KOReader rebuilds the dialog
					id = "headers",
					callback = editHeaders,
				},
				{
					text = _("Save"),
					callback = function()
						local new_fields = dialog:getFields()

						-- Validate URL before saving
						local is_valid, validated_url_or_error = CatalogManager.validateCatalogUrl(new_fields[2])

						if not is_valid then
							-- Show error message
							UIManager:show(InfoMessage:new {
								text = _("Invalid URL: ") .. validated_url_or_error,
								timeout = 3,
							})
							return -- Don't close dialog, let user fix it
						end

						-- Validate catalog name
						if not new_fields[1] or new_fields[1]:match("^%s*$") then
							UIManager:show(InfoMessage:new {
								text = _("Catalog name cannot be empty"),
								timeout = 3,
							})
							return
						end

						-- Use validated URL
						new_fields[2] = validated_url_or_error
						new_fields[5] = check_button_raw_names.checked or nil
						new_fields[6] = check_button_sync_catalog.checked or nil
						new_fields[7] = headers
						new_fields[8] = check_button_stream_sync.checked or nil
						local function save()
							browser:editCatalogFromInput(new_fields, item)
							UIManager:close(dialog)
						end
						if new_fields[8] then
							UIManager:show(require("ui/widget/confirmbox"):new {
								text = _("Enable two-way reading progress for supported Kavita and Komga page streams?\n\nChanges to painted pages are sent to the server. Rewinding can reset progress; Kavita's first page can mark a chapter unread. Sending the final page marks a book complete. Conflicts ask which position to use.\n\nClosing or suspending cancels requests and keeps pending changes locally until reopening. These servers cannot guarantee atomic conflict detection. Downloaded books are not synchronized."),
								ok_text = _("Save and enable"),
								ok_callback = save,
							})
						else
							save()
						end
					end,
				},
			},
		},
	}
	check_button_raw_names = CheckButton:new {
		text = _("Use server filenames"),
		checked = item and item.raw_names,
		parent = dialog,
	}
	check_button_sync_catalog = CheckButton:new {
		text = _("Sync catalog"),
		checked = item and item.sync,
		parent = dialog,
	}
	check_button_stream_sync = CheckButton:new {
		text = _("Sync streaming progress"),
		checked = item and item.stream_sync == true,
		parent = dialog,
	}
	dialog:addWidget(check_button_raw_names)
	dialog:addWidget(check_button_sync_catalog)
	dialog:addWidget(check_button_stream_sync)

	return dialog
end

-- Build the add sub-catalog dialog
-- @param browser table OPDSBrowser instance
-- @param item_url string Catalog URL to add
-- @return table InputDialog widget
function OPDSMenuBuilder.buildSubCatalogDialog(browser, item_url)
	local dialog
	dialog = InputDialog:new {
		title = _("Add OPDS catalog"),
		input = browser.root_catalog_title .. " - " .. browser.catalog_title,
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
						local name = dialog:getInputText()
						if name ~= "" then
							UIManager:close(dialog)
							local username, password = HttpClient.basicCredentialsFor(item_url,
								browser.root_catalog_url, browser.root_catalog_username, browser.root_catalog_password)
							local fields = {
								name,
								item_url,
								username,
								password,
								browser.root_catalog_raw_names,
								nil, -- sync
								HttpClient.customHeadersFor(item_url),
							}
							browser:editCatalogFromInput(fields, nil, true)
						end
					end,
				},
			},
		},
	}

	return dialog
end

-- Build the search catalog dialog
-- @param browser table OPDSBrowser instance
-- @param item_url string Search URL template
-- @return table InputDialog widget
function OPDSMenuBuilder.buildSearchDialog(browser, item_url)
	local util = require("util")

	local dialog
	dialog = InputDialog:new {
		title = _("Search OPDS catalog"),
		input_hint = _("Alexandre Dumas"),
		description = _("%s in url will be replaced by your input"),
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
					text = _("Search"),
					is_enter_default = true,
					callback = function()
						UIManager:close(dialog)
						browser.catalog_title = _("Search results")
						local search_url = UrlUtils.buildSearchUrl(item_url, util.urlEncode(dialog:getInputText()))
						browser:updateCatalog(search_url)
					end,
				},
			},
		},
	}

	return dialog
end

-- Check if current item table has covers
-- @param item_table table Table of catalog items
-- @return boolean True if any item has a cover
function OPDSMenuBuilder.hasCovers(item_table)
	for _, item in ipairs(item_table or {}) do
		if item.cover_url then
			return true
		end
	end
	return false
end

return OPDSMenuBuilder
