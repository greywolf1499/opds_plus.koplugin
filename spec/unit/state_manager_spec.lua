local helper = require("helper")

describe("StateManager", function()
	local StateManager, Constants

	-- A manager bound to a minimal stand-in for the plugin instance.
	local function manager(settings)
		local plugin = { settings = settings }
		return StateManager.getInstance(plugin), plugin
	end

	-- A listener that records the events it receives.
	local function recorder()
		local events = {}
		return function(event)
			events[#events + 1] = event
		end, events
	end

	before_each(function()
		helper.reset()
		StateManager = helper.load("core.state_manager")
		Constants = require("models.constants")
	end)

	after_each(helper.reset)

	describe("getInstance", function()
		it("returns the same instance on every call", function()
			assert.equals(StateManager.getInstance(), StateManager.getInstance())
		end)

		it("starts clean", function()
			assert.is_false(StateManager.getInstance():isDirty())
		end)

		it("reads settings from the plugin given on the first call", function()
			local sm = manager({ display_mode = "grid" })

			assert.equals("grid", sm:getSetting("display_mode"))
		end)

		it("switches to a plugin given later without creating a second instance", function()
			local first = manager({ display_mode = "grid" })

			local second = StateManager.getInstance({ settings = { display_mode = "list" } })

			assert.equals(first, second)
			assert.equals("list", first:getSetting("display_mode"))
		end)

		it("keeps the current plugin when called without one", function()
			local sm = manager({ display_mode = "grid" })

			StateManager.getInstance()

			assert.equals("grid", sm:getSetting("display_mode"))
		end)
	end)

	describe("reset", function()
		it("drops the instance together with its plugin, dirty flag and listeners", function()
			local sm = manager({ display_mode = "grid" })
			local listener, events = recorder()
			sm:addChangeListener(listener)
			sm:markDirty()

			StateManager.reset()
			local fresh = StateManager.getInstance()
			fresh:markDirty()

			assert.are_not.equal(sm, fresh)
			assert.is_nil(fresh:getSetting("display_mode"))
			assert.same({ "dirty" }, events)
		end)
	end)

	describe("init", function()
		it("binds the plugin and clears the dirty flag", function()
			local sm = StateManager.getInstance()
			sm:markDirty()

			sm:init({ settings = { display_mode = "grid" } })

			assert.is_false(sm:isDirty())
			assert.equals("grid", sm:getSetting("display_mode"))
		end)
	end)

	describe("markDirty", function()
		it("flags unsaved changes on the manager and on the plugin", function()
			local sm, plugin = manager({})

			sm:markDirty()

			assert.is_true(sm:isDirty())
			assert.is_true(plugin.updated)
		end)

		it("works when there is no plugin to tell", function()
			local sm = StateManager.getInstance()

			assert.has_no.errors(function()
				sm:markDirty()
			end)
			assert.is_true(sm:isDirty())
		end)
	end)

	describe("markClean", function()
		it("clears the dirty flag", function()
			local sm = manager({})
			sm:markDirty()

			sm:markClean()

			assert.is_false(sm:isDirty())
		end)
	end)

	describe("settings access", function()
		it("getSettings returns the plugin's own settings table", function()
			local settings = { display_mode = "grid" }
			local sm = manager(settings)

			assert.equals(settings, sm:getSettings())
		end)

		it("getSettings returns an empty table when there is no plugin or it has no settings yet", function()
			assert.same({}, StateManager.getInstance():getSettings())

			StateManager.reset()
			assert.same({}, StateManager.getInstance({}):getSettings())
		end)

		it("getSetting returns stored values, including false and 0", function()
			local sm = manager({ flag = false, count = 0, name = "x" })

			assert.is_false(sm:getSetting("flag", true))
			assert.equals(0, sm:getSetting("count", 5))
			assert.equals("x", sm:getSetting("name", "default"))
		end)

		it("getSetting returns the default for a key that is not stored", function()
			local sm = manager({})

			assert.equals("fallback", sm:getSetting("missing", "fallback"))
			assert.is_nil(sm:getSetting("missing"))
		end)

		it("setSetting writes into the plugin's settings and marks the state dirty", function()
			local sm, plugin = manager({})

			sm:setSetting("grid_columns", 4)

			assert.equals(4, plugin.settings.grid_columns)
			assert.equals(4, sm:getSetting("grid_columns"))
			assert.is_true(sm:isDirty())
			assert.is_true(plugin.updated)
		end)

		it("setSetting does not fail when there is no plugin", function()
			local sm = StateManager.getInstance()

			assert.has_no.errors(function()
				sm:setSetting("grid_columns", 4)
			end)
			assert.is_true(sm:isDirty())
		end)
	end)

	describe("typed accessors", function()
		it("isDebugMode is off unless debug_mode is stored as true", function()
			assert.is_false(manager({}):isDebugMode())

			assert.is_false(manager({ debug_mode = false }):isDebugMode())

			assert.is_true(manager({ debug_mode = true }):isDebugMode())
		end)

		it("getDisplayMode defaults to list and follows the stored mode", function()
			local sm, plugin = manager({})
			assert.equals("list", sm:getDisplayMode())

			plugin.settings.display_mode = "grid"

			assert.equals("grid", sm:getDisplayMode())
		end)

		it("reports the sync directory, download limit and file types, with defaults", function()
			local empty = manager({})
			assert.is_nil(empty:getSyncDir())
			assert.equals(Constants.SYNC.DEFAULT_MAX_DOWNLOADS, empty:getMaxSyncDownloads())
			assert.is_nil(empty:getFiletypes())

			local configured = manager({ sync_dir = "/books", sync_max_dl = 20, filetypes = "epub, pdf" })
			assert.equals("/books", configured:getSyncDir())
			assert.equals(20, configured:getMaxSyncDownloads())
			assert.equals("epub, pdf", configured:getFiletypes())
		end)

		it("getFontSettings returns the built-in fonts when nothing is stored", function()
			assert.same(Constants.DEFAULT_FONT_SETTINGS, manager({}):getFontSettings())
		end)

		it("getFontSettings lets every stored value win, including false", function()
			local stored = {
				title_font = "cfont",
				title_size = 22,
				title_bold = false,
				info_font = "ffont",
				info_size = 12,
				info_bold = true,
				info_color = "black",
				use_same_font = false,
			}

			assert.same(stored, manager(stored):getFontSettings())
		end)

		it("getCoverSettings returns the preset and ratio, with defaults", function()
			assert.same(
				{ preset_name = "Regular", ratio = Constants.DEFAULT_COVER_HEIGHT_RATIO },
				manager({}):getCoverSettings()
			)

			assert.same(
				{ preset_name = "Large", ratio = 0.25 },
				manager({ cover_size_preset = "Large", cover_height_ratio = 0.25 }):getCoverSettings()
			)
		end)

		it("getGridLayoutSettings returns the preset and column count, with defaults", function()
			assert.same(
				{
					preset_name = Constants.DEFAULT_GRID_SETTINGS.size_preset,
					columns = Constants.DEFAULT_GRID_SETTINGS.columns,
				},
				manager({}):getGridLayoutSettings()
			)

			assert.same(
				{ preset_name = "Compact", columns = 5 },
				manager({ grid_size_preset = "Compact", grid_columns = 5 }):getGridLayoutSettings()
			)
		end)

		it("getGridBorderSettings returns style, size and color, with defaults", function()
			assert.same({
				style = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_style,
				size = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_size,
				color = Constants.DEFAULT_GRID_BORDER_SETTINGS.border_color,
			}, manager({}):getGridBorderSettings())

			assert.same(
				{ style = "solid", size = 4, color = "black" },
				manager({ grid_border_style = "solid", grid_border_size = 4, grid_border_color = "black" })
					:getGridBorderSettings()
			)
		end)
	end)

	describe("setDisplayMode", function()
		it("changes the mode and marks the state dirty", function()
			local sm, plugin = manager({})

			sm:setDisplayMode("grid")

			assert.equals("grid", sm:getDisplayMode())
			assert.is_true(sm:isDirty())
			assert.is_true(plugin.updated)
		end)

		it("writes the mode to the settings file right away", function()
			local dir = helper.tmpdir()
			local path = dir .. "/opdsplus.lua"
			local Settings = helper.load("config.settings", {
				luasettings = require("support.luasettings"),
				datastorage = require("support.datastorage").new(dir),
			})
			local store = Settings:new(path)
			local sm = StateManager.getInstance({ settings = store.data, opds_settings = store.storage })

			sm:setDisplayMode("grid")

			assert.equals("grid", Settings:new(path):get("display_mode"))
		end)

		it("does not need a settings file to change the mode", function()
			local sm = manager({})

			assert.has_no.errors(function()
				sm:setDisplayMode("grid")
			end)
			assert.equals("grid", sm:getDisplayMode())
		end)
	end)

	describe("change listeners", function()
		it("are told about dirty and clean transitions", function()
			local sm = manager({})
			local first, first_events = recorder()
			local second, second_events = recorder()
			sm:addChangeListener(first)
			sm:addChangeListener(second)

			sm:markDirty()
			sm:markClean()

			assert.same({ "dirty", "clean" }, first_events)
			assert.same({ "dirty", "clean" }, second_events)
		end)

		it("are told about dirty when a setting changes", function()
			local sm = manager({})
			local listener, events = recorder()
			sm:addChangeListener(listener)

			sm:setSetting("grid_columns", 4)

			assert.same({ "dirty" }, events)
		end)

		it("stop being called once removed by the id they were added with", function()
			local sm = manager({})
			local removed, removed_events = recorder()
			local kept, kept_events = recorder()
			local id = sm:addChangeListener(removed)
			sm:addChangeListener(kept)

			sm:removeChangeListener(id)
			sm:markDirty()

			assert.same({}, removed_events)
			assert.same({ "dirty" }, kept_events)
		end)

		it("are not affected by removing an id that was never handed out", function()
			local sm = manager({})
			local listener, events = recorder()
			sm:addChangeListener(listener)

			assert.has_no.errors(function()
				sm:removeChangeListener(99)
			end)
			sm:markDirty()

			assert.same({ "dirty" }, events)
		end)

		it("do not stop the others, or the state change, when one of them throws", function()
			local sm = manager({})
			local listener, events = recorder()
			sm:addChangeListener(function()
				error("listener failure")
			end)
			sm:addChangeListener(listener)

			assert.has_no.errors(function()
				sm:markDirty()
			end)

			assert.same({ "dirty" }, events)
			assert.is_true(sm:isDirty())
		end)

		it("skip registered values that are not functions", function()
			local sm = manager({})
			local listener, events = recorder()
			sm:addChangeListener("not a function")
			sm:addChangeListener(listener)

			assert.has_no.errors(function()
				sm:markDirty()
			end)

			assert.same({ "dirty" }, events)
		end)

		it("gives each listener its own id, also after another listener was removed", function()
			-- With listeners A, B, C and B removed, the number of slots in use is no longer an id to hand out
			local sm = manager({})
			local calls = {}
			local function named(name)
				return function()
					calls[#calls + 1] = name
				end
			end
			sm:addChangeListener(named("a"))
			local id_b = sm:addChangeListener(named("b"))
			local id_c = sm:addChangeListener(named("c"))
			sm:removeChangeListener(id_b)
			local id_d = sm:addChangeListener(named("d"))

			assert.are_not.equal(id_c, id_d)
			sm:removeChangeListener(id_c)
			sm:markDirty()

			table.sort(calls)
			assert.same({ "a", "d" }, calls)
		end)

		it("does not hand out the id of a removed listener again", function()
			local sm = manager({})
			local first = sm:addChangeListener(function() end)
			sm:removeChangeListener(first)

			assert.are_not.equal(first, sm:addChangeListener(function() end))
		end)
	end)
end)
