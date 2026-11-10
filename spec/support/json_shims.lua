-- Stand-ins for KOReader's JSON decoders, built on dkjson so the unit tier needs no KOReader install.
-- They mimic how each real library reports null and bad input; spec/contract/json_real_libs_spec.lua
-- checks that utils/json_decode gives the same results with the real libraries.
local dkjson = require("dkjson")

local shims = {}

--- Like rapidjson: null is a unique sentinel, bad input returns nil and a message.
function shims.rapidjson()
	local null = setmetatable({}, { __tostring = function() return "rapidjson.null" end })
	return {
		null = null,
		decode = function(text)
			local value, _, err = dkjson.decode(text, 1, null)
			if err then
				return nil, err
			end
			return value
		end,
	}
end

--- Like LuaJSON (KOReader's json): null is json.util.null, bad input raises an error, and decode is a
-- callable table rather than a function.
function shims.luajson()
	local null = function() end
	local decode = setmetatable({}, {
		__call = function(_, text)
			local value, _, err = dkjson.decode(text, 1, null)
			if err then
				error(err)
			end
			return value
		end,
	})
	return { util = { null = null }, decode = decode }
end

return shims
