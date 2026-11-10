-- Builds zip archives in memory for specs: stored (uncompressed) entries, with a Unix mode in the central
-- directory so readers see files, folders, links and devices as they would in a real archive.
-- spec/support/fake_archiver.lua reads them back; the contract tier checks KOReader's ffi/archiver
-- reads them the same way.
local bit = require("bit")

local zipbuilder = {}

local MODES = {
	file = 0x8000 + 420, -- 0644
	directory = 0x4000 + 493, -- 0755
	link = 0xA000 + 511,
	["char device"] = 0x2000 + 420,
	["block device"] = 0x6000 + 420,
	["named pipe"] = 0x1000 + 420,
	socket = 0xC000 + 420,
}
zipbuilder.MODES = MODES

local crc_table = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if bit.band(c, 1) == 1 then
			c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
		else
			c = bit.rshift(c, 1)
		end
	end
	crc_table[i] = c
end

function zipbuilder.crc32(data)
	local crc = 0xFFFFFFFF
	for i = 1, #data do
		crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, data:byte(i)), 0xFF)])
	end
	crc = bit.bnot(crc)
	if crc < 0 then
		crc = crc + 0x100000000
	end
	return crc
end

local function u16(n)
	return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
	return u16(n % 65536) .. u16(math.floor(n / 65536) % 65536)
end

--- Builds a zip
-- @param entries table List of { path = string, mode = "file"|"directory"|"link"|..., content = string }.
--   A link's content is its target. Names are written as given, so specs can craft hostile ones.
-- @return string The zip bytes
function zipbuilder.build(entries)
	local locals, central = {}, {}
	local offset = 0
	for _, entry in ipairs(entries) do
		local mode = MODES[entry.mode or "file"] or error("unknown mode " .. tostring(entry.mode))
		local data = entry.content or ""
		local crc = zipbuilder.crc32(data)
		local name = entry.path
		local header = table.concat({
			u32(0x04034b50), u16(10), u16(0), u16(0), u16(0), u16(0x21),
			u32(crc), u32(#data), u32(#data), u16(#name), u16(0), name,
		})
		locals[#locals + 1] = header .. data
		central[#central + 1] = table.concat({
			u32(0x02014b50), u16(0x0300 + 30), u16(10), u16(0), u16(0), u16(0), u16(0x21),
			u32(crc), u32(#data), u32(#data), u16(#name), u16(0), u16(0), u16(0), u16(0),
			u32(mode * 65536), u32(offset), name,
		})
		offset = offset + #header + #data
	end
	local directory = table.concat(central)
	return table.concat(locals) .. directory .. table.concat({
		u32(0x06054b50), u16(0), u16(0), u16(#entries), u16(#entries),
		u32(#directory), u32(offset), u16(0),
	})
end

--- A plugin release as the release script packages it: every file under one top-level folder
-- @param files table name -> content, names relative to the plugin folder
-- @param prefix string|nil Top-level folder, default "opds_plus.koplugin"
function zipbuilder.plugin(files, prefix)
	prefix = prefix or "opds_plus.koplugin"
	local names = {}
	for name in pairs(files) do
		names[#names + 1] = name
	end
	table.sort(names)
	local entries = { { path = prefix .. "/", mode = "directory" } }
	local dirs = {}
	for _, name in ipairs(names) do
		local parent = ""
		for component in name:gmatch("([^/]+)/") do
			parent = parent .. component .. "/"
			if not dirs[parent] then
				dirs[parent] = true
				entries[#entries + 1] = { path = prefix .. "/" .. parent, mode = "directory" }
			end
		end
		entries[#entries + 1] = { path = prefix .. "/" .. name, mode = "file", content = files[name] }
	end
	return zipbuilder.build(entries)
end

return zipbuilder
