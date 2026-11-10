local helper = require("helper")
local lfs = require("lfs")
local luasettings = require("support.luasettings")
local datastorage = require("support.datastorage")

describe("Settings", function()
	local Settings, Constants, dir, path

	local function seed(data)
		helper.fs.write(path, luasettings.dump(data))
	end

	local function reopen()
		return Settings:new(path)
	end

	-- Backdates a file so that the next flush keeps its previous contents as "<file>.old".
	local function age(file)
		lfs.touch(file, os.time() - 120, os.time() - 120)
	end

	-- What a fresh install ends up with after initializeDefaults().
	local function defaults()
		local expected = {
			cover_height_ratio = Constants.DEFAULT_COVER_HEIGHT_RATIO,
			cover_size_preset = "Regular",
			prefer_large_covers = false,
			cover_cache_enabled = true,
			cover_cache_max_mb = Constants.COVER_CACHE.DEFAULT_MAX_MB,
			cover_cache_ttl_minutes = Constants.COVER_CACHE.DEFAULT_TTL_MINUTES,
			cover_parallel_downloads = true,
			navigation_thumbnails = true,
			save_book_description = true,
			display_mode = "list",
			grid_columns = Constants.DEFAULT_GRID_SETTINGS.columns,
			grid_cover_height_ratio = Constants.DEFAULT_GRID_SETTINGS.cover_height_ratio,
			grid_size_preset = Constants.DEFAULT_GRID_SETTINGS.size_preset,
			grid_border_style = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_style,
			grid_border_size = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_size,
			grid_border_color = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_color,
			debug_mode = false,
		}
		for key, value in pairs(Constants.DEFAULT_FONT_SETTINGS) do
			expected[key] = value
		end
		return expected
	end

	before_each(function()
		helper.reset()
		dir = helper.tmpdir()
		path = dir .. "/opdsplus.lua"
		Settings = helper.load("config.settings", {
			luasettings = luasettings,
			datastorage = datastorage.new(dir),
		})
		Constants = require("models.constants")
	end)

	after_each(helper.reset)

	describe("new", function()
		it("keeps the settings in opdsplus.lua inside KOReader's settings directory by default", function()
			Settings:new():saveAndFlush("display_mode", "grid")

			assert.is_true(helper.fs.exists(dir .. "/settings/opdsplus.lua"))
			assert.equals("grid", Settings:new():get("display_mode"))
		end)

		it("uses a custom settings file instead of the default one", function()
			local custom = dir .. "/custom.lua"
			Settings:new(custom):saveAndFlush("display_mode", "grid")

			assert.equals("grid", Settings:new(custom):get("display_mode"))
			assert.is_false(helper.fs.exists(dir .. "/settings/opdsplus.lua"))
			assert.is_nil(Settings:new():get("display_mode"))
		end)

		it("loads the settings already stored in the file", function()
			seed({ display_mode = "grid", servers = { { title = "Books", url = "http://example.org/opds" } } })

			local settings = reopen()

			assert.equals("grid", settings:get("display_mode"))
			assert.same({ { title = "Books", url = "http://example.org/opds" } }, settings:get("servers"))
		end)

		it("starts empty when the settings file is corrupt and has no backup", function()
			helper.fs.write(path, "return {")

			local settings
			assert.has_no.errors(function()
				settings = reopen()
			end)

			assert.same({}, settings.data)
			assert.is_true(settings.is_first_run)
		end)
	end)

	describe("is_first_run", function()
		it("is true when there is no settings file yet", function()
			assert.is_true(reopen().is_first_run)
		end)

		it("is true when the settings file holds nothing", function()
			seed({})

			assert.is_true(reopen().is_first_run)
		end)

		it("is false when the settings file holds any setting, even a false one", function()
			seed({ debug_mode = false })

			assert.is_false(reopen().is_first_run)
		end)

		it("stays true after initializeDefaults so a fresh install can still be recognised", function()
			local settings = reopen()

			settings:initializeDefaults()

			assert.is_true(settings.is_first_run)
		end)

		it("is false on the next start once the defaults were flushed", function()
			local settings = reopen()
			settings:initializeDefaults()
			settings:flush()

			assert.is_false(reopen().is_first_run)
		end)
	end)

	describe("get", function()
		it("returns the stored value", function()
			local settings = reopen()
			settings:set("grid_columns", 4)

			assert.equals(4, settings:get("grid_columns", 3))
		end)

		it("returns the caller's default for a key that was never set", function()
			local settings = reopen()

			assert.equals("grid", settings:get("display_mode", "grid"))
			assert.is_nil(settings:get("display_mode"))
		end)

		it("returns a stored false instead of the default", function()
			local settings = reopen()
			settings:set("cover_cache_enabled", false)

			assert.is_false(settings:get("cover_cache_enabled", true))
		end)

		it("falls back to the built-in default for font settings that are not set", function()
			local settings = reopen()

			for key, default in pairs(Constants.DEFAULT_FONT_SETTINGS) do
				assert.equals(default, settings:get(key))
			end
		end)

		it("prefers the built-in font default over the default passed by the caller", function()
			local settings = reopen()

			assert.equals(Constants.DEFAULT_FONT_SETTINGS.title_size, settings:get("title_size", 99))
		end)

		it("prefers a stored font setting to the built-in default, even when it is false", function()
			local settings = reopen()
			settings:set("title_size", 22)
			settings:set("title_bold", false)

			assert.equals(22, settings:get("title_size"))
			assert.is_false(settings:get("title_bold"))
		end)
	end)

	describe("set", function()
		it("changes the value in memory only, leaving the file as it was until the next flush", function()
			local settings = reopen()
			settings:saveAndFlush("display_mode", "list")

			settings:set("display_mode", "grid")

			assert.equals("grid", settings:get("display_mode"))
			assert.equals("list", reopen():get("display_mode"))
		end)
	end)

	describe("saveAndFlush", function()
		it("writes the value to disk straight away", function()
			reopen():saveAndFlush("display_mode", "grid")

			assert.equals("grid", reopen():get("display_mode"))
		end)

		it("also writes the changes that were only set before", function()
			local settings = reopen()
			settings:set("grid_columns", 4)

			settings:saveAndFlush("display_mode", "grid")

			local reloaded = reopen()
			assert.equals(4, reloaded:get("grid_columns"))
			assert.equals("grid", reloaded:get("display_mode"))
		end)
	end)

	describe("flush", function()
		it("keeps every kind of value the plugin stores across a restart", function()
			local stored = {
				title = 'a "quoted"\nname',
				ratio = 0.35,
				columns = 4,
				enabled = false,
				servers = {
					{
						title = "Books",
						url = "http://example.org/opds",
						sync = true,
						headers = { { name = "X-Token", value = "abc" } },
					},
				},
			}
			local settings = reopen()
			for key, value in pairs(stored) do
				settings:set(key, value)
			end

			settings:flush()

			assert.same(stored, reopen().data)
		end)

		it("replaces the previous contents each time", function()
			local settings = reopen()
			settings:set("display_mode", "grid")
			settings:set("debug_mode", false)
			settings:flush()

			settings:set("display_mode", "list")
			settings:set("debug_mode", true)
			settings:flush()

			assert.same({ display_mode = "list", debug_mode = true }, reopen().data)
		end)

		it("persists changes made through the data table when the storage is flushed directly", function()
			local settings = reopen()

			settings.data.cover_height_ratio = 0.3
			settings:set("display_mode", "grid")
			settings.storage:flush()

			assert.same({ cover_height_ratio = 0.3, display_mode = "grid" }, reopen().data)
		end)
	end)

	describe("readSetting and saveSetting", function()
		it("share their values with get and set", function()
			local settings = reopen()

			settings:saveSetting("sync_dir", "/books")
			settings:set("sync_max_dl", 20)

			assert.equals("/books", settings:get("sync_dir"))
			assert.equals(20, settings:readSetting("sync_max_dl"))
		end)

		it("keep raw entries such as the catalog list across a restart", function()
			local servers = { { title = "Books", url = "http://example.org/opds" } }
			local settings = reopen()
			settings:saveSetting("servers", servers)
			settings:flush()

			assert.same(servers, reopen():readSetting("servers"))
		end)
	end)

	describe("initializeDefaults", function()
		it("gives a fresh install every default setting", function()
			local settings = reopen()

			settings:initializeDefaults()

			assert.same(defaults(), settings.data)
		end)

		it("fills in only the settings that are missing", function()
			seed({ display_mode = "grid", title_size = 20, cover_cache_max_mb = 128 })
			local settings = reopen()

			settings:initializeDefaults()

			local expected = defaults()
			expected.display_mode = "grid"
			expected.title_size = 20
			expected.cover_cache_max_mb = 128
			assert.same(expected, settings.data)
		end)

		it("keeps every value the user already chose, including false", function()
			local chosen = {
				cover_height_ratio = 0.25,
				cover_size_preset = "Custom",
				prefer_large_covers = true,
				cover_cache_enabled = false,
				cover_cache_max_mb = 256,
				cover_cache_ttl_minutes = 30,
				cover_parallel_downloads = false,
				navigation_thumbnails = false,
				save_book_description = false,
				title_font = "cfont",
				title_size = 22,
				title_bold = false,
				info_font = "ffont",
				info_size = 12,
				info_bold = true,
				info_color = "black",
				use_same_font = false,
				display_mode = "grid",
				grid_columns = 5,
				grid_cover_height_ratio = 0.35,
				grid_size_preset = "Custom",
				grid_border_style = "solid",
				grid_border_size = 4,
				grid_border_color = "black",
				debug_mode = true,
			}
			seed(chosen)
			local settings = reopen()

			settings:initializeDefaults()

			assert.same(chosen, settings.data)
		end)

		it("leaves other data in the file, such as catalogs and downloads, alone", function()
			local servers = { { title = "Books", url = "http://example.org/opds" } }
			local downloads = { { file = "/books/a.epub" } }
			seed({ servers = servers, downloads = downloads })
			local settings = reopen()

			settings:initializeDefaults()

			assert.same(servers, settings:get("servers"))
			assert.same(downloads, settings:get("downloads"))
		end)

		it("keeps the defaults and the user's later changes across a restart", function()
			local first = reopen()
			first:initializeDefaults()
			first:set("display_mode", "grid")
			first:set("cover_cache_enabled", false)
			first:flush()

			local second = reopen()
			second:initializeDefaults()

			local expected = defaults()
			expected.display_mode = "grid"
			expected.cover_cache_enabled = false
			assert.same(expected, second.data)
		end)

		describe("legacy large_cover setting", function()
			local function migrate(data)
				seed(data)
				local settings = reopen()
				settings:initializeDefaults()
				return settings:get("prefer_large_covers")
			end

			it("turns prefer_large_covers on when it was on", function()
				assert.is_true(migrate({ large_cover = true }))
			end)

			it("leaves prefer_large_covers off when it was off or never set", function()
				assert.is_false(migrate({ large_cover = false }))
				assert.is_false(migrate({ display_mode = "grid" }))
				assert.is_false(migrate({}))
			end)

			it("does not override an existing prefer_large_covers", function()
				assert.is_false(migrate({ prefer_large_covers = false, large_cover = true }))
				assert.is_true(migrate({ prefer_large_covers = true, large_cover = false }))
			end)
		end)
	end)

	describe("delete", function()
		-- Leaves a settings file plus a ".old" backup of its previous contents.
		local function write_with_backup()
			local settings = reopen()
			settings:saveAndFlush("display_mode", "list")
			age(path)
			settings:saveAndFlush("display_mode", "grid")
			assert.is_true(helper.fs.exists(path .. ".old"))
			return settings
		end

		it("removes the settings file", function()
			local settings = reopen()
			settings:saveAndFlush("display_mode", "grid")

			settings:delete()

			assert.is_false(helper.fs.exists(path))
		end)

		it("removes the settings file at the default location", function()
			local settings = Settings:new()
			settings:saveAndFlush("display_mode", "grid")

			settings:delete()

			assert.is_false(helper.fs.exists(dir .. "/settings/opdsplus.lua"))
		end)

		it("removes the .old backup as well", function()
			local settings = write_with_backup()

			settings:delete()

			assert.is_false(helper.fs.exists(path))
			assert.is_false(helper.fs.exists(path .. ".old"))
		end)

		it("makes the next start a first run without resurrecting the backup", function()
			local settings = write_with_backup()

			settings:delete()

			local restarted = reopen()
			assert.is_true(restarted.is_first_run)
			assert.same({}, restarted.data)
		end)

		it("keeps later flushes of the shared storage from recreating the file", function()
			local settings = write_with_backup()

			settings:delete()
			settings:flush()
			settings:saveAndFlush("display_mode", "list")
			settings.storage:flush()
			settings.storage:close()

			assert.same({}, helper.fs.list(dir))
		end)

		it("leaves other files in the directory alone", function()
			helper.fs.write(dir .. "/other.lua", "return {}")
			helper.fs.write(dir .. "/other.lua.old", "return {}")
			local settings = write_with_backup()

			settings:delete()

			assert.same({ "other.lua", "other.lua.old" }, helper.fs.list(dir))
		end)

		it("does not fail when nothing was ever written", function()
			local settings = reopen()

			assert.has_no.errors(function()
				settings:delete()
			end)
			assert.same({}, helper.fs.list(dir))
		end)
	end)
end)
