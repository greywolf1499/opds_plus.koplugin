local helper = require("helper")

describe("BrowserContext", function()
	local BrowserContext

	before_each(function()
		helper.reset()
		BrowserContext = helper.load("core.browser_context")
	end)

	after_each(helper.reset)

	-- Every field has its own value, so a field read from the wrong place shows up
	local function newBrowser()
		return {
			catalog_type = "catalog-type",
			search_type = "search-type",
			search_template_type = "search-template-type",
			acquisition_rel = "acquisition-rel",
			borrow_rel = "borrow-rel",
			stream_rel = "stream-rel",
			facet_rel = "facet-rel",
			catalog_rel = "catalog-rel",
			thumbnail_rel = "thumbnail-rel",
			image_rel = "image-rel",
			root_catalog_username = "ann",
			root_catalog_password = "secret",
			root_catalog_url = "https://catalog.example/opds",
			sync = false,
			settings = { prefer_large_covers = true, navigation_thumbnails = false },
		}
	end

	local function withoutCredentials(context)
		context.username = nil
		context.password = nil
		return context
	end

	describe("fromBrowser", function()
		it("takes the types, relations, flags and credentials of the browser", function()
			local browser = newBrowser()
			browser.sync = true
			assert.same({
				catalog_type = "catalog-type",
				search_type = "search-type",
				search_template_type = "search-template-type",
				acquisition_rel = "acquisition-rel",
				borrow_rel = "borrow-rel",
				stream_rel = "stream-rel",
				facet_rel = "facet-rel",
				catalog_rel = "catalog-rel",
				thumbnail_rel = "thumbnail-rel",
				image_rel = "image-rel",
				sync = true,
				prefer_large_covers = true,
				navigation_thumbnails = false,
				username = "ann",
				password = "secret",
				basic_auth_origin = "https://catalog.example:443",
			}, BrowserContext.fromBrowser(browser))
		end)

		it("does not change the browser", function()
			local browser = newBrowser()
			local context = BrowserContext.fromBrowser(browser)
			context.username = "other"
			context.catalog_type = "other"
			assert.equals("ann", browser.root_catalog_username)
			assert.equals("catalog-type", browser.catalog_type)
		end)

		it("prefers large covers only when the setting is exactly true", function()
			local browser = newBrowser()
			for _, case in ipairs({ { true, true }, { false, false }, { "yes", false }, { 1, false } }) do
				browser.settings = { prefer_large_covers = case[1] }
				assert.equals(case[2], BrowserContext.fromBrowser(browser).prefer_large_covers, tostring(case[1]))
			end
			browser.settings = {}
			assert.is_false(BrowserContext.fromBrowser(browser).prefer_large_covers)
		end)

		it("shows thumbnails in navigation unless the setting is exactly false", function()
			local browser = newBrowser()
			for _, case in ipairs({ { true, true }, { false, false }, { "no", true }, { 0, true } }) do
				browser.settings = { navigation_thumbnails = case[1] }
				assert.equals(case[2], BrowserContext.fromBrowser(browser).navigation_thumbnails, tostring(case[1]))
			end
			browser.settings = {}
			assert.is_true(BrowserContext.fromBrowser(browser).navigation_thumbnails)
		end)

		it("uses the defaults of the cover settings when the browser has no settings", function()
			local browser = newBrowser()
			browser.settings = nil
			local context = BrowserContext.fromBrowser(browser)
			assert.is_falsy(context.prefer_large_covers)
			assert.is_true(context.navigation_thumbnails)
		end)

		it("leaves out what the browser does not have", function()
			local context = BrowserContext.fromBrowser({})
			assert.is_nil(context.catalog_type)
			assert.is_nil(context.username)
			assert.is_nil(context.password)
			assert.is_nil(context.sync)
		end)
	end)

	describe("anonymous", function()
		it("is the context of the browser without its credentials", function()
			local browser = newBrowser()
			local expected = withoutCredentials(BrowserContext.fromBrowser(browser))
			local context = BrowserContext.anonymous(browser)
			assert.is_nil(context.username)
			assert.is_nil(context.password)
			assert.same(expected, context)
		end)

		it("does not clear the credentials of the browser", function()
			local browser = newBrowser()
			BrowserContext.anonymous(browser)
			assert.equals("ann", browser.root_catalog_username)
			assert.equals("secret", browser.root_catalog_password)
		end)
	end)

	describe("withAuth", function()
		it("uses the given credentials instead of those of the browser", function()
			local browser = newBrowser()
			local expected = BrowserContext.fromBrowser(browser)
			expected.username, expected.password = "bob", "hunter2"
			expected.basic_auth_origin = "https://other.example:443"
			assert.same(expected, BrowserContext.withAuth(browser, "bob", "hunter2", "https://other.example/feed"))
			assert.is_false(BrowserContext.withAuth(browser, "bob", "hunter2").basic_auth_origin)
		end)

		it("uses no credentials when given nil", function()
			local context = BrowserContext.withAuth(newBrowser(), nil, nil)
			assert.is_nil(context.username)
			assert.is_nil(context.password)
		end)

		it("does not change the credentials of the browser", function()
			local browser = newBrowser()
			BrowserContext.withAuth(browser, "bob", "hunter2")
			assert.equals("ann", browser.root_catalog_username)
			assert.equals("secret", browser.root_catalog_password)
		end)
	end)

	describe("forSync", function()
		it("turns the sync flag on and keeps everything else", function()
			local browser = newBrowser()
			local expected = BrowserContext.fromBrowser(browser)
			expected.sync = true
			local context = BrowserContext.forSync(browser)
			assert.is_true(context.sync)
			assert.equals("ann", context.username)
			assert.equals("secret", context.password)
			assert.same(expected, context)
		end)

		it("does not turn on the sync flag of the browser", function()
			local browser = newBrowser()
			BrowserContext.forSync(browser)
			assert.is_false(browser.sync)
		end)
	end)

	describe("validate", function()
		local required = {
			"catalog_type",
			"search_type",
			"search_template_type",
			"acquisition_rel",
			"borrow_rel",
			"stream_rel",
			"facet_rel",
			"catalog_rel",
			"thumbnail_rel",
			"image_rel",
		}

		it("accepts the context of a complete browser and returns it", function()
			local context = BrowserContext.fromBrowser(newBrowser())
			local result = BrowserContext.validate(context)
			assert.is_true(result:isOk())
			assert.equals(context, result.value)
		end)

		it("does not need credentials, flags or cover settings", function()
			local context = BrowserContext.anonymous(newBrowser())
			context.sync = nil
			context.prefer_large_covers = nil
			context.navigation_thumbnails = nil
			assert.is_true(BrowserContext.validate(context):isOk())
		end)

		it("names the field that is missing", function()
			for _, field in ipairs(required) do
				local context = BrowserContext.fromBrowser(newBrowser())
				context[field] = nil
				local result = BrowserContext.validate(context)
				assert.is_true(result:isErr(), field)
				assert.equals("Missing required field: " .. field, result.error, field)
			end
		end)

		it("fails when several fields are missing", function()
			local context = BrowserContext.fromBrowser(newBrowser())
			context.catalog_type, context.facet_rel, context.image_rel = nil, nil, nil
			local result = BrowserContext.validate(context)
			assert.is_true(result:isErr())
			assert.is_truthy(result.error:find("Missing required field: ", 1, true))
		end)

		it("fails for a context built from a browser that has no types", function()
			assert.is_true(BrowserContext.validate(BrowserContext.fromBrowser({})):isErr())
		end)
	end)

	describe("validateLegacy", function()
		it("returns true and the context when the context is valid", function()
			local context = BrowserContext.fromBrowser(newBrowser())
			local valid, returned = BrowserContext.validateLegacy(context)
			assert.is_true(valid)
			assert.equals(context, returned)
		end)

		it("returns false and the message when a field is missing", function()
			local context = BrowserContext.fromBrowser(newBrowser())
			context.facet_rel = nil
			local valid, message = BrowserContext.validateLegacy(context)
			assert.is_false(valid)
			assert.equals("Missing required field: facet_rel", message)
		end)
	end)
end)
