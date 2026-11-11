local Constants = require("models.constants")

local CoverMemory = {}
CoverMemory.__index = CoverMemory

function CoverMemory:new(max_bytes)
	return setmetatable({
		max_bytes = max_bytes or Constants.COVER_CACHE.DECODED_MAX_BYTES,
		bytes = 0,
		pinned_bytes = 0,
		clock = 0,
		records = {},
		entries = {},
	}, self)
end

local function detach(memory, record)
	local entry = record.entry
	if entry then
		memory.entries[entry] = nil
		entry.cover_bb = nil
		entry.lazy_load_cover = true
		record.entry = nil
	end
end

function CoverMemory:_free(record)
	assert(record.pins == 0, "cannot free a pinned cover")
	detach(self, record)
	self.records[record.bb] = nil
	self.bytes = self.bytes - record.bytes
	record.bb:free()
end

function CoverMemory:_retire(record)
	detach(self, record)
	record.retired = true
	if record.pins == 0 then self:_free(record) end
end

function CoverMemory:_trim()
	while self.bytes > self.max_bytes do
		local oldest
		for _, record in pairs(self.records) do
			if record.pins == 0 and (not oldest or record.used < oldest.used) then
				oldest = record
			end
		end
		if not oldest then break end
		self:_free(oldest)
	end
end

function CoverMemory:pin(bb)
	local record = assert(self.records[bb], "cannot pin an unowned cover")
	self.clock = self.clock + 1
	record.used = self.clock
	if record.pins == 0 then self.pinned_bytes = self.pinned_bytes + record.bytes end
	record.pins = record.pins + 1
	local released = false
	return function()
		if released then return end
		released = true
		record.pins = record.pins - 1
		if record.pins == 0 then
			self.pinned_bytes = self.pinned_bytes - record.bytes
			if record.retired then self:_free(record) end
		end
		self:_trim()
	end
end

function CoverMemory:add(entry, bb)
	assert(not self.records[bb], "cover is already owned")
	if entry and self.entries[entry] then self:_retire(self.entries[entry]) end
	-- Match BlitBuffer's allocation, including row padding and unrotated height.
	local bytes = assert(tonumber(bb.stride * bb.h), "cover has no allocation size")
	local record = {
		bb = bb, bytes = bytes, pins = 0, entry = entry,
		retired = entry == nil,
	}
	self.records[bb] = record
	self.bytes = self.bytes + bytes
	if entry then
		self.entries[entry] = record
		entry.cover_bb = bb
		entry.lazy_load_cover = false
	end
	local release = self:pin(bb)
	self:_trim()
	return release
end

function CoverMemory:get(entry)
	local record = self.entries[entry]
	if not record then return end
	self.clock = self.clock + 1
	record.used = self.clock
	return record.bb
end

function CoverMemory:clear()
	-- A closed listing can still have borrowers in an open dialog.
	for _, record in pairs(self.records) do self:_retire(record) end
end

return CoverMemory
