-- Catalog Manager for OPDS Browser
-- Handles catalog configuration, CRUD operations, and sync settings

local logger = require("logger")
local util = require("util")

local OPDSUtils = require("opds_utils")

local CatalogManager = {}

-- Generate root item table from server list
-- @param servers table List of server configurations
-- @param downloads table Download queue
-- @param _ function Gettext translation function
-- @return table Item table for root menu
function CatalogManager.genItemTableFromRoot(servers, downloads, _)
	local item_table = {
		{
			text = _("Downloads"),
			mandatory = #downloads,
		},
	}
	for _, server in ipairs(servers) do
		table.insert(item_table, OPDSUtils.buildRootEntry(server))
	end
	return item_table
end

-- Add or update a catalog from input fields
-- @param servers table List of server configurations
-- @param item_table table Current item table
-- @param fields table Input fields: [1]=title, [2]=url, [3]=username, [4]=password, [5]=raw_names, [6]=sync
-- @param item table|nil Existing item to update (nil for new)
-- @param no_refresh boolean Don't refresh item table if true
-- @return number, number New index, item number for refresh
function CatalogManager.editCatalogFromInput(servers, item_table, fields, item, no_refresh)
	local new_server = {
		title     = fields[1],
		url       = fields[2]:match("^%a+://") and fields[2] or "http://" .. fields[2],
		username  = fields[3] ~= "" and fields[3] or nil,
		password  = fields[4] ~= "" and fields[4] or nil,
		raw_names = fields[5],
		sync      = fields[6],
	}

	local new_item = OPDSUtils.buildRootEntry(new_server)
	local new_idx, itemnumber

	if item then
		-- Editing existing catalog
		new_idx = item.idx
		itemnumber = -1
	else
		-- Adding new catalog
		new_idx = #servers + 2 -- +1 for 0-based, +1 for "Downloads" entry
		itemnumber = new_idx
	end

	servers[new_idx - 1] = new_server
	item_table[new_idx] = new_item

	return new_idx, itemnumber, (not no_refresh)
end

-- Delete a catalog from the list
-- @param servers table List of server configurations
-- @param item_table table Current item table
-- @param item table Item to delete
-- @return table Updated item table
function CatalogManager.deleteCatalog(servers, item_table, item)
	table.remove(servers, item.idx - 1)
	table.remove(item_table, item.idx)
	return item_table
end

-- Update a field in a catalog configuration
-- @param catalog table Catalog/server configuration to update
-- @param field_name string Field name to update
-- @param value any New value for the field
function CatalogManager.updateCatalogField(catalog, field_name, value)
	catalog[field_name] = value
end

-- Find catalog by URL
-- @param servers table List of server configurations
-- @param catalog_url string URL to search for
-- @return table|nil, number|nil Catalog object and index, or nil if not found
function CatalogManager.findCatalogByUrl(servers, catalog_url)
	for idx, server in ipairs(servers) do
		if server.url == catalog_url then
			return server, idx
		end
	end
	return nil, nil
end

-- Find catalog by title
-- @param servers table List of server configurations
-- @param title string Title to search for
-- @return table|nil, number|nil Catalog object and index, or nil if not found
function CatalogManager.findCatalogByTitle(servers, title)
	for idx, server in ipairs(servers) do
		if server.title == title then
			return server, idx
		end
	end
	return nil, nil
end

