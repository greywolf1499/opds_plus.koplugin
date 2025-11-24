-- Debug utility for OPDS Plus
-- Provides conditional debug logging based on settings

local logger = require("logger")

local Debug = {}

--- Log debug message if debug mode is enabled
-- @param manager table Plugin manager instance with settings
-- @param ... any Values to log
function Debug.log(manager, ...)
	if manager and manager.settings and manager.settings.debug_mode then
		logger.dbg("OPDS+:", ...)
	end
end

--- Create a debug logger function bound to a specific context
-- @param context string Context identifier (e.g., "Browser", "DownloadMgr")
-- @param manager table Plugin manager instance with settings
-- @return function Debug logging function
function Debug.createLogger(context, manager)
	return function(...)
		if manager and manager.settings and manager.settings.debug_mode then
			logger.dbg("OPDS+ [" .. context .. "]:", ...)
		end
	end
end

return Debug
