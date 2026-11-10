-- Maps a parsed OPDS 2.0 feed to the item table the browser, the cover menus and the sync use, the same
-- model core/mappers/atom.lua builds from an Atom feed (spec/integration/mapper_contract_spec.lua checks
-- both against it).
--
-- Groups: a group with navigation links is flattened into "Group - link" entries, and a group with a
-- link of its own becomes a folder entry for it. A group of inline publications without a link becomes
-- a shelf: a folder whose address is the feed's own with "#opdsplus-group=<n>" added. The fetcher strips
-- the fragment, so opening a shelf maps the cached feed again and lists only that group. A feed made of
-- nothing but such groups (the results of a Komga search, for one) lists their publications in place,
-- and so does a sync, which never opens folders.

local DocumentRegistry = require("document/documentregistry")
local _ = require("gettext")

local Constants = require("models.constants")
local CatalogUtils = require("utils.catalog_utils")
local UrlUtils = require("utils.url_utils")
local FileUtils = require("utils.file_utils")
local UriTemplate = require("utils.uri_template")

local Opds2Mapper = {}

local function hasText(value)
	return type(value) == "string" and value:find("%S") ~= nil
end

local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do
		if type(key) == "string" then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	return keys
end

local function uiLanguage()
	local settings = rawget(_G, "G_reader_settings")
	if type(settings) == "table" and type(settings.readSetting) == "function" then
		local language = settings:readSetting("language")
		if type(language) == "string" and language ~= "" then
			return language
		end
	end
end

--- A string that may be localized ({ en = "...", fr = "..." }): the UI language, then English, then
-- the first language in alphabetical order
local function localized(value, language)
	if type(value) == "string" then
		return hasText(value) and value or nil
	end
	if type(value) ~= "table" then
		return nil
	end
	local function pick(key)
		local text = key and value[key]
		return hasText(text) and text or nil
	end
	local keys = sortedKeys(value)
	if language then
		local base = language:match("^(%a+)")
		local found = pick(language) or pick(language:gsub("_", "-")) or pick(base)
		if found then
			return found
		end
		for __, key in ipairs(keys) do
			if base and key:match("^(%a+)") == base and pick(key) then
				return pick(key)
			end
		end
	end
	if pick("en") then
		return pick("en")
	end
	for __, key in ipairs(keys) do
		if pick(key) then
			return pick(key)
		end
	end
	return nil
end

--- The rel of a link as a set; OPDS 2.0 allows a string or a list
local function relSet(rel)
	local set = {}
	if type(rel) == "string" then
		set[rel] = true
	elseif type(rel) == "table" then
		for __, value in ipairs(rel) do
			if type(value) == "string" then
				set[value] = true
			end
		end
	end
	return set
end

local function isLink(link)
	return type(link) == "table" and type(link.href) == "string" and link.href ~= ""
end

local function isTemplated(link)
	return link.templated == true or UriTemplate.isTemplated(link.href)
end

local function list(value)
	return type(value) == "table" and value or {}
end