-- Validate catalog URL
-- @param catalog_url string URL to validate
-- @return boolean, string|nil True if valid, false + error message if invalid
function CatalogManager.validateCatalogUrl(catalog_url)
	if not catalog_url or catalog_url == "" then
		return false, "URL cannot be empty"
	end

	-- Add protocol if missing
	if not catalog_url:match("^%a+://") then
		catalog_url = "http://" .. catalog_url
	end

	-- Basic URL validation
	local url = require("socket.url")
	local parsed = url.parse(catalog_url)

	if not parsed then
		return false, "Invalid URL format"
	end

	if not parsed.scheme then
		return false, "Missing protocol (http:// or https://)"
	end

	if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
		return false, "Only HTTP and HTTPS protocols are supported"
	end

	if not parsed.host or parsed.host == "" then
		return false, "Missing hostname"
	end

	-- Validate hostname format (basic check for valid characters)
	if not parsed.host:match("^[%w%.%-]+$") then
		return false, "Invalid hostname format"
	end

	-- Check for at least one dot in hostname (unless it's localhost)
	if parsed.host ~= "localhost" and not parsed.host:match("%.") then
		return false, "Invalid hostname: must be a domain name or IP address"
	end

	-- Validate that it's not just random characters
	-- Should have a valid TLD or be an IP address
	local is_ip = parsed.host:match("^%d+%.%d+%.%d+%.%d+$")
	local has_valid_tld = parsed.host:match("%.%a%a+$") or parsed.host:match("%.%a%a%a+$")

	if not is_ip and not has_valid_tld and parsed.host ~= "localhost" then
		return false, "Invalid domain: '" .. parsed.host .. "' doesn't appear to be a valid hostname"
	end

	return true, catalog_url
end

-- Get list of catalogs with sync enabled
-- @param servers table List of server configurations
-- @return table List of sync-enabled catalogs
function CatalogManager.getSyncEnabledCatalogs(servers)
	local sync_catalogs = {}
	for _, server in ipairs(servers) do
		if server.sync then
			table.insert(sync_catalogs, server)
		end
	end
	return sync_catalogs
end

-- Get list of catalogs with authentication
-- @param servers table List of server configurations
-- @return table List of catalogs requiring authentication
function CatalogManager.getAuthenticatedCatalogs(servers)
	local auth_catalogs = {}
	for _, server in ipairs(servers) do
		if server.username then
			table.insert(auth_catalogs, server)
		end
	end
	return auth_catalogs
end

-- Export catalogs to a table (for saving/sharing)
-- @param servers table List of server configurations
-- @param include_credentials boolean Include username/password in export
-- @return table Exportable catalog list
function CatalogManager.exportCatalogs(servers, include_credentials)
	local export = {}
	for _, server in ipairs(servers) do
		local catalog = {
			title = server.title,
			url = server.url,
			raw_names = server.raw_names,
			sync = server.sync,
		}

		if include_credentials then
			catalog.username = server.username
			catalog.password = server.password
		end

		table.insert(export, catalog)
	end
	return export
end

-- Import catalogs from a table
-- @param servers table Existing server list to append to
-- @param import_data table Catalog data to import
-- @param merge_duplicates boolean If true, skip duplicates; if false, import all
-- @return number, number Number imported, number skipped
function CatalogManager.importCatalogs(servers, import_data, merge_duplicates)
	local imported = 0
	local skipped = 0

	for _, catalog in ipairs(import_data) do
		-- Validate required fields
		if catalog.title and catalog.url then
			local exists = false

			if merge_duplicates then
				-- Check for duplicates by URL
				for _, existing in ipairs(servers) do
					if existing.url == catalog.url then
						exists = true
						skipped = skipped + 1
						break
					end
				end
			end

			if not exists then
				table.insert(servers, {
					title = catalog.title,
					url = catalog.url,
					username = catalog.username,
					password = catalog.password,
					raw_names = catalog.raw_names,
					sync = catalog.sync,
				})
				imported = imported + 1
			end
		else
			skipped = skipped + 1
		end
	end

	return imported, skipped
end

-- Get catalog statistics
-- @param servers table List of server configurations
-- @return table Statistics: total, with_auth, with_sync, searchable
function CatalogManager.getCatalogStats(servers)
	local stats = {
		total = #servers,
		with_auth = 0,
		with_sync = 0,
		searchable = 0,
	}

	for _, server in ipairs(servers) do
		if server.username then
			stats.with_auth = stats.with_auth + 1
		end
		if server.sync then
			stats.with_sync = stats.with_sync + 1
		end
		if server.url and server.url:match("%%s") then
			stats.searchable = stats.searchable + 1
		end
	end

	return stats
end

-- Sort catalogs by specified field
-- @param servers table List of server configurations
-- @param sort_by string Field to sort by: "title", "url", "sync"
-- @param ascending boolean Sort direction
-- @return table Sorted server list
function CatalogManager.sortCatalogs(servers, sort_by, ascending)
	local sorted = {}
	for _, server in ipairs(servers) do
		table.insert(sorted, server)
	end

	table.sort(sorted, function(a, b)
		local val_a, val_b

		if sort_by == "title" then
			val_a = a.title or ""
			val_b = b.title or ""
		elseif sort_by == "url" then
			val_a = a.url or ""
			val_b = b.url or ""
		elseif sort_by == "sync" then
			val_a = a.sync and 1 or 0
			val_b = b.sync and 1 or 0
		else
			return false
		end

		if ascending then
			return val_a < val_b
		else
			return val_a > val_b
		end
	end)

	return sorted
end

-- Duplicate catalog (create a copy)
-- @param server table Server configuration to duplicate
-- @param new_title string|nil Optional new title (defaults to "Copy of {title}")
-- @return table New catalog configuration
function CatalogManager.duplicateCatalog(server, new_title)
	local _ = require("gettext")
	return {
		title = new_title or _("Copy of ") .. server.title,
		url = server.url,
		username = server.username,
		password = server.password,
		raw_names = server.raw_names,
		sync = server.sync,
		last_download = nil, -- Don't copy sync state
	}
end

return CatalogManager
