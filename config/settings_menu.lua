local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local Version = require("opds_plus_version")

local SettingsMenu = {}

function SettingsMenu.create(plugin)
	return {
		{
			text = _("Browse Catalogs"),
			callback = function()
				plugin:onShowOPDSCatalog()
			end,
		},
		{
			text = _("Settings"),
			sub_item_table = {
				{
					text = _("Display Mode"),
					sub_item_table = {
						{
							text = _("List View"),
							checked_func = function()
								local mode = plugin.settings.display_mode
								return mode == "list" or mode == nil
							end,
							callback = function()
								plugin.settings.display_mode = "list"
								plugin.opds_settings:saveSetting("settings", plugin.settings)
								plugin.opds_settings:flush()
								UIManager:show(InfoMessage:new {
									text = _("Display mode set to List View.\n\nChanges will apply when you next browse a catalog."),
									timeout = 2,
								})
							end,
						},
						{
							text = _("Grid View"),
							checked_func = function()
								return plugin.settings.display_mode == "grid"
							end,
							callback = function()
								plugin.settings.display_mode = "grid"
								plugin.opds_settings:saveSetting("settings", plugin.settings)
								plugin.opds_settings:flush()
								UIManager:show(InfoMessage:new {
									text = _("Display mode set to Grid View.\n\nChanges will apply when you next browse a catalog."),
									timeout = 2,
								})
							end,
						},
					},
				},
				{
					text = _("List View Settings"),
					sub_item_table = {
						{
							text = _("Cover Size"),
							callback = function()
								plugin:showCoverSizeMenu()
							end,
						},
					},
				},
				{
					text = _("Grid View Settings"),
					sub_item_table = {
						{
							text = _("Grid Layout"),
							callback = function()
								plugin:showGridLayoutMenu()
							end,
						},
						{
							text = _("Grid Borders"),
							callback = function()
								plugin:showGridBorderMenu()
							end,
						},
					},
				},
				{
					text = _("Font & Text"),
					sub_item_table = {
						{
							text = _("Use Same Font for All"),
							checked_func = function()
								return plugin:getSetting("use_same_font")
							end,
							callback = function()
								local current = plugin:getSetting("use_same_font")
								plugin:saveSetting("use_same_font", not current)
								UIManager:show(InfoMessage:new {
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
										plugin:showFontSelectionMenu("title_font", _("Title Font"))
									end,
								},
								{
									text = _("Title Size"),
									callback = function()
										plugin:showSizeSelectionMenu("title_size", _("Title Font Size"), 12, 24, 16)
									end,
								},
								{
									text = _("Title Bold"),
									checked_func = function()
										return plugin:getSetting("title_bold")
									end,
									callback = function()
										local current = plugin:getSetting("title_bold")
										plugin:saveSetting("title_bold", not current)
										UIManager:show(InfoMessage:new {
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
										return not plugin:getSetting("use_same_font")
									end,
									callback = function()
										plugin:showFontSelectionMenu("info_font", _("Information Font"))
									end,
								},
								{
									text = _("Info Size"),
									callback = function()
										plugin:showSizeSelectionMenu("info_size", _("Information Font Size"), 10,
											20, 14)
									end,
								},
								{
									text = _("Info Bold"),
									checked_func = function()
										return plugin:getSetting("info_bold")
									end,
									callback = function()
										local current = plugin:getSetting("info_bold")
										plugin:saveSetting("info_bold", not current)
										UIManager:show(InfoMessage:new {
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
												return plugin:getSetting("info_color") == "dark_gray"
											end,
											callback = function()
												plugin:saveSetting("info_color", "dark_gray")
												UIManager:show(InfoMessage:new {
													text = _("Information text color set to dark gray."),
													timeout = 2,
												})
											end,
										},
										{
											text = _("Black (High Contrast)"),
											checked_func = function()
												return plugin:getSetting("info_color") == "black"
											end,
											callback = function()
												plugin:saveSetting("info_color", "black")
												UIManager:show(InfoMessage:new {
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
				{
					text = _("Developer"),
					sub_item_table = {
						{
							text = _("Debug Mode"),
							checked_func = function()
								return plugin.settings.debug_mode == true
							end,
							callback = function()
								plugin.settings.debug_mode = not plugin.settings.debug_mode
								plugin.opds_settings:saveSetting("settings", plugin.settings)
								plugin.opds_settings:flush()
								UIManager:show(InfoMessage:new {
									text = plugin.settings.debug_mode and
										_("Debug mode enabled.\n\nDetailed logging is now active.") or
										_("Debug mode disabled.\n\nNormal logging restored."),
									timeout = 2,
								})
							end,
						},
					},
				},
				{
					text = T(_("About OPDS Plus v%1"), Version.VERSION),
					callback = function()
						UIManager:show(InfoMessage:new {
							text = T(_("OPDS Plus Plugin\nVersion: %1\n\nAn enhanced OPDS catalog browser with cover display support.\n\nFeatures:\n• List and Grid view modes\n• Customizable covers and fonts\n• Grid border options\n\nBased on KOReader's OPDS plugin"), Version.VERSION),
							timeout = 5,
						})
					end,
				},
			},
		},
	}
end

return SettingsMenu
