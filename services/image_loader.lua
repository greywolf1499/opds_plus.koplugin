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
local active_jobs = 0

local Batch = {
    loading = false,
    cancelled = false,
    url_map = {},
    callback = nil,
    username = nil,
    password = nil,
}
Batch.__index = Batch

function Batch:new(o)
    return setmetatable(o or {}, self)
end

function Batch:defer(seconds)
    self.pause_until = math.max(self.pause_until or 0,
        time.now() + time.s(seconds or Constants.IMAGE_LOADER.INPUT_QUIET_TIME))
end

-- Fetch one URL in a forked subprocess, which writes the body to a temporary
-- file: a pipe could fill up and block the child before it exits. Returns nil
-- when no subprocess could be started.
local function startFetch(url, username, password)
    -- os.tmpname() raises where /tmp does not exist (Android).
    local has_path, path = pcall(os.tmpname)
    if not has_path or not path then
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
    active_jobs = active_jobs + 1
    return {
        pid = pid,
        path = path,
        url = url,
        deadline = time.now() + time.s(Constants.TIMEOUTS.IMAGE_MAX_TIME + 5),
    }
end

local function releaseSlot(job)
    if not job.slot_released then
        job.slot_released = true
        active_jobs = active_jobs - 1
    end
end

local function stopFetch(job)
    if not FFIUtil.isSubProcessDone(job.pid) then
        -- The child has no descendants, so kill its PID directly: it may not
        -- have reached runInSubProcess's process group setup yet.
        ffi.C.kill(job.pid, 9)
        FFIUtil.isSubProcessDone(job.pid, true)
    end
    releaseSlot(job)
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
    self.cancelled = false
    local stop_loading = false
    local next_index = 1
    local jobs = {}
    local ready = {}
    local continuation
    local pending_fetch
    local delivered = false
    local ttl_seconds = (self.cache_ttl_minutes or Constants.COVER_CACHE.DEFAULT_TTL_MINUTES) * 60
    local max_bytes = (self.cache_max_mb or Constants.COVER_CACHE.DEFAULT_MAX_MB) * 1024 * 1024

    local function deliver(url, content)
        if not stop_loading and content then
            delivered = true
            if self.callback then
                local more = self.callback(url, content)
                if not stop_loading and type(more) == "function" then
                    continuation = more
                end
            end
        end
    end

    local function finish(url, content, stale_content)
        if content then
            if self.cover_cache_enabled ~= false then
                if not CoverCache.put(url, content, max_bytes) then
                    Debug.error("ImageLoader:", "Failed to cache cover")
                end
            end
            deliver(url, content)
        else
            Debug.error("ImageLoader:", "Failed to download cover:", url)
            deliver(url, stale_content)
        end
    end

    -- Downloads run in subprocesses, so a slow server never blocks the UI;
    -- decoding, cache writes and callbacks stay in this process.
    local poll, after_paint, paint_wrapper, halt
    local delay
    poll = function()
        if stop_loading then
            return
        end
        if self.can_continue and not self.can_continue() then
            halt()
            return
        end

        delivered = false
        -- Reap bounded children even during input, but leave disk reads and rendering for an idle slice.
        for index = #jobs, 1, -1 do
            local job = jobs[index]
            if FFIUtil.isSubProcessDone(job.pid) then
                table.remove(jobs, index)
                releaseSlot(job)
                ready[#ready + 1] = job
            elseif time.now() > job.deadline then
                table.remove(jobs, index)
                stopFetch(job)
                job.failed = true
                ready[#ready + 1] = job
            end
        end

        if time.now() < (self.pause_until or 0) then
            -- Input only postpones expensive work; it never kills and restarts a download.
            UIManager:scheduleIn(Constants.IMAGE_LOADER.POLL_INTERVAL, poll)
            return
        end
        local blocked = false
        -- One shared work slot: a continuation, a completed fetch, or a cache lookup/new fetch.
        if continuation then
            local work = continuation
            continuation = nil
            delivered = true
            local more = work()
            if not stop_loading and type(more) == "function" then
                continuation = more
            end
        elseif #ready > 0 then
            local job = table.remove(ready, 1)
            finish(job.url, not job.failed and readFetch(job) or nil, job.stale_content)
        elseif #jobs + #ready < Constants.IMAGE_LOADER.MAX_PARALLEL
            and (pending_fetch or next_index <= #urls) then
            if not pending_fetch then
                local url = urls[next_index]
                next_index = next_index + 1
                local cached = self.cover_cache_enabled ~= false and CoverCache.get(url, ttl_seconds)
                if cached and not cached.stale then
                    Debug.log("ImageLoader:", "Cover cache hit:", url)
                    deliver(url, cached.content)
                else
                    pending_fetch = { url = url, stale_content = cached and cached.content or nil }
                end
            end
            -- Contention is not a fork failure: wait rather than performing blocking HTTP.
            if pending_fetch and active_jobs < Constants.IMAGE_LOADER.MAX_PARALLEL then
                local fetch = pending_fetch
                pending_fetch = nil
                Debug.log("ImageLoader:", "Fetching cover with auth:", self.username and "yes" or "no")
                local job = self.parallel_downloads ~= false and startFetch(fetch.url, self.username, self.password)
                if job then
                    job.stale_content = fetch.stale_content
                    table.insert(jobs, job)
                elseif self.prefetch then
                    Debug.error("ImageLoader:", "Skipping cover prefetch: subprocess unavailable")
                    next_index = #urls + 1
                else
                    -- Parallel downloads are off or no subprocess could be started:
                    -- fetch in this process, as before.
                    local success, content = HttpClient.getUrlContent(
                        fetch.url,
                        Constants.TIMEOUTS.IMAGE_LOAD,
                        Constants.TIMEOUTS.IMAGE_MAX_TIME,
                        self.username,
                        self.password
                    )
                    finish(fetch.url, success and content or nil, fetch.stale_content)
                    -- The fetch blocked the UI: end this tick so it can run before the next cover.
                    blocked = true
                end
            end
        end

        if stop_loading then
            return
        end
        self.loading = #jobs > 0 or #ready > 0 or continuation ~= nil
            or pending_fetch ~= nil or next_index <= #urls
        if self.loading then
            delay = blocked and Constants.UI_TIMING.IMAGE_BATCH_DELAY or Constants.IMAGE_LOADER.POLL_INTERVAL
            if delivered then
                -- Start the positive delay after repaint, not before a potentially slow e-ink paint.
                paint_wrapper = UIManager:tickAfterNext(after_paint)
            else
                UIManager:scheduleIn(delay, poll)
            end
        end
    end

    after_paint = function()
        paint_wrapper = nil
        if not stop_loading then
            UIManager:scheduleIn(delay, poll)
        end
    end

    if self.loading then
        UIManager:nextTick(poll)
    end

    halt = function()
        stop_loading = true
        self.loading = false
        self.cancelled = true
        self.callback = nil
        continuation = nil
        pending_fetch = nil
        UIManager:unschedule(poll)
        UIManager:unschedule(after_paint)
        if paint_wrapper then
            UIManager:unschedule(paint_wrapper)
        end
        for _, job in ipairs(jobs) do
            stopFetch(job)
        end
        jobs = {}
        for _, job in ipairs(ready) do
            if not job.failed then
                os.remove(job.path)
            end
        end
        ready = {}
    end

    return halt
end

--- Load images from URLs asynchronously
-- @param urls table Array of URLs to load
--- @param callback function Callback(url, content); may return a function for one later render slice
-- @param username string|nil HTTP auth username
-- @param password string|nil HTTP auth password
-- @param cover_cache_enabled boolean|nil Whether to use in-memory cover cache (default: true)
-- @param cache_max_mb number|nil Maximum cache size in MB
-- @param cache_ttl_minutes number|nil Cache TTL in minutes
-- @param parallel_downloads boolean|nil Download covers in subprocesses (default: true)
-- @return table, function Batch instance and halt function
function ImageLoader:loadImages(
    urls,
    callback,
    username,
    password,
    cover_cache_enabled,
    cache_max_mb,
    cache_ttl_minutes,
    parallel_downloads
)
    local batch = Batch:new {
        username = username,
        password = password,
        cover_cache_enabled = cover_cache_enabled ~= false,
        cache_max_mb = cache_max_mb,
        cache_ttl_minutes = cache_ttl_minutes,
        parallel_downloads = parallel_downloads ~= false,
    }
    batch.callback = callback
    local halt = batch:loadImages(urls)
    return batch, halt
end

--- Warm disk-cache bytes only; unsupported subprocesses never fall back to blocking HTTP.
function ImageLoader:prefetch(urls, username, password, cache_max_mb, cache_ttl_minutes, can_continue)
    local batch = Batch:new {
        prefetch = true,
        username = username,
        password = password,
        cover_cache_enabled = true,
        parallel_downloads = true,
        cache_max_mb = cache_max_mb,
        cache_ttl_minutes = cache_ttl_minutes,
        can_continue = can_continue,
    }
    return batch, batch:loadImages(urls)
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
