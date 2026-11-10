-- Stand-in for KOReader's ffi/archiver Reader, for zips made by spec/support/zipbuilder.lua (stored
-- entries only). Same calls and entry tables as the real one ({ path, mode, size, index }), including
-- the quirk that extractToMemory/extractToPath only work on entries seen by iterate() on that Reader.
--
--   local archiver = require("support.fake_archiver").new({ fail_extract = { ["x/a.lua"] = true } })
--   helper.stub("ffi/archiver", archiver)
local lfs = require("lfs")

local M = {}

-- libarchive's zip reader only knows files, folders and links; other Unix modes come out as files
-- (checked by spec/contract/ota_real_libs_spec.lua).
local MODE_BITS = {
	[0x8000] = "file",
	[0x4000] = "directory",
	[0xA000] = "link",
}

local function u16(data, at)
	local a, b = data:byte(at, at + 1)
	return a + b * 256
end

local function u32(data, at)
	return u16(data, at) + u16(data, at + 2) * 65536
end

--- Reads the central directory of a stored zip
-- @return table|nil List of { path, mode, size, data }
-- @return string|nil error
function M.parse(data)
	if #data < 22 or u32(data, #data - 21) ~= 0x06054b50 then
		return nil, "Unrecognized archive format"
	end
	local eocd = #data - 21
	local count, cd_offset = u16(data, eocd + 10), u32(data, eocd + 16)
	local entries, at = {}, cd_offset + 1
	for _ = 1, count do
		if u32(data, at) ~= 0x02014b50 then
			return nil, "Damaged central directory"
		end
		local size = u32(data, at + 24)
		local name_len, extra_len, comment_len = u16(data, at + 28), u16(data, at + 30), u16(data, at + 32)
		local external = u32(data, at + 38)
		local local_offset = u32(data, at + 42)
		local name = data:sub(at + 46, at + 45 + name_len)
		local mode_bits = math.floor(external / 65536)
		mode_bits = mode_bits - mode_bits % 0x1000
		local lname, lextra = u16(data, local_offset + 27), u16(data, local_offset + 29)
		local start = local_offset + 31 + lname + lextra
		entries[#entries + 1] = {
			path = name,
			mode = MODE_BITS[mode_bits % 0x10000] or "file",
			-- and it gives a link no size
			size = MODE_BITS[mode_bits % 0x10000] == "link" and 0 or size,
			data = data:sub(start, start + size - 1),
		}
		at = at + 46 + name_len + extra_len + comment_len
	end
	return entries
end

--- A fresh archiver module
-- @param options table|nil { fail_open = bool, fail_extract = { [entry path] = true } }
function M.new(options)
	options = options or {}
	local archiver = { opened = {}, extracted = {} }

	local Reader = {}
	Reader.__index = Reader

	function Reader:new()
		return setmetatable({ entries = {}, size = 0 }, Reader)
	end

	function Reader:open(filepath)
		self.err = nil
		if options.fail_open then
			self.err = "fake open failure"
			return
		end
		local file = io.open(filepath, "rb")
		if not file then
			self.err = "Failed to open '" .. tostring(filepath) .. "'"
			return
		end
		local data = file:read("*a")
		file:close()
		local parsed, err = M.parse(data)
		if not parsed then
			self.err = err
			return
		end
		archiver.opened[#archiver.opened + 1] = filepath
		self.parsed = parsed
		self.filepath = filepath
		self.seen = {}
		return true
	end

	function Reader:iterate()
		local i = 0
		return function()
			i = i + 1
			local raw = self.parsed and self.parsed[i]
			if not raw then
				return nil
			end
			local entry = { path = raw.path, mode = raw.mode, size = raw.size, index = i }
			self.entries[i], self.entries[raw.path] = entry, entry
			self.seen[raw.path] = raw
			self.size = i
			return entry
		end
	end

	function Reader:extractToMemory(key)
		local raw = self.seen and self.seen[key]
		if not raw or raw.mode ~= "file" or (options.fail_extract or {})[key] then
			return
		end
		return raw.data
	end

	function Reader:extractToPath(key, dest_path)
		local raw = self.seen and self.seen[key]
		if not raw then
			return false, "no such path"
		end
		if (options.fail_extract or {})[key] then
			self.err = "fake extract failure"
			return false
		end
		archiver.extracted[#archiver.extracted + 1] = dest_path
		if raw.mode == "directory" then
			return lfs.attributes(dest_path, "mode") == "directory" or lfs.mkdir(dest_path) and true
		elseif raw.mode == "file" then
			local file = io.open(dest_path, "wb")
			if not file then
				return false
			end
			file:write(raw.data)
			file:close()
			return true
		end
		self.err = "fake archiver does not extract " .. raw.mode
		return false
	end

	function Reader:close()
		self.parsed = nil
		self.seen = nil
	end

	archiver.Reader = Reader
	return archiver
end

return M
