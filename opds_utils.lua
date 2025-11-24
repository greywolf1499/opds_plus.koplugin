-- OPDS utility functions
-- DEPRECATED: This file is kept for backward compatibility.
-- New code should use the specific utility modules:
--   - utils/url_utils.lua for URL operations
--   - utils/file_utils.lua for file operations
--   - utils/catalog_utils.lua for catalog operations

local UrlUtils = require("utils.url_utils")
local FileUtils = require("utils.file_utils")
local CatalogUtils = require("utils.catalog_utils")
local logger = require("logger")

local OPDSUtils = {}

-- Delegate to CatalogUtils
OPDSUtils.buildRootEntry = CatalogUtils.buildRootEntry
OPDSUtils.parseEntryTitle = CatalogUtils.parseEntryTitle
OPDSUtils.parseEntryAuthor = CatalogUtils.parseEntryAuthor
OPDSUtils.extractPSEStreamInfo = CatalogUtils.extractPSEStreamInfo

-- Delegate to UrlUtils
OPDSUtils.buildAbsoluteUrl = UrlUtils.buildAbsolute
OPDSUtils.extractFilenameFromUrl = UrlUtils.extractFilename
OPDSUtils.parseContentDisposition = UrlUtils.parseContentDisposition
OPDSUtils.isSearchableUrl = UrlUtils.isSearchable
OPDSUtils.buildSearchUrl = UrlUtils.buildSearchUrl
OPDSUtils.isCatalogNavigationLink = UrlUtils.isCatalogNavigationLink
OPDSUtils.isAcquisitionLink = UrlUtils.isAcquisitionLink

-- Delegate to FileUtils
OPDSUtils.ensureFileExtension = FileUtils.ensureExtension

-- Debug logging (kept here for backward compatibility)
function OPDSUtils.debugLog(manager, ...)
	if manager and manager.settings and manager.settings.debug_mode then
		logger.dbg("OPDS+ Utils:", ...)
	end
end

return OPDSUtils
