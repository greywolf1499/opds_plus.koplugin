local HttpClient = require("services.http_client")
local UIManager = require("ui/uimanager")
local Constants = require("models.constants")
local Debug = require("utils.debug")
local CoverCache = require("services.cover_cache")

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
    local stop_loading = false
    local pending_urls = { table.unpack(urls) }
    local ttl_seconds = (self.cache_ttl_minutes or Constants.COVER_CACHE.DEFAULT_TTL_MINUTES) * 60
    local max_bytes = (self.cache_max_mb or Constants.COVER_CACHE.DEFAULT_MAX_MB) * 1024 * 1024

    local run_image
    run_image = function()
        if stop_loading then
            self.loading = false
            return
        end

        local url = table.remove(pending_urls, 1)
        if not url then
            self.loading = false
            return
        end

        local stale_content = nil
        if self.cover_cache_enabled ~= false then
            local cached = CoverCache.get(url, ttl_seconds)
            if cached and not cached.stale then
                Debug.log("ImageLoader:", "Cover cache hit:", url)
                if self.callback then
                    self.callback(url, cached.content)
                end

                if #pending_urls > 0 then
                    UIManager:scheduleIn(Constants.UI_TIMING.IMAGE_BATCH_DELAY, run_image)
                else
                    self.loading = false
                end
                return
            end

            Debug.log("ImageLoader:", "Cover cache miss:", url)
            if cached and cached.content then
                stale_content = cached.content
            end
        end

        Debug.log("ImageLoader:", "Fetching cover with auth:", self.username and "yes" or "no")

        local success, content = HttpClient.getUrlContent(
            url,
            Constants.TIMEOUTS.IMAGE_LOAD,
            Constants.TIMEOUTS.IMAGE_MAX_TIME,
            self.username,
            self.password
        )

        if stop_loading then
            self.loading = false
            return
        end

        if success then
            if self.callback then
                self.callback(url, content)
            end

            if self.cover_cache_enabled ~= false then
                CoverCache.put(url, content, max_bytes)
            end
        else
            Debug.error("ImageLoader:", "Failed to download cover:", content or "unknown error")
            if stale_content and self.callback then
                self.callback(url, stale_content)
            end
        end

        if #pending_urls > 0 then
            UIManager:scheduleIn(Constants.UI_TIMING.IMAGE_BATCH_DELAY, run_image)
        else
            self.loading = false
        end
    end

    if #urls == 0 then
        self.loading = false
    end

    UIManager:nextTick(run_image)

    local halt = function()
        stop_loading = true
        self.loading = false
        self.callback = nil
        UIManager:unschedule(run_image)
    end

    return halt
end

--- Load images from URLs asynchronously
-- @param urls table Array of URLs to load
-- @param callback function Callback(url, content) called for each loaded image
-- @param username string|nil HTTP auth username
-- @param password string|nil HTTP auth password
-- @param cover_cache_enabled boolean|nil Whether to use in-memory cover cache (default: true)
-- @param cache_max_mb number|nil Maximum cache size in MB
-- @param cache_ttl_minutes number|nil Cache TTL in minutes
-- @return table, function Batch instance and halt function
function ImageLoader:loadImages(urls, callback, username, password, cover_cache_enabled, cache_max_mb, cache_ttl_minutes)
    local batch = Batch:new {
        username = username,
        password = password,
        cover_cache_enabled = cover_cache_enabled ~= false,
        cache_max_mb = cache_max_mb,
        cache_ttl_minutes = cache_ttl_minutes,
    }
    batch.callback = callback
    local halt = batch:loadImages(urls)
    return batch, halt
end

--- Clear disk cover cache.
function ImageLoader.clearCache()
    CoverCache.clear()
end

return ImageLoader
