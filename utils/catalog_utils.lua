-- Catalog utility functions for OPDS operations
-- Handles catalog entry construction and formatting

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
		if type(entry_title.type) == "string" and entry_title.div ~= "" then
			return entry_title.div
		end
	end

	return default
end

--- Parse author from entry (handles various formats)
-- @param entry_author table Author information from OPDS entry
-- @param default string Default value if parsing fails
-- @return string|nil Parsed author name or nil
function CatalogUtils.parseEntryAuthor(entry_author, default)
	default = default or "Unknown Author"

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

return CatalogUtils
