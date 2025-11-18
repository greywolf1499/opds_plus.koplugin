-- Debug logging helper for OPDS Plus
local logger = require("logger")

local DebugHelper = {}

function DebugHelper:init(settings)
    self.settings = settings
end

function DebugHelper:log(...)
    if self.settings and self.settings.debug_mode then
        logger.dbg("OPDS+:", ...)
    end
end

function DebugHelper:warn(...)
    if self.settings and self.settings.debug_mode then
        logger.warn("OPDS+:", ...)
    end
end

-- Always log errors regardless of debug mode
function DebugHelper:error(...)
    logger.warn("OPDS+ ERROR:", ...)
end

return DebugHelper
