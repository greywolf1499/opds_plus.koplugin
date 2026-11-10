-- Parses a catalog feed. The Atom (OPDS 1.x) parser lives in core/parsers/atom.lua.
local AtomParser = require("core.parsers.atom")

local OPDSParser = {}

--- Parses the text of a feed
-- @param text string The feed as the server sent it
-- @return table The parsed feed
function OPDSParser:parse(text)
	return AtomParser:parse(text)
end

return OPDSParser
