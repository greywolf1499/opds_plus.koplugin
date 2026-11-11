-- Catalog utility functions for OPDS operations
-- Handles catalog entry construction and formatting

local util = require("util")
local logger = require("logger")

local CatalogUtils = {}

--- Build a catalog entry for the root menu
-- @param server table Server configuration object
-- @return table Formatted catalog entry
function CatalogUtils.buildRootEntry(server)
	local icons = ""
	if server.username then
		icons = "\u{f2c0}" -- Lock icon for authenticated catalogs
	end
	if server.sync then
		icons = "\u{f46a} " .. icons -- Sync icon
	end
	return {
		text       = server.title,
		mandatory  = icons,
		url        = server.url,
		username   = server.username,
		password   = server.password,
		raw_names  = server.raw_names,
		headers    = server.headers,
		searchable = server.url and server.url:match("%%s") and true or false,
		sync       = server.sync,
	}
end

--- Parse title from entry (handles both string and table formats)
-- @param entry_title string|table Title from OPDS entry
-- @param default string Default value if parsing fails
-- @return string Parsed title
function CatalogUtils.parseEntryTitle(entry_title, default)
	default = default or "Unknown"

	if type(entry_title) == "string" then
		return entry_title
	elseif type(entry_title) == "table" then
		-- The parser gives an XHTML title as { type = "xhtml", div = <text> }. An empty div can come as a
		-- table or as nothing at all, and neither is a title.
		if type(entry_title.type) == "string" and type(entry_title.div) == "string" and entry_title.div ~= "" then
			return entry_title.div
		end
	end

	return default
end

--- Parse one author element (handles various formats)
-- @param entry_author table A single <author> element
-- @param default string Default value if parsing fails
-- @return string|nil Parsed author name or nil
local function parseAuthorName(entry_author, default)
	if type(entry_author) ~= "table" or not entry_author.name then
		return nil
	end

	local author = entry_author.name

	if type(author) == "table" then
		if #author > 0 then
			return table.concat(author, ", ")
		else
			return nil
		end
	elseif type(author) == "string" then
		return author
	end

	return default
end

--- Parse author from entry (handles various formats)
-- @param entry_author table Author information from OPDS entry: the list of its <author>
--        elements, or a single <author> element
-- @param default string Default value if parsing fails
-- @return string|nil Parsed author names joined by ", " or nil
function CatalogUtils.parseEntryAuthor(entry_author, default)
	default = default or "Unknown Author"

	-- Repeated <author> elements arrive as a list, a lone element as a table with a name
	if type(entry_author) == "table" and entry_author.name == nil and #entry_author > 0 then
		local names = {}
		for _, author in ipairs(entry_author) do
			local name = parseAuthorName(author, default)
			if name then
				table.insert(names, name)
			end
		end
		if #names > 0 then
			return table.concat(names, ", ")
		end
		return nil
	end

	return parseAuthorName(entry_author, default)
end

local function trimmed(text)
	if type(text) ~= "string" then
		return nil
	end
	text = util.trim(text)
	return text ~= "" and text or nil
end

--- Series name and index from <dc:series> and <dc:series_index> (Calibre-Web-Automated),
-- or <dc:seriesPosition> (dir2opds)
local function seriesFromElements(entry)
	local name = trimmed(entry["dc:series"])
	if not name then
		return nil
	end
	return name, entry["dc:series_index"] or entry["dc:seriesPosition"]
end

--- Whether the <meta> refines the element with this id.
-- luxl skips punctuation at the start of an attribute value, so refines="#series" is read as "series".
local function refersTo(meta, id)
	return type(meta.refines) == "string" and meta.refines:gsub("^#", "") == id
end

--- Series name and index from EPUB3 collection metadata (Grimmory):
-- <meta property="belongs-to-collection" id="series">Name</meta> and
-- <meta property="group-position" refines="#series">3</meta>
local function seriesFromMeta(metas)
	if type(metas) ~= "table" then
		return nil
	end

	local name, id
	for _, meta in ipairs(metas) do
		if type(meta) == "table" and meta.property == "belongs-to-collection" and trimmed(meta["#text"]) then
			name, id = trimmed(meta["#text"]), meta.id
			break
		end
	end
	if not name then
		return nil
	end

	local index
	if id then
		for _, meta in ipairs(metas) do
			if type(meta) == "table" and meta.property == "group-position" and refersTo(meta, id) then
				index = meta["#text"]
				break
			end
		end
	end
	return name, index
end

-- Calibre and Calibre-Web start the content with the optional lines RATING, TAGS and SERIES
local SERIES_LINE_LIMIT = 3

