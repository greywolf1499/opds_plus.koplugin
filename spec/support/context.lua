-- A navigation context like the one OPDSBrowser builds, from the plugin's own constants.
-- Plugin modules are required when the function runs, so helper.reset() between tests is safe.
--
--   local context = require("support.context")
--   context()                                 default settings, no credentials
--   context{ prefer_large_covers = true }     browser settings
--   context{ sync = true, username = "u" }    other context fields
local SETTING_KEYS = { prefer_large_covers = true, navigation_thumbnails = true }

return function(options)
	options = options or {}
	local Constants = require("models.constants")
	local BrowserContext = require("core.browser_context")

	local settings = {}
	for key, value in pairs(options) do
		if SETTING_KEYS[key] then
			settings[key] = value
		end
	end

	local context = BrowserContext.fromBrowser({
		catalog_type = Constants.CATALOG_TYPE,
		search_type = Constants.SEARCH_TYPE,
		search_template_type = Constants.SEARCH_TEMPLATE_TYPE,
		acquisition_rel = Constants.ACQUISITION_REL,
		borrow_rel = Constants.BORROW_REL,
		stream_rel = Constants.STREAM_REL,
		facet_rel = Constants.FACET_REL,
		catalog_rel = Constants.CATALOG_REL,
		image_rel = Constants.IMAGE_REL,
		thumbnail_rel = Constants.THUMBNAIL_REL,
		settings = settings,
		root_catalog_username = options.username,
		root_catalog_password = options.password,
		sync = options.sync,
	})
	return context
end
