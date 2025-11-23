-- OPDS specification constants and configuration values
-- Extracted from opdsbrowserplus.lua for better maintainability

local OPDSConstants = {
	-- MIME Types
	CATALOG_TYPE = "application/atom%+xml",
	SEARCH_TYPE = "application/opensearchdescription%+xml",
	SEARCH_TEMPLATE_TYPE = "application/atom%+xml",

	-- Relationship Types
	ACQUISITION_REL = "^http://opds%-spec%.org/acquisition",
	BORROW_REL = "http://opds-spec.org/acquisition/borrow",
	STREAM_REL = "http://vaemendis.net/opds-pse/stream",
	FACET_REL = "http://opds-spec.org/facet",

	-- Image Relationship Types
	IMAGE_REL = {
		["http://opds-spec.org/image"] = true,
		["http://opds-spec.org/cover"] = true,
		["x-stanza-cover-image"] = true,
	},

	THUMBNAIL_REL = {
		["http://opds-spec.org/image/thumbnail"] = true,
		["http://opds-spec.org/thumbnail"] = true,
		["x-stanza-cover-image-thumbnail"] = true,
	},

	-- Cache Configuration
	CACHE_SLOTS = 20,

	-- UI Icons
	ICONS = {
		MENU = "appbar.menu",
		PLUS = "plus",
		AUTHENTICATED = "\u{f2c0}", -- Lock icon for authenticated catalogs
		SYNC_ENABLED = "\u{f46a}",  -- Sync icon
		GRID_VIEW = "\u{25A6}",     -- Square icon for grid view
		LIST_VIEW = "\u{2261}",     -- List icon for list view
		ADD_CATALOG = "\u{f067}",   -- Plus in circle
		SEARCH = "\u{f002}",        -- Search icon
		FILTER = "\u{f0b0}",        -- Filter icon
		DOWNLOAD = "\u{2B07}",      -- Downwards arrow
		STREAM_START = "\u{23EE}",  -- Double triangle left
		STREAM_NEXT = "\u{23E9}",   -- Double triangle right
		STREAM_RESUME = "\u{25B6}", -- Play triangle
	},

	-- Default Filenames
	DEFAULT_TITLE = "Unknown",
	DEFAULT_AUTHOR = "Unknown Author",
	DEFAULT_FILENAME = "<server filename>",
}

return OPDSConstants
