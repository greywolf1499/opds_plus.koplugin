local CatalogUtils = require("utils.catalog_utils")
local logger = require("logger")

local Progress = { MAX_SAVED_STREAMS = 500 }
Progress.__index = Progress

local function snapshot(remote)
    return {
        position = remote.position, page = remote.page, completed = remote.completed, modified = remote.modified,
    }
end

function Progress.new(settings, key, count, save, scope)
    local records = settings.stream_progress or {}
    local record = records[key]
    if record ~= nil and (type(record) ~= "table" or not CatalogUtils.pageNumber(record.page)) then
        logger.warn("OPDSPSE: invalid saved stream position")
        record = nil
    end
    local self = setmetatable({
        settings = settings, key = key, count = CatalogUtils.pageNumber(count),
        records = records, record = record or {}, save = save, scope = scope,
    }, Progress)
    local baseline = self.record.sync
    if baseline ~= nil then
        local remote = type(baseline) == "table" and baseline.remote
        if type(remote) ~= "table" or type(remote.position) ~= "number"
            or remote.position < 0 or remote.position % 1 ~= 0
            or (self.count and remote.position > self.count)
            or type(remote.page) ~= "number" or not CatalogUtils.pageNumber(remote.page)
            or (self.count and remote.page > self.count)
            or type(remote.completed) ~= "boolean"
            or (remote.modified ~= nil and type(remote.modified) ~= "string")
            or (baseline.local_page ~= nil
                and (type(baseline.local_page) ~= "number" or not CatalogUtils.pageNumber(baseline.local_page))) then
            logger.warn("OPDSPSE: invalid saved stream synchronization baseline")
            self.record.sync = nil
        end
    end
    if scope and self.record.sync and self.record.sync.scope ~= scope then
        self.record.sync = nil
        logger.dbg("OPDSPSE: authentication changed; discarding synchronization baseline")
    end
    return self
end

function Progress:page()
    return CatalogUtils.pageNumber(self.record.page)
end

function Progress:pending()
    local page = self:page()
    return page ~= nil and (not self.record.sync or page ~= self.record.sync.local_page)
end

function Progress:resolve(remote, provider)
    local page, baseline = self:page(), self.record.sync
    if not page then return "remote" end
    local target, completed = provider:target(page)
    if remote.position == target and remote.completed == completed then return "equal" end
    if baseline and provider.same(baseline.remote, remote) then return "local" end
    if baseline and not self:pending() then return "remote" end
    return "conflict"
end

-- Choosing a remote position must not discard local progress if its image fails or is cancelled.
function Progress:cancelChoice()
    self.adopting, self.keeping = nil, nil
end

function Progress:adopt(remote)
    self.adopting = snapshot(remote)
    self.keeping = nil
end

function Progress:keepLocal(remote, page)
    self.adopting = nil
    if page then
        self.keeping = { remote = snapshot(remote), page = page }
        return
    end
    self.record.sync = { remote = snapshot(remote), scope = self.scope }
    self.dirty = true
end

function Progress:acknowledge(remote, sent_page)
    self.record.sync = { remote = snapshot(remote), local_page = sent_page, scope = self.scope }
    self.dirty = true
end

-- Call only after a successfully decoded page has actually been painted.
function Progress:recordPage(page)
    page = CatalogUtils.pageNumber(page)
    if not page or (self.count and page > self.count) then
        logger.warn("OPDSPSE: invalid displayed stream position")
        return false
    end
    self.record.page, self.record.updated = page, os.time()
    if self.adopting and self.adopting.page == page then
        self:acknowledge(self.adopting, page)
    elseif self.keeping and self.keeping.page == page then
        self:keepLocal(self.keeping.remote)
    end
    self.adopting, self.keeping = nil, nil
    self.records[self.key] = self.record
    self.settings.stream_progress = self.records
    self.dirty = true
    local size = 0
    for record_key in pairs(self.records) do
        if record_key ~= self.key then size = size + 1 end
    end
    while size >= self.MAX_SAVED_STREAMS do
        local oldest, oldest_time
        for record_key, record in pairs(self.records) do
            local stamp = type(record) == "table" and tonumber(record.updated) or 0
            stamp = stamp or 0
            if record_key ~= self.key and (not oldest or stamp < oldest_time) then
                oldest, oldest_time = record_key, stamp
            end
        end
        self.records[oldest] = nil
        size = size - 1
    end
    return true
end

function Progress:flush()
    if self.dirty then
        self.save(self.records)
        self.dirty = false
    end
end

return Progress
