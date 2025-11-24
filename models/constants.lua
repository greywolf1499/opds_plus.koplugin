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
