-- Debug utility for OPDS Plus
-- Provides conditional debug logging based on StateManager settings

local logger = require("logger")

local Debug = {}

-- Lazy-load StateManager to avoid circular dependencies
local function getStateManager()
	local StateManager = require("core.state_manager")
	return StateManager.getInstance()
end

--- Check if debug mode is enabled
-- @return boolean True if debug mode is on
local function isDebugEnabled()
	local state = getStateManager()
	return state:isDebugMode()
end

--- Log debug message if debug mode is enabled (StateManager-based)
-- No manager parameter needed - uses StateManager singleton
-- @param prefix string Log prefix (e.g., "Browser:", "DownloadMgr:")
-- @param ... any Values to log
function Debug.log(prefix, ...)
	if isDebugEnabled() then
		logger.dbg("OPDS+", prefix, ...)
	end
end

--- Legacy log function for backward compatibility
-- Accepts manager as first param but ignores it, uses StateManager instead
-- @param manager table|nil Plugin manager instance (ignored, kept for compatibility)
-- @param prefix string Log prefix
-- @param ... any Values to log
function Debug.logCompat(manager, prefix, ...)
	-- Ignore manager param, use StateManager
	if isDebugEnabled() then
		logger.dbg("OPDS+", prefix, ...)
	end
end

--- Create a debug logger function bound to a specific context
-- Uses StateManager instead of requiring manager to be passed
-- @param context string Context identifier (e.g., "Browser", "DownloadMgr")
-- @return function Debug logging function
function Debug.createLogger(context)
	local prefix = "[" .. context .. "]:"
	return function(...)
		if isDebugEnabled() then
			logger.dbg("OPDS+", prefix, ...)
		end
	end
end

--- Create a debug logger with method-style calling
-- Returns an object with a log method for OOP-style usage
-- @param context string Context identifier
-- @return table Object with log method
function Debug.createContextLogger(context)
	local prefix = "[" .. context .. "]:"
	return {
		log = function(self, ...)
			if isDebugEnabled() then
				logger.dbg("OPDS+", prefix, ...)
			end
		end,
		--- Check if debug is enabled (useful for expensive debug operations)
		isEnabled = function()
			return isDebugEnabled()
		end,
	}
end

return Debug
