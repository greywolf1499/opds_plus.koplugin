local helper = require("helper")
local ui_stub = require("support.ui")

describe("Two-way streaming coordinator", function()
    local Sync, progress, provider, ui, jobs, selected, sync, settings, allowed, Result
    local function remote(page)
        return { position = page, page = page, completed = page == 10, modified = tostring(page) }
    end
    local function finish(index, reason)
        local job = jobs[index]
        job.done = true
        job.callback(not reason and job.work() or nil, reason)
    end
    local function paint(page) sync:onPage(page) end
    local function start()
        sync:start(function(page) selected = page end, 1)
        finish(#jobs)
    end
    before_each(function()
        helper.reset()
        ui, jobs, settings, allowed = ui_stub.new(), {}, {}, true
        ui.stubs["services.stream_loader"] = { start = function(work, callback, options)
            local job = { work = work, callback = callback, options = options }
            function job:cancel() self.cancelled = true end
            jobs[#jobs + 1] = job
            return job
        end }
        Sync = helper.load("core.stream_sync", ui.stubs)
        Result = require("utils.result")
        progress = require("core.stream_progress").new(settings, "book", 10, function() end, "scope")
        provider = { count = 10, remote = remote(3), writes = {} }
        function provider:target(page) return page, page == 10 end
        function provider.same(a, b)
            return a and b and a.position == b.position and a.completed == b.completed and a.modified == b.modified
        end
        function provider:pull()
            return self.offline and Result.err("Offline") or Result.ok(self.remote)
        end
        function provider:synchronize(expected, page)
            if not self.same(expected, self.remote) then
                return Result.ok({ conflict = true, remote = self.remote })
            end
            self.writes[#self.writes + 1] = page
            self.remote = remote(page)
            return Result.ok({ remote = self.remote })
        end
        sync = Sync.new(progress, provider, function() return allowed end)
    end)
    after_each(helper.reset)

    it("coalesces painted pages and retains a rewind made during an older write", function()
        start()
        assert.equals(3, selected)
        assert.is_nil(settings.stream_progress)
        paint(3)
        ui:run_scheduled()
        assert.equals(1, #jobs)
        paint(5)
        paint(6)
        assert.equals(1, #ui.scheduled)
        ui:run_scheduled()
        assert.is_true(jobs[2].options.background)
        paint(2)
        finish(2)
        assert.same({ 6 }, provider.writes)
        assert.equals(2, progress:page())
        assert.is_true(progress:pending())
        ui:run_scheduled()
        finish(3)
        assert.same({ 6, 2 }, provider.writes)
        assert.is_false(progress:pending())
    end)

    it("keeps local state offline and does not retry blindly on each page turn", function()
        progress:recordPage(4)
        provider.offline = true
        start()
        assert.equals(4, selected)
        assert.matches("saved locally", ui:last().text)
        paint(5)
        ui:run_scheduled()
        assert.equals(1, #jobs)
        assert.same({}, provider.writes)
        assert.equals(5, settings.stream_progress.book.page)
    end)

    it("asks on concurrent changes and adopts a server choice only after paint", function()
        progress:recordPage(3)
        progress:acknowledge(remote(3), 3)
        paint(4)
        provider.remote = remote(7)
        start()
        assert.equals("ButtonDialog", ui:last().kind)
        ui:press(ui:last(), "Use server page 7")
        assert.equals(7, selected)
        assert.equals(4, progress:page())
        sync:pause()
        assert.equals(4, progress:page())
        start()
        ui:press(ui:last(), "Use server page 7")
        paint(7)
        assert.is_false(progress:pending())
        ui:run_scheduled()
        assert.same({}, provider.writes)
    end)

    it("allows explicit local conflict choices without discarding server changes before paint", function()
        progress:recordPage(4)
        start()
        ui:press(ui:last(), "Use device page 4")
        assert.is_nil(settings.stream_progress.book.sync)
        paint(4)
        ui:run_scheduled()
        provider.remote = remote(8)
        finish(#jobs)
        assert.equals("ButtonDialog", ui:last().kind)
        assert.same({}, provider.writes)
        ui:press(ui:last(), "Read locally without syncing")
        paint(6)
        ui:run_scheduled()
        assert.same({}, provider.writes)
        assert.equals(6, progress:page())
    end)

    it("cancels on suspend and ignores late acknowledgements without losing pending state", function()
        start()
        paint(3)
        paint(5)
        ui:run_scheduled()
        sync:pause()
        assert.is_true(jobs[2].cancelled)
        finish(2)
        assert.is_true(progress:pending())
        assert.equals(3, settings.stream_progress.book.sync.local_page)
        start()
        paint(5)
        assert.is_false(progress:pending())
        ui:run_scheduled()
        assert.same({ 5 }, provider.writes)
    end)

    it("refuses scheduled writes after settings change and rejects results after a new session", function()
        start()
        paint(3)
        paint(5)
        allowed = false
        ui:run_scheduled()
        assert.equals(1, #jobs)
        assert.matches("settings changed", ui:last().text)
        assert.is_true(progress:pending())
        allowed = true
        start()
        paint(5)
        ui:run_scheduled()
        sync:stop()
        finish(#jobs)
        assert.is_true(progress:pending())
    end)
end)
