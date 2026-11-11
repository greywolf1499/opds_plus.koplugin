-- Decodes JSON text from a catalog server into plain Lua tables.
--
-- rapidjson (bundled with KOReader since v2025.10) is used when it loads, otherwise KOReader's LuaJSON.
-- Both decoders represent JSON null with a sentinel value. Those sentinels are removed here so callers
-- can treat a missing key and a null one alike: object members set to null are dropped and null array
-- elements are left out, keeping the array a proper sequence.

local JsonDecode = {}

local BOM = "\239\187\191"

-- Tables nested deeper than this are refused rather than risking a stack overflow on hostile input
local MAX_DEPTH = 200

-- LuaJSON's decode is a table with a __call metamethod rather than a function
local function isCallable(value)
	if type(value) == "function" then
		return true
	end
	local meta = type(value) == "table" and getmetatable(value)
	return type(meta) == "table" and meta.__call ~= nil
end

-- rapidjson when it loads, else LuaJSON. Only one decoder is tried: a second would reject bad input too.
local function loadBackend()
	local ok, rapidjson = pcall(require, "rapidjson")
	if ok and type(rapidjson) == "table" and isCallable(rapidjson.decode) then
		return { null = rapidjson.null, decode = rapidjson.decode }
	end
	local ok_json, json = pcall(require, "json")
	if ok_json and type(json) == "table" and isCallable(json.decode) then
		return { null = json.util and json.util.null, decode = json.decode }
	end
end

local function scrub(value, null, depth)
	if value == null and null ~= nil then
		return nil
	end
	if type(value) ~= "table" then
		return value
	end
	if depth > MAX_DEPTH then
		error("JSON nested too deeply", 0)
	end

	local result = {}
	local length = #value
	local sequence_count = 0
	for i = 1, length do
		local item = scrub(value[i], null, depth + 1)
		if item ~= nil then
			sequence_count = sequence_count + 1
			result[sequence_count] = item
		end
	end
	for key, item in pairs(value) do
		local is_array_index = type(key) == "number" and key >= 1 and key <= length and key % 1 == 0
		if not is_array_index then
			result[key] = scrub(item, null, depth + 1)
		end
	end
	return result
end

--- Decodes JSON text
-- @param text string JSON text, optionally starting with a UTF-8 byte order mark
-- @return any|nil The decoded value with null sentinels removed, or nil when it cannot be decoded
-- @return string|nil An error message when decoding failed
function JsonDecode.decode(text)
	if type(text) ~= "string" then
		return nil, "no JSON text"
	end
	if text:sub(1, 3) == BOM then
		text = text:sub(4)
	end
	if not text:find("%S") then
		return nil, "empty JSON text"
	end

	local backend = loadBackend()
	if not backend then
		return nil, "no JSON decoder available"
	end
	local ok, decoded, decode_err = pcall(function()
		return backend.decode(text)
	end)
	if not ok then
		return nil, tostring(decoded)
	end
	if decoded == nil or (decoded == backend.null and backend.null ~= nil) then
		return nil, decode_err and tostring(decode_err) or "JSON text decodes to nothing"
	end

	local scrubbed_ok, result = pcall(scrub, decoded, backend.null, 1)
	if not scrubbed_ok then
		return nil, tostring(result)
	end
	return result
end

return JsonDecode
