-- Browser Context Factory for OPDS Browser
-- Centralizes creation of context objects passed to navigation and parsing functions
-- This eliminates repeated context building code (DRY principle)

local Result = require("utils.result")

local BrowserContext = {}

--- Create a parsing/navigation context from browser state
-- This context is passed to NavigationHandler and FeedFetcher functions
-- @param browser table OPDSBrowser instance or table with required fields
-- @return table Context object with all OPDS type constants and auth info
function BrowserContext.fromBrowser(browser)
	return {
		-- OPDS MIME type patterns
		catalog_type = browser.catalog_type,
		search_type = browser.search_type,
		search_template_type = browser.search_template_type,

		-- Relationship type patterns
		acquisition_rel = browser.acquisition_rel,
		borrow_rel = browser.borrow_rel,
		stream_rel = browser.stream_rel,
		facet_rel = browser.facet_rel,

		-- Image relationship types
		thumbnail_rel = browser.thumbnail_rel,
		image_rel = browser.image_rel,

		-- Runtime state
		sync = browser.sync,

		-- Authentication
		username = browser.root_catalog_username,
		password = browser.root_catalog_password,
	}
end

--- Create a minimal context for unauthenticated requests
-- Useful for public catalogs or initial discovery
-- @param browser table OPDSBrowser instance with type constants
-- @return table Context object without authentication
function BrowserContext.anonymous(browser)
	local context = BrowserContext.fromBrowser(browser)
	context.username = nil
	context.password = nil
	return context
end

--- Create a context with custom authentication
-- Useful when credentials differ from browser's root catalog
-- @param browser table OPDSBrowser instance with type constants
-- @param username string|nil Username for HTTP auth
-- @param password string|nil Password for HTTP auth
-- @return table Context object with custom credentials
function BrowserContext.withAuth(browser, username, password)
	local context = BrowserContext.fromBrowser(browser)
	context.username = username
	context.password = password
	return context
end

--- Create a context for sync operations
-- Sets sync flag to true, which affects parsing behavior
-- @param browser table OPDSBrowser instance
-- @return table Context object with sync mode enabled
function BrowserContext.forSync(browser)
	local context = BrowserContext.fromBrowser(browser)
	context.sync = true
	return context
end

--- Validate that a context has all required fields
-- @param context table Context object to validate
-- @return Result Result.ok(context) if valid, Result.err(message) if invalid
function BrowserContext.validate(context)
	local required_fields = {
		"catalog_type",
		"search_type",
		"search_template_type",
		"acquisition_rel",
		"borrow_rel",
		"stream_rel",
		"facet_rel",
		"thumbnail_rel",
		"image_rel",
	}

	for _, field in ipairs(required_fields) do
		if context[field] == nil then
			return Result.err("Missing required field: " .. field)
		end
	end

	return Result.ok(context)
end

--- Validate context with legacy (boolean, error) return pattern
-- For backward compatibility with existing code
-- @param context table Context object to validate
-- @return boolean, string|nil True if valid, false + error message if invalid
function BrowserContext.validateLegacy(context)
	local result = BrowserContext.validate(context)
	return result:unpack()
end

return BrowserContext
