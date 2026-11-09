local HttpClient = require("services.http_client")
local UIManager = require("ui/uimanager")
local Constants = require("models.constants")
local Debug = require("utils.debug")
local CoverCache = require("services.cover_cache")
local FFIUtil = require("ffi/util")
local ffi = require("ffi")
local time = require("ui/time")
require("ffi/posix_h")

if ffi.os == "Linux" then
    -- pcall: a no-op if KOReader already declares it.
    pcall(ffi.cdef, "int prctl(int, ...);")
end

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

-- Fetch one URL in a forked subprocess, which writes the body to a temporary
-- file: a pipe could fill up and block the child before it exits. Returns nil
-- when no subprocess could be started.
local function startFetch(url, username, password)
    -- os.tmpname() raises where /tmp does not exist (Android).
    local has_path, path = pcall(os.tmpname)
    if not has_path then
        return nil
    end
    local parent = ffi.C.getpid()
    local pid = FFIUtil.runInSubProcess(function()
        if ffi.os == "Linux" then
            -- Die with the UI process (PR_SET_PDEATHSIG = 1, SIGKILL = 9); bail
            -- out if it is already gone.
            local word = ffi.typeof("unsigned long")
            if ffi.C.prctl(1, word(9), word(0), word(0), word(0)) ~= 0 or ffi.C.getppid() ~= parent then
                return
            end
        end
        local success, content = HttpClient.getUrlContent(
            url,
            Constants.TIMEOUTS.IMAGE_LOAD,
            Constants.TIMEOUTS.IMAGE_MAX_TIME,
            username,
            password
        )
        if success and content and content ~= "" then
            local file = io.open(path, "wb")
            if file then
                file:write(content)
                file:close()
            end
        end
    end)
    if not pid then
        os.remove(path)
        return nil
    end
    return {
        pid = pid,
        path = path,
        url = url,
        deadline = time.now() + time.s(Constants.TIMEOUTS.IMAGE_MAX_TIME + 5),
    }
end

local function stopFetch(job)
    if not FFIUtil.isSubProcessDone(job.pid) then
        -- The child has no descendants, so kill its PID directly: it may not
        -- have reached runInSubProcess's process group setup yet.
        ffi.C.kill(job.pid, 9)
        FFIUtil.isSubProcessDone(job.pid, true)
    end
    os.remove(job.path)
end

local function readFetch(job)
    local file = io.open(job.path, "rb")
    local content = file and file:read("*a")
    if file then
        file:close()
    end
    os.remove(job.path)
    if content and content ~= "" then
        return content
    end
end

function Batch:loadImages(urls)
    if self.loading then
        error("batch already in progress")
    end

    self.loading = #urls > 0
    local stop_loading = false
    local next_index = 1
    local jobs = {}
    local ttl_seconds = (self.cache_ttl_minutes or Constants.COVER_CACHE.DEFAULT_TTL_MINUTES) * 60
    local max_bytes = (self.cache_max_mb or Constants.COVER_CACHE.DEFAULT_MAX_MB) * 1024 * 1024

    local function deliver(url, content)
        if not stop_loading and content and self.callback then
            self.callback(url, content)
        end
    end

    local function finish(url, content, stale_content)
        if content then
            if self.cover_cache_enabled ~= false then
                CoverCache.put(url, content, max_bytes)
            end
            deliver(url, content)
        else
            Debug.error("ImageLoader:", "Failed to download cover:", url)
            deliver(url, stale_content)
        end
    end

    -- Downloads run in subprocesses, so a slow server never blocks the UI;
    -- decoding, cache writes and callbacks stay in this process.
    local poll
    poll = function()
        if stop_loading then
            return
        end

        for index = #jobs, 1, -1 do
            local job = jobs[index]
            if FFIUtil.isSubProcessDone(job.pid) then
                table.remove(jobs, index)
                finish(job.url, readFetch(job), job.stale_content)
            elseif time.now() > job.deadline then
                table.remove(jobs, index)
                stopFetch(job)
                finish(job.url, nil, job.stale_content)
            end
            if stop_loading then
                return
            end
        end

        -- Cache hits share the per-tick budget, so decoding them is spread out too.
        local budget = Constants.IMAGE_LOADER.MAX_PARALLEL
        local blocked = false
        while budget > 0 and #jobs < Constants.IMAGE_LOADER.MAX_PARALLEL and next_index <= #urls do
            budget = budget - 1
            local url = urls[next_index]
            next_index = next_index + 1

            local stale_content = nil
            local cached = self.cover_cache_enabled ~= false and CoverCache.get(url, ttl_seconds)
            if cached and not cached.stale then
                Debug.log("ImageLoader:", "Cover cache hit:", url)
                deliver(url, cached.content)
            else
                if cached and cached.content then
                    stale_content = cached.content
                end
                Debug.log("ImageLoader:", "Fetching cover with auth:", self.username and "yes" or "no")
                local job = startFetch(url, self.username, self.password)
                if job then
                    job.stale_content = stale_content
                    table.insert(jobs, job)
                else
                    -- No subprocess available: fetch in this process, as before.
                    local success, content = HttpClient.getUrlContent(
                        url,
                        Constants.TIMEOUTS.IMAGE_LOAD,
                        Constants.TIMEOUTS.IMAGE_MAX_TIME,
                        self.username,
                        self.password
                    )
                    finish(url, success and content or nil, stale_content)
                    -- The fetch blocked the UI: end this tick so it can run before the next cover.
                    blocked = true
                end
            end
            if stop_loading then
                return
            end
            if blocked then
                break
            end
        end

        self.loading = #jobs > 0 or next_index <= #urls
        if self.loading then
            local delay = blocked and Constants.UI_TIMING.IMAGE_BATCH_DELAY or Constants.IMAGE_LOADER.POLL_INTERVAL
            UIManager:scheduleIn(delay, poll)
        end
    end

    if self.loading then
        UIManager:nextTick(poll)
    end

    local halt = function()
        stop_loading = true
        self.loading = false
        self.callback = nil
        UIManager:unschedule(poll)
        for _, job in ipairs(jobs) do
            stopFetch(job)
        end
        jobs = {}
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

--- Remove the disk cover cache together with its directories.
function ImageLoader.purgeCache()
    CoverCache.purge()
end

return ImageLoader
