-- Navigation Handler for OPDS Browser
-- Handles catalog navigation, browsing history, and feed parsing

local DocumentRegistry = require("document/documentregistry")
local socket_url = require("socket.url")
local util = require("util")
local _ = require("gettext")

local Constants = require("models.constants")
local OPDSUtils = require("opds_utils")
local BrowserContext = require("core.browser_context")

local NavigationHandler = {}

-- Parse OPDS catalog into item table for menu display
-- @param catalog table Parsed OPDS feed
-- @param item_url string Base URL for building absolute URLs
-- @param browser_context table Browser context with catalog_type, acquisition_rel, etc.
-- @param debug_callback function Optional debug logging callback
-- @return table Item table suitable for menu display
function NavigationHandler.genItemTableFromCatalog(catalog, item_url, browser_context, debug_callback)
	local item_table = {}
	local facet_groups = nil
	local search_url = nil

	if not catalog then
		return item_table, facet_groups, search_url
	end

	local feed = catalog.feed or catalog
	facet_groups = {}

	local function build_href(href)
		return OPDSUtils.buildAbsoluteUrl(item_url, href)
	end

	local has_opensearch = false
	local hrefs = {}

	-- Process feed links (navigation, search, facets)
	if feed.link then
		for __, link in ipairs(feed.link) do
			if link.type ~= nil then
				if link.type:find(browser_context.catalog_type) then
					if link.rel and link.href then
						hrefs[link.rel] = build_href(link.href)
					end
				end

				if not browser_context.sync then
					-- Search support
					if link.type:find(browser_context.search_type) then
						if link.href then
							local FeedFetcher = require("core.feed_fetcher")
							search_url = build_href(FeedFetcher.getSearchTemplate(
								build_href(link.href),
								browser_context.search_template_type,
								browser_context.username,
								browser_context.password,
								debug_callback
							))
							has_opensearch = true
						end
					end

					if link.type:find(browser_context.search_template_type) and link.rel and link.rel:find("search") then
						if link.href and not has_opensearch then
							search_url = build_href(link.href:gsub("{searchTerms}", "%%s"))
						end
					end

					-- Facets
					if link.rel == browser_context.facet_rel then
						local group_name = link["opds:facetGroup"] or _("Filters")
						if not facet_groups[group_name] then
							facet_groups[group_name] = {}
						end
						table.insert(facet_groups[group_name], link)
					end
				end
			end
		end
	end
	item_table.hrefs = hrefs

	-- Process feed entries (books/sub-catalogs)
	for __, entry in ipairs(feed.entry or {}) do
		local item = {}
		item.acquisitions = {}

		if entry.link then
			for ___, link in ipairs(entry.link) do
				local link_href = build_href(link.href)

				-- Check if it's a navigation link (sub-catalog)
				if OPDSUtils.isCatalogNavigationLink(link, browser_context.catalog_type) then
					item.url = link_href
				end

				if link.rel or link.title then
					-- Borrow links
					if link.rel == browser_context.borrow_rel then
						table.insert(item.acquisitions, {
							type = "borrow",
						})
						-- Acquisition links (downloads)
					elseif OPDSUtils.isAcquisitionLink(link, browser_context.acquisition_rel) then
						table.insert(item.acquisitions, {
							type  = link.type,
							href  = link_href,
							title = link.title,
						})
						-- PSE streaming
					elseif link.rel == browser_context.stream_rel then
						local count, last_read = OPDSUtils.extractPSEStreamInfo(link)
						if count then
							table.insert(item.acquisitions, {
								type      = link.type,
								href      = link_href,
								title     = link.title,
								count     = count,
								last_read = last_read,
							})
						end
						-- Cover images
					elseif browser_context.thumbnail_rel[link.rel] then
						item.thumbnail = link_href
					elseif browser_context.image_rel[link.rel] then
						item.image = link_href
						-- Other downloadable types
					elseif link.rel ~= "alternate" and DocumentRegistry:hasProvider(nil, link.type) then
						table.insert(item.acquisitions, {
							type  = link.type,
							href  = link_href,
							title = link.title,
						})
					end

					-- Special handling for PDF links
					if link.title == "pdf" or link.type == "application/pdf"
						and link.rel ~= "subsection" then
						local original_href = link.href
						local parsed = socket_url.parse(original_href)
						if not parsed then parsed = { path = original_href } end
						local path = parsed.path or ""

						if not util.stringEndsWith(path, "/pdf/") then
							local appended = false
							if util.getFileNameSuffix(path) ~= "pdf" then
								if path == "" then
									path = ".pdf"
								else
									path = path .. ".pdf"
								end
								appended = true
							end
							if appended then
								parsed.path = path
								local new_href = socket_url.build(parsed)
								table.insert(item.acquisitions, {
									type = link.title,
									href = build_href(new_href),
								})
							end
						end
					end
				end
			end
		end

		-- Parse title and author
		local title = OPDSUtils.parseEntryTitle(entry.title, _(Constants.DEFAULT_TITLE))
		item.text = title
		local author = OPDSUtils.parseEntryAuthor(entry.author, _(Constants.DEFAULT_AUTHOR))
		if author then
			item.text = title .. " - " .. author
		end

		-- Add cover information for display
		if (item.thumbnail or item.image) and item.acquisitions and #item.acquisitions > 0 then
			if debug_callback then
				debug_callback("Book entry with cover:", title)
			end

			-- Prefer thumbnail over full image for performance
			if item.thumbnail then
				item.cover_url = item.thumbnail
				item.lazy_load_cover = true
			elseif item.image then
				item.cover_url = item.image
				item.lazy_load_cover = true
			end
		end

		item.title = title
		item.author = author
		item.content = entry.content or entry.summary
		table.insert(item_table, item)
	end

	if next(facet_groups) == nil then facet_groups = nil end

	return item_table, facet_groups, search_url
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

	local menu_table = FeedFetcher.genItemTableFromURL(
		item_url,
		context.username,
		context.password,
		debug_callback,
		function(catalog, url)
			local items, facets, search = NavigationHandler.genItemTableFromCatalog(
				catalog, url, context, debug_callback)
			browser.facet_groups = facets
			browser.search_url = search
			return items
		end
	)

	-- Count how many have covers
	local cover_count = 0
	for _, item in ipairs(menu_table) do
		if item.cover_url then
			cover_count = cover_count + 1
		end
	end

	if #menu_table > 0 or browser.facet_groups or browser.search_url then
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
		end
	)

	if #menu_table > 0 then
		for __, item in ipairs(menu_table) do
			table.insert(browser.item_table, item)
		end
		browser.item_table.hrefs = menu_table.hrefs
		browser:switchItemTable(browser.catalog_title, browser.item_table, -1)
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
