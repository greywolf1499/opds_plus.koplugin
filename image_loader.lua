local logger = require("logger")
local getUrlContent = require("url_content")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local ImageLoader = {}

local Batch = {
    loading = false,
    url_map = {},
    callback = nil,
    username = nil,
    password = nil,
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

            logger.dbg("OPDS+: Fetching cover with auth:", self.username and "yes" or "no")

            local completed, success, content = Trapper:dismissableRunInSubprocess(function()
                return getUrlContent(url, 10, 30, self.username, self.password)
            end)

            if completed and success then
                self.callback(url, content)
            elseif completed and not success then
                logger.warn("OPDS+: Failed to download cover:", content or "unknown error")
            end

            if #url_queue > 0 then
                UIManager:scheduleIn(0.2, run_image)
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

function ImageLoader:loadImages(urls, callback, username, password)
    local batch = Batch:new{
        username = username,
        password = password,
    }
    batch.callback = callback
    local halt = batch:loadImages(urls)
    return batch, halt
end

return ImageLoader
