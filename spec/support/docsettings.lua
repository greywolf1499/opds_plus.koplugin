-- Stand-in for KOReader's frontend/docsettings.lua, for specs: only the custom book metadata calls
-- the plugin makes, with the same call shapes as the real module (findCustomMetadataFile and
-- flushCustomMetadata are methods, openSettingsFile is not). Nothing touches the disk.
--
--   local doc_settings = require("support.docsettings").new()
--   helper.stub("docsettings", doc_settings)
--   doc_settings.has_custom_metadata["/books/Dune.epub"] = true   -- the book already has some
--   doc_settings.flush_result = nil                               -- writing the file fails
--   doc_settings.flush_error = "disk full"                        -- writing the file raises
--   ... afterwards ...
--   doc_settings.saved["/books/Dune.epub"] == { doc_props = {...}, custom_props = {...} }
local M = {}

function M.new()
	local DocSettings = { has_custom_metadata = {}, saved = {}, flush_result = true }

	function DocSettings:findCustomMetadataFile(doc_path)
		if self.has_custom_metadata[doc_path] then
			return doc_path .. ".sdr/metadata.custom.lua"
		end
	end

	function DocSettings.openSettingsFile()
		local settings = { data = {} }

		function settings:saveSetting(key, value)
			self.data[key] = value
		end

		function settings:flushCustomMetadata(doc_path)
			if DocSettings.flush_error then
				error(DocSettings.flush_error)
			end
			if DocSettings.flush_result then
				DocSettings.saved[doc_path] = self.data
			end
			return DocSettings.flush_result
		end

		return settings
	end

	return DocSettings
end

return M
