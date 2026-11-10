-- Smoke test for the plugin tree under test: the checkout, or with PLUGIN_ROOT an extracted release zip.
--
-- 1. Every Lua file loads. The KOReader modules the plugin requires are replaced by permissive stand-ins
--    that accept any call, so UI modules load as well. What counts is that the file parses, runs its top
--    level and finds the other files of the plugin.
-- 2. Every plugin module required anywhere, also inside a function that no test calls, is in the tree.
local helper = require("helper")

local PLUGIN_DIRS = { core = true, config = true, models = true, services = true, ui = true, utils = true }

-- Plugin modules are required with dots (`core.parser`); KOReader's use slashes (`ui/uimanager`) or a plain name.
local function is_plugin_module(name)
	local first = name:match("^([^.]+)%.")
	return name == "opds_plus_version" or (first ~= nil and PLUGIN_DIRS[first] == true)
end

-- A module that accepts anything: any field is the stand-in again, calling it gives it back.
local function permissive_module()
	local stand_in = {}
	local function same()
		return stand_in
	end
	local function zero()
		return 0
	end
	local function empty()
		return ""
	end
	setmetatable(stand_in, {
		__index = function(_, key)
			if type(key) == "number" then
				return nil -- ipairs() over a stand-in must end
			end
			return stand_in
		end,
		__call = same,
		__concat = empty,
		__tostring = empty,
		__len = zero,
		__unm = zero,
		__add = zero,
		__sub = zero,
		__mul = zero,
		__div = zero,
		__mod = zero,
		__pow = zero,
		__lt = function()
			return false
		end,
		__le = function()
			return false
		end,
	})
	return stand_in
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = file:read("*a")
	file:close()
	return content
end

local function without_comments(source)
	return (source:gsub("%-%-%[(=*)%[.-%]%1%]", ""):gsub("%-%-[^\n]*", ""))
end

-- The names required in a source file by require("name"), require "name" and require('name')
local function required_names(source)
	local names = {}
	source = without_comments(source)
	for _, pattern in ipairs({ "require%s*%(%s*\"([^\"]+)\"", "require%s*%(%s*'([^']+)'", "require%s+\"([^\"]+)\"" }) do
		for name in source:gmatch(pattern) do
			names[#names + 1] = name
		end
	end
	return names
end

local function module_path(name)
	return helper.plugin_root .. "/" .. name:gsub("%.", "/") .. ".lua"
end

describe("the plugin tree", function()
	local searchers, searcher, loaded_by_searcher

	before_each(function()
		helper.reset()
		loaded_by_searcher = {}
		searchers = package.loaders
		searcher = function(name)
			if is_plugin_module(name) then
				return "\n\tno file for plugin module '" .. name .. "' in " .. helper.plugin_root
			end
			return function()
				loaded_by_searcher[#loaded_by_searcher + 1] = name
				return permissive_module()
			end
		end
		table.insert(searchers, searcher)
	end)

	after_each(function()
		for index = #searchers, 1, -1 do
			if searchers[index] == searcher then
				table.remove(searchers, index)
			end
		end
		for _, name in ipairs(loaded_by_searcher) do
			package.loaded[name] = nil
		end
		helper.reset()
	end)

	local modules = helper.plugin_modules()

	it("has the files KOReader looks for", function()
		local present = {}
		for _, name in ipairs(modules) do
			present[name] = true
		end

		assert.is_true(present.main)
		assert.is_true(present._meta)
		assert.is_true(present.opds_plus_version)
	end)

	for _, name in ipairs(modules) do
		it("loads " .. name, function()
			local ok, result = pcall(require, name)

			assert.is_true(ok, tostring(result))
		end)
	end

	it("describes itself to KOReader", function()
		local meta = require("_meta")

		assert.equals("opdsplus", meta.name)
		assert.equals("OPDS Plus", meta.fullname)
		assert.matches("^%d+%.%d+%.%d+$", meta.version)
		assert.equals(require("opds_plus_version").VERSION, meta.version)
	end)

	it("requires only plugin modules that are in the tree", function()
		local missing = {}
		for _, name in ipairs(modules) do
			for _, required in ipairs(required_names(read(module_path(name)))) do
				if is_plugin_module(required) and not io.open(module_path(required), "rb") then
					missing[#missing + 1] = name .. " requires " .. required
				end
			end
		end

		assert.same({}, missing)
	end)

	describe("the scan for requires", function()
		it("sees the forms of require the plugin uses, and not the ones in comments", function()
			local source = [==[
local A = require("core.a")
local B = require "core.b"
local C = require('core.c')
-- local D = require("core.d")
--[[ local E = require("core.e") ]]
local F = require( "core.f" )
]==]

			assert.same({ "core.a", "core.f", "core.c", "core.b" }, required_names(source))
		end)

		it("tells plugin modules from KOReader's", function()
			assert.is_true(is_plugin_module("core.parser"))
			assert.is_true(is_plugin_module("ui.menus.list_menu"))
			assert.is_true(is_plugin_module("opds_plus_version"))
			assert.is_false(is_plugin_module("ui/widget/menu"))
			assert.is_false(is_plugin_module("socket.http"))
			assert.is_false(is_plugin_module("util"))
		end)
	end)

	it("does not make up plugin modules that are missing", function()
		local ok, err = pcall(require, "core.no_such_module")

		assert.is_false(ok)
		assert.matches("no file for plugin module 'core.no_such_module'", err)
	end)
end)
