-- The model both mappers must produce, checked on every fixture of either format. ui/browser, the cover
-- menus, the download dialog and the sync read these fields, so a mapper that breaks one of the rules
-- breaks the UI whichever format the catalog speaks.
local helper = require("helper")
local lfs = require("lfs")
local shims = require("support.json_shims")

local BASE = "https://library.example.org/opds/catalog/"

local function fixtures(dir, suffix)
	local names = {}
	for name in lfs.dir(helper.spec_root .. "/fixtures/" .. dir) do
		if name:sub(-#suffix) == suffix then
			names[#names + 1] = dir .. "/" .. name
		end
	end
	table.sort(names)
	return names
end

local function is_absolute(value)
	return type(value) == "string" and value:match("^https?://") ~= nil
end

local function optional_string(value)
	return value == nil or type(value) == "string"
end

local function check_model(item_table, facet_groups, search_url)
	assert.is_table(item_table.hrefs, "item_table.hrefs")
	for rel, href in pairs(item_table.hrefs) do
		assert.is_string(rel)
		assert.is_true(is_absolute(href), "href of " .. rel)
	end

	for i, item in ipairs(item_table) do
		local where = "item " .. i
		assert.is_string(item.text, where)
		assert.is_string(item.title, where)
		assert.is_true(item.text:find("%S") ~= nil, where .. " has text")
		assert.is_table(item.acquisitions, where)
		assert.is_true(item.url == nil or is_absolute(item.url), where .. " url")
		for _, field in ipairs({ "author", "series", "series_index", "content" }) do
			assert.is_true(optional_string(item[field]), where .. " " .. field)
		end
		for j, acquisition in ipairs(item.acquisitions) do
			if acquisition.type ~= "borrow" then
				assert.is_true(is_absolute(acquisition.href), where .. " acquisition " .. j)
				assert.is_true(optional_string(acquisition.title), where .. " acquisition title " .. j)
			end
		end
		if item.cover_url then
			assert.is_true(is_absolute(item.cover_url), where .. " cover_url")
			assert.is_true(item.cover_url == item.thumbnail or item.cover_url == item.image, where .. " cover source")
			assert.is_true(item.lazy_load_cover, where .. " lazy_load_cover")
		end
	end

	if facet_groups ~= nil then
		assert.is_table(facet_groups)
		assert.is_not_nil(next(facet_groups), "an empty facet table is nil instead")
		for name, links in pairs(facet_groups) do
			assert.is_string(name)
			assert.is_true(#links > 0, "facet group " .. name)
			for _, link in ipairs(links) do
				assert.is_string(link.title)
				assert.is_string(link.href)
				assert.is_true(optional_string(link["thr:count"]))
				assert.is_true(link["opds:activeFacet"] == nil or link["opds:activeFacet"] == "true")
			end
		end
	end

	assert.is_true(search_url == nil or (is_absolute(search_url) and search_url:find("%s", 1, true) ~= nil),
		"search_url has a %s slot")
end

describe("mapper contract", function()
	local NavigationHandler, OPDSParser, make_context

	before_each(function()
		helper.reset()
		helper.stub("rapidjson", shims.rapidjson())
		helper.stub("document/documentregistry", require("support.documentregistry").new())
		helper.stub("core.feed_fetcher", {
			getSearchTemplate = function()
				return "/opds/search?q=%s"
			end,
		})
		OPDSParser = require("core.parser")
		NavigationHandler = require("core.navigation_handler")
		make_context = require("support.context")
	end)

	after_each(helper.reset)

	local all = fixtures("opds1", ".xml")
	for _, name in ipairs(fixtures("opds2", ".json")) do
		all[#all + 1] = name
	end

	for _, name in ipairs(all) do
		for _, options in ipairs({ {}, { prefer_large_covers = true }, { sync = true } }) do
			local label = next(options) and (" with " .. next(options)) or ""
			it(name .. label, function()
				local catalog = OPDSParser:parse(helper.fixture(name))
				assert.equals(name:find("^opds2/") ~= nil, OPDSParser.isOpds2(catalog))
				check_model(NavigationHandler.genItemTableFromCatalog(catalog, BASE, make_context(options)))
			end)
		end
	end

	it("both mappers give an empty model for a missing feed", function()
		local items, facets, search = NavigationHandler.genItemTableFromCatalog(nil, BASE, make_context())
		assert.same({}, items)
		assert.is_nil(facets)
		assert.is_nil(search)
	end)
end)
