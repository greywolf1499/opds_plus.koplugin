-- OPDS specification constants and configuration values
-- Centralized location for all plugin constants

local Constants = {
	-- OPDS MIME Types
	CATALOG_TYPE = "application/atom%+xml",
	SEARCH_TYPE = "application/opensearchdescription%+xml",
	SEARCH_TEMPLATE_TYPE = "application/atom%+xml",

	-- OPDS Relationship Types
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

	-- HTTP Status Codes
	HTTP_STATUS = {
		OK = 200,
		MOVED_PERMANENTLY = 301,
		FOUND = 302, -- Redirect
		BAD_REQUEST = 400,
		UNAUTHORIZED = 401,
		FORBIDDEN = 403,
		NOT_FOUND = 404,
		NOT_ACCEPTABLE = 406,
	},

	-- HTTP Success Range
	HTTP_SUCCESS_MIN = 200,
	HTTP_SUCCESS_MAX = 299,

	-- Network Timeouts (in seconds)
	TIMEOUTS = {
		DEFAULT = 10,
		MAX_TIME = 30,
		IMAGE_LOAD = 10,
		IMAGE_MAX_TIME = 30,
	},

	-- Sync Settings
	SYNC = {
		DEFAULT_MAX_DOWNLOADS = 50,
		MAX_DOWNLOADS_LIMIT = 1000,
		STEP = 10,
		HOLD_STEP = 50,
		-- Time window (in seconds) to consider a file as "recently downloaded"
		-- Used to count downloads after subprocess interruption
		DOWNLOAD_FRESHNESS_SECONDS = 300, -- 5 minutes
	},

	-- UI Timing (in seconds)
	UI_TIMING = {
		NOTIFICATION_TIMEOUT = 1,
		DUPLICATE_NOTIFICATION_TIMEOUT = 3,
		DOWNLOAD_SCHEDULE_DELAY = 1,
		IMAGE_BATCH_DELAY = 0.2,
	},

	-- Cache Configuration
	CACHE_SLOTS = 20,

	-- UI Icons
	ICONS = {
		MENU = "appbar.menu",
		PLUS = "plus",
		AUTHENTICATED = "\u{f2c0}", -- Lock icon for authenticated catalogs
		SYNC_ENABLED = "\u{f46a}", -- Sync icon
		GRID_VIEW = "\u{25A6}", -- Square icon for grid view
		LIST_VIEW = "\u{2261}", -- List icon for list view
		ADD_CATALOG = "\u{f067}", -- Plus in circle
		SEARCH = "\u{f002}",  -- Search icon
		FILTER = "\u{f0b0}",  -- Filter icon
		DOWNLOAD = "\u{2B07}", -- Downwards arrow
		STREAM_START = "\u{23EE}", -- Double triangle left
		STREAM_NEXT = "\u{23E9}", -- Double triangle right
		STREAM_RESUME = "\u{25B6}", -- Play triangle
	},

	-- Default Display Values
	DEFAULT_TITLE = "Unknown",
	DEFAULT_AUTHOR = "Unknown Author",
	DEFAULT_FILENAME = "<server filename>",

	-- Default Cover Size Presets
	COVER_SIZE_PRESETS = {
		{
			name = "Compact",
			description = "8 books per page",
			ratio = 0.08,
		},
		{
			name = "Regular",
			description = "6 books per page (default)",
			ratio = 0.10,
		},
		{
			name = "Large",
			description = "4 books per page",
			ratio = 0.15,
		},
		{
			name = "Extra Large",
			description = "3 books per page",
			ratio = 0.20,
		},
	},

	-- Default Cover Height Ratio
	DEFAULT_COVER_HEIGHT_RATIO = 0.10,

	-- Default Font Settings
	DEFAULT_FONT_SETTINGS = {
		title_font = "smallinfofont",
		title_size = 16,
		title_bold = true,
		info_font = "smallinfofont",
		info_size = 14,
		info_bold = false,
		info_color = "dark_gray",
		use_same_font = true,
	},

	-- Default Grid Settings
	DEFAULT_GRID_SETTINGS = {
		columns = 3,
		cover_height_ratio = 0.20,
		size_preset = "Balanced",
	},

	-- Default Grid Border Settings
	DEFAULT_GRID_BORDER_SETTINGS = {
		border_style = "none",
		border_size = 2,
		border_color = "dark_gray",
	},

	-- Default Server List
	DEFAULT_SERVERS = {
		{
			title = "Project Gutenberg",
			url = "https://m.gutenberg.org/ebooks.opds/?format=opds",
		},
		{
			title = "Standard Ebooks",
			url = "https://standardebooks.org/feeds/opds",
		},
		{
			title = "ManyBooks",
			url = "http://manybooks.net/opds/index.php",
		},
		{
			title = "Internet Archive",
			url = "https://bookserver.archive.org/",
		},
		{
			title = "textos.info (Spanish)",
			url = "https://www.textos.info/catalogo.atom",
		},
		{
			title = "Gallica (French)",
			url = "https://gallica.bnf.fr/opds",
		},
	},
}

return Constants
