-- Parses an OPDS 2.0 (JSON) feed.
--
-- Publications carry the parts a reader needs to display a book (readingOrder, resources, toc,
-- landmarks, pageList). The catalog never uses them, so they are dropped right after decoding to keep
-- feeds small in memory.
local JsonDecode = require("utils.json_decode")

local Opds2Parser = {}

local PRUNED_KEYS = { "readingOrder", "resources", "toc", "landmarks", "pageList" }

local function prune(publication)
	if type(publication) == "table" then
		for _, key in ipairs(PRUNED_KEYS) do
			publication[key] = nil
		end
	end
end

local function prunePublications(publications)
	if type(publications) == "table" then
		for _, publication in ipairs(publications) do
			prune(publication)
		end
	end
end

--- Parses the text of an OPDS 2.0 feed
-- @param text string JSON text
-- @return table The decoded feed; raises an error when the text is not a JSON object
function Opds2Parser.parse(text)
	local feed, err = JsonDecode.decode(text)
	if not feed then
		error("Cannot read the OPDS 2.0 feed: " .. tostring(err), 0)
	end
	if type(feed) ~= "table" or feed[1] ~= nil then
		error("Cannot read the OPDS 2.0 feed: it is not a JSON object", 0)
	end

	-- A feed of a single publication is itself a publication
	prune(feed)
	prunePublications(feed.publications)
	if type(feed.groups) == "table" then
		for _, group in ipairs(feed.groups) do
			if type(group) == "table" then
				prunePublications(group.publications)
			end
		end
	end
	return feed
end

return Opds2Parser
