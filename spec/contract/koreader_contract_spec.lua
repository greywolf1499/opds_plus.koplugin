-- Contract checks between the specs' stand-ins and a real KOReader install.
--
-- The rest of the suite runs against stand-ins (spec/support/, spec/vendor/) so that it needs no KOReader.
-- This tier is their safety net. It runs the stand-ins against the real modules, and it checks that every
-- KOReader API the plugin calls still exists. It is opt-in: it only runs when it finds a KOReader install
-- (KOREADER_DIR, default /usr/lib/koreader), so CI and fresh clones stay hermetic.
--
--   scripts/test.sh --contract
--   KOREADER_DIR=/opt/koreader scripts/test.sh --contract
local helper = require("helper")
local lfs = require("lfs")

local KOREADER = (os.getenv("KOREADER_DIR") or "/usr/lib/koreader"):gsub("/+$", "")

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local content = handle:read("*a")
	handle:close()
	return content
end

if lfs.attributes(KOREADER .. "/frontend/util.lua", "mode") ~= "file" then
	describe("KOReader contract", function()
		pending("no KOReader install at " .. KOREADER .. ": set KOREADER_DIR to run these checks")
	end)
	return
end

local function pack(...)
	return { n = select("#", ...), ... }
end

-- Runs a real KOReader file and returns what it returns, without registering it with require(): the
-- stand-ins that the specs use for the same module stay in place. `stand_ins` replaces the modules the
-- file needs native libraries for; everything else it requires comes from the install.
local function load_real(relative, stand_ins)
	local saved_path = package.path
	package.path = table.concat({
		KOREADER .. "/?.lua",
		KOREADER .. "/frontend/?.lua",
		KOREADER .. "/common/?.lua",
		package.path,
	}, ";")
	local already_loaded = {}
	for name in pairs(package.loaded) do
		already_loaded[name] = true
	end
	local saved = {}
	for name, value in pairs(stand_ins or {}) do
		saved[name] = { loaded = package.loaded[name], preload = package.preload[name] }
		package.loaded[name] = nil
		package.preload[name] = function()
			return value
		end
	end
	local ok, result = pcall(function()
		return assert(loadfile(KOREADER .. "/" .. relative))()
	end)
	for name, previous in pairs(saved) do
		package.loaded[name] = previous.loaded
		package.preload[name] = previous.preload
	end
	-- What the file required stays with it and does not leak into the specs that follow
	for name in pairs(package.loaded) do
		if not already_loaded[name] and not saved[name] then
			package.loaded[name] = nil
		end
	end
	package.path = saved_path
	assert(ok, result)
	return result
end

-- A call's outcome for comparing two implementations: its results, or just the fact that it failed
-- (error messages carry the position of the code that raised them).
local function outcome(fn, ...)
	local results = pack(pcall(fn, ...))
	if not results[1] then
		return { failed = true }
	end
	return results
end

local function show(args)
	local parts = {}
	for index = 1, args.n or #args do
		parts[index] = string.format("%q", tostring(args[index]))
	end
	return table.concat(parts, ", ")
end

