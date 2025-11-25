-- Settings management module for OPDS Plus
-- Handles persistence, defaults, and settings access

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Constants = require("models.constants")

local Settings = {}

--- Initialize settings manager
-- @param settings_file string Optional custom settings file path
-- @return table Settings instance
function Settings:new(settings_file)
	local o = {}
	setmetatable(o, self)
	self.__index = self

	o.settings_file = settings_file or DataStorage:getSettingsDir() .. "/opdsplus.lua"
	o.storage = LuaSettings:open(o.settings_file)
	o.data = o.storage.data
	o.is_first_run = next(o.data) == nil

	return o
end

--- Get a setting value with optional default
-- @param key string Setting key
-- @param default any Default value if not set
-- @return any Setting value or default
function Settings:get(key, default)
	if self.data[key] ~= nil then
		return self.data[key]
	end
	-- Check in font settings defaults
	if Constants.DEFAULT_FONT_SETTINGS[key] ~= nil then
		return Constants.DEFAULT_FONT_SETTINGS[key]
	end
	return default
end

--- Set a setting value
-- @param key string Setting key
-- @param value any Value to set
function Settings:set(key, value)
	self.data[key] = value
end

--- Save a specific setting and flush to disk
-- @param key string Setting key
-- @param value any Value to save
function Settings:saveAndFlush(key, value)
	self:set(key, value)
	self:flush()
end

--- Save settings to storage
function Settings:save()
	self.storage:saveSetting("settings", self.data)
end

--- Flush settings to disk
function Settings:flush()
	self.storage:flush()
end

--- Initialize all default settings
function Settings:initializeDefaults()
	-- Cover settings
	if not self.data.cover_height_ratio then
		self.data.cover_height_ratio = Constants.DEFAULT_COVER_HEIGHT_RATIO
	end
	if not self.data.cover_size_preset then
		self.data.cover_size_preset = "Regular"
	end

	-- Font settings
	for key, default_value in pairs(Constants.DEFAULT_FONT_SETTINGS) do
		if self.data[key] == nil then
			self.data[key] = default_value
		end
	end

	-- Display mode settings
	if not self.data.display_mode then
		self.data.display_mode = "list" -- Default to list view
	end
	if not self.data.grid_columns then
		self.data.grid_columns = Constants.DEFAULT_GRID_SETTINGS.columns
	end
	if not self.data.grid_cover_height_ratio then
		self.data.grid_cover_height_ratio = Constants.DEFAULT_GRID_SETTINGS.cover_height_ratio
	end
	if not self.data.grid_size_preset then
		self.data.grid_size_preset = Constants.DEFAULT_GRID_SETTINGS.size_preset
	end

	-- Grid border settings
	if not self.data.grid_border_style then
		self.data.grid_border_style = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_style
	end
	if not self.data.grid_border_size then
		self.data.grid_border_size = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_size
	end
	if not self.data.grid_border_color then
		self.data.grid_border_color = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_color
	end

	-- Debug mode (default: false for production)
	if self.data.debug_mode == nil then
		self.data.debug_mode = false
	end
end

--- Read a raw setting from storage
-- @param key string Setting key
-- @param default any Default value
-- @return any Setting value
function Settings:readSetting(key, default)
	return self.storage:readSetting(key, default)
end

--- Save a raw setting to storage
-- @param key string Setting key
-- @param value any Value to save
function Settings:saveSetting(key, value)
	self.storage:saveSetting(key, value)
end

return Settings
