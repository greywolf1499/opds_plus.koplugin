-- State Manager for OPDS Plus
-- Centralizes state change tracking and persistence notifications
-- Reduces direct _manager.updated coupling throughout the codebase

local StateManager = {}
StateManager.__index = StateManager

-- Singleton instance
local instance = nil

--- Get or create the StateManager singleton
-- @param plugin table Optional plugin instance to initialize with
-- @return StateManager
function StateManager.getInstance(plugin)
	if not instance then
		instance = setmetatable({
			_plugin = plugin,
			_dirty = false,
			_change_listeners = {},
		}, StateManager)
	elseif plugin then
		instance._plugin = plugin
	end
	return instance
end

--- Reset the singleton (primarily for testing)
function StateManager.reset()
	instance = nil
end

--- Initialize with a plugin instance
-- @param plugin table Plugin instance (OPDS main module)
function StateManager:init(plugin)
	self._plugin = plugin
	self._dirty = false
end

--- Mark state as changed (needs persistence)
-- This replaces scattered `browser._manager.updated = true` calls
function StateManager:markDirty()
	self._dirty = true
	if self._plugin then
		self._plugin.updated = true
	end
	self:_notifyListeners("dirty")
end

--- Check if state has unsaved changes
-- @return boolean True if there are unsaved changes
function StateManager:isDirty()
	return self._dirty
end

--- Clear the dirty flag (after save)
function StateManager:markClean()
	self._dirty = false
	self:_notifyListeners("clean")
end

--- Get the current settings data
-- @return table Settings data table
function StateManager:getSettings()
	if self._plugin and self._plugin.settings then
		return self._plugin.settings
	end
	return {}
end

--- Get a specific setting value
-- @param key string Setting key
-- @param default any Default value if not set
-- @return any Setting value or default
function StateManager:getSetting(key, default)
	local settings = self:getSettings()
	if settings[key] ~= nil then
		return settings[key]
	end
	return default
end

--- Update a setting value and mark dirty
-- @param key string Setting key
-- @param value any Value to set
function StateManager:setSetting(key, value)
	local settings = self:getSettings()
	settings[key] = value
	self:markDirty()
end

--- Check if debug mode is enabled
-- @return boolean True if debug mode is on
function StateManager:isDebugMode()
	return self:getSetting("debug_mode", false)
end

--- Get display mode (list/grid)
-- @return string "list" or "grid"
function StateManager:getDisplayMode()
	return self:getSetting("display_mode", "list")
end

--- Set display mode
-- @param mode string "list" or "grid"
function StateManager:setDisplayMode(mode)
	self:setSetting("display_mode", mode)
	-- Also persist immediately for display mode changes
	if self._plugin and self._plugin.opds_settings then
		self._plugin.opds_settings:saveSetting("settings", self:getSettings())
		self._plugin.opds_settings:flush()
	end
end

--- Get sync directory
-- @return string|nil Sync directory path or nil
function StateManager:getSyncDir()
	return self:getSetting("sync_dir")
end

--- Get maximum sync downloads
-- @return number Maximum downloads (default 50)
function StateManager:getMaxSyncDownloads()
	local Constants = require("models.constants")
	return self:getSetting("sync_max_dl", Constants.SYNC.DEFAULT_MAX_DOWNLOADS)
end

--- Get filetypes filter string
-- @return string|nil Filetypes string or nil
function StateManager:getFiletypes()
	return self:getSetting("filetypes")
end

--- Register a listener for state changes
-- @param listener function Callback function(event_type)
-- @return number Listener ID for removal
function StateManager:addChangeListener(listener)
	table.insert(self._change_listeners, listener)
	return #self._change_listeners
end

--- Remove a change listener
-- @param listener_id number ID returned from addChangeListener
function StateManager:removeChangeListener(listener_id)
	self._change_listeners[listener_id] = nil
end

--- Internal: notify all listeners of state change
-- @param event_type string Type of event ("dirty" or "clean")
function StateManager:_notifyListeners(event_type)
	for _, listener in pairs(self._change_listeners) do
		if type(listener) == "function" then
			pcall(listener, event_type)
		end
	end
end

return StateManager