describe("KOReader contract", function()
	before_each(helper.reset)
	after_each(helper.reset)

	describe("vendored files", function()
		local vendored = {
			["luxl.lua"] = "frontend/luxl.lua",
			["socket/url.lua"] = "common/socket/url.lua",
		}
		for copy, original in pairs(vendored) do
			it("spec/vendor/" .. copy .. " is the " .. original .. " of the installed KOReader", function()
				assert(
					read(helper.spec_root .. "/vendor/" .. copy) == read(KOREADER .. "/" .. original),
					"spec/vendor/"
						.. copy
						.. " differs from "
						.. original
						.. ": copy the installed file and update spec/vendor/README.md"
				)
			end)
		end
	end)

	describe("the util stand-in", function()
		local stand_in, real

		before_each(function()
			stand_in = require("util")
			real = load_real("frontend/util.lua", {
				["ffi/utf8proc"] = {},
				["ffi/util"] = {
					isAndroid = function()
						return false
					end,
				},
			})
			-- The original parses `mount`; util_stub.lua always answers "ext4"
			real.getFilesystemType = stand_in.getFilesystemType
		end)

		local function agrees(name, cases)
			for _, args in ipairs(cases) do
				args.n = args.n or #args
				local expected = outcome(real[name], unpack(args, 1, args.n))
				local actual = outcome(stand_in[name], unpack(args, 1, args.n))
				assert.same(expected, actual, name .. "(" .. show(args) .. ")")
			end
		end

		local long_name = string.rep("\u{e9}", 300) .. ".epub"

		local cases = {
			trim = { { "" }, { "   " }, { "x" }, { "  x  " }, { "\t a b \n" }, { "a  b" }, { " \u{e9} " } },
			stringEndsWith = { { "file.epub", ".epub" }, { "file.epub", "" }, { "a", "abc" }, { "", "" }, { "abc", "c" } },
			replaceAllInvalidChars = { { "a/b" }, { 'a:b*c?"<>|' }, { "name. " }, { "a  " }, { ".." }, { "" } },
			splitFilePathName = {
				{ "" }, { "a" }, { "/" }, { "/a" }, { "a/b" }, { "/x/y/z.epub" }, { "dir/" }, { "../x.epub" },
			},
			splitFileNameSuffix = {
				{ "" }, { "a" }, { "a.b" }, { "a.b.c" }, { ".hidden" }, { "a." }, { "x.EPUB" }, { "dir.d/file" },
			},
			getFileNameSuffix = { { "" }, { "a" }, { "a.b" }, { "a.b.c" }, { "x.EPUB" }, { "dir.d/file" } },
			fixUtf8 = {
				{ "ok", "?" }, { "\255", "?" }, { "a\195", "" }, { "\195\169\128x", "?" }, { "", "?" },
				{ "\240\159\152\128", "?" }, { "\240\159\152", "?" },
			},
			unicodeCodepointToUtf8 = {
				{ 65 }, { 233 }, { 0x7FF }, { 0x800 }, { 8364 }, { 0xFFFF }, { 128512 }, { 0x10FFFF },
			},
			htmlEntitiesToUtf8 = {
				{ "&amp;" }, { "&lt;b&gt;" }, { "&#65;" }, { "&#x1F600;" }, { "&nbsp;" }, { "&unknown;" },
				{ "a &amp;amp; b" }, { "&#xZZ;" }, { "no entity" },
			},
			htmlToPlainText = { { "<p>Hi</p>" }, { "a<br/>b" }, { "plain" }, { "x &amp; y" }, { "<b>bold</b> &lt;3" } },
			htmlToPlainTextIfHtml = { { "<p>Hi</p>" }, { "plain" }, { "a &amp; b" }, { "<b>x</b>" }, { "" } },
			getSafeFilename = {
				{ "a/b.epub" }, { "a:b.epub" }, { "x\n y.epub" }, { long_name }, { "<b>T</b>.pdf" },
				{ "no suffix" }, { "a/b.epub", "/tmp" }, { "a.thisisalongextension" }, { "a\r\nb\tc.epub" },
			},
			urlEncode = { { "a b" }, { "a/b?c=d&e" }, { "\u{e9}" }, { "100%" }, { "a b", "" }, { "a/b c", "/" } },
		}
		for name, name_cases in pairs(cases) do
			it("util." .. name .. " gives what KOReader gives", function()
				agrees(name, name_cases)
			end)
		end

		it("util.gsplit splits like KOReader", function()
			local function parts(module, ...)
				local list = {}
				for part in module.gsplit(...) do
					list[#list + 1] = part
				end
				return list
			end

			for _, args in ipairs({
				{ "a,b,,c", "," },
				{ "a b  c" },
				{ "abc", "x" },
				{ ",a,", ",", false, true },
				{ "a1b22c", "%d+", true },
				{ "", "," },
			}) do
				assert.same(parts(real, unpack(args)), parts(stand_in, unpack(args)), show(args))
			end
			assert.has_error(function()
				parts(real, "abc", "x*")
			end)
			assert.has_error(function()
				parts(stand_in, "abc", "x*")
			end)
		end)

		it("util.makePath and util.removeFile report what KOReader reports", function()
			local function exercise(module)
				local base = helper.tmpdir()
				local function relative(value)
					return type(value) == "string" and (value:gsub(base:gsub("%p", "%%%0"), "<tmp>")) or value
				end
				local nested = base .. "/a/b/c"
				local created, create_err = module.makePath(nested)
				local again = module.makePath(nested)
				local handle = assert(io.open(base .. "/file.txt", "w"))
				handle:close()
				local through_file, through_err = module.makePath(base .. "/file.txt/sub")
				local removed = module.removeFile(base .. "/file.txt")
				local not_a_file, not_a_file_err = module.removeFile(base .. "/a")
				local no_file, no_file_err = module.removeFile(nil)
				return {
					created = created and true,
					create_err = create_err,
					again = again,
					is_directory = lfs.attributes(nested, "mode"),
					through_file = through_file,
					through_err = relative(through_err),
					removed = removed and true,
					file_gone = lfs.attributes(base .. "/file.txt", "mode"),
					not_a_file = not_a_file,
					not_a_file_err = relative(not_a_file_err),
					no_file = no_file,
					no_file_err = no_file_err,
				}
			end

			assert.same(exercise(real), exercise(stand_in))
		end)
	end)

	describe("the ffi/util stand-in", function()
		it("template fills in %1, %2... like KOReader", function()
			local stand_in = require("ffi/util")
			local real = load_real("ffi/util.lua", { ["libs/libkoreader-lfs"] = lfs })
			-- KOReader's LuaJIT has Lua 5.2's table.pack; plain LuaJIT does not
			local original_pack = table.pack
			table.pack = original_pack or pack

			local ok, err = pcall(function()
				for _, args in ipairs({
					{ "no parameters" },
					{ "%1 of %2", "a", "b" },
					{ "%2 before %1", "a", "b" },
					{ "%3 is missing", "a" },
					{ "100%", "x" },
					{ "%10 is two digits", "a" },
					{ "%1 and %1", "x" },
					{ "%0 is not a parameter", "x" },
					{ "", "x" },
				}) do
					assert.same(
						outcome(real.template, unpack(args)),
						outcome(stand_in.template, unpack(args)),
						show(args)
					)
				end
			end)

			table.pack = original_pack
			assert(ok, err)
		end)
	end)

	describe("the socketutil stand-in", function()
		local stand_in, real

		before_each(function()
			stand_in = require("support.socketutil").new()
			-- LuaSocket comes from the test toolchain: KOReader's own socket.lua needs its native core
			require("socket")
			require("ltn12")
			real = load_real("frontend/socketutil.lua", {
				device = { model = "contract" },
				version = {
					getShortVersion = function()
						return "v0"
					end,
				},
				["socket.http"] = { USERAGENT = "LuaSocket 3" },
				["ssl.https"] = {},
				["ffi/util"] = require("ffi/util"),
			})
		end)

		it("has the constants of KOReader", function()
			local checked = 0
			for name, value in pairs(stand_in) do
				if type(name) == "string" and name:match("^[A-Z_]+$") then
					assert.equals(real[name], value, name)
					checked = checked + 1
				end
			end
			assert.is_true(checked >= 9)
		end)

		it("starts with the timeouts of KOReader", function()
			assert.equals(real.block_timeout, stand_in.block_timeout)
			assert.equals(real.total_timeout, stand_in.total_timeout)
		end)

		it("sets and resets the timeouts like KOReader", function()
			for _, args in ipairs({ { 1, 2 }, {}, { 7 } }) do
				real:set_timeout(unpack(args))
				stand_in:set_timeout(unpack(args))
				assert.same({ real.block_timeout, real.total_timeout }, { stand_in.block_timeout, stand_in.total_timeout })
			end

			real:reset_timeout()
			stand_in:reset_timeout()
			assert.same({ real.block_timeout, real.total_timeout }, { stand_in.block_timeout, stand_in.total_timeout })
		end)

		it("redacts what KOReader redacts from headers and requests", function()
			local headers = {
				authorization = "Basic abc",
				cookie = "a=b",
				["proxy-authorization"] = "x",
				["set-cookie"] = "c=d",
				accept = "text/html",
				["x-token"] = "visible",
			}
			local request = { url = "http://a.example/", user = "me", password = "pw", method = "GET", headers = headers }

			assert.same(real.redact_headers(headers), stand_in.redact_headers(headers))
			assert.same(real.redact_request(request), stand_in.redact_request(request))
		end)
	end)

	describe("the cache stand-in", function()
		local function exercise(Cache)
			local cache = Cache:new({ slots = 20 })
			local value = { xml = "<feed/>", etag = '"1"' }
			cache:insert("key", value)
			local found = cache:check("key")
			local missing = cache:check("other")
			cache:clear()
			return {
				same_table = rawequal(found, value),
				missing = missing,
				after_clear = cache:check("key"),
			}
		end

		it("stores, finds and clears plain tables like KOReader's Cache", function()
			local real = load_real("frontend/cache.lua", {
				["libs/libkoreader-lfs"] = lfs,
				["ffi/sha2"] = {
					md5 = function(text)
						return text
					end,
				},
			})

			assert.same(exercise(real), exercise(require("support.cache").new()))
			assert.same({ same_table = true }, { same_table = exercise(real).same_table })
		end)

		it("has no used_size, so the plugin must not call it", function()
			local real = load_real("frontend/cache.lua", {
				["libs/libkoreader-lfs"] = lfs,
				["ffi/sha2"] = { md5 = tostring },
			})

			assert.is_nil(real.used_size)
		end)
	end)

	describe("the KOReader API the plugin uses", function()
		-- Inherited from Widget and the base classes the scan can't see in a widget's own file
		local inherited = { new = true, extend = true, init = true, handleEvent = true }
		-- Modules whose members the scan can't judge: Device is assembled for each platform; the members of
		-- `socket` that are modules of their own live in other files
		local skipped = { device = true, socket = true }

		local function strip_comments(source)
			return (source:gsub("%-%-%[(=*)%[.-%]%1%]", ""):gsub("%-%-[^\n]*", ""))
		end

		local function real_source(module)
			local path_form = module:gsub("%.", "/")
			for _, form in ipairs({ "/frontend/", "/", "/common/" }) do
				local path = KOREADER .. form .. path_form .. ".lua"
				if lfs.attributes(path, "mode") == "file" then
					return read(path)
				end
			end
		end

		local function used_members()
			local names = helper.plugin_modules()
			-- The plugin's own modules are required with dots (core.parser), KOReader's with slashes
			local own, own_dirs = {}, {}
			for _, name in ipairs(names) do
				own[name] = true
				local dir = name:match("^([^.]+)%.")
				if dir then
					own_dirs[dir] = true
				end
			end
			local function is_own(module)
				local dir = module:match("^([^.]+)%.")
				return own[module] or (dir ~= nil and own_dirs[dir] == true)
			end

			local used = {} -- module -> member -> first file that uses it
			for _, name in ipairs(names) do
				local file = name:gsub("%.", "/") .. ".lua"
				local source = strip_comments(read(helper.plugin_root .. "/" .. file))
				-- `local host = require("socket.url").parse(url).host` binds a field of the module, not the module
				for alias, module, rest in source:gmatch(
					"local%s+([%w_]+)%s*=%s*require%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?([^\n]*)") do
					if not is_own(module) and not rest:find("^%s*[%.:%[%(]") then
						for member in source:gmatch("%f[%w_]" .. alias .. "[.:]([%w_]+)") do
							used[module] = used[module] or {}
							used[module][member] = used[module][member] or file
						end
					end
				end
			end
			return used
		end

		it("is still there: every member of a KOReader module the plugin calls is in that module", function()
			local used = used_members()
			local scanned, missing = {}, {}
			for module, members in pairs(used) do
				local source = not skipped[module] and real_source(module)
				if source then
					scanned[#scanned + 1] = module
					for member, file in pairs(members) do
						if not inherited[member] and not source:find("%f[%w_]" .. member .. "%f[^%w_]") then
							missing[#missing + 1] = module .. "." .. member .. " (" .. file .. ")"
						end
					end
				end
			end
			table.sort(missing)

			assert.same({}, missing)
			-- The scan must have looked at something, or an empty result proves nothing
			assert.is_true(#scanned >= 20, "scanned only " .. #scanned .. " KOReader modules")
			local scanned_set = {}
			for _, module in ipairs(scanned) do
				scanned_set[module] = true
			end
			for _, module in ipairs({ "util", "ui/uimanager", "socketutil", "luxl", "ui/bidi", "ui/trapper" }) do
				assert.is_true(scanned_set[module], module .. " was not scanned")
			end
		end)
	end)

	describe("the book types KOReader registers", function()
		-- mimetype -> set of extensions, from every addProvider("ext", "mimetype", ...) of the document providers
		local function registrations()
			local by_mimetype, extensions = {}, {}
			local dir = KOREADER .. "/frontend/document"
			for name in lfs.dir(dir) do
				if name:match("%.lua$") then
					local source = read(dir .. "/" .. name)
					for extension, mimetype in source:gmatch("addProvider%(%s*\"([^\"]+)\"%s*,%s*\"([^\"]+)\"") do
						by_mimetype[mimetype] = by_mimetype[mimetype] or {}
						by_mimetype[mimetype][extension] = true
						extensions[extension] = true
					end
				end
			end
			return by_mimetype, extensions
		end

		it("leave the types the plugin maps itself unregistered, and open what they map to", function()
			local Constants = helper.load("models.constants")
			local by_mimetype, extensions = registrations()
			assert.is_true(extensions.epub and extensions.cbz and true, "found no providers to compare with")
			for mimetype, extension in pairs(Constants.MIME_EXTENSIONS) do
				assert.is_nil(by_mimetype[mimetype], mimetype .. " is registered now: its entry is not needed")
				if extension ~= "cb7" then
					assert.is_true(extensions[extension], extension .. " is not opened by KOReader")
				end
			end
		end)

		it("include every type the stand-in registry knows, under the extension it gives", function()
			local registry = require("support.documentregistry").new()
			local by_mimetype = registrations()
			for mimetype in pairs(registry.mimetypes) do
				assert.is_table(by_mimetype[mimetype], mimetype .. " is not registered by KOReader")
				local extension = registry:mimeToExt(mimetype)
				assert.is_true(by_mimetype[mimetype][extension], mimetype .. " is not registered as " .. extension)
			end
		end)
	end)
end)