--- Series name and index from the "SERIES: Name [3]" line of the content (Calibre, Calibre-Web)
-- Extra byte offsets identify a complete metadata line safe to remove from a description.
local function seriesFromContent(markup)
	if type(markup) ~= "string" then
		return nil
	end

	local lines_read, metadata_prefix = 0, true
	for line_start, line, after_break in (markup .. "<br />"):gmatch("()(.-)<br%s*/?>()") do
		lines_read = lines_read + 1
		if lines_read > SERIES_LINE_LIMIT then
			break
		end

		local wrapper = line:match("^%s*<div[^>]*>") or ""
		local text = line:sub(#wrapper + 1)
		local first, last, value = text:find("^%s*SERIES:([^<]*)")
		local series = trimmed(value)
		if series and first and last then
			local name, index = series:match("^(.-)%s*%[(%d[%d%.]*)%]$")
			if name then
				name = trimmed(name)
			else
				name = series
			end
			local remove_first, remove_last
			local tail = text:sub(last + 1)
			-- Only a complete metadata line is safe to remove, never prose around an embedded marker.
			if metadata_prefix and name and not series:find("[\r\n]") and (not index or tonumber(index))
				and not tail:gsub("</[%w:_%-]+%s*>", ""):find("%S") then
				remove_first = line_start + #wrapper + first - 1
				remove_last = tail == "" and math.min(after_break - 1, #markup)
					or line_start + #wrapper + last - 1
			end
			return name, index, remove_first, remove_last
		end
		local field = trimmed(text)
		if field and (field:find("[\r\n]") or (not field:match("^RATING:") and not field:match("^TAGS:"))) then
			metadata_prefix = false
		end
	end
	return nil
end

--- Shorten an index such as "20.0" or "3.50" to "20" or "3.5"
local function normalizeSeriesIndex(index)
	index = trimmed(index)
	if index and index:match("^%d+%.%d*$") then
		index = index:gsub("0+$", "")
		index = index:gsub("%.$", "")
	end
	return index
end

-- Text of an element that is either plain text or, like <publisher>, holds a <name>
local function elementText(value)
	if type(value) == "table" then
		value = value.name
	end
	return trimmed(value)
end

--- The date part of a timestamp ("1851-01-01T00:00:00Z" -> "1851-01-01"), other text unchanged
-- @param value any Date as the catalog gives it
-- @return string|nil
function CatalogUtils.formatDate(value)
	local text = trimmed(value)
	if not text then
		return nil
	end
	return text:match("^(%d%d%d%d%-%d%d%-%d%d)[T ]") or text
end

--- Publisher, publication date and language of an Atom entry, from Dublin Core elements
-- @param entry table Entry from the parsed OPDS feed
-- @return string|nil, string|nil, string|nil Publisher, date published, language
function CatalogUtils.parseEntryDetails(entry)
	local publisher = elementText(entry["dcterms:publisher"]) or elementText(entry["dc:publisher"])
		or elementText(entry.publisher)
	local published = CatalogUtils.formatDate(elementText(entry["dcterms:issued"]) or elementText(entry["dc:issued"]))
	local language = elementText(entry["dcterms:language"]) or elementText(entry["dc:language"])
	return publisher, published, language
end

--- Get the series of an entry and the position of the book in it
-- @param entry table Entry from the parsed OPDS feed
-- @return string|nil, string|nil Series name and index, nil when the entry has no series
function CatalogUtils.parseEntrySeries(entry)
	local name, index = seriesFromElements(entry)
	if not name then
		name, index = seriesFromMeta(entry.meta)
	end
	if not name then
		name, index = seriesFromContent(entry.content)
	end
	if not name then
		name, index = seriesFromContent(entry.summary)
	end
	if not name then
		return nil
	end

	return name, normalizeSeriesIndex(index)
end

--- Return an exactly representable positive page number, or nil.
function CatalogUtils.pageNumber(value)
	local number = (type(value) == "number" or type(value) == "string") and tonumber(value)
	-- Above this limit, incrementing a Lua number may no longer change the page.
	return number and number >= 1 and number <= 9007199254740991 and number % 1 == 0 and number or nil
end

--- Extract a valid count and bounded one-based last_read from PSE attributes.
function CatalogUtils.extractPSEStreamInfo(link)
	local count, last_read

	for k, v in pairs(link) do
		if type(k) == "string" then
			if k:sub(-6) == ":count" then
				count = CatalogUtils.pageNumber(v)
				if not count then logger.warn("OPDS+ invalid PSE page count") end
			elseif k:sub(-9) == ":lastRead" then
				last_read = CatalogUtils.pageNumber(v)
				if not last_read and tonumber(v) ~= 0 then
					logger.warn("OPDS+ invalid PSE resume position")
				end
			end
		end
	end

	if not count then return nil end
	if last_read and last_read > count then
		logger.warn("OPDS+ PSE resume position exceeds page count")
		last_read = count
	end
	return count, last_read
end

--- Get the description of an entry as plain text
-- @param entry table Catalog entry whose content is plain text or HTML
-- @return string Plain text description, empty if the entry has none
function CatalogUtils.getDescription(entry)
	if type(entry.content) ~= "string" then
		return ""
	end
	local content = entry.content
	local name, index, first, last = seriesFromContent(content)
	if name and first and last and type(entry.series) == "string"
		and util.htmlEntitiesToUtf8(name) == util.htmlEntitiesToUtf8(entry.series)
		and normalizeSeriesIndex(index) == normalizeSeriesIndex(entry.series_index) then
		content = content:sub(1, first - 1) .. content:sub(last + 1)
	end
	return util.htmlToPlainTextIfHtml(content)
end

return CatalogUtils
