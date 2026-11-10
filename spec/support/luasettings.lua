-- File-backed stand-in for KOReader's frontend/luasettings.lua (v2026.07.1), for specs.
--
-- Same on-disk contract as the real module: a settings file is a Lua chunk that returns the data
-- table; open() falls back to "<file>.old"; flush() first moves a file older than 60 seconds to
-- ".old". Only what the plugin (and its specs) use is implemented: open, readSetting, saveSetting,
-- delSetting, has, flush, close and purge. Files are written as plain Lua so a spec can also read or
-- seed them directly.
local lfs = require("lfs")

local LuaSettings = {}
LuaSettings.__index = LuaSettings

local function sorted_keys(tbl)
	local keys = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		if type(a) ~= type(b) then
			return type(a) < type(b)
		end
		return a < b
	end)
	return keys
end

local function serialize(value, depth, parents)
	local kind = type(value)
	if kind == "table" then
		if parents[value] then
			return "nil --[[ LOOP ]]"
		end
		parents[value] = true
		local lines = {}
		for _, key in ipairs(sorted_keys(value)) do
			lines[#lines + 1] = string.rep("\t", depth + 1)
				.. "["
				.. serialize(key, depth + 1, parents)
				.. "] = "
				.. serialize(value[key], depth + 1, parents)
				.. ","
		end
		parents[value] = nil
		if #lines == 0 then
			return "{}"
		end
		return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.rep("\t", depth) .. "}"
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	end
	return "nil"
end

--- Serializes `data` the way flush() does (a chunk that returns it).
function LuaSettings.dump(data)
	return "-- we can read Lua syntax here!\nreturn " .. serialize(data, 0, {}) .. "\n"
end

function LuaSettings:open(file_path)
	local new = setmetatable({ file = file_path }, LuaSettings)
	local ok, stored = pcall(dofile, file_path)
	if not (ok and stored) then
		ok, stored = pcall(dofile, file_path .. ".old")
	end
	new.data = (ok and stored) or {}
	return new
end

function LuaSettings:readSetting(key, default)
	if not default then
		return self.data[key]
	end
	if self.data[key] == nil then
		self.data[key] = default
	end
	return self.data[key]
end

function LuaSettings:saveSetting(key, value)
	self.data[key] = value
	return self
end

function LuaSettings:delSetting(key)
	self.data[key] = nil
	return self
end

function LuaSettings:has(key)
	return self.data[key] ~= nil
end

function LuaSettings:backup(file)
	file = file or self.file
	if lfs.attributes(file, "mode") == "file" and lfs.attributes(file, "modification") < os.time() - 60 then
		os.rename(file, file .. ".old")
	end
end

function LuaSettings:flush()
	if not self.file then
		return
	end
	self:backup()
	local handle = assert(io.open(self.file, "w"))
	handle:write(LuaSettings.dump(self.data))
	handle:close()
	return self
end

function LuaSettings:close()
	self:flush()
end

function LuaSettings:purge()
	if self.file then
		os.remove(self.file)
	end
	return self
end

return LuaSettings
