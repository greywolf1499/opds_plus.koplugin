-- Settings dialog builders for OPDS Plus
-- Extracted from main.lua for better organization and maintainability

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Constants = require("models.constants")
local _ = require("gettext")
local T = require("ffi/util").template

local SettingsDialogs = {}

--- Show cover size preset selection menu
-- @param plugin table Plugin instance (OPDS main)
function SettingsDialogs.showCoverSizeMenu(plugin)
	local current_preset = plugin:getCurrentPresetName()
	local current_ratio = plugin:getCoverHeightRatio()

	-- Build button list with presets
	local buttons = {}

	-- Add preset buttons
	for i = 1, #Constants.COVER_SIZE_PRESETS do
		local preset = Constants.COVER_SIZE_PRESETS[i]
		local is_current = (current_preset == preset.name)
		local button_text = preset.name
		if is_current then
			button_text = "✓ " .. button_text
		end

		table.insert(buttons, {
			{
				text = button_text,
				callback = function()
					UIManager:close(plugin.cover_size_dialog)
					plugin:setCoverHeightRatio(preset.ratio, preset.name)
					UIManager:show(InfoMessage:new {
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
				UIManager:close(plugin.cover_size_dialog)
				SettingsDialogs.showCustomSizeDialog(plugin)
			end,
		},
	})

	-- Create and show dialog
	plugin.cover_size_dialog = ButtonDialog:new {
		title = _("Cover Size Settings\n\nSelect a preset or choose custom size"),
		title_align = "center",
		buttons = buttons,
	}
	UIManager:show(plugin.cover_size_dialog)
end

--- Show custom cover size spinner dialog
-- @param plugin table Plugin instance (OPDS main)
function SettingsDialogs.showCustomSizeDialog(plugin)
	local current_ratio = plugin:getCoverHeightRatio()
	local current_percent = math.floor(current_ratio * 100)
	local spin_widget
	spin_widget = SpinWidget:new {
		title_text = _("Custom Cover Size"),
		info_text = _("Adjust the size of book covers as a percentage of screen height.\n\n• Smaller values = more books per page\n• Larger values = bigger covers, fewer books per page\n\nRecommended: 8-12% for compact, 15-20% for large"),
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
			plugin:setCoverHeightRatio(new_ratio, "Custom")
			UIManager:show(InfoMessage:new {
				text = T(_("Cover size set to Custom (%1%).\n\nChanges will apply when you next browse a catalog."),
					spin.value),
				timeout = 3,
			})
		end,
		extra_text = _("Back to Presets"),
		extra_callback = function()
			UIManager:close(spin_widget)
			SettingsDialogs.showCoverSizeMenu(plugin)
		end,
	}
	UIManager:show(spin_widget)
end

--- Show font selection menu
-- @param plugin table Plugin instance
-- @param setting_key string Setting key (e.g., "title_font")
-- @param title string Dialog title
function SettingsDialogs.showFontSelectionMenu(plugin, setting_key, title)
	local current_font = plugin:getSetting(setting_key)
	local available_fonts = plugin:getAvailableFonts()

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
					UIManager:close(plugin.font_dialog)
					plugin:saveSetting(setting_key, font_info.value)
					UIManager:show(InfoMessage:new {
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
	plugin.font_dialog = ButtonDialog:new {
		title = T(_("%1 Selection\n\nChoose a font"), title),
		title_align = "center",
		buttons = buttons,
	}
	UIManager:show(plugin.font_dialog)
end

--- Show font size selection spinner
-- @param plugin table Plugin instance
-- @param setting_key string Setting key (e.g., "title_size")
-- @param title string Dialog title
-- @param min_size number Minimum font size
-- @param max_size number Maximum font size
-- @param default_size number Default font size
function SettingsDialogs.showSizeSelectionMenu(plugin, setting_key, title, min_size, max_size, default_size)
	local current_size = plugin:getSetting(setting_key)

	local spin_widget = SpinWidget:new {
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
			plugin:saveSetting(setting_key, spin.value)
			UIManager:show(InfoMessage:new {
				text = T(_("%1 set to %2pt.\n\nChanges will apply when you next browse a catalog."),
					title,
					spin.value),
				timeout = 2,
			})
		end,
	}
	UIManager:show(spin_widget)
end

--- Show grid layout preset menu
-- @param plugin table Plugin instance
function SettingsDialogs.showGridLayoutMenu(plugin)
	local current_columns = plugin.settings.grid_columns or 3
	local current_preset = plugin.settings.grid_size_preset or "Balanced"

	local buttons = {}

	-- Preset buttons with column counts
	local presets = {
		{ name = "Compact",  columns = 4, desc = _("More books per page, smaller covers") },
		{ name = "Balanced", columns = 3, desc = _("Good balance of size and quantity") },
		{ name = "Spacious", columns = 2, desc = _("Fewer books, larger covers") },
	}

	for i, preset in ipairs(presets) do
		local is_current = (current_preset == preset.name and current_columns == preset.columns)
		local button_text = preset.name .. " (" .. preset.columns .. " " .. _("cols") .. ")"
		if is_current then
			button_text = "✓ " .. button_text
		end

		table.insert(buttons, {
			{
				text = button_text,
				callback = function()
					UIManager:close(plugin.grid_layout_dialog)
					plugin.settings.grid_columns = preset.columns
					plugin.settings.grid_size_preset = preset.name
					plugin.opds_settings:saveSetting("settings", plugin.settings)
					plugin.opds_settings:flush()
					UIManager:show(InfoMessage:new {
						text = T(_("Grid layout set to %1\n\n%2\n\nChanges will apply when you next browse a catalog in grid view."),
							preset.name, preset.desc),
						timeout = 2.5,
					})
				end,
			},
		})
	end

	-- Add separator
	table.insert(buttons, {})

	-- Custom option
	local custom_text = _("Custom")
	local is_custom = (current_preset ~= "Compact" and current_preset ~= "Balanced" and current_preset ~= "Spacious")
	if is_custom then
		custom_text = "✓ " .. custom_text .. " (" .. current_columns .. " " .. _("cols") .. ")"
	end

	table.insert(buttons, {
		{
			text = custom_text,
			callback = function()
				UIManager:close(plugin.grid_layout_dialog)
				SettingsDialogs.showGridColumnsMenu(plugin)
			end,
		},
	})

	plugin.grid_layout_dialog = ButtonDialog:new {
		title = _("Grid Layout Presets\n\nChoose how books are displayed in grid view"),
		title_align = "center",
		buttons = buttons,
	}
	UIManager:show(plugin.grid_layout_dialog)
end

--- Show custom grid columns menu
-- @param plugin table Plugin instance
function SettingsDialogs.showGridColumnsMenu(plugin)
	local current_columns = plugin.settings.grid_columns or 3

	local buttons = {}

	for cols = 2, 4 do
		local is_current = (current_columns == cols)
		local button_text = tostring(cols)
		if cols == 2 then
			button_text = button_text .. " " .. _("columns (wider)")
		elseif cols == 3 then
			button_text = button_text .. " " .. _("columns (balanced)")
		else
			button_text = button_text .. " " .. _("columns (compact)")
		end

		if is_current then
			button_text = "✓ " .. button_text
		end

		table.insert(buttons, {
			{
				text = button_text,
				callback = function()
					UIManager:close(plugin.grid_columns_dialog)
					plugin.settings.grid_columns = cols
					plugin.settings.grid_size_preset = "Custom"
					plugin.opds_settings:saveSetting("settings", plugin.settings)
					plugin.opds_settings:flush()
					UIManager:show(InfoMessage:new {
						text = T(_("Grid columns set to %1 (Custom).\n\nChanges will apply when you next browse a catalog in grid mode."), cols),
						timeout = 2,
					})
				end,
			},
		})
	end

	-- Add separator and back button
	table.insert(buttons, {})
	table.insert(buttons, {
		{
			text = "← " .. _("Back to Presets"),
			callback = function()
				UIManager:close(plugin.grid_columns_dialog)
				SettingsDialogs.showGridLayoutMenu(plugin)
			end,
		},
	})

	plugin.grid_columns_dialog = ButtonDialog:new {
		title = _("Custom Grid Columns\n\nManually choose column count"),
		title_align = "center",
		buttons = buttons,
	}
	UIManager:show(plugin.grid_columns_dialog)
end

--- Show grid border style menu
-- @param plugin table Plugin instance
function SettingsDialogs.showGridBorderMenu(plugin)
	local current_style = plugin.settings.grid_border_style or "none"
	local current_size = plugin.settings.grid_border_size or 2
	local current_color = plugin.settings.grid_border_color or "dark_gray"

	local buttons = {}

	-- Border Style Section
	table.insert(buttons, {
		{
			text = _("Border Style"),
			enabled = false,
		},
	})

	local styles = {
		{ id = "none",       name = _("No Borders"),       desc = _("Clean, borderless grid") },
		{ id = "hash",       name = _("Hash Grid"),        desc = _("Shared borders like # pattern") },
		{ id = "individual", name = _("Individual Tiles"), desc = _("Each book has its own border") },
	}

	for i, style in ipairs(styles) do
		local is_current = (current_style == style.id)
		local button_text = style.name
		if is_current then
			button_text = "✓ " .. button_text
		end

		table.insert(buttons, {
			{
				text = button_text,
				callback = function()
					UIManager:close(plugin.grid_border_dialog)
					plugin.settings.grid_border_style = style.id
					plugin.opds_settings:saveSetting("settings", plugin.settings)
					plugin.opds_settings:flush()
					UIManager:show(InfoMessage:new {
						text = T(_("Border style set to: %1\n\n%2\n\nChanges will apply when you next browse a catalog in grid view."),
							style.name, style.desc),
						timeout = 2.5,
					})
				end,
			},
		})
	end

	-- Separator
	table.insert(buttons, {})

	-- Border Customization (only if not "none")
	if current_style ~= "none" then
		table.insert(buttons, {
			{
				text = _("Customize Borders"),
				enabled = false,
			},
		})

		-- Border Size
		table.insert(buttons, {
			{
				text = T(_("Border Thickness: %1px"), current_size),
				callback = function()
					UIManager:close(plugin.grid_border_dialog)
					SettingsDialogs.showGridBorderSizeMenu(plugin)
				end,
			},
		})

		-- Border Color
		local color_display = current_color == "dark_gray" and _("Dark Gray") or
			current_color == "light_gray" and _("Light Gray") or
			_("Black")
		table.insert(buttons, {
			{
				text = T(_("Border Color: %1"), color_display),
				callback = function()
					UIManager:close(plugin.grid_border_dialog)
					SettingsDialogs.showGridBorderColorMenu(plugin)
				end,
			},
		})
	end

	plugin.grid_border_dialog = ButtonDialog:new {
		title = _("Grid Border Settings\n\nCustomize the appearance of grid borders"),
		title_align = "center",
		buttons = buttons,
	}
	UIManager:show(plugin.grid_border_dialog)
end

--- Show border thickness spinner
-- @param plugin table Plugin instance
function SettingsDialogs.showGridBorderSizeMenu(plugin)
	local current_size = plugin.settings.grid_border_size or 2
	local spin_widget
	spin_widget = SpinWidget:new {
		title_text = _("Border Thickness"),
		info_text = _("Adjust the thickness of grid borders.\n\n• Thinner borders = more subtle\n• Thicker borders = more defined\n\nRecommended: 2-3px"),
		value = current_size,
		value_min = 1,
		value_max = 5,
		value_step = 1,
		value_hold_step = 1,
		unit = "px",
		ok_text = _("Apply"),
		default_value = 2,
		callback = function(spin)
			plugin.settings.grid_border_size = spin.value
			plugin.opds_settings:saveSetting("settings", plugin.settings)
			plugin.opds_settings:flush()
			UIManager:show(InfoMessage:new {
				text = T(_("Border thickness set to %1px.\n\nChanges will apply when you next browse a catalog in grid view."),
					spin.value),
				timeout = 2,
			})
		end,
		extra_text = _("Back to Borders"),
		extra_callback = function()
			UIManager:close(spin_widget)
			SettingsDialogs.showGridBorderMenu(plugin)
		end,
	}
	UIManager:show(spin_widget)
end

--- Show border color selection menu
-- @param plugin table Plugin instance
function SettingsDialogs.showGridBorderColorMenu(plugin)
	local current_color = plugin.settings.grid_border_color or "dark_gray"

	local buttons = {}

	local colors = {
		{ id = "light_gray", name = _("Light Gray"), desc = _("Subtle, minimal contrast") },
		{ id = "dark_gray",  name = _("Dark Gray"),  desc = _("Balanced, clear definition") },
		{ id = "black",      name = _("Black"),      desc = _("High contrast, bold borders") },
	}

	for i, color in ipairs(colors) do
		local is_current = (current_color == color.id)
		local button_text = color.name
		if is_current then
			button_text = "✓ " .. button_text
		end

		table.insert(buttons, {
			{
				text = button_text,
				callback = function()
					UIManager:close(plugin.grid_border_color_dialog)
					plugin.settings.grid_border_color = color.id
					plugin.opds_settings:saveSetting("settings", plugin.settings)
					plugin.opds_settings:flush()
					UIManager:show(InfoMessage:new {
						text = T(_("Border color set to: %1\n\n%2\n\nChanges will apply when you next browse a catalog in grid view."),
							color.name, color.desc),
						timeout = 2.5,
					})
				end,
			},
		})
	end

	-- Separator
	table.insert(buttons, {})

	-- Back button
	table.insert(buttons, {
		{
			text = "← " .. _("Back to Border Settings"),
			callback = function()
				UIManager:close(plugin.grid_border_color_dialog)
				SettingsDialogs.showGridBorderMenu(plugin)
			end,
		},
	})

	plugin.grid_border_color_dialog = ButtonDialog:new {
		title = _("Border Color\n\nChoose the color for grid borders"),
		title_align = "center",
		buttons = buttons,
	}
	UIManager:show(plugin.grid_border_color_dialog)
end

return SettingsDialogs
