-- Parses a catalog feed, Atom (OPDS 1.x) or JSON (OPDS 2.0). An OPDS 2.0 feed is tagged with its
-- format; a feed without the tag is an Atom one, as parsed feeds always were.
--
-- The format is read from the payload itself: some servers send OPDS 2.0 as plain application/json,
-- and others label everything text/xml. The content type only breaks a tie when the payload gives no hint.
local AtomParser = require("core.parsers.atom")
local Opds2Parser = require("core.parsers.opds2")

local OPDSParser = {}

-- Key of the format tag in a parsed OPDS 2.0 feed
OPDSParser.FORMAT_KEY = "_opdsplus_format"
OPDSParser.ATOM = "atom"
OPDSParser.OPDS2 = "opds2"

local BOM = "\239\187\191"

local function withoutBom(text)
	if text:sub(1, 3) == BOM then
		return text:sub(4)
	end
	return text
end

--- Tells which format a feed is in
-- @param text string The feed as the server sent it
-- @param content_type string|nil The Content-Type header, if known
-- @return string OPDSParser.ATOM or OPDSParser.OPDS2
function OPDSParser.detectFormat(text, content_type)
	local first = withoutBom(text):match("^%s*(.)")
	if first == "{" or first == "[" then
		return OPDSParser.OPDS2
	elseif first == "<" then
		return OPDSParser.ATOM
	end
	if type(content_type) == "string" and content_type:lower():find("json", 1, true) then
		return OPDSParser.OPDS2
	end
	return OPDSParser.ATOM
end

--- Parses the text of a feed
-- @param text string The feed as the server sent it
-- @param content_type string|nil The Content-Type header, if known
-- @return table The parsed feed; an OPDS 2.0 one carries OPDSParser.OPDS2 under OPDSParser.FORMAT_KEY
function OPDSParser:parse(text, content_type)
	if OPDSParser.detectFormat(text, content_type) == OPDSParser.OPDS2 then
		local feed = Opds2Parser.parse(text)
		feed[OPDSParser.FORMAT_KEY] = OPDSParser.OPDS2
		return feed
	end
	return AtomParser:parse(withoutBom(text))
end

--- Whether a parsed feed is an OPDS 2.0 one
-- @param feed table|nil A feed returned by OPDSParser:parse
-- @return boolean
function OPDSParser.isOpds2(feed)
	return type(feed) == "table" and feed[OPDSParser.FORMAT_KEY] == OPDSParser.OPDS2
end

return OPDSParser
