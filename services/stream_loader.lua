local TrapWidget = require("ui/widget/trapwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("gettext")

local StreamLoader = { TIMEOUT = 60 }

-- Only request data crosses the worker boundary; decoding and viewer ownership stay in the parent.
function StreamLoader.start(request, callback, options)
    local job = {}
    local background = options and options.background == true
    -- Trapper only needs the dismiss callback for a background job, not an input-trapping window.
    local widget = background and {} or TrapWidget:new {
        text = options and options.text or _("Loading page... (tap or press a key to cancel)"),
    }
    job.widget = widget
    function job:cancel(reason)
        if self.done or self.cancelled then return true end
        self.cancelled = reason or "cancelled"
        if widget.dismiss_callback then widget.dismiss_callback() end
        return true
    end
    function widget:handleEvent(event)
        if event.handler == "onKeyPress" or event.handler == "onKeyRepeat" or event.handler == "onGesture" then
            return job:cancel()
        end
        return TrapWidget.handleEvent(self, event)
    end
    function widget:onSuspend() return job:cancel() end
    function widget:onCloseWidget()
        if job.widget_closed then return end
        job.widget_closed = true
        job:cancel()
        return TrapWidget.onCloseWidget(self)
    end
    local timeout = function()
        logger.warn("OPDSPSE: stream request timed out")
        job:cancel("timeout")
    end
    Trapper:wrap(function()
        if not background then
            UIManager:show(widget)
            UIManager:forceRePaint()
        end
        UIManager:scheduleIn(StreamLoader.TIMEOUT, timeout)
        local completed, packet = Trapper:dismissableRunInSubprocess(function()
            local ok, result = pcall(request)
            socketutil:reset_timeout()
            if not ok then
                logger.warn("OPDSPSE: stream request failed")
                return { error = true }
            end
            return result
        end, widget)
        job.done = true
        UIManager:unschedule(timeout)
        if not background and not job.widget_closed then UIManager:close(widget) end
        if job.cancelled then
            callback(nil, job.cancelled)
        elseif not completed then
            logger.warn("OPDSPSE: could not start stream worker")
            callback(nil, "unavailable")
        elseif type(packet) ~= "table" or packet.error then
            logger.warn("OPDSPSE: stream worker returned no usable result")
            callback(nil, "failed")
        else
            callback(packet)
        end
    end)
    return job
end

return StreamLoader
