local logger = require("logger")
local HttpClient = require("services.http_client")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local Constants = require("models.constants")

local ImageLoader = {}

local Batch = {
    loading = false,
    url_map = {},
    callback = nil,
    username = nil,
    password = nil,
    debug_mode = nil,
}
Batch.__index = Batch

function Batch:new(o)
    return setmetatable(o or {}, self)
end

function Batch:loadImages(urls)
    if self.loading then
        error("batch already in progress")
    end

    self.loading = true
    local url_queue = { table.unpack(urls) }
    local stop_loading = false

    local run_image
    run_image = function()
        Trapper:wrap(function()
            if stop_loading then return end

            local url = table.remove(url_queue, 1)

            if self.debug_mode then
                logger.dbg("OPDS+: Fetching cover with auth:", self.username and "yes" or "no")
            end

            local completed, success, content = Trapper:dismissableRunInSubprocess(function()
                return HttpClient.getUrlContent(url,
                    Constants.TIMEOUTS.IMAGE_LOAD,
                    Constants.TIMEOUTS.IMAGE_MAX_TIME,
                    self.username, self.password)
            end)

            if completed and success then
                self.callback(url, content)
            elseif completed and not success then
                -- Always log errors
                logger.warn("OPDS+: Failed to download cover:", content or "unknown error")
            end

            if #url_queue > 0 then
                UIManager:scheduleIn(Constants.UI_TIMING.IMAGE_BATCH_DELAY, run_image)
            else
                self.loading = false
            end
        end)
    end

    if #urls == 0 then
        self.loading = false
    end

    UIManager:nextTick(run_image)

    local halt = function()
        stop_loading = true
        UIManager:unschedule(run_image)
    end

    return halt
end

function ImageLoader:loadImages(urls, callback, username, password, debug_mode)
    local batch = Batch:new {
        username = username,
        password = password,
        debug_mode = debug_mode,
    }
    batch.callback = callback
    local halt = batch:loadImages(urls)
    return batch, halt
end

return ImageLoader
