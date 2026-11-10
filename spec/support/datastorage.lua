-- Stand-in for KOReader's datastorage, rooted in a directory the spec owns (see helper.tmpdir()).
local fs = require("support.fs")

local M = {}

--- @param root string Directory standing in for KOReader's data directory
function M.new(root)
	local DataStorage = { root = root }

	function DataStorage:getDataDir()
		fs.mkdirs(root)
		return root
	end

	function DataStorage:getFullDataDir()
		fs.mkdirs(root)
		return root
	end

	function DataStorage:getSettingsDir()
		fs.mkdirs(root .. "/settings")
		return root .. "/settings"
	end

	return DataStorage
end

return M
