local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local StreamLoader = require("services.stream_loader")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Sync = {}
Sync.__index = Sync

function Sync.new(progress, provider, allowed)
    local self = setmetatable({ progress = progress, provider = provider, allowed = allowed, generation = 0 }, Sync)
    self.send = function() self:push() end
    return self
end

function Sync:cancel()
    self.generation = self.generation + 1
    UIManager:unschedule(self.send)
    local job = self.job
    self.job = nil
    if job then job:cancel() end
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

function Sync:pause()
    self.paused, self.ready = true, false
    self:cancel()
    self.progress:cancelChoice()
    self.progress:flush()
end

function Sync:stop()
    self.stopped = true
    self:pause()
end

function Sync:failure(message)
    self:pause()
    logger.warn("OPDS+ stream synchronization paused")
    UIManager:show(InfoMessage:new {
        text = (message or _("Could not synchronize reading progress."))
            .. "\n\n" .. _("Progress is saved locally. Reopen this stream to retry synchronization."),
    })
end

function Sync:request(work, done, background)
    if self.stopped or not self.allowed() then
        self:failure(_("Catalog settings changed. Server synchronization has stopped."))
        return
    end
    local generation = self.generation
    local job = StreamLoader.start(function()
        local result = work()
        -- Result's metatable must not cross the subprocess serialization boundary.
        return { result = { success = result.success, value = result.value, error = result.error } }
    end, function(packet, reason)
        if self.stopped or generation ~= self.generation then return end
        self.job = nil
        if not self.allowed() then
            self:failure(_("Catalog settings changed. Server synchronization has stopped."))
            return
        end
        local result = packet and packet.result
        if type(result) ~= "table" or result.success ~= true or type(result.value) ~= "table" then
            if reason == "cancelled" then self:pause()
            else self:failure(type(result) == "table" and result.error or nil) end
            done(nil, reason)
            return
        end
        done(result.value)
    end, { background = background, text = _("Checking reading progress... (tap or press a key to cancel)") })
    if not job.done then self.job = job end
end

function Sync:display(page)
    self.ready = false
    if self.viewer then self.viewer:adoptStreamPage(page)
    else self.viewer = self.open(page) end
end

function Sync:select(remote, choice, page)
    self.remote, self.paused = remote, false
    if choice == "remote" or choice == "equal" then
        page = remote.page
        self.progress:adopt(remote)
    elseif choice == "keep" then
        self.progress:keepLocal(remote, page)
    end
    self:display(page)
end

function Sync:conflict(remote, explicit_page)
    self.paused, self.ready = true, false
    UIManager:unschedule(self.send)
    if self.viewer then
        self.viewer:cancelPageRequest()
        -- Finish any decoded-but-not-yet-painted replacement before naming the local page.
        UIManager:forceRePaint()
    end
    local page = math.min(explicit_page or self.progress:page() or 1, self.provider.count)
    local function choose(choice)
        local dialog = self.dialog
        self.dialog = nil
        UIManager:close(dialog)
        if self.stopped then return end
        if choice == "offline" then
            self.paused = true
            self:display(page)
        else
            self:select(remote, choice, page)
        end
    end
    self.dialog = ButtonDialog:new {
        title = T(_("Reading progress differs.\n\nDevice: page %1 (%2)\nServer: page %3 (%4)\n\nChoose a position. Rewinds are allowed; the highest page is not chosen automatically."),
            page, page == self.provider.count and _("complete") or _("in progress"),
            remote.page, remote.completed and _("complete") or _("in progress")),
        dismissable = false,
        buttons = {
            { { text = T(_("Use device page %1"), page), callback = function() choose("keep") end } },
            { { text = T(_("Use server page %1"), remote.page), callback = function() choose("remote") end } },
            { { text = _("Read locally without syncing"), callback = function() choose("offline") end } },
        },
    }
    UIManager:show(self.dialog)
end

function Sync:start(open, fallback, explicit_page)
    self.open = open
    self:cancel()
    self.progress:cancelChoice()
    self.paused, self.ready = true, false
    self:request(function() return self.provider:pull() end, function(remote, reason)
        if not remote then
            if reason ~= "cancelled" then self:display(explicit_page or self.progress:page() or fallback or 1) end
            return
        end
        local choice = self.progress:resolve(remote, self.provider)
        if explicit_page then
            local position, completed = self.provider:target(explicit_page)
            choice = remote.position == position and remote.completed == completed and "equal" or "conflict"
        end
        if choice == "conflict" then self:conflict(remote, explicit_page)
        else self:select(remote, choice, self.progress:page()) end
    end, false)
end

function Sync:onPage(page)
    if self.stopped then return end
    self.progress:recordPage(page)
    self.progress:flush()
    self.ready = true
    self:schedule()
end

function Sync:schedule()
    UIManager:unschedule(self.send)
    if not self.stopped and not self.paused and self.ready and not self.job and self.progress:pending() then
        UIManager:scheduleIn(2, self.send)
    end
end

function Sync:push()
    if self.stopped or self.paused or not self.ready or self.job or not self.progress:pending() then return end
    local page, expected = self.progress:page(), self.remote
    self:request(function() return self.provider:synchronize(expected, page) end, function(result)
        if not result then return end
        if result.conflict then
            self:conflict(result.remote)
        else
            self.remote = result.remote
            self.progress:acknowledge(result.remote, page)
            self.progress:flush()
            self:schedule()
        end
    end, true)
end

return Sync
