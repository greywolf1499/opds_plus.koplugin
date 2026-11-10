-- Catalog utility functions for OPDS operations
-- Handles catalog entry construction and formatting

local util = require("util")

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
			author = table.concat(author, ", ")
			return author
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
local function seriesFromContent(markup)
	if type(markup) ~= "string" then
		return nil
	end

	local lines_read = 0
	for line in (markup .. "<br />"):gmatch("(.-)<br%s*/?>") do
		lines_read = lines_read + 1
		if lines_read > SERIES_LINE_LIMIT then
			break
		end

		local text = line:gsub("^%s*<div[^>]*>", "")
		local series = trimmed(text:match("^%s*SERIES:([^<]*)"))
		if series then
			local name, index = series:match("^(.-)%s*%[(%d[%d%.]*)%]$")
			if name then
				return trimmed(name), index
			end
			return series
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

--- Extract count and last_read from PSE stream link attributes
-- @param link table Link object with PSE attributes
-- @return number|nil, number|nil count, last_read values
function CatalogUtils.extractPSEStreamInfo(link)
	local count, last_read

	for k, v in pairs(link) do
		if k:sub(-6) == ":count" then
			count = tonumber(v)
		elseif k:sub(-9) == ":lastRead" then
			last_read = tonumber(v)
		end
	end

	return count, (last_read and last_read > 0 and last_read or nil)
end

--- Get the description of an entry as plain text
-- @param entry table Catalog entry whose content is plain text or HTML
-- @return string Plain text description, empty if the entry has none
function CatalogUtils.getDescription(entry)
	if type(entry.content) ~= "string" then
		return ""
	end
	return util.htmlToPlainTextIfHtml(entry.content)
end

return CatalogUtils