-- Names from a contributor value: a string, an object with a (localized) name, or a list of those
local function contributorNames(value, language, names)
	if type(value) == "string" then
		if hasText(value) then
			names[#names + 1] = value
		end
	elseif type(value) == "table" then
		if value.name ~= nil then
			local name = localized(value.name, language)
			if name then
				names[#names + 1] = name
			end
		else
			for __, each in ipairs(value) do
				if type(each) ~= "table" or each[1] == nil then
					contributorNames(each, language, names)
				end
			end
		end
	end
	return names
end

local function authorOf(metadata, language)
	local names = contributorNames(metadata.author, language, {})
	if #names == 0 then
		names = contributorNames(metadata.contributor, language, {})
	end
	if #names == 0 then
		return nil
	end
	return table.concat(names, ", ")
end

local function publisherOf(metadata, language)
	local names = contributorNames(metadata.publisher, language, {})
	return #names > 0 and table.concat(names, ", ") or nil
end

-- A BCP 47 tag or a list of them
local function languageOf(metadata)
	local tags = {}
	for __, tag in ipairs(type(metadata.language) == "table" and metadata.language or { metadata.language }) do
		if type(tag) == "string" and hasText(tag) then
			tags[#tags + 1] = tag
		end
	end
	return #tags > 0 and table.concat(tags, ", ") or nil
end

local function seriesIndex(position)
	if type(position) == "number" then
		if position % 1 == 0 then
			return string.format("%d", position)
		end
		return (string.format("%.4f", position):gsub("0+$", ""):gsub("%.$", ""))
	elseif type(position) == "string" then
		return position:match("^%s*(.-)%s*$")
	end
	return nil
end

-- The first series of belongsTo; a collection counts only when it gives a position
local function seriesOf(metadata, language)
	local belongs = metadata.belongsTo
	if type(belongs) ~= "table" then
		return nil
	end
	for __, key in ipairs({ "series", "collection" }) do
		local value = belongs[key]
		local entries = (type(value) == "table" and value[1] ~= nil) and value or { value }
		for ___, entry in ipairs(entries) do
			local name, position
			if type(entry) == "string" then
				name = hasText(entry) and entry or nil
			elseif type(entry) == "table" then
				name = localized(entry.name, language)
				position = entry.position
			end
			if name and (key == "series" or position ~= nil) then
				local index = seriesIndex(position)
				return name, index ~= "" and index or nil
			end
		end
	end
	return nil
end

-- Thumbnail and full-size image: an explicit rel first, then the smallest and largest by
-- width * height, then the first image (Komga gives one image with no rel and no size)
local function imagesOf(images, context)
	local first, thumb_by_rel, image_by_rel
	local sized = {}
	for __, image in ipairs(list(images)) do
		if isLink(image) and not isTemplated(image) then
			first = first or image
			for rel in pairs(relSet(image.rel)) do
				if context.thumbnail_rel[rel] then
					thumb_by_rel = thumb_by_rel or image
				elseif context.image_rel[rel] then
					image_by_rel = image_by_rel or image
				end
			end
			local width, height = tonumber(image.width), tonumber(image.height)
			if width and height and width > 0 and height > 0 then
				sized[#sized + 1] = { image = image, area = width * height, order = #sized }
			end
		end
	end
	if not first then
		return nil
	end
	table.sort(sized, function(a, b)
		if a.area ~= b.area then
			return a.area < b.area
		end
		return a.order < b.order
	end)
	local smallest = sized[1] and sized[1].image
	local largest = sized[#sized] and sized[#sized].image
	local thumbnail = thumb_by_rel or smallest or first
	local image = image_by_rel or largest or first
	return thumbnail.href, image.href
end

-- The type a chain of indirect acquisitions ends in, as in an ACSM or LCP licence for an EPUB
local function finalIndirectType(properties)
	local indirect = type(properties) == "table" and properties.indirectAcquisition
	local final
	local depth = 0
	while type(indirect) == "table" and type(indirect[1]) == "table" and depth < 10 do
		if type(indirect[1].type) == "string" then
			final = indirect[1].type
		end
		indirect = indirect[1].child
		depth = depth + 1
	end
	return final
end

local function hasProvider(mime)
	return FileUtils.mimeExtension(mime, DocumentRegistry) ~= nil
end

local function matchesAny(rels, pattern)
	for rel in pairs(rels) do
		if rel:match(pattern) then
			return true
		end
	end
	return false
end

local function acquisitionsOf(links, build_href, context, language)
	local acquisitions = {}
	for __, link in ipairs(list(links)) do
		if isLink(link) and not isTemplated(link) then
			local rels = relSet(link.rel)
			local title = localized(link.title, language)
			if rels[context.borrow_rel] then
				table.insert(acquisitions, { type = "borrow" })
			elseif matchesAny(rels, context.acquisition_rel) then
				local mime = link.type
				if not hasProvider(mime) then
					mime = finalIndirectType(link.properties) or mime
				end
				table.insert(acquisitions, { type = mime, href = build_href(link.href), title = title })
			elseif not rels.self and not rels.alternate and hasProvider(link.type) then
				table.insert(acquisitions, { type = link.type, href = build_href(link.href), title = title })
			end
		end
	end
	return acquisitions
end

local function setCover(item, context, title, debug_callback)
	local is_book = #item.acquisitions > 0
	local show_cover = is_book or (item.url ~= nil and context.navigation_thumbnails)
	if not (item.thumbnail or item.image) or not show_cover then
		return
	end
	if debug_callback then
		debug_callback(is_book and "Book entry with cover:" or "Catalog entry with cover:", title)
	end
	if context.prefer_large_covers and item.image then
		item.cover_url = item.image
	else
		item.cover_url = item.thumbnail or item.image
	end
	item.lazy_load_cover = true
end

local function publicationItem(publication, build_href, context, language, debug_callback)
	if type(publication) ~= "table" then
		return nil
	end
	local metadata = type(publication.metadata) == "table" and publication.metadata or {}
	local item = { acquisitions = acquisitionsOf(publication.links, build_href, context, language) }

	local title = localized(metadata.title, language) or _(Constants.DEFAULT_TITLE)
	local author = authorOf(metadata, language)
	item.text = author and (title .. " - " .. author) or title
	item.series, item.series_index = seriesOf(metadata, language)
	item.publisher = publisherOf(metadata, language)
	item.published = CatalogUtils.formatDate(metadata.published)
	item.language = languageOf(metadata)

	local thumbnail, image = imagesOf(publication.images, context)
	item.thumbnail = thumbnail and build_href(thumbnail)
	item.image = image and build_href(image)
	setCover(item, context, title, debug_callback)

	item.title = title
	item.author = author
	local description = localized(metadata.description, language)
	if hasText(description) then
		item.content = description
	end
	return item
end

local SHELF_FRAGMENT = "#opdsplus-group="

local function folderItem(title, href, count)
	return {
		text = title,
		title = title,
		url = href,
		acquisitions = {},
		mandatory = count and string.format("%d", count) or nil,
	}
end

local function groupTitle(group, language)
	return localized(type(group.metadata) == "table" and group.metadata.title, language)
end

local function hasPublications(group)
	return type(group.publications) == "table" and #group.publications > 0
end

local function hasNavigation(group)
	return type(group.navigation) == "table" and #group.navigation > 0
end

-- The link a group's folder opens: its self link, else its first plain link
local function groupLink(group)
	local target
	for __, link in ipairs(list(group.links)) do
		if isLink(link) and not isTemplated(link) then
			if relSet(link.rel).self then
				return link
			end
			target = target or link
		end
	end
	return target
end

local function isShelf(group, language)
	return type(group) == "table" and not hasNavigation(group) and hasPublications(group)
		and not (groupTitle(group, language) and groupLink(group))
end

-- True when the feed has nothing to show but groups that would become shelves
local function onlyShelves(catalog, language)
	if #list(catalog.navigation) > 0 or #list(catalog.publications) > 0 then
		return false
	end
	local shelves = 0
	for __, group in ipairs(list(catalog.groups)) do
		if isShelf(group, language) then
			shelves = shelves + 1
		elseif type(group) == "table" and (hasNavigation(group) or groupLink(group)) then
			return false
		end
	end
	return shelves > 0
end

--- The group a shelf address points at
-- @param item_url string|nil Address of a feed or of one of its shelves
-- @return number|nil Index of the group in the feed's groups
function Opds2Mapper.shelfIndex(item_url)
	return type(item_url) == "string" and tonumber(item_url:match("#opdsplus%-group=(%d+)$")) or nil
end

local function facetLink(link, item_url, build_href, language)
	local href = build_href(link.href)
	local properties = type(link.properties) == "table" and link.properties or {}
	local count = tonumber(properties.numberOfItems)
	local rels = relSet(link.rel)
	return {
		title = localized(link.title, language) or _(Constants.DEFAULT_TITLE),
		href = href,
		["thr:count"] = count and string.format("%d", count) or nil,
		["opds:activeFacet"] = (rels.self or href == item_url) and "true" or nil,
	}
end

-- Base for relative links: the feed's self link, else the address it was fetched from
local function baseUrl(feed, item_url)
	for __, link in ipairs(list(feed.links)) do
		if isLink(link) and relSet(link.rel).self and not isTemplated(link) then
			return UrlUtils.buildAbsolute(item_url, link.href)
		end
	end
	return item_url
end

--- Maps a parsed OPDS 2.0 feed
-- @param catalog table Feed from core/parsers/opds2.lua
-- @param item_url string Address the feed was fetched from
-- @param browser_context table Context from core/browser_context.lua
-- @param debug_callback function|nil Optional debug logging callback
-- @return table, table|nil, string|nil Item table (with .hrefs), facet groups, search URL with %s
function Opds2Mapper.map(catalog, item_url, browser_context, debug_callback)
	local item_table = {}
	if type(catalog) ~= "table" then
		return item_table, nil, nil
	end

	local context = browser_context
	local language = context.language or uiLanguage()
	local shelf = Opds2Mapper.shelfIndex(item_url)
	item_url = UrlUtils.stripFragment(item_url)
	local base = baseUrl(catalog, item_url)
	local function build_href(href)
		return UrlUtils.buildAbsolute(base, href)
	end

	local facet_groups = {}
	local search_url
	local has_opensearch = false
	local hrefs = {}

	for __, link in ipairs(list(catalog.links)) do
		if isLink(link) then
			local rels = relSet(link.rel)
			if rels.search then
				if not context.sync then
					if type(link.type) == "string" and link.type:find(context.search_type) then
						local FeedFetcher = require("core.feed_fetcher")
						local template = FeedFetcher.getSearchTemplate(
							build_href(link.href),
							context.search_template_type,
							context.username,
							context.password,
							debug_callback
						)
						if template then
							search_url = build_href(template)
							has_opensearch = true
						end
					elseif isTemplated(link) and not has_opensearch then
						local templated_url = UriTemplate.toSearchUrl(link.href)
						if templated_url then
							search_url = build_href(templated_url)
						end
					end
				end
			elseif not isTemplated(link) then
				for rel in pairs(rels) do
					hrefs[rel] = build_href(link.href)
				end
			end
		end
	end
	item_table.hrefs = hrefs

	local function addPublications(publications)
		for __, publication in ipairs(list(publications)) do
			local item = publicationItem(publication, build_href, context, language, debug_callback)
			if item then
				table.insert(item_table, item)
			end
		end
	end

	if shelf then
		-- The feed's paging and facets are not the shelf's
		item_table.hrefs = {}
		local group = list(catalog.groups)[shelf]
		if isShelf(group, language) then
			addPublications(group.publications)
		elseif debug_callback then
			debug_callback("The feed has no OPDS 2.0 shelf", shelf)
		end
		return item_table, nil, search_url
	end

	local function addFacet(group_name, link)
		group_name = group_name or _("Filters")
		facet_groups[group_name] = facet_groups[group_name] or {}
		table.insert(facet_groups[group_name], facetLink(link, item_url, build_href, language))
	end

	local function addNavigation(links, group_title)
		for __, link in ipairs(list(links)) do
			if isLink(link) and not isTemplated(link) then
				local rels = relSet(link.rel)
				if rels[context.facet_rel] then
					if not context.sync then
						addFacet(group_title, link)
					end
				elseif not rels.self then
					local title = localized(link.title, language) or _(Constants.DEFAULT_TITLE)
					if group_title then
						title = group_title .. " - " .. title
					end
					table.insert(item_table, folderItem(title, build_href(link.href)))
				end
			end
		end
	end

	addNavigation(catalog.navigation)

	local shelves_in_place = context.sync or onlyShelves(catalog, language)
	for index, group in ipairs(list(catalog.groups)) do
		if type(group) == "table" then
			local title = groupTitle(group, language)
			local metadata = type(group.metadata) == "table" and group.metadata or {}
			if hasNavigation(group) then
				addNavigation(group.navigation, title)
			elseif isShelf(group, language) then
				if shelves_in_place then
					addPublications(group.publications)
				else
					table.insert(item_table, folderItem(title or _(Constants.DEFAULT_TITLE),
						item_url .. SHELF_FRAGMENT .. index, #group.publications))
				end
			else
				local target = groupLink(group)
				if title and target then
					table.insert(item_table, folderItem(title, build_href(target.href),
						tonumber(metadata.numberOfItems)))
				elseif debug_callback then
					debug_callback("Skipping OPDS 2.0 group without a link:", title or index)
				end
			end
		end
	end

	if not context.sync then
		for __, facet in ipairs(list(catalog.facets)) do
			if type(facet) == "table" then
				local name = localized(type(facet.metadata) == "table" and facet.metadata.title, language)
				for ___, link in ipairs(list(facet.links)) do
					if isLink(link) and not isTemplated(link) then
						addFacet(name, link)
					end
				end
			end
		end
	end

	addPublications(catalog.publications)

	if next(facet_groups) == nil then
		facet_groups = nil
	end
	return item_table, facet_groups, search_url
end

return Opds2Mapper
