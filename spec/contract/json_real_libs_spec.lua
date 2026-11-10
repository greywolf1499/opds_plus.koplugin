-- Contract checks for spec/support/json_shims.lua: utils/json_decode gives the same results with
-- KOReader's real rapidjson and LuaJSON as with the dkjson stand-ins the unit tier uses.
-- Opt-in like the rest of this tier (KOREADER_DIR).
local helper = require("helper")
local lfs = require("lfs")
local shims = require("support.json_shims")

local KOREADER = (os.getenv("KOREADER_DIR") or "/usr/lib/koreader"):gsub("/+$", "")

if lfs.attributes(KOREADER .. "/common/json.lua", "mode") ~= "file" then
	describe("JSON real libraries", function()
		pending("no KOReader install at " .. KOREADER .. ": set KOREADER_DIR to run these checks")
	end)
	return
end

-- Puts the install on the search paths for this file's tests. LuaJSON requires some of its parts only
-- when it decodes, so the paths and modules stay until teardown, which forgets everything loaded here
-- so the other specs' stand-ins stay as they were.
local saved = {}

local function use_koreader()
	saved.path, saved.cpath = package.path, package.cpath
	saved.loaded = {}
	for loaded in pairs(package.loaded) do
		saved.loaded[loaded] = true
	end
	package.path = table.concat({
		KOREADER .. "/?.lua", KOREADER .. "/common/?.lua", KOREADER .. "/frontend/?.lua", package.path,
	}, ";")
	package.cpath = table.concat({ KOREADER .. "/common/?.so", KOREADER .. "/libs/?.so", package.cpath }, ";")
	require("ffi/loadlib")
end

local function forget_koreader()
	for loaded in pairs(package.loaded) do
		if not saved.loaded[loaded] then
			package.loaded[loaded] = nil
		end
	end
	package.path, package.cpath = saved.path, saved.cpath
end

local SAMPLES = {
	'{"metadata":{"title":"Feed","numberOfItems":2},"links":[{"rel":["self","first"],"href":"/a"}]}',
	'{"a":null,"b":{"c":null,"d":[1,null,2]},"e":[null]}',
	'\239\187\191{"title":"caf\\u00e9","n":1.5,"t":true,"f":false}',
	'[{"href":"/x"},null,{"href":"/y"}]',
}

-- The OPDS 2.0 fixtures, captured from real servers or written to their shapes
for name in lfs.dir(helper.spec_root .. "/fixtures/opds2") do
	if name:sub(-5) == ".json" then
		SAMPLES[#SAMPLES + 1] = helper.fixture("opds2/" .. name)
	end
end

local BAD = { "{bad", "null", "", '{"a":1', "\239\187\191" }

describe("JSON real libraries", function()
	local real = {}

	setup(function()
		use_koreader()
		real.rapidjson = require("rapidjson")
		real.luajson = require("json")
	end)

	teardown(forget_koreader)

	before_each(helper.reset)
	after_each(helper.reset)

	local function decoder(rapidjson, json)
		helper.reset()
		helper.stub("rapidjson", rapidjson or nil)
		if not rapidjson then
			package.preload.rapidjson = function() error("module 'rapidjson' not found") end
		end
		helper.stub("json", json)
		return helper.load("utils.json_decode")
	end

	local function results(JsonDecode)
		local out = {}
		for i, text in ipairs(SAMPLES) do
			out[i] = JsonDecode.decode(text)
		end
		for i, text in ipairs(BAD) do
			local value, err = JsonDecode.decode(text)
			out["bad" .. i] = { value = value, has_error = type(err) == "string" }
		end
		return out
	end

	it("rapidjson gives the same results as its stand-in", function()
		local expected = results(decoder(shims.rapidjson(), shims.luajson()))
		assert.same(expected, results(decoder(real.rapidjson, real.luajson)))
	end)

	it("LuaJSON gives the same results as its stand-in", function()
		local expected = results(decoder(nil, shims.luajson()))
		assert.same(expected, results(decoder(nil, real.luajson)))
	end)

	it("rejects every bad input with a message", function()
		for _, JsonDecode in ipairs({ decoder(real.rapidjson, real.luajson), decoder(nil, real.luajson) }) do
			for i, text in ipairs(BAD) do
				local value, err = JsonDecode.decode(text)
				assert.is_nil(value, "bad input " .. i)
				assert.is_string(err, "bad input " .. i)
			end
		end
	end)
end)
