-- Catalog Manager for OPDS Browser
-- Handles catalog configuration, CRUD operations, and sync settings

local CatalogUtils = require("utils.catalog_utils")
local RequestHeaders = require("utils.request_headers")
local _ = require("gettext")

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
		table.insert(item_table, CatalogUtils.buildRootEntry(server))
	end
	return item_table
end

-- Add or update a catalog from input fields
-- @param servers table List of server configurations
-- @param item_table table Current item table
-- @param fields table Input fields: [1]=title, [2]=url, [3]=username, [4]=password, [5]=raw_names, [6]=sync,
-- [7]=custom HTTP headers (a list of { name, value }, copied; none when empty or nil)
-- @param item table|nil Existing item to update (nil for new)
-- @param no_refresh boolean Don't refresh item table if true
-- @return number, number New index, item number for refresh
function CatalogManager.editCatalogFromInput(servers, item_table, fields, item, no_refresh)
	local headers = RequestHeaders.copy(fields[7])
	local new_server = {
		title     = fields[1],
		url       = fields[2]:match("^%a+://") and fields[2] or "http://" .. fields[2],
		username  = fields[3] ~= "" and fields[3] or nil,
		password  = fields[4] ~= "" and fields[4] or nil,
		raw_names = fields[5],
		sync      = fields[6],
		headers   = headers and #headers > 0 and headers or nil,
	}

	local new_item = CatalogUtils.buildRootEntry(new_server)
	local new_idx, itemnumber

	if item then
		-- Editing existing catalog
		new_idx = item.idx
		itemnumber = -1
		-- The edit dialog has no field for the default catalog, so carry it over
		local old_server = servers[new_idx - 1]
		new_server.is_default = old_server and old_server.is_default or nil
		-- The sync checkpoint belongs to the feed it was taken from: keep it only for the same address
		if old_server and old_server.url == new_server.url then
			new_server.last_download = old_server.last_download
		end
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

-- Find the catalog chosen to open on launch
-- @param servers table List of server configurations
-- @return table|nil, number|nil Catalog object and index, or nil if none is chosen
function CatalogManager.findDefaultCatalog(servers)
	for idx, server in ipairs(servers) do
		if server.is_default then
			return server, idx
		end
	end
	return nil, nil
end

-- Choose the catalog to open on launch; at most one catalog is the default
-- @param servers table List of server configurations
-- @param default_server table|nil Catalog to make the default, nil for none
function CatalogManager.setDefaultCatalog(servers, default_server)
	for _, server in ipairs(servers) do
		server.is_default = (server == default_server) or nil
	end
end

-- Validate catalog URL
-- Surrounding whitespace is dropped, a missing protocol becomes http:// and the protocol is lower-cased, because
-- the HTTP client only knows "http" and "https" in lower case.
-- @param catalog_url string URL to validate
-- @return boolean, string True and the normalised URL if valid, false and an error message if invalid
function CatalogManager.validateCatalogUrl(catalog_url)
	catalog_url = type(catalog_url) == "string" and catalog_url:match("^%s*(.-)%s*$") or ""
	if catalog_url == "" then
		return false, _("URL cannot be empty")
	end

	local scheme = catalog_url:match("^(%a+)://")
	if scheme then
		catalog_url = scheme:lower() .. catalog_url:sub(#scheme + 1)
	else
		catalog_url = "http://" .. catalog_url
	end

	-- Basic URL validation
	local url = require("socket.url")
	local parsed = url.parse(catalog_url)

	if not parsed then
		return false, _("Invalid URL format")
	end

	if not parsed.scheme then
		return false, _("Missing protocol (http:// or https://)")
	end

	if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
		return false, _("Only HTTP and HTTPS protocols are supported")
	end

	if not parsed.host or parsed.host == "" then
		return false, _("Missing hostname")
	end

	-- Host names may use letters, digits, dots, hyphens and underscores (Docker and NAS names do). The parser
	-- takes the brackets off an IPv6 address, so look for them in the authority.
	local is_name = parsed.host:match("^[%w%._%-]+$")
	local is_ipv6 = parsed.host:match("^[%x:%.]+$") and parsed.host:find(":", 1, true)
		and parsed.authority and parsed.authority:find("[" .. parsed.host .. "]", 1, true)
	if not (is_name or is_ipv6) then
		return false, _("Invalid hostname format")
	end

	-- An empty port is fine (the default port is used)
	if parsed.port and parsed.port ~= "" then
		local port = parsed.port:match("^%d+$") and tonumber(parsed.port)
		if not port or port < 1 or port > 65535 then
			return false, _("Invalid port")
		end
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
