-- Navigation Handler for OPDS Browser
-- Handles catalog navigation, browsing history, and feed parsing

local Constants = require("models.constants")
local AtomMapper = require("core.mappers.atom")
local Opds2Mapper = require("core.mappers.opds2")
local OPDSParser = require("core.parser")
local BrowserContext = require("core.browser_context")

local NavigationHandler = {}

-- Parse OPDS catalog into item table for menu display
-- @param catalog table Parsed OPDS feed, Atom or OPDS 2.0 (see core/parser.lua)
-- @param item_url string Base URL for building absolute URLs
-- @param browser_context table Browser context with catalog_type, acquisition_rel, etc.
-- @param debug_callback function Optional debug logging callback
-- @return table Item table suitable for menu display
function NavigationHandler.genItemTableFromCatalog(catalog, item_url, browser_context, debug_callback)
	if OPDSParser.isOpds2(catalog) then
		return Opds2Mapper.map(catalog, item_url, browser_context, debug_callback)
	end
	return AtomMapper.map(catalog, item_url, browser_context, debug_callback)
end

-- Update catalog display with new URL
-- @param item_url string URL to fetch and display
-- @param browser table Browser instance
-- @param paths_updated boolean Whether paths have already been updated
-- @return boolean True if successful
function NavigationHandler.updateCatalog(item_url, browser, paths_updated)
	local FeedFetcher = require("core.feed_fetcher")

	if browser._debugLog then
		browser:_debugLog("updateCatalog called for:", item_url)
	end

	local context = BrowserContext.fromBrowser(browser)
	local debug_callback = function(...) if browser._debugLog then browser:_debugLog(...) end end

	local facets, search
	local menu_table = FeedFetcher.genItemTableFromURL(
		item_url,
		context.username,
		context.password,
		debug_callback,
		function(catalog, url)
			local items
			items, facets, search = NavigationHandler.genItemTableFromCatalog(catalog, url, context, debug_callback)
			return items
		end, nil, context.basic_auth_origin
	)

	return NavigationHandler.applyCatalog(menu_table, facets, search, item_url, browser, paths_updated)
end

function NavigationHandler.applyCatalog(menu_table, facets, search, item_url, browser, paths_updated)
	-- Count how many have covers
	local cover_count = 0
	for _, item in ipairs(menu_table) do
		if item.cover_url then
			cover_count = cover_count + 1
		end
	end

	if #menu_table > 0 or facets or search then
		browser.facet_groups = facets
		browser.search_url = search
		if not paths_updated then
			table.insert(browser.paths, {
				url   = item_url,
				title = browser.catalog_title,
			})
		end
		browser:switchItemTable(browser.catalog_title, menu_table)

		-- Set appropriate title bar icon based on content
		if browser.facet_groups or browser.search_url then
			-- Has facets/search - use facet menu
			browser.title_bar_left_icon = Constants.ICONS.MENU
			browser.onLeftButtonTap = function()
				browser:showFacetMenu()
			end
		else
			-- No facets - use catalog menu for view toggle + add catalog
			browser.title_bar_left_icon = cover_count > 0 and Constants.ICONS.MENU or Constants.ICONS.PLUS
			browser.onLeftButtonTap = function()
				if cover_count > 0 then
					browser:showCatalogMenu()
				else
					browser:addSubCatalog(item_url)
				end
			end
		end

		if browser.page_num <= 1 then
			browser:onNextPage(true)
		end

		return true
	end

	return false
end

-- Append catalog items to current list (pagination)
-- @param item_url string URL to fetch next page from
-- @param browser table Browser instance
-- @return boolean True if items were appended
function NavigationHandler.appendCatalog(item_url, browser)
	local FeedFetcher = require("core.feed_fetcher")

	local context = BrowserContext.fromBrowser(browser)
	local debug_callback = function(...) if browser._debugLog then browser:_debugLog(...) end end

	local menu_table = FeedFetcher.genItemTableFromURL(
		item_url,
		context.username,
		context.password,
		debug_callback,
		function(catalog, url)
			-- luacheck: ignore facets search
			local items, facets, search = NavigationHandler.genItemTableFromCatalog(
				catalog, url, context, debug_callback)
			return items
		end, nil, context.basic_auth_origin
	)

	return NavigationHandler.appendItems(menu_table, browser)
end

function NavigationHandler.appendItems(menu_table, browser, itemnumber)
	if #menu_table > 0 then
		for __, item in ipairs(menu_table) do
			table.insert(browser.item_table, item)
		end
		browser.item_table.hrefs = menu_table.hrefs
		browser:switchItemTable(browser.catalog_title, browser.item_table, itemnumber or -1)
		return true
	end

	return false
end

-- Get navigation history depth
-- @param browser table Browser instance
-- @return number Number of levels deep in navigation
function NavigationHandler.getNavigationDepth(browser)
	return #browser.paths
end

-- Get current catalog URL
-- @param browser table Browser instance
-- @return string|nil Current catalog URL or nil if at root
function NavigationHandler.getCurrentUrl(browser)
	if #browser.paths > 0 then
		return browser.paths[#browser.paths].url
	end
	return nil
end

-- Get current catalog title
-- @param browser table Browser instance
-- @return string|nil Current catalog title or nil if at root
function NavigationHandler.getCurrentTitle(browser)
	if #browser.paths > 0 then
		return browser.paths[#browser.paths].title
	end
	return nil
end

-- Get breadcrumb trail (for potential future UI feature)
-- @param browser table Browser instance
-- @return table Array of {title, url} for navigation path
function NavigationHandler.getBreadcrumbs(browser)
	local breadcrumbs = {}

	if browser.root_catalog_title then
		table.insert(breadcrumbs, {
			title = browser.root_catalog_title,
			url = nil, -- Root has no URL
		})
	end

	for _, path in ipairs(browser.paths) do
		table.insert(breadcrumbs, {
			title = path.title,
			url = path.url,
		})
	end

	return breadcrumbs
end

-- Check if at root level
-- @param browser table Browser instance
-- @return boolean True if at root catalog list
function NavigationHandler.isAtRoot(browser)
	return #browser.paths == 0
end

return NavigationHandler
