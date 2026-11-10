-- Maps a parsed Atom (OPDS 1.x) feed to the item table the browser, the cover menus and the sync use.
-- Moved verbatim from core/navigation_handler.lua; NavigationHandler.genItemTableFromCatalog calls it.

local DocumentRegistry = require("document/documentregistry")
local socket_url = require("socket.url")
local util = require("util")
local _ = require("gettext")

local Constants = require("models.constants")
local UrlUtils = require("utils.url_utils")
local FileUtils = require("utils.file_utils")
local CatalogUtils = require("utils.catalog_utils")

local AtomMapper = {}

-- An empty <content/> parses to a table, which must not hide a summary that has text
local function hasText(value)
	return type(value) == "string" and value:find("%S") ~= nil
end

-- Parse OPDS catalog into item table for menu display
-- @param catalog table Parsed OPDS feed
-- @param item_url string Base URL for building absolute URLs
-- @param browser_context table Browser context with catalog_type, acquisition_rel, etc.
-- @param debug_callback function Optional debug logging callback
-- @return table Item table suitable for menu display
function AtomMapper.map(catalog, item_url, browser_context, debug_callback)
	local item_table = {}
	local facet_groups = nil
	local search_url = nil

	if not catalog then
		return item_table, facet_groups, search_url
	end

	local feed = catalog.feed or catalog
	facet_groups = {}

	local function build_href(href)
		return UrlUtils.buildAbsolute(item_url, href)
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
							local template = FeedFetcher.getSearchTemplate(
								build_href(link.href),
								browser_context.search_template_type,
								browser_context.username,
								browser_context.password,
								debug_callback
							)
							-- Without a template there is nothing to search with: resolving a nil href would
							-- give the address of this very catalog, and searching would only reload it.
							if template then
								search_url = build_href(template)
								has_opensearch = true
							end
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
				if UrlUtils.isCatalogNavigationLink(link, browser_context.catalog_type, browser_context.catalog_rel) then
					item.url = link_href
				end

				if link.rel or link.title then
					local acquisitions_before = #item.acquisitions
					-- Borrow links
					if link.rel == browser_context.borrow_rel then
						table.insert(item.acquisitions, {
							type = "borrow",
						})
						-- Acquisition links (downloads)
					elseif UrlUtils.isAcquisitionLink(link, browser_context.acquisition_rel) then
						table.insert(item.acquisitions, {
							type  = link.type,
							href  = link_href,
							title = link.title,
						})
						-- PSE streaming
					elseif link.rel == browser_context.stream_rel then
						local count, last_read = CatalogUtils.extractPSEStreamInfo(link)
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
					elseif link.rel ~= "alternate" and FileUtils.mimeExtension(link.type, DocumentRegistry) then
						table.insert(item.acquisitions, {
							type  = link.type,
							href  = link_href,
							title = link.title,
						})
					end

					-- Special handling for PDF links that nothing above has taken. Adding them again would give the
					-- book a second PDF button that points at an address the server never sent.
					if #item.acquisitions == acquisitions_before
						and (link.title == "pdf" or link.type == "application/pdf")
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
		local title = CatalogUtils.parseEntryTitle(entry.title, _(Constants.DEFAULT_TITLE))
		item.text = title
		local author = CatalogUtils.parseEntryAuthor(entry.author, _(Constants.DEFAULT_AUTHOR))
		if author then
			item.text = title .. " - " .. author
		end
		item.series, item.series_index = CatalogUtils.parseEntrySeries(entry)

		-- Add cover information for display. An entry that only opens a sub-catalog, such as a series in a
		-- comic server's feed, can carry artwork too.
		local is_book = #item.acquisitions > 0
		local show_cover = is_book or (item.url ~= nil and browser_context.navigation_thumbnails)
		if (item.thumbnail or item.image) and show_cover then
			if debug_callback then
				debug_callback(is_book and "Book entry with cover:" or "Catalog entry with cover:", title)
			end

			-- Prefer larger images only when explicitly enabled.
			if browser_context.prefer_large_covers and item.image then
				item.cover_url = item.image
				item.lazy_load_cover = true
			elseif item.thumbnail then
				item.cover_url = item.thumbnail
				item.lazy_load_cover = true
			elseif item.image then
				item.cover_url = item.image
				item.lazy_load_cover = true
			end
		end

		item.title = title
		item.author = author
		if hasText(entry.content) then
			item.content = entry.content
		elseif hasText(entry.summary) then
			item.content = entry.summary
		end
		table.insert(item_table, item)
	end

	if next(facet_groups) == nil then facet_groups = nil end

	return item_table, facet_groups, search_url
end

return AtomMapper
