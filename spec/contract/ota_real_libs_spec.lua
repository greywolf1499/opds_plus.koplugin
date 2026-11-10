-- Contract checks for the OTA updater's test doubles: KOReader's real ffi/archiver reads zipbuilder's
-- zips exactly as spec/support/fake_archiver.lua does, and the real ffi/sha2 agrees with
-- spec/support/sha256_stub.lua. Opt-in like the rest of this tier (KOREADER_DIR).
local helper = require("helper")
local lfs = require("lfs")
local zipbuilder = require("support.zipbuilder")
local fake_archiver = require("support.fake_archiver")
local sha256_stub = require("support.sha256_stub")

local KOREADER = (os.getenv("KOREADER_DIR") or "/usr/lib/koreader"):gsub("/+$", "")

if lfs.attributes(KOREADER .. "/ffi/archiver.lua", "mode") ~= "file" then
	describe("OTA real libraries", function()
		pending("no KOReader install at " .. KOREADER .. ": set KOREADER_DIR to run these checks")
	end)
	return
end

-- Loads a KOReader module with the install on package.path, leaving the specs' stand-ins alone.
local function load_real(name)
	local saved_path, saved_cpath = package.path, package.cpath
	package.path = table.concat({ KOREADER .. "/?.lua", KOREADER .. "/frontend/?.lua", package.path }, ";")
	package.cpath = table.concat({ KOREADER .. "/?.so", KOREADER .. "/libs/?.so", package.cpath }, ";")
	local before = {}
	for loaded in pairs(package.loaded) do
		before[loaded] = true
	end
	local ok, result = pcall(function()
		require("ffi/loadlib")
		return assert(loadfile(KOREADER .. "/" .. name .. ".lua"))()
	end)
	for loaded in pairs(package.loaded) do
		if not before[loaded] and loaded ~= "ffi/loadlib" then
			package.loaded[loaded] = nil
		end
	end
	package.path, package.cpath = saved_path, saved_cpath
	assert(ok, result)
	return result
end

describe("OTA real libraries", function()
	local dir

	before_each(function()
		helper.reset()
		dir = helper.tmpdir()
	end)

	after_each(helper.reset)

	local function listing(archiver, path)
		local reader = archiver.Reader:new()
		assert(reader:open(path), reader.err)
		local entries, contents = {}, {}
		for entry in reader:iterate() do
			entries[#entries + 1] = { path = entry.path, mode = entry.mode, size = tonumber(entry.size) }
		end
		for _, entry in ipairs(entries) do
			if entry.mode == "file" then
				local fresh = archiver.Reader:new()
				assert(fresh:open(path))
				for _ in fresh:iterate() do -- luacheck: ignore 512
				end
				contents[entry.path] = fresh:extractToMemory(entry.path)
				fresh:close()
			end
		end
		reader:close()
		return entries, contents
	end

	it("ffi/archiver reads zipbuilder zips as fake_archiver does", function()
		local path = helper.fs.write(dir .. "/release.zip", zipbuilder.build({
			{ path = "opds_plus.koplugin/", mode = "directory" },
			{ path = "opds_plus.koplugin/main.lua", content = "return {}\n" },
			{ path = "opds_plus.koplugin/core/", mode = "directory" },
			{ path = "opds_plus.koplugin/core/x.lua", content = ("x"):rep(5000) },
			{ path = "opds_plus.koplugin/link", mode = "link", content = "/etc" },
			{ path = "opds_plus.koplugin/../escaped.txt", content = "pwned" },
			{ path = "opds_plus.koplugin/fifo", mode = "named pipe" },
		}))
		local real_entries, real_contents = listing(load_real("ffi/archiver"), path)
		local fake_entries, fake_contents = listing(fake_archiver.new(), path)
		assert.same(real_entries, fake_entries)
		assert.same(real_contents, fake_contents)
	end)

	it("ffi/sha2.sha256 agrees with sha256_stub", function()
		local sha2 = load_real("ffi/sha2")
		local zip = zipbuilder.plugin({ ["main.lua"] = "return {}\n" })
		for _, message in ipairs({ "", "abc", ("\255"):rep(55), ("z"):rep(64), ("q"):rep(1000), zip }) do
			assert.equals(sha2.sha256(message), sha256_stub.sha256(message))
		end
	end)
end)
