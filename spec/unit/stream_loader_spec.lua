local helper = require("helper")
local ui_stub = require("support.ui")
local socketutil_stub = require("support.socketutil")

describe("Cancellable stream worker", function()
    local Loader, ui, pending, thread, received, calls
    before_each(function()
        helper.reset()
        ui, received, calls = ui_stub.new(), {}, 0
        local trapper = {}
        function trapper:wrap(work)
            thread = coroutine.create(work)
            assert(coroutine.resume(thread))
        end
        function trapper:dismissableRunInSubprocess(work, widget)
            pending = work
            widget.dismiss_callback = function() assert(coroutine.resume(thread, false)) end
            return coroutine.yield()
        end
        ui.stubs["ui/trapper"] = trapper
        ui.stubs.socketutil = socketutil_stub.new()
        Loader = helper.load("services.stream_loader", ui.stubs)
    end)
    after_each(helper.reset)

    local function receive(packet, reason)
        calls = calls + 1
        received = { packet = packet, reason = reason }
    end
    local function finish(completed, packet)
        assert(coroutine.resume(thread, completed, packet))
    end

    it("delivers plain request data only after completion and clears its watchdog", function()
        local job = Loader.start(function() return { data = "image" } end, receive)
        assert.equals(0, calls)
        assert.equals(1, #ui.scheduled)
        finish(true, pending())
        assert.same({ packet = { data = "image" } }, received)
        assert.is_true(job.done)
        assert.same({}, ui.scheduled)
        assert.equals(job.widget, ui.closed[1])
        job:cancel()
        assert.equals(1, calls)
    end)

    it("cancels raw key, repeat and pan input instead of waiting for the server", function()
        for _, handler in ipairs({ "onKeyPress", "onKeyRepeat", "onGesture" }) do
            local job = Loader.start(function() error("must not run") end, receive)
            job.widget:handleEvent({ handler = handler, args = { { ges = "pan" } } })
            assert.is_true(job.done)
            assert.equals("cancelled", received.reason)
            assert.same({}, ui.scheduled)
        end
        assert.equals(3, calls)
    end)

    it("cancels suspended and externally closed loading widgets once", function()
        local job = Loader.start(function() return {} end, receive)
        job.widget:onCloseWidget()
        assert.same({}, ui.closed)
        job.widget:onSuspend()
        assert.equals("cancelled", received.reason)
        assert.equals(1, calls)
    end)

    it("reports a watchdog timeout distinctly from user cancellation", function()
        Loader.start(function() return {} end, receive)
        ui:run_scheduled()
        assert.equals("timeout", received.reason)
        assert.equals(1, calls)
        assert.is_true(require("logger").logged("warn", "timed out"))
    end)

    it("refuses a failed fork without an implicit synchronous retry", function()
        Loader.start(function() error("must not run") end, receive)
        finish(false)
        assert.equals("unavailable", received.reason)
        assert.is_true(require("logger").logged("warn", "could not start"))
    end)

    it("reports exceptions and invalid worker output without logging request details", function()
        Loader.start(function() error("private request details") end, receive)
        finish(true, pending())
        assert.equals("failed", received.reason)
        assert.is_false(require("logger").logged("warn", "private request details"))
        Loader.start(function() return {} end, receive)
        finish(true)
        assert.equals("failed", received.reason)
    end)
end)
