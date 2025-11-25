-- Button Dialog Builder Utility
-- Provides fluent API for building ButtonDialog widgets with common patterns

local ButtonDialog = require("ui/widget/buttondialog")

local ButtonDialogBuilder = {}

--- Create a new builder instance
-- @return table Builder instance
function ButtonDialogBuilder:new()
	local o = {
		_title = "",
		_title_align = "center",
		_buttons = {},
	}
	setmetatable(o, self)
	self.__index = self
	return o
end

--- Set dialog title
-- @param title string Dialog title
-- @return table Builder instance for chaining
function ButtonDialogBuilder:setTitle(title)
	self._title = title
	return self
end

--- Set title alignment
-- @param align string Alignment ("left", "center", "right")
-- @return table Builder instance for chaining
function ButtonDialogBuilder:setTitleAlign(align)
	self._title_align = align
	return self
end

--- Add a single button
-- @param text string Button text
-- @param callback function Button callback
-- @param enabled boolean Optional - whether button is enabled (default: true)
-- @return table Builder instance for chaining
function ButtonDialogBuilder:addButton(text, callback, enabled)
	if enabled == nil then enabled = true end

	table.insert(self._buttons, {
		{
			text = text,
			callback = callback,
			enabled = enabled,
		},
	})
	return self
end

--- Add multiple buttons in a row
-- @param buttons table Array of {text, callback, enabled} tables
-- @return table Builder instance for chaining
function ButtonDialogBuilder:addButtonRow(buttons)
	local row = {}
	for _, btn in ipairs(buttons) do
		table.insert(row, {
			text = btn.text or btn[1],
			callback = btn.callback or btn[2],
			enabled = btn.enabled == nil and true or btn.enabled,
		})
	end
	table.insert(self._buttons, row)
	return self
end

--- Add a separator (empty row)
-- @return table Builder instance for chaining
function ButtonDialogBuilder:addSeparator()
	table.insert(self._buttons, {})
	return self
end

--- Add a header/label button (non-clickable)
-- @param text string Label text
-- @return table Builder instance for chaining
function ButtonDialogBuilder:addLabel(text)
	table.insert(self._buttons, {
		{
			text = text,
			enabled = false,
		},
	})
	return self
end

--- Add options with checkmark for current selection
-- @param options table Array of option objects with {name, value, ...}
-- @param current any Current selected value
-- @param callback function Callback receiving selected option
-- @param name_field string Optional - field name for option name (default: "name")
-- @param value_field string Optional - field name for option value (default: "value")
-- @return table Builder instance for chaining
function ButtonDialogBuilder:addOptionsWithCheckmark(options, current, callback, name_field, value_field)
	name_field = name_field or "name"
	value_field = value_field or "value"

	for _, option in ipairs(options) do
		local is_current = (current == option[value_field])
		local button_text = option[name_field]
		if is_current then
			button_text = "✓ " .. button_text
		end

		table.insert(self._buttons, {
			{
				text = button_text,
				callback = function()
					callback(option)
				end,
			},
		})
	end
	return self
end

--- Add options with checkmark and description (shown after selection)
-- @param options table Array of {name, value, desc, ...}
-- @param current any Current selected value
-- @param callback function Callback receiving selected option
-- @return table Builder instance for chaining
function ButtonDialogBuilder:addOptionsWithCheckmarkAndDesc(options, current, callback)
	for _, option in ipairs(options) do
		local is_current = (current == option.value or current == option.id)
		local button_text = option.name
		if is_current then
			button_text = "✓ " .. button_text
		end

		table.insert(self._buttons, {
			{
				text = button_text,
				callback = function()
					callback(option)
				end,
			},
		})
	end
	return self
end

--- Add a back/return button
-- @param text string Button text (default: "← Back")
-- @param callback function Callback function
-- @return table Builder instance for chaining
function ButtonDialogBuilder:addBackButton(text, callback)
	text = text or "← Back"
	return self:addButton(text, callback)
end

--- Build and return the ButtonDialog widget
-- @return table ButtonDialog widget
function ButtonDialogBuilder:build()
	return ButtonDialog:new {
		title = self._title,
		title_align = self._title_align,
		buttons = self._buttons,
	}
end

--- Build, show, and return the ButtonDialog widget
-- @param UIManager table UIManager instance
-- @return table ButtonDialog widget
function ButtonDialogBuilder:buildAndShow(UIManager)
	local dialog = self:build()
	UIManager:show(dialog)
	return dialog
end

return ButtonDialogBuilder
