-- Test bootstrap for OPDS Plus, loaded by busted before the specs (see .busted).
--
-- The plugin is written for KOReader, but its non-UI code needs only a few KOReader modules. This
-- file makes the plugin loadable under plain LuaJIT: it points `package.path` at the plugin and at
-- spec/, and registers small stand-ins for the KOReader modules nearly every module requires
-- (gettext, logger, ffi/util, util, libs/libkoreader-lfs). Heavier stand-ins live in spec/support/ and
-- are installed per spec with helper.stub() or passed to helper.load().
--
-- Environment:
--   PLUGIN_ROOT  plugin tree to test; defaults to the repository root. Point it at an extracted
--                release zip to check that the package is complete.
--
-- Typical spec:
--   local helper = require("helper")
--   describe("Thing", function()
--       local Thing
--       before_each(function()
--           helper.reset()
--           Thing = helper.load("utils.thing", { datastorage = my_stub })
--       end)
--       after_each(helper.reset)
--   end)
-- Loaded once per run: busted runs this file as the helper, and specs then require() it. During a first
-- require() Lua leaves a placeholder in package.loaded, so only a table counts as "already loaded".
if type(package.loaded.helper) == "table" then
	return package.loaded.helper
end

local lfs = require("lfs")
local fs

local helper = {}
package.loaded.helper = helper

local function absolute(path)
	if path:sub(1, 1) == "/" then
		return path
	end
	return lfs.currentdir() .. "/" .. path:gsub("^%./", "")
end

local spec_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "spec"
helper.spec_root = absolute(spec_dir):gsub("/$", "")
helper.root = helper.spec_root:match("^(.*)/spec$") or lfs.currentdir()
helper.plugin_root = absolute(os.getenv("PLUGIN_ROOT") or helper.root):gsub("/$", "")

-- Top-level directories that aren't part of the plugin when PLUGIN_ROOT is the repository itself.
helper.non_runtime_dirs = { spec = true, scripts = true, tools = true, docs = true, dist = true }

-- Entries relative to the working directory are dropped: they would let a file missing from
-- PLUGIN_ROOT (say, from a release zip) be found in the checkout instead.
local function foreign_path_entries()
	local kept = {}
	for entry in package.path:gmatch("[^;]+") do
		if entry:sub(1, 2) ~= "./" and entry:sub(1, 1) ~= "?" then
			kept[#kept + 1] = entry
		end
	end
	return table.concat(kept, ";")
end

package.path = table.concat({
	helper.plugin_root .. "/?.lua",
	helper.spec_root .. "/vendor/?.lua",
	helper.spec_root .. "/?.lua",
	foreign_path_entries(),
}, ";")

fs = require("support.fs")
helper.fs = fs
-- From here on, live os.remove, os.rename and lfs.rmdir raise for paths outside a helper.tmpdir().
fs.install_guards()

-- Stand-ins registered for every spec. Their factories run again after helper.reset(), so each
-- test sees fresh state (for example an empty logger.calls).
local baseline_names = {}

local function baseline(name, factory)
	baseline_names[#baseline_names + 1] = name
	package.preload[name] = factory
end

baseline("gettext", function()
	local gettext = {}
	function gettext.ngettext(singular, plural, n)
		return n == 1 and singular or plural
	end
	function gettext.pgettext(_, msgid)
		return msgid
	end
	function gettext.npgettext(_, singular, plural, n)
		return n == 1 and singular or plural
	end
	return setmetatable(gettext, {
		__call = function(_, msgid)
			return msgid
		end,
	})
end)

baseline("logger", function()
	local logger = { calls = {}, levels = { dbg = 1, info = 2, warn = 3, err = 4 } }
	for level in pairs(logger.levels) do
		logger[level] = function(...)
			logger.calls[#logger.calls + 1] = { level = level, n = select("#", ...), ... }
		end
	end
	-- Whether any call at `level` has a string argument containing `text` (plain match).
	function logger.logged(level, text)
		for _, call in ipairs(logger.calls) do
			if call.level == level then
				for i = 1, call.n do
					if type(call[i]) == "string" and call[i]:find(text, 1, true) then
						return true
					end
				end
			end
		end
		return false
	end
	return logger
end)

baseline("ffi/util", function()
	-- Same behaviour as ffi/util.template in KOReader, without table.pack (plain LuaJIT lacks it).
	local function template(str, ...)
		if select("#", ...) == 0 then
			return str
		end
		local params = { ... }
		local result = string.gsub(str, "%%([1-9][0-9]?)", function(i)
			return params[tonumber(i)]
		end)
		return result
	end
	return { template = template }
end)

baseline("util", function()
	return dofile(helper.spec_root .. "/support/util_stub.lua")
end)

baseline("libs/libkoreader-lfs", function()
	return lfs
end)

local overridden = {}
local saved_globals = {}

local function owned_by_plugin(name)
	return type(name) == "string"
		and lfs.attributes(helper.plugin_root .. "/" .. name:gsub("%.", "/") .. ".lua", "mode") == "file"
end

--- Replaces a module for the current test; helper.reset() puts the original back.
-- @param name string Module name as passed to require()
-- @param value any The module (any truthy value, including a function)
function helper.stub(name, value)
	if overridden[name] == nil then
		overridden[name] = { loaded = package.loaded[name], preload = package.preload[name] }
	end
	package.preload[name] = nil
	package.loaded[name] = value
end

--- Replaces a global for the current test; helper.reset() puts the original back.
function helper.global(name, value)
	if saved_globals[name] == nil then
		saved_globals[name] = { value = _G[name] }
	end
	_G[name] = value
end

--- Stubs the given modules (name -> module) and requires `name`.
function helper.load(name, stubs)
	for stub_name, value in pairs(stubs or {}) do
		helper.stub(stub_name, value)
	end
	return require(name)
end

--- A fresh /tmp/opds_plus_test_* dir, removed by helper.reset(). The only place specs may write or delete.
function helper.tmpdir()
	return fs.tmpdir()
end

--- Contents of a file under spec/fixtures, such as "opds1/komga_pse.xml".
function helper.fixture(path)
	local content = fs.read(helper.spec_root .. "/fixtures/" .. path)
	assert(content, "missing fixture: " .. path)
	return content
end

--- Forgets everything a test did to the module system: plugin modules (so singletons and require-time
-- state start over), stand-ins, stubs, globals and temp dirs.
function helper.reset()
	for name in pairs(package.loaded) do
		if owned_by_plugin(name) then
			package.loaded[name] = nil
		end
	end
	for _, name in ipairs(baseline_names) do
		package.loaded[name] = nil
	end
	for name, saved in pairs(overridden) do
		package.loaded[name] = saved.loaded
		package.preload[name] = saved.preload
	end
	overridden = {}
	for name, saved in pairs(saved_globals) do
		_G[name] = saved.value
	end
	saved_globals = {}
	fs.cleanup()
end

--- Every module of the plugin tree under test, as require() names, sorted.
function helper.plugin_modules()
	local modules = {}
	local function walk(dir, prefix)
		for name in lfs.dir(dir) do
			local path = dir .. "/" .. name
			local mode = lfs.attributes(path, "mode")
			if mode == "directory" then
				local skip = name:sub(1, 1) == "." or (prefix == "" and helper.non_runtime_dirs[name])
				if not skip then
					walk(path, prefix .. name .. ".")
				end
			elseif mode == "file" and name:match("%.lua$") then
				modules[#modules + 1] = prefix .. name:gsub("%.lua$", "")
			end
		end
	end
	walk(helper.plugin_root, "")
	table.sort(modules)
	return modules
end

return helper
