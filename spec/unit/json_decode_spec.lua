local helper = require("helper")
local shims = require("support.json_shims")

describe("JsonDecode", function()
	local JsonDecode

	-- Makes require(name) fail, as on a KOReader without that library. helper.reset() undoes it.
	local function unavailable(name)
		helper.stub(name, nil)
		package.preload[name] = function()
			error("module '" .. name .. "' not found")
		end
	end

	local function load(stubs)
		for name, value in pairs(stubs) do
			if value == false then
				unavailable(name)
			else
				helper.stub(name, value)
			end
		end
		JsonDecode = helper.load("utils.json_decode")
	end

	before_each(helper.reset)
	after_each(helper.reset)

	for _, backend in ipairs({ "rapidjson", "luajson" }) do
		describe("with " .. backend, function()
			before_each(function()
				if backend == "rapidjson" then
					load({ rapidjson = shims.rapidjson(), json = false })
				else
					load({ rapidjson = false, json = shims.luajson() })
				end
			end)

			it("decodes objects, arrays and scalars", function()
				local value = JsonDecode.decode('{"title":"Feed","count":3,"ok":true,"tags":["a","b"]}')
				assert.same({ title = "Feed", count = 3, ok = true, tags = { "a", "b" } }, value)
			end)

			it("drops members set to null, at any depth", function()
				local value = JsonDecode.decode('{"a":null,"b":{"c":null,"d":1}}')
				assert.same({ b = { d = 1 } }, value)
			end)

			it("leaves null elements out of arrays, keeping them sequences", function()
				local value = JsonDecode.decode('{"links":[null,{"href":"/a"},null,{"href":"/b"}]}')
				assert.same({ links = { { href = "/a" }, { href = "/b" } } }, value)
				assert.equals(2, #value.links)
			end)

			it("reads text that starts with a byte order mark", function()
				assert.same({ a = 1 }, JsonDecode.decode('\239\187\191{"a":1}'))
			end)

			it("returns nil and a message for bad input", function()
				local value, err = JsonDecode.decode("{bad")
				assert.is_nil(value)
				assert.is_string(err)
			end)

			it("returns nil and a message when the whole text is null", function()
				local value, err = JsonDecode.decode("null")
				assert.is_nil(value)
				assert.is_string(err)
			end)
		end)
	end

	it("prefers rapidjson when both libraries load", function()
		local rapid = shims.rapidjson()
		local used
		local decode = rapid.decode
		rapid.decode = function(text)
			used = true
			return decode(text)
		end
		load({ rapidjson = rapid, json = shims.luajson() })
		assert.same({ a = 1 }, JsonDecode.decode('{"a":1}'))
		assert.is_true(used)
	end)

	it("returns nil and a message for missing or blank text", function()
		load({ rapidjson = shims.rapidjson() })
		local texts = { n = 4, nil, "", " \n", "\239\187\191" }
		for i = 1, texts.n do
			local value, err = JsonDecode.decode(texts[i])
			assert.is_nil(value, "text " .. i)
			assert.is_string(err, "text " .. i)
		end
	end)

	it("refuses absurdly deep nesting instead of overflowing the stack", function()
		load({ rapidjson = shims.rapidjson() })
		local value, err = JsonDecode.decode(string.rep("[", 300) .. string.rep("]", 300))
		assert.is_nil(value)
		assert.is_string(err)
	end)

	it("returns nil and a message when no decoder loads", function()
		load({ rapidjson = false, json = false })
		local value, err = JsonDecode.decode('{"a":1}')
		assert.is_nil(value)
		assert.matches("no JSON decoder", err)
	end)
end)
