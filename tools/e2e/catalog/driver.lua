-- KOReader user patch for the catalog e2e run: tools/e2e/catalog/run.sh installs it as patches/2-harness.lua.
--
-- Drives the OPDS Plus plugin in a real, headless KOReader against mock_opds_server.py and writes key=value
-- results to $HARNESS_OUT; every scenario ends with "<name>.result=PASS|FAIL".
-- Env: HARNESS_OUT, HARNESS_TMP (the run's scratch dir), HARNESS_BASE (the mock server),
-- HARNESS_SCENARIOS (comma list, default all but the explicit ones), HARNESS_SHOTS (screenshot dir, optional),
-- HARNESS_NO_DPAD and HARNESS_NO_KEYBOARD (see below).
--
-- Some scenarios replace os.rename and os.tmpname for a moment to simulate failures.
-- The marked duplicate-field exceptions below are temporary hooks, restored after each check.
-- luacheck: ignore 122

local UIManager = require("ui/uimanager")
local Device = require("device")

-- HARNESS_NO_DPAD=1 turns the emulator into a touch-only device before the plugin loads, which is when it reads it.
if os.getenv("HARNESS_NO_DPAD") == "1" then
    Device.hasDPad = function() return false end
    Device.hasKeys = function() return false end
end
-- HARNESS_NO_KEYBOARD=1 hides the emulator's keyboard shortcut boxes in lists, which e-readers do not show.
if os.getenv("HARNESS_NO_KEYBOARD") == "1" then
    require("ui/widget/menu").is_enable_shortcut = false
end
local out_path = os.getenv("HARNESS_OUT")
if not out_path then
    return
end
local shots_dir = os.getenv("HARNESS_SHOTS")
local wanted = os.getenv("HARNESS_SCENARIOS")
if wanted == "" then wanted = nil end
local out = assert(io.open(out_path, "w"))

local function emit(key, value)
    out:write(key, "=", tostring(value):gsub("[\r\n]+", " "), "\n")
    out:flush()
end

-- Every directory a scenario makes is a numbered one in $HARNESS_TMP, inside the run's own work dir, and only
-- such a directory is ever removed.
local tmp_root = os.getenv("HARNESS_TMP") or ""
local TMP_ROOT_PATTERN = "^/tmp/opds_plus_test_harness%.%w+/tmp$"
local tmp_counter = 0

assert(tmp_root:match(TMP_ROOT_PATTERN), "HARNESS_TMP is not a harness work dir")
require("ffi/posix_h")
local tmp_file_counter = 0
-- Lua's os.tmpname ignores TMPDIR; keep every test-created file inside this run.
---@diagnostic disable-next-line: duplicate-set-field
os.tmpname = function()
    tmp_file_counter = tmp_file_counter + 1
    local path = string.format("%s/image-%d-%06d.tmp", tmp_root, require("ffi").C.getpid(), tmp_file_counter)
    assert(io.open(path, "wb")):close()
    return path
end

local function make_temp_dir()
    assert(tmp_root:match(TMP_ROOT_PATTERN), "HARNESS_TMP is not a harness work dir: " .. tmp_root)
    tmp_counter = tmp_counter + 1
    local dir = string.format("%s/d%03d", tmp_root, tmp_counter)
    assert(require("libs/libkoreader-lfs").mkdir(dir))
    return dir
end

local function remove_temp_dir(dir)
    local escaped = tmp_root:gsub("%p", "%%%0")
    if type(dir) ~= "string" or not tmp_root:match(TMP_ROOT_PATTERN) or not dir:match("^" .. escaped .. "/d%d%d%d$") then
        error("refusing to remove " .. tostring(dir))
    end
    os.execute("rm -rf --one-file-system -- '" .. dir .. "'")
end

-- Capture every toast / message the plugin shows (e.g. "Cannot get catalog info from nil").
local current = "init"
local toasts = {}
local orig_show = UIManager.show
UIManager.show = function(self, widget, ...)
    if type(widget) == "table" and type(widget.text) == "string" and widget.text ~= "" then
        toasts[#toasts + 1] = widget.text
        emit(current .. ".toast", widget.text)
    end
    return orig_show(self, widget, ...)
end

local function reset_toasts()
    toasts = {}
end

local function toast_has(fragment)
    for _, text in ipairs(toasts) do
        if text:find(fragment, 1, true) then return true end
    end
    return false
end

local function find_plugin()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if not fm then return nil end
    -- KOReader >= 2026.07 names the instance after the directory (opds_plus), older ones use _meta.name.
    local p = fm.opds_plus or fm.opdsplus
    if p then return p end
    for _, child in ipairs(fm) do
        if type(child) == "table" and child.onShowOPDSPlusCatalog then return child end
    end
end

local function plugin()
    return assert(find_plugin(), "OPDS Plus plugin is not loaded")
end

local function open_browser()
    local p = plugin()
    if p.opds_browser then
        UIManager:close(p.opds_browser)
        p.opds_browser = nil
    end
    p:onShowOPDSPlusCatalog()
    return p.opds_browser
end

local function find_item(b, text)
    for _, item in ipairs(b.item_table) do
        if item.text and item.text:find(text, 1, true) then
            return item
        end
    end
end

local function count(b)
    local books, thumbs = 0, 0
    for _, item in ipairs(b.item_table) do
        if item.acquisitions and #item.acquisitions > 0 then books = books + 1 end
        if item.cover_url then thumbs = thumbs + 1 end
    end
    return books, thumbs
end

-- Poll `cond` every 0.5s until it is truthy or `timeout` seconds passed, then call on_done(result).
local function wait_for(cond, timeout, on_done)
    local waited = 0
    local function poll()
        local ok, res = pcall(cond)
        if (ok and res) or waited >= timeout then
            on_done(ok and res or false)
            return
        end
        waited = waited + 0.5
        UIManager:scheduleIn(0.5, poll)
    end
    poll()
end

-- Wait for each requested feed page before sending another navigation action.
local function browse_all(b, limit, done, on_tap)
    local taps = 0
    local pending_tap
    local browse
    browse = function()
        if b._catalog_job then
            wait_for(function() return not b._catalog_job end, 30, function(ok)
                if ok then browse() else
                    emit(current .. ".error", "catalog pagination timed out")
                    b:cancelCatalogLoad()
                    done(taps)
                end
            end)
            return
        end
        if pending_tap and on_tap then on_tap(taps, false) end
        pending_tap = false
        while taps < limit do
            local hrefs = b.item_table.hrefs
            if b.page >= b.page_num and not (hrefs and hrefs.next) then break end
            taps = taps + 1
            if on_tap then on_tap(taps, true) end
            b:onNextPage()
            if b._catalog_job then
                pending_tap = true
                return browse()
            end
            if on_tap then on_tap(taps, false) end
        end
        done(taps)
    end
    browse()
end

local function shot(name)
    if shots_dir then
        Device.screen:shot(shots_dir .. "/" .. name .. ".png")
    end
end

local SCENARIOS = {
    { name = "crawlable", entry = "All Mock Books", expect_books = 120 },
    { name = "p50", entry = "Paged 250 (50 per page)", expect_books = 250 },
    { name = "p100", entry = "Paged 250 (100 per page)", expect_books = 250 },
    { name = "p50sc", entry = "Paged 250 with 10% empty content", expect_books = 250 },
    { name = "p100sc", entry = "Paged 250 (100 per page, 10% empty content)", expect_books = 250 },
    { name = "navthumbs", entry = "Navigation with thumbnails", expect_books = 0, expect_thumbs = 6 },
}

local function scenario_steps(sc)
    local b
    return {
        function()
            current = sc.name
            b = open_browser()
            emit(sc.name .. ".root_items", #b.item_table)
            b:onMenuSelect(find_item(b, "Mock Library"))
        end,
        function()
            local entry = find_item(b, sc.entry)
            emit(sc.name .. ".entry_found", entry ~= nil)
            emit(sc.name .. ".entry_url", entry and entry.url or "nil")
            if entry then b:onMenuSelect(entry) end
        end,
        function(advance)
            emit(sc.name .. ".paths", #b.paths)
            browse_all(b, 200, function(taps)
                emit(sc.name .. ".taps", taps)
                local books, thumbs = count(b)
                emit(sc.name .. ".books", books)
                emit(sc.name .. ".expected_books", sc.expect_books)
                emit(sc.name .. ".items", #b.item_table)
                emit(sc.name .. ".with_cover_url", thumbs)
                emit(sc.name .. ".menu_pages", b.page_num)
                local pass = books == sc.expect_books and (sc.expect_thumbs == nil or thumbs == sc.expect_thumbs)
                emit(sc.name .. ".result", pass and "PASS" or "FAIL")
                shot(sc.name)
                advance()
            end)
            return "async"
        end,
    }
end

-- Tell the mock server to drop a marker line in requests.jsonl so request counts can be split per phase.
local function mark(name)
    local http = require("socket.http")
    http.TIMEOUT = 5
    http.request((os.getenv("HARNESS_BASE") or "http://127.0.0.1:18080") .. "/__mark/" .. name)
end

local function cache_dir()
    return require("datastorage"):getDataDir() .. "/cache/opds_plus/covers"
end

local function count_cache_files(suffix)
    local lfs = require("libs/libkoreader-lfs")
    local n = 0
    if lfs.attributes(cache_dir(), "mode") == "directory" then
        for name in lfs.dir(cache_dir()) do
            if name:sub(-#suffix) == suffix then n = n + 1 end
        end
    end
    return n
end

-- Earlier scenarios open lists with covers and leave them in the cache; the cover scenario needs a cold start.
local function remove_cache_files()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(cache_dir(), "mode") ~= "directory" then return end
    for name in lfs.dir(cache_dir()) do
        if name:sub(-4) == ".img" or name:sub(-4) == ".tmp" then os.remove(cache_dir() .. "/" .. name) end
    end
end

-- Cover entries on the menu's current page that want a cover, and how many already have a rendered bitmap.
local function visible_covers(b)
    local want, have = 0, 0
    local first = (b.page - 1) * b.perpage + 1
    local last = math.min(b.page * b.perpage, #b.item_table)
    for idx = first, last do
        local item = b.item_table[idx]
        if item and item.cover_url then
            want = want + 1
            if item.cover_bb then have = have + 1 end
        end
    end
    return want, have
end

-- Open the paged feed, then page forward `pages` times waiting for every visible cover on each page.
local function covers_pass(label, pages, done)
    local b = open_browser()
    b:onMenuSelect(find_item(b, "Mock Library"))
    UIManager:scheduleIn(0.3, function()
        b:onMenuSelect(find_item(b, "Paged 250 (50 per page)"))
        local page = 0
        local want_total, have_total = 0, 0
        local function load_page()
            page = page + 1
            wait_for(function()
                local want, have = visible_covers(b)
                return want > 0 and want == have
            end, 20, function(ok)
                local want, have = visible_covers(b)
                emit(label .. ".page" .. page, have .. "/" .. want .. (ok and "" or " (timeout)"))
                want_total, have_total = want_total + want, have_total + have
                if page < pages then
                    b:onNextPage()
                    load_page()
                else
                    done(want_total, have_total)
                end
            end)
        end
        load_page()
    end)
end

local function covers_steps()
    local pass1_wanted, pass1_rendered
    return {
        function(advance)
            current = "covers"
            remove_cache_files()
            emit("covers.cache_dir", cache_dir())
            emit("covers.cache_before", count_cache_files(".img"))
            covers_pass("covers.pass1", 3, function(want, have)
                pass1_wanted, pass1_rendered = want, have
                emit("covers.pass1_wanted", want)
                emit("covers.pass1_rendered", have)
                emit("covers.cache_files", count_cache_files(".img"))
                emit("covers.tmp_leftovers", count_cache_files(".tmp"))
                advance()
            end)
            return "async"
        end,
        function(advance)
            mark("pass2")
            covers_pass("covers.pass2", 3, function(want, have)
                emit("covers.pass2_wanted", want)
                emit("covers.pass2_rendered", have)
                emit("covers.cache_files_after", count_cache_files(".img"))
                local pass = pass1_wanted > 0 and pass1_rendered == pass1_wanted
                    and want == pass1_wanted and have == want
                    and count_cache_files(".img") == pass1_wanted and count_cache_files(".tmp") == 0
                emit("covers.result", pass and "PASS" or "FAIL")
                advance()
            end)
            return "async"
        end,
    }
end

-- Exercises services.cover_cache in real KOReader under different DataStorage behaviours (no network).
local function cachelib_steps()
    return {
        function()
            current = "cachelib"
            local DataStorage = require("datastorage")
            local lfs = require("libs/libkoreader-lfs")
            local orig_full, orig_dir, orig_rename = DataStorage.getFullDataDir, DataStorage.getDataDir, os.rename
            local orig_cwd = lfs.currentdir()
            local all_ok = true

            local function fresh()
                package.loaded["services.cover_cache"] = nil
                return require("services.cover_cache")
            end
            local function check(label, fn)
                local ok, res = pcall(fn)
                if not ok then res = "ERROR: " .. tostring(res) end
                if res ~= "ok" then all_ok = false end
                emit("cachelib." .. label, res)
            end
            local function roundtrip(CC)
                if not CC.put("http://example.test/a.png", "payload", 0) then return "put failed" end
                local got = CC.get("http://example.test/a.png", 60)
                CC.clear()
                return (got and got.content == "payload") and "ok" or "get mismatch"
            end

            check("normal", function() return roundtrip(fresh()) end)

            ---@diagnostic disable-next-line: duplicate-set-field
            DataStorage.getFullDataDir = function() return nil end
            check("full_data_dir_nil", function() return roundtrip(fresh()) end)

            DataStorage.getFullDataDir = nil
            check("full_data_dir_missing", function() return roundtrip(fresh()) end)

            local tmp = make_temp_dir()
            lfs.chdir(tmp)
            ---@diagnostic disable-next-line: duplicate-set-field
            DataStorage.getDataDir = function() return "./relkoha" end
            check("relative_data_dir", function()
                local res = roundtrip(fresh())
                local landed = lfs.attributes(tmp .. "/relkoha/cache/opds_plus/covers", "mode") == "directory"
                local leaked = lfs.attributes("/relkoha", "mode") ~= nil
                if res == "ok" and not landed then res = "not created under cwd" end
                if res == "ok" and leaked then res = "created under /" end
                return res
            end)
            lfs.chdir(orig_cwd)
            DataStorage.getDataDir = orig_dir
            DataStorage.getFullDataDir = orig_full

            -- A failed publish must leave the previous cached cover intact and no temp file behind.
            check("failed_write_keeps_old", function()
                local CC = fresh()
                if not CC.put("http://example.test/b.png", "old-content", 0) then return "seed put failed" end
                ---@diagnostic disable-next-line: duplicate-set-field
                os.rename = function() return nil, "simulated rename failure" end
                local put_new = CC.put("http://example.test/b.png", "new-content", 0)
                os.rename = orig_rename
                local got = CC.get("http://example.test/b.png", 60)
                local tmp_left = count_cache_files(".tmp")
                CC.clear()
                if put_new then return "put reported success despite failed publish" end
                if not got or got.content ~= "old-content" then return "previous content lost" end
                if tmp_left ~= 0 then return "temp file left behind" end
                return "ok"
            end)

            os.rename = orig_rename
            remove_temp_dir(tmp)
            package.loaded["services.cover_cache"] = nil
            emit("cachelib.result", all_ok and "PASS" or "FAIL")
        end,
    }
end

-- Link-rel classification matrix for sub-catalog navigation links (#83), using the plugin's own modules.
local function rels_steps()
    return {
        function()
            current = "rels"
            local UrlUtils = require("utils.url_utils")
            local Constants = require("models.constants")
            local atom = "application/atom+xml;profile=opds-catalog;kind=acquisition"
            local cases = {
                { "none", nil, atom, true },
                { "subsection", "subsection", atom, true },
                { "opds subsection", "http://opds-spec.org/subsection", atom, true },
                { "popular", "http://opds-spec.org/sort/popular", atom, true },
                { "new", "http://opds-spec.org/sort/new", atom, true },
                { "crawlable", "http://opds-spec.org/crawlable", atom, true },
                { "acquisition", "http://opds-spec.org/acquisition", atom, false },
                { "next", "next", atom, false },
                { "self", "self", atom, false },
                { "search", "search", atom, false },
                { "facet", "http://opds-spec.org/facet", atom, false },
                { "html type", "subsection", "text/html", false },
                { "no type", "subsection", nil, false },
            }
            local all_ok = true
            for _, c in ipairs(cases) do
                local got = UrlUtils.isCatalogNavigationLink({ rel = c[2], type = c[3] }, Constants.CATALOG_TYPE,
                    Constants.CATALOG_REL)
                local ok = got == c[4]
                if not ok then all_ok = false end
                emit("rels." .. c[1], ok and "ok" or ("expected " .. tostring(c[4]) .. " got " .. tostring(got)))
            end
            emit("rels.result", all_ok and "PASS" or "FAIL")
        end,
    }
end

-- Helpers for the sync / settings scenarios (#96, #82) ---------------------------------------------

local BASE = os.getenv("HARNESS_BASE") or "http://127.0.0.1:18080"

-- PASS/FAIL bookkeeping: check() emits "<scenario>.<label>=ok|FAIL (detail)", finish() emits the verdict.
local function checker(scenario)
    local state = { ok = true }
    function state.check(label, cond, detail)
        if not cond then state.ok = false end
        local text = cond and "ok" or ("FAIL" .. (detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
        emit(scenario .. "." .. label, text)
    end
    function state.finish()
        emit(scenario .. ".result", state.ok and "PASS" or "FAIL")
    end
    return state
end

local function close_browser(p)
    if p.opds_browser then
        UIManager:close(p.opds_browser)
        p.opds_browser = nil
    end
end

local function close_window_with_text(fragment)
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        local text = type(widget) == "table" and widget.text
        if type(text) == "string" and text:find(fragment, 1, true) then UIManager:close(widget) end
    end
end

local function window_has_text(fragment)
    for _, entry in ipairs(UIManager._window_stack) do
        local text = type(entry.widget) == "table" and entry.widget.text
        if type(text) == "string" and text:find(fragment, 1, true) then return true end
    end
    return false
end

local function fresh_dir()
    return make_temp_dir()
end

local function count_files(dir, suffix)
    local n = 0
    for name in require("libs/libkoreader-lfs").dir(dir) do
        if name:sub(-#suffix) == suffix then n = n + 1 end
    end
    return n
end

-- The plugin shares its server table with every browser it creates, so an added entry is seen immediately.
local function add_server(p, title, path, sync)
    local server = { title = title, url = BASE .. path, sync = sync or nil }
    table.insert(p.servers, server)
    return server
end

local function remove_server(p, server)
    for i, candidate in ipairs(p.servers) do
        if candidate == server then
            table.remove(p.servers, i)
            return
        end
    end
end

-- Counts feed fetches made by any browser while installed; call restore() to remove the hook.
local function count_feed_fetches()
    local FeedFetcher = require("core.feed_fetcher")
    local CatalogLoader = require("services.catalog_loader")
    local orig = FeedFetcher.genItemTableFromURL
    local orig_start = CatalogLoader.start
    local state = { n = 0 }
    ---@diagnostic disable-next-line: duplicate-set-field
    FeedFetcher.genItemTableFromURL = function(url, user, pass, debug_callback, parser, request_state)
        if not request_state then state.n = state.n + 1 end
        return orig(url, user, pass, debug_callback, parser, request_state)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    CatalogLoader.start = function(...)
        state.n = state.n + 1
        return orig_start(...)
    end
    function state.restore()
        FeedFetcher.genItemTableFromURL, CatalogLoader.start = orig, orig_start
    end
    return state
end

-- Pretend Wi-Fi is off: NetworkMgr hands over the callback it would run once connected.
local function simulate_offline()
    local NetworkMgr = require("ui/network/manager")
    local orig_connected, orig_before = NetworkMgr.isConnected, NetworkMgr.beforeWifiAction
    local state = {}
    NetworkMgr.isConnected = function() return false end
    NetworkMgr.beforeWifiAction = function(_, callback) state.callback = callback end
    function state.restore()
        NetworkMgr.isConnected, NetworkMgr.beforeWifiAction = orig_connected, orig_before
    end
    return state
end

-- Sync gesture behaviour (#96): the dispatcher actions behind "Sync all catalogs" / "Force sync all catalogs".
local function syncgesture_steps()
    local p, server, dir, c
    return {
        function()
            current = "syncgesture"
            c = checker("syncgesture")
            p = plugin()
            close_browser(p)
            dir = fresh_dir()
            server = add_server(p, "Mock Sync", "/opds/sync")

            p.settings.sync_dir = nil
            reset_toasts()
            p:onStartOPDSSyncAllCatalogs()
            c.check("A0.asks_for_sync_dir", toast_has("choose a folder"))
            close_browser(p)

            -- A: nothing is flagged for sync, so the gesture must say that instead of claiming "Up to date!"
            p.settings.sync_dir = dir
            reset_toasts()
            local fetches = count_feed_fetches()
            p:onStartOPDSSyncAllCatalogs()
            fetches.restore()
            c.check("A.explains_nothing_is_flagged", toast_has("No catalogs are set to sync"), toasts[#toasts])
            c.check("A.no_false_up_to_date", not toast_has("Up to date"))
            c.check("A.no_feed_requests", fetches.n == 0, fetches.n)
            c.check("A.no_leaked_browser", p.opds_browser == nil)
            close_browser(p)
        end,
        -- B: with Wi-Fi off, the gesture must wait for the connection before it touches the network
        function(advance)
            server.sync = true
            reset_toasts()
            local offline = simulate_offline()
            local fetches = count_feed_fetches()
            p:onStartOPDSSyncAllCatalogs()
            c.check("B.waits_for_network", offline.callback ~= nil)
            c.check("B.no_requests_while_offline", fetches.n == 0, fetches.n)
            offline.restore()
            if offline.callback then offline.callback() end
            c.check("B.requests_once_online", fetches.n > 0, fetches.n)
            fetches.restore()
            wait_for(function()
                return count_files(dir, ".epub") >= 3 and toast_has("3 books downloaded")
            end, 40, function(ok)
                c.check("B.books_downloaded", ok, count_files(dir, ".epub") .. " files")
                c.check("B.last_download_recorded", (server.last_download or ""):find("/dl/903.epub", 1, true),
                    server.last_download)
                c.check("B.no_leaked_browser", p.opds_browser == nil)
                close_browser(p)
                advance()
            end)
            return "async"
        end,
        -- B2: the same gesture again has nothing new to fetch, which is the one time "Up to date!" is right
        function()
            reset_toasts()
            p:onStartOPDSSyncAllCatalogs()
            c.check("B2.up_to_date_when_nothing_new", toast_has("Up to date"))
            close_browser(p)
        end,
        -- C: a failure while reading a feed must not leave the browser stuck in sync mode
        function()
            local FeedFetcher = require("core.feed_fetcher")
            local orig = FeedFetcher.genItemTableFromURL
            ---@diagnostic disable-next-line: duplicate-set-field
            FeedFetcher.genItemTableFromURL = function() error("simulated feed failure") end
            local b = open_browser()
            reset_toasts()
            local ok = pcall(function() b:checkSyncDownload() end)
            FeedFetcher.genItemTableFromURL = orig
            c.check("C.error_is_contained", ok)
            c.check("C.sync_flag_cleared", not b.sync)
            c.check("C.progress_message_closed", not window_has_text("Synchronizing"))
            c.check("C.reports_failure", toast_has("Sync failed"))
            close_window_with_text("Synchronizing")
            close_browser(p)
            remove_server(p, server)
            p.settings.sync_dir = nil
            remove_temp_dir(dir)
            c.finish()
        end,
    }
end

-- Feed shapes that used to crash the sync (#96): a link-less first entry and a Gutenberg style one-book sub-feed.
local function syncguards_steps()
    local p, c
    local cases = {
        { name = "mixed", path = "/opds/sync_mixed", books = 2, newest = "/dl/912.epub" },
        { name = "gutenberg", path = "/opds/gut_root", books = 1, newest = "/dl/921.epub" },
    }
    local steps = {
        function()
            current = "syncguards"
            c = checker("syncguards")
            p = plugin()
            close_browser(p)
        end,
    }
    for _, case in ipairs(cases) do
        steps[#steps + 1] = function(advance)
            local dir = fresh_dir()
            p.settings.sync_dir = dir
            local server = add_server(p, "Mock " .. case.name, case.path, true)
            reset_toasts()
            -- KOReader sandboxes plugin event handlers: an error is only logged and the handler returns false.
            local handled = p:onStartOPDSSyncAllCatalogs()
            c.check(case.name .. ".handler_completes", handled ~= false)
            c.check(case.name .. ".progress_message_closed", not window_has_text("Synchronizing"))
            c.check(case.name .. ".no_failure_toast", not toast_has("Sync failed"), toasts[#toasts])
            wait_for(function() return count_files(dir, ".epub") >= case.books end, handled ~= false and 30 or 0,
                function()
                    local files = count_files(dir, ".epub")
                    c.check(case.name .. ".books", files == case.books, files .. " of " .. case.books)
                    c.check(case.name .. ".last_download", (server.last_download or ""):find(case.newest, 1, true),
                        server.last_download)
                    close_window_with_text("Synchronizing")
                    remove_server(p, server)
                    close_browser(p)
                    p.settings.sync_dir = nil
                    remove_temp_dir(dir)
                    advance()
                end)
            return "async"
        end
    end
    steps[#steps + 1] = function() c.finish() end
    return steps
end

-- "Delete plugin settings" from KOReader's plugin dialog (#82). Runs last: it removes the settings file.
local function delsettings_steps()
    return {
        function()
            current = "delsettings"
            local c = checker("delsettings")
            local lfs = require("libs/libkoreader-lfs")
            local DataStorage = require("datastorage")
            local PluginLoader = require("pluginloader")
            local StateManager = require("core.state_manager")
            local CoverCache = require("services.cover_cache")
            local p = plugin()
            close_browser(p)
            local function exists(path) return lfs.attributes(path, "mode") ~= nil end
            local settings_file = p.opds_settings_file
            local cache_parent = DataStorage:getDataDir() .. "/cache/opds_plus"

            -- Everything the plugin persists: its settings (plus KOReader's backup copy) and cached covers.
            p:saveSetting("cover_height_ratio", 0.55)
            local backup = assert(io.open(settings_file .. ".old", "w"))
            backup:write("return {}\n")
            backup:close()
            remove_cache_files() -- the exact count below needs a cold cache; earlier scenarios leave covers behind
            CoverCache.put("http://example.test/del-a.png", "payload-a", 0)
            CoverCache.put("http://example.test/del-b.png", "payload-b", 0)
            G_reader_settings:saveSetting("download_dir", tmp_root .. "/downloads")
            c.check("seed.settings_file", exists(settings_file))
            c.check("seed.backup_file", exists(settings_file .. ".old"))
            c.check("seed.cached_covers", count_cache_files(".img") == 2, count_cache_files(".img"))

            -- KOReader only offers "Delete plugin and settings" for plugins that can do it.
            c.check("offered_in_plugin_dialog",
                (p.deletePluginSettings or p.settings_file or p.settings_key) and true or false)

            -- KOReader purges the plugin directory first, so nothing may be required lazily while deleting.
            local loaded = {}
            for name in pairs(package.loaded) do loaded[name] = true end
            local ok = PluginLoader:deletePluginSettings(p)
            local late = {}
            for name in pairs(package.loaded) do
                if not loaded[name] then late[#late + 1] = name end
            end
            c.check("delete_succeeds", ok == true, ok)
            c.check("needs_no_late_requires", #late == 0, table.concat(late, ","))
            c.check("settings_file_removed", not exists(settings_file))
            c.check("backup_file_removed", not exists(settings_file .. ".old"))
            c.check("cover_cache_removed", not exists(cache_parent))
            c.check("shared_download_dir_kept", G_reader_settings:readSetting("download_dir") == tmp_root .. "/downloads")

            -- Whatever flushes afterwards (settings dialogs, KOReader's own FlushSettings) must not bring it back.
            p:saveSetting("cover_height_ratio", 0.7)
            p.opds_settings:flush()
            StateManager.getInstance():markDirty()
            UIManager:flushSettings()
            c.check("not_recreated_by_late_flush", not exists(settings_file) and not exists(settings_file .. ".old"))
            c.finish()
        end,
    }
end

-- Next-page taps over a server-paged feed (#92): they should only ask the server when screens run out.
local function prefetch_steps()
    local c = checker("prefetch")
    local b, fetches, tiny, tiny_before
    return {
        function()
            current = "prefetch"
            fetches = count_feed_fetches()
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Library"))
        end,
        function()
            b:onMenuSelect(find_item(b, "Paged 250 (50 per page)"))
        end,
        function(advance)
            local start = fetches.n
            local screens = b.page_num
            emit("prefetch.perpage", b.perpage)
            emit("prefetch.screens_on_open", screens)
            emit("prefetch.items_on_open", #b.item_table)
            local per_tap = {}
            browse_all(b, 80, function(taps)
                local first_fetch_tap
                for tap, n in ipairs(per_tap) do
                    if n > 0 then
                        first_fetch_tap = tap
                        break
                    end
                end
                emit("prefetch.taps_to_reach_the_end", taps)
                emit("prefetch.first_fetch_on_tap", first_fetch_tap)
                emit("prefetch.feed_fetches", fetches.n - start)
                emit("prefetch.items_at_end", #b.item_table)
                c.check("first_fetch_is_one_screen_before_the_end",
                    first_fetch_tap == math.max(1, screens - 1), first_fetch_tap)
                c.check("every_item_reachable", #b.item_table == 250, #b.item_table)
                c.check("one_fetch_per_feed_page", fetches.n - start == 4, fetches.n - start)
                local ok = pcall(function() b:onNextPage() end)
                c.check("tap_at_the_end_returns", ok)
                advance()
            end, function(tap, before)
                per_tap[tap] = before and fetches.n or fetches.n - per_tap[tap]
            end)
            return "async"
        end,
        -- Tiny feed pages: the first open must still fill a few screens, and must stop.
        function()
            close_browser(plugin())
            tiny = add_server(plugin(), "Mock Tiny Pages", "/opds/paged?page=1&size=3&total=60")
            tiny_before = fetches.n
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Tiny Pages"))
        end,
        function(advance)
            emit("prefetch.tiny.screens_on_open", b.page_num)
            emit("prefetch.tiny.items_on_open", #b.item_table)
            emit("prefetch.tiny.fetches_on_open", fetches.n - tiny_before)
            c.check("tiny_pages_fill_a_few_screens", b.page_num >= 3, b.page_num)
            browse_all(b, 60, function()
                c.check("tiny_pages_all_reachable", #b.item_table == 60, #b.item_table)
                remove_server(plugin(), tiny)
                fetches.restore()
                c.finish()
                advance()
            end)
            return "async"
        end,
    }
end

-- Keyboard / D-pad handling (#93): focus underline cell by cell, Back walking up, Home, view switching.
local function nontouch_steps()
    local StateManager = require("core.state_manager")
    local Event = require("ui/event")
    local Key = require("device/key")
    local c = checker("nontouch")
    local b, expected, first_item, orig_dpad, orig_keys, orig_is_touch, orig_focus_nt
    local FocusManager = require("ui/widget/focusmanager")

    local function press(widget, name)
        return widget:handleEvent(Event:new("KeyPress", Key:new(name, {})))
    end

    local function shown(widget)
        for _, entry in ipairs(UIManager._window_stack) do
            if entry.widget == widget then return true end
        end
        return false
    end

    -- "row,col" of every cell on the page that draws the focus underline.
    local function focused_cells()
        local found = {}
        for y, row in ipairs(b.layout) do
            for x, cell in ipairs(row) do
                local line = cell._underline
                if line and line.style ~= "none" and line.background:getColor8().a == 0 then
                    found[#found + 1] = y .. "," .. x
                end
            end
        end
        return table.concat(found, " ")
    end

    local function is_dark(x, y, threshold)
        return Device.screen.bb:getPixel(x, y):getColor8().a < threshold
    end

    -- "row,col" of every cell whose bottom row on screen is a full-width dark line, i.e. a drawn focus underline.
    local function painted_lines()
        local found = {}
        for y, row in ipairs(b.layout) do
            for x, cell in ipairs(row) do
                local d, dark = cell.dimen, 0
                for px = d.x, d.x + d.w - 1 do
                    if is_dark(px, d.y + d.h - 1, 128) then dark = dark + 1 end
                end
                if dark >= d.w * 0.9 then found[#found + 1] = y .. "," .. x end
            end
        end
        return table.concat(found, " ")
    end

    -- Dark pixels in the rows a grid cell keeps for its underline. With no line drawn, only the author text that
    -- overflows its box can put ink there.
    local function underline_rows_ink()
        local ink = 0
        for _, row in ipairs(b.layout) do
            for _, cell in ipairs(row) do
                local d = cell.dimen
                for py = d.y + d.h - cell._underline.dimen.h, d.y + d.h - 1 do
                    for px = d.x, d.x + d.w - 1 do
                        if is_dark(px, py, 250) then ink = ink + 1 end
                    end
                end
            end
        end
        return ink
    end

    local function item_no()
        return b.getFocusedItemNumber and b:getFocusedItemNumber() or "n/a"
    end

    local function page_range()
        return (b.page - 1) * b.perpage + 1, math.min(b.page * b.perpage, #b.item_table)
    end

    local function open_library()
        b = open_browser()
        b:onMenuSelect(find_item(b, "Mock Library"))
    end

    local function open_paged()
        b:onMenuSelect(find_item(b, "Paged 250 (50 per page)"))
    end

    return {
        function()
            current = "nontouch"
            -- A non-touch D-pad device: Menu then draws the focus after every refresh, not only after key presses.
            orig_is_touch, orig_focus_nt = Device.isTouchDevice, FocusManager.FOCUS_ONLY_ON_NT
            Device.isTouchDevice = function() return false end
            FocusManager.FOCUS_ONLY_ON_NT = 0
            close_window_with_text("Documents will be rendered")
            StateManager.getInstance():setDisplayMode("list")
            open_library()
        end,
        open_paged,
        function()
            emit("nontouch.list.perpage", b.perpage)
            emit("nontouch.list.paths", #b.paths)
            c.check("list.back_key_bound", b.key_events.Back ~= nil)
            c.check("list.home_key_closes",
                b.key_events.Close ~= nil and b.key_events.Close[1] ~= nil and b.key_events.Close[1][1] == "Home")
            local in_footer = false
            for i = 1, #b.page_info do
                if b.page_info[i] == b.page_info_text then in_footer = true end
            end
            c.check("list.page_counter_is_still_the_menu_button", in_footer)
            emit("nontouch.list.page_counter_text", b.page_info_text.text)
            c.check("list.page_counter_text",
                tostring(b.page_info_text.text):find("1 / " .. b.page_num, 1, true) ~= nil, b.page_info_text.text)
            emit("nontouch.list.focus_on_open", focused_cells())
            press(b, "Down")
            press(b, "Down")
            press(b, "Up")
            c.check("list.focus_moves_item_by_item", item_no() == 2 and focused_cells() == "2,1",
                tostring(item_no()) .. " / " .. focused_cells())
        end,
        function()
            close_window_with_text("Documents will be rendered")
            shot("nontouch_list_focus")
            c.check("dialog.press_handled", press(b, "Press") == true)
        end,
        function()
            local dialog = b.book_info_dialog
            c.check("dialog.opens_on_enter", dialog ~= nil and shown(dialog))
            if dialog then
                shot("nontouch_book_info")
                press(dialog, "Back")
                c.check("dialog.back_key_closes_it", not shown(dialog))
                c.check("dialog.browser_stays_open", shown(b))
            end
        end,
        function()
            b:onNextPage()
            press(b, "Down")
            press(b, "Down")
            expected = (b.page - 1) * b.perpage + 3
            c.check("toggle.focus_before", item_no() == expected, tostring(item_no()) .. " vs " .. expected)
            local ok, err = pcall(function() b:toggleViewMode() end)
            c.check("toggle.runs", ok, err)
        end,
        function()
            close_window_with_text("Switched to")
            local first, last = page_range()
            emit("nontouch.grid.perpage", b.perpage)
            emit("nontouch.grid.page_after_toggle", b.page)
            emit("nontouch.grid.page_counter_text", b.page_info_text.text)
            c.check("toggle.item_stays_on_screen", expected >= first and expected <= last,
                expected .. " not in " .. first .. ".." .. last)
            c.check("toggle.focus_stays_on_item", item_no() == expected, tostring(item_no()) .. " vs " .. expected)
            c.check("toggle.one_cell_underlined", focused_cells() ~= "" and not focused_cells():find(" ", 1, true),
                focused_cells())
        end,
        function()
            shot("nontouch_grid_focus")
            c.check("grid.focused_line_painted", painted_lines() == focused_cells(),
                painted_lines() .. " vs " .. focused_cells())
            local columns = #b.layout[1]
            emit("nontouch.grid.columns", columns)
            local x, y = b.selected.x, b.selected.y
            local sideways = (b.layout[y][x + 1] and 1) or (b.layout[y][x - 1] and -1) or 0
            local before = item_no()
            press(b, sideways == 1 and "Right" or "Left")
            c.check("grid.sideways_moves_one_cell", item_no() == before + sideways,
                tostring(before) .. " -> " .. tostring(item_no()))
            x, y = b.selected.x, b.selected.y
            local down = (b.layout[y + 1] and b.layout[y + 1][x]) and 1 or -1
            before = item_no()
            press(b, down == 1 and "Down" or "Up")
            c.check("grid.vertical_moves_one_row", item_no() == before + down * columns,
                tostring(before) .. " -> " .. tostring(item_no()))
            c.check("grid.one_cell_underlined", focused_cells() ~= "" and not focused_cells():find(" ", 1, true),
                focused_cells())
        end,
        -- After the repaint the line must follow the focus: nothing is left behind on the cells it left.
        function()
            shot("nontouch_grid_moved")
            c.check("grid.line_follows_focus", painted_lines() == focused_cells(),
                painted_lines() .. " vs " .. focused_cells())
        end,
        function(advance)
            local depth = #b.paths
            press(b, "Back")
            wait_for(function() return not b._catalog_job end, 10, function(done)
                c.check("back.walks_up_one_level", done and #b.paths == depth - 1 and shown(b),
                    depth .. " -> " .. #b.paths)
                advance()
            end)
            return "async"
        end,
        function()
            local guard = 0
            while #b.paths > 0 and guard < 10 do
                press(b, "Back")
                guard = guard + 1
            end
            c.check("back.reaches_the_server_list", #b.paths == 0 and shown(b), #b.paths)
            press(b, "Back")
            c.check("back.closes_at_the_server_list", not shown(b))
        end,
        function()
            open_library()
        end,
        function()
            c.check("home.library_open", shown(b))
            press(b, "Home")
            c.check("home.closes_the_browser", not shown(b))
        end,
        -- A touch-only device: no keys wired, no focus drawn, and the view switch must still keep the place.
        function()
            Device.isTouchDevice, FocusManager.FOCUS_ONLY_ON_NT = orig_is_touch, orig_focus_nt
            orig_dpad, orig_keys = Device.hasDPad, Device.hasKeys
            Device.hasDPad = function() return false end
            Device.hasKeys = function() return false end
            StateManager.getInstance():setDisplayMode("list")
            open_library()
        end,
        open_paged,
        function()
            c.check("touch.no_back_key_bound", b.key_events.Back == nil)
            c.check("touch.no_focus_drawn", focused_cells() == "", focused_cells())
            shot("touch_list")
            b:onNextPage()
            b:onNextPage()
            first_item = (b.page - 1) * b.perpage + 1
            local ok, err = pcall(function() b:toggleViewMode() end)
            c.check("touch.toggle_runs", ok, err)
        end,
        function()
            close_window_with_text("Switched to")
            local first, last = page_range()
            emit("nontouch.touch.grid_perpage", b.perpage)
            c.check("touch.toggle_keeps_the_place", first_item >= first and first_item <= last,
                first_item .. " not in " .. first .. ".." .. last)
        end,
        -- A step later the toast is off the screen, so only the grid is left to measure.
        function()
            shot("touch_grid")
            -- Nothing is focused here, so the rows kept for the underline show whatever text overflows into them.
            local ink = underline_rows_ink()
            emit("nontouch.touch.grid_underline_rows_ink", ink)
            c.check("touch.grid_author_text_not_clipped", ink > 0, ink)
            Device.hasDPad, Device.hasKeys = orig_dpad, orig_keys
            StateManager.getInstance():setDisplayMode("list")
            close_browser(plugin())
            c.finish()
        end,
    }
end

-- List view cover size: the focus underline may only take cover height on devices that draw it (#93).
local function listcover_steps()
    local StateManager = require("core.state_manager")
    local c = checker("listcover")
    local b
    return {
        function()
            current = "listcover"
            StateManager.getInstance():setDisplayMode("list")
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Library"))
        end,
        function()
            b:onMenuSelect(find_item(b, "Paged 250 (50 per page)"))
        end,
        function()
            emit("listcover.has_dpad", tostring(Device:hasDPad()))
            emit("listcover.perpage", b.perpage)
            emit("listcover.cover_height", b.cover_height)
            emit("listcover.cover_width", b.cover_width)
            emit("listcover.item_height", b.item_height)
            shot("listcover")
            if not Device:hasDPad() then
                -- 6 px of padding above and below, as before the underline was added.
                c.check("covers_keep_their_size_without_a_dpad", b.item_height - b.cover_height == 12,
                    b.item_height .. " - " .. b.cover_height)
            end
            close_browser(plugin())
            c.finish()
        end,
    }
end

-- Parallel cover downloads (#98): drive services.image_loader directly against slow mock covers ---------------

local fork_pids = {}
local real_run_in_subprocess

-- ImageLoader uses files; Trapper's catalog workers use pipes. Count them only when requested.
local function watch_forks(include_catalogs)
    local FFIUtil = require("ffi/util")
    if real_run_in_subprocess then return end
    real_run_in_subprocess = FFIUtil.runInSubProcess
    ---@diagnostic disable-next-line: duplicate-set-field
    FFIUtil.runInSubProcess = function(...)
        local pid, fd = real_run_in_subprocess(...)
        if pid and (include_catalogs or select(2, ...) ~= true) then fork_pids[#fork_pids + 1] = pid end
        return pid, fd
    end
end

local function unwatch_forks()
    if real_run_in_subprocess then
        require("ffi/util").runInSubProcess = real_run_in_subprocess
        real_run_in_subprocess = nil
    end
end

local function server_stats(reset)
    local chunks = {}
    local http = require("socket.http")
    http.TIMEOUT = 5
    http.request({
        url = BASE .. (reset and "/__stats/reset" or "/__stats"),
        sink = require("ltn12").sink.table(chunks),
    })
    local stats = {}
    for key, value in table.concat(chunks):gmatch('"([%w_]+)": (%d+)') do stats[key] = tonumber(value) end
    return stats
end

-- Only count temporary files owned by this harness run.
local function count_lua_tmp()
    local lfs = require("libs/libkoreader-lfs")
    local n = 0
    for name in lfs.dir(tmp_root) do
        if name:find("^image%-%d+%-%d+%.tmp$") then n = n + 1 end
    end
    return n
end

-- Subprocesses still present in /proc; an unreaped zombie counts too.
local function alive_children(first)
    local lfs = require("libs/libkoreader-lfs")
    local n = 0
    for index = first, #fork_pids do
        if lfs.attributes("/proc/" .. fork_pids[index], "mode") then n = n + 1 end
    end
    return n
end

local function slow_cover_urls(first, n, delay, query)
    local urls = {}
    for i = 1, n do
        urls[i] = string.format("%s/cover/%d.png?delay=%s%s", BASE, first + i - 1, delay, query or "")
    end
    return urls
end

-- Run one ImageLoader batch to the end. opts: urls, cache (bool), ttl (minutes), parallel (nil = default), user, pass.
-- A 25 ms timer measures how long the UI went without running; done(result) gets the measurements.
local function run_batch(opts, done)
    local ImageLoader = require("services.image_loader")
    local socket = require("socket")
    local first_fork = #fork_pids + 1
    server_stats(true)
    local started = socket.gettime()
    local got, stamps, pngs = {}, {}, 0
    local last_tick, max_gap, finished = started, 0, false
    local function tick()
        local now = socket.gettime()
        max_gap = math.max(max_gap, now - last_tick)
        last_tick = now
        if not finished then UIManager:scheduleIn(0.025, tick) end
    end
    UIManager:scheduleIn(0.025, tick)
    local batch = ImageLoader:loadImages(opts.urls, function(url, content)
        got[#got + 1] = { url = url, content = content }
        stamps[#stamps + 1] = socket.gettime()
        if content:sub(1, 4) == "\137PNG" then pngs = pngs + 1 end
    end, opts.user, opts.pass, opts.cache, nil, opts.ttl, opts.parallel)
    wait_for(function() return not batch.loading end, 30, function(ok)
        finished = true
        local min_gap
        for i = 2, #stamps do
            local gap = stamps[i] - stamps[i - 1]
            if not min_gap or gap < min_gap then min_gap = gap end
        end
        done({
            completed = ok,
            got = got,
            count = #got,
            pngs = pngs,
            wall = (stamps[#stamps] or socket.gettime()) - started,
            max_gap = max_gap,
            min_gap = min_gap or 0,
            forks = #fork_pids - first_fork + 1,
            leftover_children = alive_children(first_fork),
            server = server_stats(false),
        })
    end)
end

local function emit_batch(prefix, r)
    emit(prefix .. ".completed", r.completed)
    emit(prefix .. ".callbacks", r.count)
    emit(prefix .. ".png_payloads", r.pngs)
    emit(prefix .. ".wall_s", string.format("%.2f", r.wall))
    emit(prefix .. ".ui_max_gap_ms", string.format("%.0f", r.max_gap * 1000))
    emit(prefix .. ".min_callback_gap_ms", string.format("%.0f", r.min_gap * 1000))
    emit(prefix .. ".forks", r.forks)
    emit(prefix .. ".server_requests", r.server.requests)
    emit(prefix .. ".server_max_inflight", r.server.max_inflight)
    emit(prefix .. ".server_with_auth", r.server.with_auth)
end

-- Queue real UI key events during deliberately slow decoding, not timer callbacks posing as input.
local function inputfairness_steps()
    local Event = require("ui/event")
    local Key = require("device/key")
    local RenderImage = require("ui/renderimage")
    local FocusManager = require("ui/widget/focusmanager")
    local StateManager = require("core.state_manager")
    local CoverCache = require("services.cover_cache")
    local FFIUtil = require("ffi/util")
    local time = require("ui/time")
    local c = checker("inputfairness")
    local steps = {}

    for _, case in ipairs({
        { name = "cached", cached = true },
        { name = "duplicates", cached = true, duplicate = true },
        { name = "cold" },
    }) do
        steps[#steps + 1] = function(advance)
            current = "inputfairness"
            local p = plugin()
            close_window_with_text("rendered in color")
            close_window_with_text("cache database")
            close_browser(p)
            remove_cache_files()
            local old_mode = StateManager.getInstance():getDisplayMode()
            local old_dpad, old_keys, old_touch = Device.hasDPad, Device.hasKeys, Device.isTouchDevice
            local old_focus = FocusManager.focus_non_touch
            Device.hasDPad = function() return true end
            Device.hasKeys = function() return true end
            Device.isTouchDevice = function() return false end
            FocusManager.focus_non_touch = true
            StateManager.getInstance():setDisplayMode("grid")

            local cover_url = BASE .. "/cover/900.png"
            local ok, bytes = require("services.http_client").getUrlContent(cover_url)
            assert(ok, bytes)
            local items = {}
            for index = 1, 6 do
                local address = case.duplicate and cover_url or cover_url .. "?item=" .. index
                items[index] = {
                    text = "Input test " .. index, title = "Input test " .. index, author = "Harness",
                    cover_url = address, lazy_load_cover = true, acquisitions = {},
                }
                if case.cached then assert(CoverCache.put(address, bytes, 0)) end
            end
            local b = open_browser()
            b:switchItemTable("Input fairness", items)
            local visible = b._items_to_update
            local expected = #visible
            assert(expected >= 4, "stress case needs at least four visible covers")
            local input = Device.input
            local old_wait, old_render, old_handle = input.waitEvent, RenderImage.renderImageData, b.handleEvent
            local queued, enqueued, latencies = {}, {}, {}
            local renders, updates, moves, pending = 0, 0, 0, false
            local slice_renders, slice_updates, max_renders, max_updates = 0, 0, 0, 0

            input.waitEvent = function(self, ...)
                if #queued > 0 then return { table.remove(queued, 1) } end
                return old_wait(self, ...)
            end
            b.handleEvent = function(self, event)
                local started = enqueued[event]
                local before = self:getFocusedItemNumber()
                if started then
                    latencies[#latencies + 1] = time.to_s(time.now() - started)
                    max_renders = math.max(max_renders, slice_renders)
                    max_updates = math.max(max_updates, slice_updates)
                    slice_renders, slice_updates = 0, 0
                end
                local handled = old_handle(self, event)
                if started and self:getFocusedItemNumber() ~= before then moves = moves + 1 end
                return handled
            end
            ---@diagnostic disable-next-line: duplicate-set-field
            RenderImage.renderImageData = function(self, content, ...)
                if content ~= bytes then return old_render(self, content, ...) end
                renders = renders + 1
                slice_renders = slice_renders + 1
                local event = Event:new("KeyPress", Key:new(renders % 2 == 1 and "Down" or "Up", {}))
                queued[#queued + 1], enqueued[event] = event, time.now()
                local bitmap = old_render(self, content, ...)
                FFIUtil.usleep(80000)
                pending = true
                return bitmap
            end
            for _, item in ipairs(visible) do
                local update = item.widget.update
                item.widget.update = function(self, ...)
                    if pending then
                        updates, slice_updates = updates + 1, slice_updates + 1
                        pending = false
                    end
                    return update(self, ...)
                end
            end

            wait_for(function()
                return renders == expected and #latencies == expected and #queued == 0
            end, 20, function(completed)
                input.waitEvent, RenderImage.renderImageData, b.handleEvent = old_wait, old_render, old_handle
                table.sort(latencies)
                local p50 = latencies[math.ceil(#latencies * 0.5)] or math.huge
                local p95 = latencies[math.ceil(#latencies * 0.95)] or math.huge
                emit("inputfairness." .. case.name .. ".p50_ms", math.floor(p50 * 1000))
                emit("inputfairness." .. case.name .. ".p95_ms", math.floor(p95 * 1000))
                emit("inputfairness." .. case.name .. ".max_renders_per_input", max_renders)
                emit("inputfairness." .. case.name .. ".max_updates_per_input", max_updates)
                emit("inputfairness." .. case.name .. ".expected", expected)
                emit("inputfairness." .. case.name .. ".renders", renders)
                emit("inputfairness." .. case.name .. ".updates", updates)
                emit("inputfairness." .. case.name .. ".handled_keys", #latencies)
                c.check(case.name .. ".completed", completed and renders == expected and updates == expected)
                c.check(case.name .. ".keys_move_focus", moves == expected, moves)
                c.check(case.name .. ".one_render_per_slice", max_renders == 1, max_renders)
                c.check(case.name .. ".one_update_per_slice", max_updates == 1, max_updates)
                c.check(case.name .. ".input_latency_bounded", p95 < 0.35, p95)
                close_browser(p)
                Device.hasDPad, Device.hasKeys, Device.isTouchDevice = old_dpad, old_keys, old_touch
                FocusManager.focus_non_touch = old_focus
                StateManager.getInstance():setDisplayMode(old_mode)
                advance()
            end)
            return "async"
        end
    end
    steps[#steps + 1] = function() c.finish() end
    return steps
end

local function covermemory_steps()
    local c = checker("covermemory")
    local Constants = require("models.constants")
    local CoverCache = require("services.cover_cache")
    local StateManager = require("core.state_manager")
    -- Older versions have no budget; compare that baseline with the production limit.
    local budget = Constants.COVER_CACHE.DECODED_MAX_BYTES or 8 * 1024 * 1024
    local old_mode, p, b, first_bitmap
    local items, steps = {}, {}

    local function visible_bounds()
        return (b.page - 1) * b.perpage + 1, math.min(b.page * b.perpage, #items)
    end
    local function loaded()
        local first, last = visible_bounds()
        for index = first, last do
            if not items[index].cover_bb then return false end
        end
        return true
    end
    local function retained_bytes()
        local first, last = visible_bounds()
        local total, visible = 0, 0
        for index, item in ipairs(items) do
            if item.cover_bb then
                local bytes = tonumber(item.cover_bb.stride * item.cover_bb.h)
                total = total + bytes
                if index >= first and index <= last then visible = visible + bytes end
            end
        end
        return total, visible
    end
    local function image_copies(widget, copies)
        if widget.image and widget._bb and widget._bb ~= widget.image then
            copies[#copies + 1] = widget._bb
        end
        for _, child in ipairs(widget) do image_copies(child, copies) end
    end

    steps[#steps + 1] = function()
        current = "covermemory"
        p = plugin()
        close_window_with_text("rendered in color")
        close_window_with_text("cache database")
        close_browser(p)
        old_mode = StateManager.getInstance():getDisplayMode()
        StateManager.getInstance():setDisplayMode("grid")
        remove_cache_files()
        local address = BASE .. "/cover/960.png"
        local ok, bytes = require("services.http_client").getUrlContent(address)
        assert(ok, bytes)
        for index = 1, 96 do
            local url = address .. "?memory=" .. index
            items[index] = {
                text = "Memory " .. index, title = "Memory " .. index, author = "Harness",
                cover_url = url, image = url, lazy_load_cover = true, acquisitions = {},
            }
            assert(CoverCache.put(url, bytes, 0))
        end
        b = open_browser()
        b:switchItemTable("Cover memory", items)
    end
    for page = 1, 16 do
        steps[#steps + 1] = function(advance)
            if page > 1 then
                b.page = page
                b:updateItems()
            end
            wait_for(loaded, 10, function(ok)
                c.check("page" .. page .. ".loaded", ok)
                local total, visible = retained_bytes()
                emit("covermemory.page" .. page .. ".decoded_bytes", total)
                emit("covermemory.page" .. page .. ".visible_bytes", visible)
                c.check("page" .. page .. ".bounded", total <= math.max(budget, visible), total)
                if page == 1 then first_bitmap = items[1].cover_bb end
                advance()
            end)
            return "async"
        end
    end
    steps[#steps + 1] = function(advance)
        c.check("old_page_evicted", items[1].cover_bb == nil)
        c.check("old_bitmap_freed", first_bitmap and first_bitmap:getAllocated() == 0)
        server_stats(true)
        b.page = 1
        b:updateItems()
        wait_for(loaded, 10, function(ok)
            c.check("return_redecodes_from_disk", ok and server_stats(false).requests == 0)
            local memory = b._cover_memory
            c.check("owner_tracks_buffers", memory ~= nil)
            if memory then
                local before = items[1].cover_bb
                b:toggleViewMode()
                close_window_with_text("Switched to")
                c.check("view_change_reuses_bitmap", items[1].cover_bb == before and before:getAllocated() == 1)
                b:toggleViewMode()
                close_window_with_text("Switched to")
                memory.max_bytes = 256 * 1024 -- Force pressure while the dialog borrows an off-screen cover.
                memory:_trim()
            end
            advance()
        end)
        return "async"
    end
    steps[#steps + 1] = function(advance)
        local memory = b._cover_memory
        if not memory then return end -- Already reported by owner_tracks_buffers.
        local borrowed = items[1].cover_bb
        items[1].image = items[1].cover_url .. "&delay=3"
        local dialog = require("ui.dialogs.book_info_dialog").build(b, items[1])
        UIManager:show(dialog)
        b.page = 2
        b:updateItems()
        wait_for(loaded, 10, function(ok)
            c.check("dialog_pins_offscreen_cover", ok and borrowed:getAllocated() == 1)
            local high_res
            wait_for(function()
                for bitmap, record in pairs(memory.records) do
                    if record.retired then high_res = bitmap; return true end
                end
                return false
            end, 10, function(ready)
                c.check("dialog_high_resolution_loaded", ready)
                UIManager:tickAfterNext(function()
                    local copies = {}
                    image_copies(dialog, copies)
                    c.check("dialog_has_measurable_scaled_copy", #copies > 0, #copies)
                    UIManager:close(dialog)
                    c.check("dialog_releases_high_resolution", high_res and high_res:getAllocated() == 0)
                    local freed = true
                    for _, bitmap in ipairs(copies) do
                        if bitmap:getAllocated() ~= 0 then freed = false end
                    end
                    c.check("dialog_releases_scaled_copies", freed)
                    c.check("after_dialog_within_budget",
                        memory.bytes <= math.max(memory.max_bytes, memory.pinned_bytes))
                    advance()
                end)
            end)
        end)
        return "async"
    end
    steps[#steps + 1] = function(advance)
        local memory = b._cover_memory
        if memory then memory.max_bytes = budget end
        b:toggleViewMode()
        close_window_with_text("Switched to")
        UIManager:forceRePaint()
        local copies = {}
        image_copies(b.item_group, copies)
        c.check("menu_has_measurable_scaled_copies", #copies > 0, #copies)
        b:switchItemTable("Replacement", {})
        if memory then
            c.check("catalog_replacement_releases_all", memory.bytes == 0 and next(memory.entries) == nil)
        end
        local freed = true
        for _, bitmap in ipairs(copies) do
            if bitmap:getAllocated() ~= 0 then freed = false end
        end
        c.check("catalog_replacement_releases_scaled_copies", freed)
        local function finish()
            close_browser(p)
            if memory then c.check("close_leaves_no_records", next(memory.records) == nil) end
            StateManager.getInstance():setDisplayMode(old_mode)
            remove_cache_files()
            c.finish()
            advance()
        end
        if not memory then
            finish()
        else
            b:switchItemTable("Borrowed cover", items)
            wait_for(loaded, 10, function(ok)
                c.check("borrowed_cover_reloaded", ok)
                if not ok then return finish() end
                local borrowed, image = items[1].cover_bb, items[1].image
                items[1].image = nil
                local dialog = require("ui.dialogs.book_info_dialog").build(b, items[1])
                items[1].image = image
                UIManager:show(dialog)
                close_browser(p)
                c.check("dialog_survives_menu_close", borrowed:getAllocated() == 1
                    and memory.bytes == tonumber(borrowed.stride * borrowed.h))
                UIManager:forceRePaint()
                UIManager:close(dialog)
                c.check("last_borrower_releases_cover", borrowed:getAllocated() == 0 and memory.bytes == 0)
                finish()
            end)
        end
        return "async"
    end
    return steps
end

local function parcovers_steps()
    local ImageLoader = require("services.image_loader")
    local CoverCache = require("services.cover_cache")
    local Constants = require("models.constants")
    local c = checker("parcovers")
    -- main's serial loader has no IMAGE_LOADER block, which makes it a usable "before" measurement.
    local subprocess_loader = Constants.IMAGE_LOADER ~= nil
    local workers = subprocess_loader and Constants.IMAGE_LOADER.MAX_PARALLEL or 1
    local slow, books = 0.6, 6

    return {
        -- Default settings: slow covers download side by side while the UI keeps running.
        function(advance)
            current = "parcovers"
            watch_forks()
            remove_cache_files()
            emit("parcovers.subprocess_loader", subprocess_loader)
            emit("parcovers.workers", workers)
            local tmp_before = count_lua_tmp()
            run_batch({ urls = slow_cover_urls(100, books, slow), cache = false, user = "u", pass = "p" }, function(r)
                emit_batch("parcovers.default", r)
                c.check("default_delivers_every_cover", r.completed and r.count == books and r.pngs == books, r.count)
                c.check("default_runs_" .. workers .. "_downloads_at_once", r.server.max_inflight == workers,
                    r.server.max_inflight)
                c.check("default_beats_serial_time", workers == 1 or r.wall < books * slow * 0.8, r.wall)
                c.check("default_keeps_ui_responsive", workers == 1 or r.max_gap < 0.25, r.max_gap)
                c.check("default_uses_subprocesses", r.forks == (subprocess_loader and books or 0), r.forks)
                c.check("default_sends_auth_from_subprocess", r.server.with_auth == books, r.server.with_auth)
                c.check("default_reaps_subprocesses", r.leftover_children == 0, r.leftover_children)
                c.check("default_leaves_no_temp_files", count_lua_tmp() == tmp_before, count_lua_tmp() - tmp_before)
                advance()
            end)
            return "async"
        end,
        -- halt() while downloads are running (the browser closes or the page changes).
        function(advance)
            local tmp_before, first_fork = count_lua_tmp(), #fork_pids + 1
            local halted, late = false, 0
            local batch, halt = ImageLoader:loadImages(slow_cover_urls(200, books, 3), function()
                if halted then late = late + 1 end
            end, nil, nil, false)
            UIManager:scheduleIn(0.6, function()
                local running = alive_children(first_fork)
                halt()
                halted = true
                emit("parcovers.halt.children_running_before", running)
                c.check("halt_interrupted_running_downloads", not subprocess_loader or running == workers, running)
                c.check("halt_kills_subprocesses", alive_children(first_fork) == 0, alive_children(first_fork))
                c.check("halt_stops_the_batch", batch.loading == false)
                c.check("halt_removes_temp_files", count_lua_tmp() == tmp_before, count_lua_tmp() - tmp_before)
                UIManager:scheduleIn(3.5, function()
                    c.check("halt_delivers_nothing_afterwards", late == 0, late)
                    advance()
                end)
            end)
            return "async"
        end,
        -- The switch that turns parallel downloads off: no subprocess, one blocking fetch per tick as before.
        function(advance)
            run_batch({ urls = slow_cover_urls(300, 5, 0), cache = false, parallel = false }, function(r)
                emit_batch("parcovers.gate_off", r)
                c.check("gate_off_delivers_every_cover", r.completed and r.count == 5, r.count)
                c.check("gate_off_starts_no_subprocess", r.forks == 0, r.forks)
                c.check("gate_off_fetches_one_at_a_time", r.server.max_inflight == 1, r.server.max_inflight)
                c.check("gate_off_yields_between_covers", r.min_gap >= 0.19, r.min_gap)
                advance()
            end)
            return "async"
        end,
        -- fork() fails (low memory): the loader falls back to fetching in the UI process, paced as before.
        function(advance)
            local FFIUtil = require("ffi/util")
            local counting_run = FFIUtil.runInSubProcess
            ---@diagnostic disable-next-line: duplicate-set-field
            FFIUtil.runInSubProcess = function() return nil end
            run_batch({ urls = slow_cover_urls(400, 5, 0), cache = false }, function(r)
                FFIUtil.runInSubProcess = counting_run
                emit_batch("parcovers.fork_failure", r)
                c.check("fork_failure_delivers_every_cover", r.completed and r.count == 5, r.count)
                c.check("fork_failure_fetches_one_at_a_time", r.server.max_inflight == 1, r.server.max_inflight)
                c.check("fork_failure_yields_between_covers", r.min_gap >= 0.19, r.min_gap)
                advance()
            end)
            return "async"
        end,
        -- A failed download hands back the stale cached cover; without one nothing is delivered.
        function(advance)
            local stale_url = BASE .. "/cover/500.png?fail=1"
            local bare_url = BASE .. "/cover/501.png?fail=1"
            remove_cache_files()
            CoverCache.put(stale_url, "STALE-COVER", 0)
            -- A negative TTL makes every cached entry stale.
            run_batch({ urls = { stale_url, bare_url }, cache = true, ttl = -1 }, function(r)
                local first = r.got[1]
                c.check("failed_download_serves_stale_cover", r.count == 1 and first.url == stale_url
                    and first.content == "STALE-COVER", r.count)
                local kept = CoverCache.get(stale_url, 1e9)
                c.check("failed_download_keeps_stale_cover", kept and kept.content == "STALE-COVER")
                remove_cache_files()
                advance()
            end)
            return "async"
        end,
        -- Downloaded covers land in the disk cache, and the second pass never touches the network.
        function(advance)
            local urls = slow_cover_urls(600, 4, 0.2)
            run_batch({ urls = urls, cache = true }, function(first)
                c.check("downloads_are_cached", first.count == 4 and count_cache_files(".img") == 4,
                    count_cache_files(".img"))
                run_batch({ urls = urls, cache = true }, function(second)
                    emit_batch("parcovers.cached", second)
                    c.check("cached_pass_delivers_every_cover", second.count == 4, second.count)
                    c.check("cached_pass_makes_no_request", second.server.requests == 0 and second.forks == 0,
                        second.server.requests)
                    remove_cache_files()
                    unwatch_forks()
                    c.finish()
                    advance()
                end)
            end)
            return "async"
        end,
    }
end

-- Devices without /tmp (Android) make os.tmpname() raise: covers must still load, one request at a time.
-- The "Parallel Cover Downloads" switch: stored setting, menu entry, and both callers of loadImages -----------

local function find_menu_entry(p, path)
    local entry = { sub_item_table = require("config.settings_menu").create(p) }
    for _, text in ipairs(path) do
        local found
        for _, item in ipairs(entry.sub_item_table or {}) do
            if item.text == text then
                found = item
                break
            end
        end
        if not found then return nil end
        entry = found
    end
    return entry
end

local function coverprefetch_steps()
    local c = checker("coverprefetch")
    local ImageLoader = require("services.image_loader")
    local CoverCache = require("services.cover_cache")
    local CoverLoader = require("services.cover_loader")
    local StateManager = require("core.state_manager")
    local RenderImage = require("ui/renderimage")
    local p, b, entry, old_mode, perpage
    local items, previous, steps = {}, {}, {}
    local settings = { "cover_prefetch_enabled", "cover_cache_enabled", "cover_parallel_downloads" }

    local function loaded()
        local want, have = visible_covers(b)
        return want > 0 and have == want
    end
    local function warmed()
        return b._cover_prefetch_batch and not b._cover_prefetch_batch.loading
    end
    local function toggle()
        entry.callback()
        close_window_with_text("Neighboring cover prefetch")
    end

    steps[#steps + 1] = function(advance)
        current = "coverprefetch"
        p = plugin()
        close_window_with_text("rendered in color")
        close_window_with_text("cache database")
        close_browser(p)
        for _, name in ipairs(settings) do previous[name] = p:getSetting(name) end
        old_mode = StateManager.getInstance():getDisplayMode()
        StateManager.getInstance():setDisplayMode("grid")
        entry = assert(find_menu_entry(p, { "Settings", "Cover Settings", "Prefetch Neighboring Covers" }))
        c.check("default_off", p:getSetting("cover_prefetch_enabled") == false and not entry.checked_func())
        p:saveSetting("cover_cache_enabled", true)
        p:saveSetting("cover_parallel_downloads", true)
        remove_cache_files()
        local address = BASE .. "/cover/980.png"
        local ok, bytes = require("services.http_client").getUrlContent(address)
        assert(ok, bytes)
        for index = 1, 36 do
            local url = address .. "?neighbor=" .. index .. "&delay=0.15"
            items[index] = {
                text = "Neighbor " .. index, title = "Neighbor " .. index, author = "Harness",
                cover_url = url, image = url, lazy_load_cover = true, acquisitions = {},
            }
        end
        b = open_browser()
        b:switchItemTable("Neighbor covers", items)
        perpage = b.perpage
        assert(perpage >= 3 and perpage * 3 <= #items, "fixture needs three display pages")
        items[perpage + 2].cover_url = items[perpage + 1].cover_url
        items[perpage + 2].image = items[perpage + 1].image
        for index = 1, perpage + 1 do assert(CoverCache.put(items[index].cover_url, bytes, 0)) end
        server_stats(true)
        watch_forks()
        wait_for(loaded, 10, function(ready)
            c.check("visible_covers_loaded", ready)
            UIManager:scheduleIn(0.75, function()
                c.check("default_no_speculative_requests", server_stats(false).requests == 0)
                advance()
            end)
        end)
        return "async"
    end
    steps[#steps + 1] = function(advance)
        toggle()
        c.check("toggle_persists_opt_in", p:getSetting("cover_prefetch_enabled") == true and entry.checked_func())
        local real_prefetch, real_render, real_dirty = ImageLoader.prefetch, RenderImage.renderImageData, UIManager.setDirty
        local renders, paints = 0, 0
        local snapshot, neighbor_urls
        ---@diagnostic disable-next-line: duplicate-set-field
        RenderImage.renderImageData = function(self, ...)
            renders = renders + 1
            return real_render(self, ...)
        end
        ---@diagnostic disable-next-line: duplicate-set-field
        UIManager.setDirty = function(self, widget, ...)
            if widget == b or widget == b.show_parent then paints = paints + 1 end
            return real_dirty(self, widget, ...)
        end
        ---@diagnostic disable-next-line: duplicate-set-field
        ImageLoader.prefetch = function(self, urls, ...)
            c.check("foreground_finishes_first", loaded() and not (b._cover_batch and b._cover_batch.loading))
            snapshot, neighbor_urls = { renders = renders, paints = paints }, urls
            return real_prefetch(self, urls, ...)
        end
        c.check("browser_is_foreground", UIManager:getTopmostVisibleWidget() == b)
        b:updateItems()
        wait_for(warmed, 10, function(ready)
            ImageLoader.prefetch, RenderImage.renderImageData, UIManager.setDirty = real_prefetch, real_render, real_dirty
            c.check("warming_finishes", ready)
            c.check("no_decode_or_repaint", snapshot and renders == snapshot.renders and paints == snapshot.paints,
                renders .. " renders / " .. paints .. " dirty calls")
            c.check("deduplicates_one_neighbor", neighbor_urls and #neighbor_urls == perpage - 1)
            c.check("skips_fresh_cache", server_stats(false).requests == perpage - 2, server_stats(false).requests)
            local cached, undecoded = true, true
            for index = perpage + 1, perpage * 2 do
                if not CoverCache.get(items[index].cover_url) then cached = false end
                if items[index].cover_bb then undecoded = false end
            end
            c.check("neighbor_cached_but_not_decoded", cached and undecoded)
            c.check("does_not_warm_further_pages", CoverCache.get(items[perpage * 2 + 1].cover_url) == nil)
            toggle()
            c.check("toggle_persists_off", p:getSetting("cover_prefetch_enabled") == false and not entry.checked_func())
            server_stats(true)
            b:onNextPage()
            wait_for(loaded, 10, function(visible)
                c.check("warmed_page_uses_cache", visible and server_stats(false).requests == 0)
                advance()
            end)
        end)
        return "async"
    end
    for _, setting in ipairs({ "cover_cache_enabled", "cover_parallel_downloads" }) do
        steps[#steps + 1] = function(advance)
            p:saveSetting("cover_prefetch_enabled", true)
            p:saveSetting(setting, false)
            server_stats(true)
            b:updateItems()
            UIManager:scheduleIn(0.75, function()
                c.check(setting .. ".no_warming", server_stats(false).requests == 0
                    and not b._scheduled_cover_prefetch and not b._cover_prefetch_batch)
                p:saveSetting(setting, true)
                advance()
            end)
            return "async"
        end
    end
    for _, action in ipairs({ "reverse", "layout", "catalog", "dialog", "close" }) do
        steps[#steps + 1] = function(advance)
            StateManager.getInstance():setDisplayMode("grid")
            b:switchItemTable("Neighbor covers", items)
            b.page = 2
            for index = perpage * 2 + 1, perpage * 3 do
                items[index].cover_url = BASE .. "/cover/980.png?cancel=" .. index .. "&delay=1.5"
            end
            local first, files_before = #fork_pids + 1, count_lua_tmp()
            b:updateItems()
            wait_for(function() return b._cover_prefetch_batch and alive_children(first) > 0 end, 10, function(started)
                c.check(action .. ".starts_warming", started)
                local batch = b._cover_prefetch_batch
                if action == "reverse" then
                    b:onPrevPage()
                elseif action == "layout" then
                    b:toggleViewMode()
                    close_window_with_text("Switched to")
                elseif action == "catalog" then
                    b:switchItemTable("Replacement", {})
                elseif action == "dialog" then
                    local dialog = require("ui.dialogs.book_info_dialog").build(b, items[perpage + 1])
                    UIManager:show(dialog)
                    UIManager:close(dialog)
                else
                    close_browser(p)
                end
                c.check(action .. ".cancels_batch", batch and batch.cancelled and not batch.loading)
                c.check(action .. ".reaps_children", alive_children(first) == 0)
                c.check(action .. ".cleans_tempfiles", count_lua_tmp() == files_before)
                CoverLoader.stopLoading(b)
                c.check(action .. ".cleans_timers", not b._scheduled_cover_prefetch and not b._scheduled_cover_load)
                advance()
            end)
            return "async"
        end
    end
    steps[#steps + 1] = function(advance)
        -- Cancelled clients do not cancel the mock server's sleeping handlers.
        wait_for(function() return server_stats(false).inflight == 0 end, 5, function(quiet)
            c.check("cancelled_server_requests_settle", quiet)
            server_stats(true)
            local first, delivered = #fork_pids + 1, 0
            local foreground = ImageLoader:loadImages(slow_cover_urls(990, 3, 0.3),
                function() delivered = delivered + 1 end)
            local urls = slow_cover_urls(993, 3, 0.3)
            local background = ImageLoader:prefetch(urls)
            wait_for(function() return not foreground.loading and not background.loading end, 10, function(done)
                local stats = server_stats(false)
                c.check("shared_budget_completes_both_batches", done and delivered == 3 and stats.requests == 6)
                c.check("shared_budget_never_exceeds_two", stats.max_inflight <= 2, stats.max_inflight)
                c.check("shared_budget_uses_subprocesses", #fork_pids - first + 1 == 6)
                c.check("shared_budget_reaps_all_workers", alive_children(first) == 0 and count_lua_tmp() == 0)
                local cached = true
                for _, url in ipairs(urls) do if not CoverCache.get(url) then cached = false end end
                c.check("shared_budget_warms_cache", cached)
                advance()
            end)
        end)
        return "async"
    end
    for _, failure in ipairs({ "tmpname", "fork" }) do
        steps[#steps + 1] = function(advance)
            local FFIUtil = require("ffi/util")
            local real_tmp, real_fork = os.tmpname, FFIUtil.runInSubProcess
            server_stats(true)
            if failure == "tmpname" then
                ---@diagnostic disable-next-line: duplicate-set-field
                os.tmpname = function() error("injected unavailable temporary path") end
            else
                ---@diagnostic disable-next-line: duplicate-set-field
                FFIUtil.runInSubProcess = function() return nil end
            end
            local batch = ImageLoader:prefetch(slow_cover_urls(998, 2, 0.1))
            wait_for(function() return not batch.loading end, 5, function(done)
                os.tmpname, FFIUtil.runInSubProcess = real_tmp, real_fork
                c.check(failure .. ".no_blocking_fallback", done and server_stats(false).requests == 0)
                c.check(failure .. ".no_temporary_files", count_lua_tmp() == 0)
                advance()
            end)
            return "async"
        end
    end
    steps[#steps + 1] = function()
        unwatch_forks()
        close_browser(p)
        for _, name in ipairs(settings) do p:saveSetting(name, previous[name]) end
        StateManager.getInstance():setDisplayMode(old_mode)
        remove_cache_files()
        c.finish()
    end
    return steps
end

local function covergate_steps()
    local c = checker("covergate")
    local ImageLoader = require("services.image_loader")
    local real_load_images = ImageLoader.loadImages
    local calls, last_batch = {}, nil
    local p, entry

    -- Record what every caller passes as the switch (8th argument) and keep hold of the batch it started.
    local function spy_on()
        ---@diagnostic disable-next-line: duplicate-set-field
        ImageLoader.loadImages = function(self, urls, callback, user, pass, cache, max_mb, ttl, parallel)
            calls[#calls + 1] = { count = #urls, parallel = parallel }
            local batch, halt = real_load_images(self, urls, callback, user, pass, cache, max_mb, ttl, parallel)
            last_batch = batch
            return batch, halt
        end
    end

    local function seen_since(first)
        local seen = {}
        for i = first, #calls do seen[#seen + 1] = tostring(calls[i].parallel) end
        return table.concat(seen, ",")
    end

    local function all_calls_pass(first, value)
        if #calls < first then return false end
        for i = first, #calls do
            if calls[i].parallel ~= value then return false end
        end
        return true
    end

    -- Browse the cold paged feed like a user does and check what the cover loader did with the switch.
    local function browse(label, expect_parallel, done)
        local first_call, first_fork = #calls + 1, #fork_pids + 1
        remove_cache_files()
        server_stats(true)
        covers_pass("covergate." .. label, 1, function(want, have)
            local forks = #fork_pids - first_fork + 1
            local stats = server_stats(false)
            emit("covergate." .. label .. ".forks", forks)
            emit("covergate." .. label .. ".server_max_inflight", stats.max_inflight)
            c.check(label .. ".renders_every_cover", want > 0 and have == want, have .. "/" .. want)
            c.check(label .. ".passes_the_setting", all_calls_pass(first_call, expect_parallel), seen_since(first_call))
            if expect_parallel then
                c.check(label .. ".uses_subprocesses", forks > 0, forks)
            else
                c.check(label .. ".starts_no_subprocess", forks == 0, forks)
                c.check(label .. ".fetches_one_at_a_time", stats.max_inflight <= 1, stats.max_inflight)
            end
            done()
        end)
    end

    -- Open the details dialog of a book from the current listing: its high-resolution cover is the second caller.
    local function book_dialog(label, expect_parallel, done)
        local b = plugin().opds_browser
        local book
        for _, item in ipairs(b.item_table) do
            if item.acquisitions and item.acquisitions[1] and (item.image or item.thumbnail) then
                book = item
                break
            end
        end
        c.check(label .. ".book_has_a_cover_link", book ~= nil)
        if not book then return done() end
        local first_call, first_fork = #calls + 1, #fork_pids + 1
        remove_cache_files()
        server_stats(true)
        last_batch = nil
        b:onMenuSelect(book)
        wait_for(function() return last_batch ~= nil and not last_batch.loading end, 20, function(ok)
            local forks = #fork_pids - first_fork + 1
            c.check(label .. ".loads_its_cover", ok and #calls - first_call + 1 == 1 and server_stats(false).requests == 1,
                tostring(ok) .. " / " .. (#calls - first_call + 1) .. " calls")
            c.check(label .. ".passes_the_setting", all_calls_pass(first_call, expect_parallel), seen_since(first_call))
            if expect_parallel then
                c.check(label .. ".uses_a_subprocess", forks == 1, forks)
            else
                c.check(label .. ".starts_no_subprocess", forks == 0, forks)
            end
            if b.book_info_dialog then UIManager:close(b.book_info_dialog) end
            done()
        end)
    end

    return {
        function()
            current = "covergate"
            p = plugin()
            local Settings = require("config.settings")
            local stored = p:getSetting("cover_parallel_downloads")
            c.check("default_is_on", stored == true, stored)

            -- Settings written by 1.2.x have no such key: upgrading turns it on, and a stored "off" is kept.
            local fresh = Settings:new(make_temp_dir() .. "/covergate_settings.lua")
            fresh:initializeDefaults()
            c.check("upgrade_turns_it_on", fresh.data.cover_parallel_downloads == true, fresh.data.cover_parallel_downloads)
            fresh.data.cover_parallel_downloads = false
            fresh:initializeDefaults()
            c.check("stored_off_is_kept", fresh.data.cover_parallel_downloads == false, fresh.data.cover_parallel_downloads)

            entry = find_menu_entry(p, { "Settings", "Cover Settings", "Parallel Cover Downloads" })
            c.check("menu_entry_exists", entry ~= nil)
            assert(entry, "no Parallel Cover Downloads entry in the settings menu")
            c.check("menu_entry_checked_by_default", entry.checked_func() == true, entry.checked_func())
            entry.callback()
            c.check("menu_toggle_stores_off", p:getSetting("cover_parallel_downloads") == false,
                p:getSetting("cover_parallel_downloads"))
            c.check("menu_entry_unchecks", entry.checked_func() == false, entry.checked_func())
            c.check("menu_toggle_says_disabled", window_has_text("Parallel cover downloads disabled"))
            close_window_with_text("Parallel cover downloads")
            entry.callback()
            c.check("menu_toggle_stores_on", p:getSetting("cover_parallel_downloads") == true,
                p:getSetting("cover_parallel_downloads"))
            c.check("menu_toggle_says_enabled", window_has_text("Parallel cover downloads enabled"))
            close_window_with_text("Parallel cover downloads")
        end,
        function(advance)
            watch_forks()
            spy_on()
            browse("on", true, advance)
            return "async"
        end,
        function(advance)
            book_dialog("dialog_on", true, advance)
            return "async"
        end,
        function(advance)
            entry.callback()
            close_window_with_text("Parallel cover downloads")
            browse("off", false, advance)
            return "async"
        end,
        function(advance)
            book_dialog("dialog_off", false, advance)
            return "async"
        end,
        function(advance)
            entry.callback()
            close_window_with_text("Parallel cover downloads")
            c.check("switch_back_on", p:getSetting("cover_parallel_downloads") == true,
                p:getSetting("cover_parallel_downloads"))
            local RenderImage = require("ui/renderimage")
            local render = RenderImage.renderImageData
            local renders = 0
            ---@diagnostic disable-next-line: duplicate-set-field
            RenderImage.renderImageData = function(self, ...)
                renders = renders + 1
                return render(self, ...)
            end
            local first_fork, tmp_before = #fork_pids + 1, count_lua_tmp()
            local dialog = require("ui.dialogs.book_info_dialog").build(p.opds_browser, {
                title = "Cancelled cover", acquisitions = {},
                image = BASE .. "/cover/950.png?delay=1",
            })
            UIManager:show(dialog)
            local batch = assert(last_batch, "dialog did not start a cover batch")
            UIManager:scheduleIn(0.12, function()
                UIManager:close(dialog)
                c.check("closing_dialog_cancels_its_batch", not batch.loading)
                UIManager:scheduleIn(1.2, function()
                    RenderImage.renderImageData = render
                    c.check("closed_dialog_has_no_late_decode", renders == 0, renders)
                    c.check("closed_dialog_leaves_no_child", alive_children(first_fork) == 0)
                    c.check("closed_dialog_leaves_no_temporary_file", count_lua_tmp() == tmp_before)
                    advance()
                end)
            end)
            return "async"
        end,
        function()
            ImageLoader.loadImages = real_load_images
            unwatch_forks()
            remove_cache_files()
            close_browser(p)
            c.finish()
        end,
    }
end

local function parandroid_steps()
    local c = checker("parandroid")
    local real_tmpname = os.tmpname
    return {
        function(advance)
            current = "parandroid"
            watch_forks()
            ---@diagnostic disable-next-line: duplicate-set-field
            os.tmpname = function() error("unable to generate a unique filename") end
            run_batch({ urls = slow_cover_urls(700, 5, 0), cache = false }, function(r)
                os.tmpname = real_tmpname
                unwatch_forks()
                emit_batch("parandroid", r)
                c.check("delivers_every_cover", r.completed and r.count == 5 and r.pngs == 5, r.count)
                c.check("starts_no_subprocess", r.forks == 0, r.forks)
                c.check("fetches_one_at_a_time", r.server.max_inflight == 1, r.server.max_inflight)
                c.check("yields_between_covers", r.min_gap >= 0.19, r.min_gap)
                advance()
            end)
            return "async"
        end,
        function(advance)
            watch_forks()
            ---@diagnostic disable-next-line: duplicate-set-field
            os.tmpname = function() return nil end
            run_batch({ urls = slow_cover_urls(710, 2, 0), cache = false }, function(r)
                os.tmpname = real_tmpname
                unwatch_forks()
                c.check("nil_path_delivers_every_cover", r.completed and r.count == 2 and r.pngs == 2, r.count)
                c.check("nil_path_starts_no_subprocess", r.forks == 0, r.forks)
                c.finish()
                advance()
            end)
            return "async"
        end,
    }
end

-- The "Default Catalog" setting (#89): menu entry, launch behaviour, Back, edit, delete, offline ----------------

local function defaultcat_steps()
    local c = checker("defaultcat")
    local NONE_TEXT = "None (show the list of catalogs)"
    local p, target, other, b

    -- Deliberately independent of the plugin's own helpers, so the scenario also runs (and fails) on older code.
    local function current_default()
        for _, server in ipairs(p.servers) do
            if server.is_default then return server end
        end
    end

    local function clear_default()
        for _, server in ipairs(p.servers) do server.is_default = nil end
    end

    local function settings_file_text()
        local file = io.open(p.opds_settings.file, "r")
        if not file then return "" end
        local text = file:read("*a")
        file:close()
        return text
    end

    -- The entry has no fixed text because it shows the current choice.
    local function default_entry()
        local settings = find_menu_entry(p, { "Settings" })
        for _, item in ipairs(settings and settings.sub_item_table or {}) do
            if item.text_func and item.text_func():find("Default Catalog", 1, true) then return item end
        end
    end

    local function radios()
        local entry = default_entry()
        return entry and entry.sub_item_table_func and entry.sub_item_table_func() or {}
    end

    local function radio(items, text)
        for _, item in ipairs(items) do
            if item.text == text then return item end
        end
    end

    local function lists_catalogs(browser)
        return browser ~= nil and #browser.paths == 0 and browser.item_table[1].text == "Downloads"
    end

    local function opened_target(browser)
        return browser ~= nil and #browser.paths == 1 and browser.paths[1].url == target.url
    end

    -- Menu sets item.idx only for the items it displays; a tap or long-press always comes from one of them.
    local function root_item(browser, text)
        for i, item in ipairs(browser.item_table) do
            if item.text == text then
                item.idx = i
                return item
            end
        end
    end

    return {
        -- A: the entry lists every catalog and "None"; choosing one marks only that catalog and is saved
        function()
            current = "defaultcat"
            p = plugin()
            close_browser(p)
            clear_default()
            target = add_server(p, "Mock Default Pick", "/opds/echo")
            target.username, target.password = "reader", "secret"
            other = add_server(p, "Mock Default Other", "/opds/sync")

            local entry = default_entry()
            c.check("A.menu_entry_exists", entry ~= nil)
            local items = radios()
            c.check("A.lists_every_catalog_and_none", #items == #p.servers + 1, #items .. " of " .. (#p.servers + 1))
            local none, pick = radio(items, NONE_TEXT), radio(items, target.title)
            c.check("A.none_is_marked_at_first", none ~= nil and none.checked_func() == true and pick ~= nil
                and pick.checked_func() == false)
            c.check("A.entry_text_without_default", entry and entry.text_func() == "Default Catalog",
                entry and entry.text_func())

            reset_toasts()
            if pick then pick.callback() end
            c.check("A.pick_marks_the_catalog", target.is_default == true and other.is_default == nil)
            c.check("A.pick_moves_the_radio_mark", pick ~= nil and pick.checked_func() == true and none ~= nil
                and none.checked_func() == false)
            c.check("A.entry_text_names_the_default", entry and entry.text_func() == "Default Catalog: Mock Default Pick",
                entry and entry.text_func())
            c.check("A.pick_toast", toast_has("Mock Default Pick will open"), toasts[#toasts])
            c.check("A.pick_is_saved", settings_file_text():find("is_default", 1, true) ~= nil)

            local second = radio(radios(), other.title)
            if second then second.callback() end
            c.check("A.only_one_default", other.is_default == true and target.is_default == nil)
            local first = radio(radios(), target.title)
            if first then first.callback() end
            c.check("A.choice_can_change_back", target.is_default == true and other.is_default == nil)
        end,
        -- B: launching the plugin (menu entry or gesture) opens the default catalog; Back returns to the list
        function()
            local fetches = count_feed_fetches()
            reset_toasts()
            p:onShowOPDSPlusCatalog()
            fetches.restore()
            b = p.opds_browser
            c.check("B.one_feed_request", fetches.n == 1, fetches.n)
        end,
        function()
            c.check("B.default_opens", opened_target(b), b and (#b.paths .. " path(s)"))
            c.check("B.title_is_the_catalog", b ~= nil and b.catalog_title == target.title, b and b.catalog_title)
            local sent_credentials = false
            for _, item in ipairs(b and b.item_table or {}) do
                if item.text and item.text:lower():find("authorization", 1, true) then sent_credentials = true end
            end
            c.check("B.catalog_credentials_are_sent", sent_credentials)
            c.check("B.no_error_toast", not toast_has("Cannot get catalog info"), toasts[#toasts])

            b:onBack()
            c.check("B.back_shows_the_list_of_catalogs", lists_catalogs(b))
            c.check("B.back_keeps_the_browser_open", p.opds_browser == b)
            b:onBack()
            c.check("B.back_again_closes_it", p.opds_browser == nil)
        end,
        -- C: "None" goes back to the plain list of catalogs, without any request
        function()
            reset_toasts()
            local none = radio(radios(), NONE_TEXT)
            if none then none.callback() end
            c.check("C.none_clears_the_default", current_default() == nil)
            c.check("C.none_toast", toast_has("list of catalogs will be shown"), toasts[#toasts])
            c.check("C.none_is_saved", settings_file_text():find("is_default", 1, true) == nil)

            local fetches = count_feed_fetches()
            p:onShowOPDSPlusCatalog()
            fetches.restore()
            b = p.opds_browser
            c.check("C.lists_the_catalogs", lists_catalogs(b))
            c.check("C.makes_no_request", fetches.n == 0, fetches.n)
            close_browser(p)
        end,
        -- D: the "Browse Catalogs" menu entry opens it too, but the hidden browser that sync creates must not
        function()
            target.is_default = true
            find_menu_entry(p, { "Browse Catalogs" }).callback()
            b = p.opds_browser
        end,
        function()
            c.check("D.menu_entry_opens_the_default", opened_target(b))
            close_browser(p)

            local fetches = count_feed_fetches()
            local hidden = p:_createBrowserInstance()
            fetches.restore()
            c.check("D.sync_browser_stays_idle", #hidden.paths == 0 and fetches.n == 0, fetches.n)
        end,
        -- E: with Wi-Fi off the list shows and the default opens once connected, like a tap on the catalog
        function()
            local offline = simulate_offline()
            local fetches = count_feed_fetches()
            p:onShowOPDSPlusCatalog()
            b = p.opds_browser
            c.check("E.waits_for_the_network", offline.callback ~= nil)
            c.check("E.no_request_while_offline", fetches.n == 0, fetches.n)
            c.check("E.list_of_catalogs_meanwhile", lists_catalogs(b))
            offline.restore()
            if offline.callback then offline.callback() end
            fetches.restore()
        end,
        function()
            c.check("E.opens_once_connected", opened_target(b))
            close_browser(p)
        end,
        function()
            local offline = simulate_offline()
            local fetches = count_feed_fetches()
            p:onShowOPDSPlusCatalog()
            b = p.opds_browser
            offline.restore()
            close_browser(p)
            if offline.callback then offline.callback() end
            fetches.restore()
            c.check("E.closed_browser_ignores_late_connection", fetches.n == 0
                and not b._catalog_job and not p.opds_browser)
            b:cancelCatalogLoad()
        end,
        -- F: editing the default catalog keeps it the default; deleting it leaves none and the list still works
        function()
            p:onShowOPDSPlusCatalog()
            b = p.opds_browser
        end,
        function()
            b:onBack()
            local item = root_item(b, "Mock Default Pick")
            c.check("F.root_item_found", item ~= nil)
            if item then b:editCatalogFromInput({ "Mock Default Renamed", target.url, "reader", "secret" }, item) end
            local renamed = current_default()
            c.check("F.edit_keeps_the_default", renamed ~= nil and renamed.title == "Mock Default Renamed",
                renamed and renamed.title)
            c.check("F.edit_replaced_the_entry", renamed ~= nil and renamed ~= target)
            c.check("F.edit_keeps_other_catalogs_plain", other.is_default == nil)

            item = root_item(b, "Mock Default Renamed")
            c.check("F.renamed_item_found", item ~= nil)
            if item then b:deleteCatalog(item) end
            c.check("F.delete_leaves_no_default", current_default() == nil)
            close_browser(p)

            local fetches = count_feed_fetches()
            p:onShowOPDSPlusCatalog()
            fetches.restore()
            b = p.opds_browser
            c.check("F.list_after_delete", lists_catalogs(b))
            c.check("F.no_request_after_delete", fetches.n == 0, fetches.n)
            close_browser(p)

            remove_server(p, other)
            clear_default()
            c.finish()
        end,
    }
end

-- Thumbnails on navigation entries (#24): an entry that only opens a sub-catalog shows its artwork ---------------

local function navcovers_steps()
    local StateManager = require("core.state_manager")
    local c = checker("navcovers")
    local THUMBS = 6
    local p, b, entry

    local function open_feed(name)
        close_browser(plugin())
        StateManager.getInstance():setDisplayMode("list")
        b = open_browser()
        b:onMenuSelect(find_item(b, "Mock Library"))
        return function() b:onMenuSelect(find_item(b, name)) end
    end

    -- Wait for every cover on the current page, then on each page after it.
    local function render_pages(done)
        local want_total, have_total = 0, 0
        local function load_page()
            wait_for(function()
                local want, have = visible_covers(b)
                return want > 0 and want == have
            end, 20, function()
                local want, have = visible_covers(b)
                want_total, have_total = want_total + want, have_total + have
                if b.page < b.page_num then
                    b:onNextPage()
                    load_page()
                else
                    done(want_total, have_total)
                end
            end)
        end
        load_page()
    end

    local open_nav
    return {
        function()
            current = "navcovers"
            p = plugin()
            remove_cache_files()
            server_stats(true)
            open_nav = open_feed("Navigation with thumbnails")
        end,
        function()
            open_nav()
        end,
        function(advance)
            local books, thumbs = count(b)
            c.check("default_is_on", p:getSetting("navigation_thumbnails") == true, p:getSetting("navigation_thumbnails"))
            c.check("list.entries_have_covers", thumbs == THUMBS and books == 0, thumbs .. " thumbs, " .. books .. " books")
            wait_for(function()
                local want, have = visible_covers(b)
                return want > 0 and want == have
            end, 20, advance)
            return "async"
        end,
        function(advance)
            shot("navcovers_list")
            c.check("list.starts_on_the_first_page", b.page == 1, b.page)
            render_pages(function(want, have)
                emit("navcovers.list.pages", b.page_num)
                c.check("list.renders_every_cover", want == THUMBS and have == want, have .. "/" .. want)
                c.check("list.is_the_cover_view", b._last_display_mode == "list", b._last_display_mode)
                local requests = server_stats(false).requests
                c.check("list.fetches_each_thumbnail_once", requests == THUMBS, requests)
                c.check("list.caches_each_thumbnail", count_cache_files(".img") == THUMBS, count_cache_files(".img"))
                advance()
            end)
            return "async"
        end,
        function()
            b:toggleViewMode()
        end,
        function(advance)
            close_window_with_text("Switched to")
            wait_for(function()
                local want, have = visible_covers(b)
                return want > 0 and want == have
            end, 20, advance)
            return "async"
        end,
        function(advance)
            shot("navcovers_grid")
            c.check("grid.is_the_cover_view", b._last_display_mode == "grid", b._last_display_mode)
            emit("navcovers.grid.pages", b.page_num)
            c.check("grid.starts_on_the_first_page", b.page == 1, b.page)
            render_pages(function(want, have)
                c.check("grid.renders_every_cover", want == THUMBS and have == want, have .. "/" .. want)
                advance()
            end)
            return "async"
        end,
        function()
            entry = find_menu_entry(p, { "Settings", "Cover Settings", "Thumbnails on Navigation Entries" })
            c.check("menu_entry_exists", entry ~= nil)
            assert(entry, "no Thumbnails on Navigation Entries entry in the settings menu")
            c.check("menu_entry_checked_by_default", entry.checked_func() == true, entry.checked_func())
            entry.callback()
            c.check("menu_toggle_stores_off", p:getSetting("navigation_thumbnails") == false,
                p:getSetting("navigation_thumbnails"))
            c.check("menu_entry_unchecks", entry.checked_func() == false, entry.checked_func())
            c.check("menu_toggle_says_disabled", window_has_text("Thumbnails on navigation entries disabled"))
            close_window_with_text("Thumbnails on navigation entries")
            server_stats(true)
            open_nav = open_feed("Navigation with thumbnails")
        end,
        function()
            open_nav()
        end,
        function()
            local books, thumbs = count(b)
            c.check("off.entries_are_listed", #b.item_table == THUMBS and books == 0, #b.item_table .. " entries")
            c.check("off.entries_have_no_cover_url", thumbs == 0, thumbs)
            c.check("off.is_the_plain_menu", b._last_mode_had_covers == false, tostring(b._last_mode_had_covers))
            c.check("off.requests_no_thumbnails", server_stats(false).requests == 0, server_stats(false).requests)
            open_nav = open_feed("Paged 250 (50 per page)")
        end,
        function()
            open_nav()
        end,
        function()
            local books, thumbs = count(b)
            c.check("off.book_covers_unaffected", books > 0 and thumbs == books, thumbs .. " covers, " .. books .. " books")
            entry.callback()
            c.check("menu_toggle_stores_on", p:getSetting("navigation_thumbnails") == true,
                p:getSetting("navigation_thumbnails"))
            c.check("menu_toggle_says_enabled", window_has_text("Thumbnails on navigation entries enabled"))
            close_window_with_text("Thumbnails on navigation entries")
            close_browser(p)
        end,
        function()
            remove_cache_files()
            c.finish()
        end,
    }
end

-- A cover bitmap belongs to the entry that holds it; the widgets that draw it only borrow it. ImageWidget frees what
-- it is given unless told otherwise, and Menu rebuilds its widgets on every page turn and every view switch.
local function coverown_steps()
    local StateManager = require("core.state_manager")
    local c = checker("coverown")
    local THUMBS = 6
    local p, b
    local held

    -- the solid colour the mock server paints cover n with
    local function painted(n)
        return (n * 37) % 256, (n * 91) % 256, (n * 53) % 256
    end

    -- How many entries hold a bitmap, how many of those were freed behind their back, and how many of the rest no
    -- longer show the colour the server sent. Pixels are only read from bitmaps that still own their memory.
    local function audit()
        local n_held, freed, faded = 0, 0, 0
        for _, item in ipairs(b.item_table) do
            local bb = item.cover_bb
            if bb then
                n_held = n_held + 1
                if bb:getAllocated() == 0 then
                    freed = freed + 1
                else
                    local r, g, bl = painted(tonumber(item.cover_url:match("/(%d+)%.png")))
                    local centre = bb:getPixel(math.floor(bb:getWidth() / 2), math.floor(bb:getHeight() / 2))
                    local px = centre:getColorRGB32()
                    if math.abs(px.r - r) > 2 or math.abs(px.g - g) > 2 or math.abs(px.b - bl) > 2 then
                        faded = faded + 1
                    end
                end
            end
        end
        return n_held, freed, faded
    end

    local function check_audit(label)
        local n_held, freed, faded = audit()
        emit("coverown." .. label .. ".held_freed_faded", n_held .. "/" .. freed .. "/" .. faded)
        c.check(label .. ".entries_keep_their_covers", n_held == THUMBS, n_held)
        c.check(label .. ".no_cover_was_freed", freed == 0, freed .. " of " .. n_held)
        c.check(label .. ".covers_keep_their_colour", faded == 0, faded .. " of " .. n_held)
    end

    -- Wait for every cover on the current page, then on each page after it.
    local function render_pages(done)
        local function load_page()
            wait_for(function()
                local want, have = visible_covers(b)
                return want > 0 and want == have
            end, 20, function()
                if b.page < b.page_num then
                    b:onNextPage()
                    load_page()
                else
                    done()
                end
            end)
        end
        load_page()
    end

    local function back_to_first_page()
        while b.page > 1 do b:onPrevPage() end
    end

    return {
        function()
            current = "coverown"
            p = plugin()
            remove_cache_files()
            close_browser(p)
            StateManager.getInstance():setDisplayMode("list")
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Library"))
        end,
        function()
            b:onMenuSelect(find_item(b, "Navigation with thumbnails"))
        end,
        function(advance)
            render_pages(advance)
            return "async"
        end,
        -- the covers were drawn once
        function()
            c.check("list.is_the_cover_view", b._last_display_mode == "list", b._last_display_mode)
            emit("coverown.list.pages", b.page_num)
            check_audit("list_first_visit")
        end,
        -- and are drawn again when the first page is rebuilt
        function()
            back_to_first_page()
        end,
        function()
            shot("coverown_list_revisited")
            check_audit("list_revisited")
            b:toggleViewMode()
        end,
        function(advance)
            close_window_with_text("Switched to")
            render_pages(advance)
            return "async"
        end,
        function()
            c.check("grid.is_the_cover_view", b._last_display_mode == "grid", b._last_display_mode)
            emit("coverown.grid.pages", b.page_num)
            shot("coverown_grid")
            check_audit("grid")
            b:toggleViewMode()
        end,
        function(advance)
            close_window_with_text("Switched to")
            render_pages(advance)
            return "async"
        end,
        function()
            back_to_first_page()
        end,
        function()
            shot("coverown_list_again")
            check_audit("list_again")
            held = {}
            for _, item in ipairs(b.item_table) do
                if item.cover_bb then held[#held + 1] = item.cover_bb end
            end
            close_browser(p)
        end,
        -- the entries own the bitmaps, so closing the browser is what releases them
        function()
            local leaked = 0
            for _, bb in ipairs(held) do
                if bb:getAllocated() == 1 then leaked = leaked + 1 end
            end
            c.check("close.frees_every_cover", #held == THUMBS and leaked == 0, leaked .. " of " .. #held .. " still allocated")
            remove_cache_files()
            c.finish()
        end,
    }
end

-- Taps the first button below `root` whose text contains `fragment`.
local function press_button(root, fragment)
    local seen = {}
    local function walk(widget)
        if type(widget) ~= "table" or seen[widget] then return false end
        seen[widget] = true
        if type(widget.text) == "string" and type(widget.callback) == "function"
            and widget.text:find(fragment, 1, true) then
            widget.callback()
            return true
        end
        for _, child in ipairs(widget) do
            if walk(child) then return true end
        end
        return false
    end
    return walk(root)
end

local function window_with_text(fragment)
    for _, entry in ipairs(UIManager._window_stack) do
        local text = type(entry.widget) == "table" and entry.widget.text
        if type(text) == "string" and text:find(fragment, 1, true) then return entry.widget end
    end
end

-- Path of the downloaded .epub in `dir` whose name contains `fragment`.
local function find_book(dir, fragment)
    for name in require("libs/libkoreader-lfs").dir(dir) do
        if name:sub(-5) == ".epub" and name:find(fragment, 1, true) then return dir .. "/" .. name end
    end
end

-- What KOReader keeps as custom metadata for a book: its file, the custom properties and the original ones.
local function custom_metadata(file)
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findCustomMetadataFile(file)
    if not metadata_file then return nil end
    local stored = DocSettings.openSettingsFile(metadata_file)
    return {
        file = metadata_file,
        custom = stored:readSetting("custom_props") or {},
        original = stored:readSetting("doc_props") or {},
    }
end

-- The description a catalog gives for a book is saved with the downloaded file as custom metadata (#85).
local function descsave_steps()
    local DocSettings = require("docsettings")
    local DocumentRegistry = require("document/documentregistry")
    local DownloadManager = require("core.download_manager")
    local lfs = require("libs/libkoreader-lfs")
    local fm = require("apps/filemanager/filemanager").instance
    local c = checker("descsave")
    local TITLE, AUTHOR = "Real Book Title", "Real Author"
    local p, b, server, sync_server, dir, sync_dir, previous_dir, file_a

    local function count_keys(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    local function single_format() return press_button(b.book_info_dialog, "Download (EPUB)") end
    local function choose_format()
        return press_button(b.book_info_dialog, "Download…") and press_button(b.format_dialog, "EPUB")
    end
    local function overwrite()
        return single_format() and press_button(window_with_text("already exists"), "Overwrite")
    end

    -- Opens the dialog of the book called `title`, taps through `how`, waits until KOReader offers to read the
    -- downloaded book, then runs check(path).
    local function download(label, title, how, check)
        return function(advance)
            reset_toasts()
            b:onMenuSelect(find_item(b, title))
            c.check(label .. ".download_pressed", how() == true)
            wait_for(function() return window_has_text("File saved to") end, 20, function(saved)
                c.check(label .. ".download_finishes", saved)
                close_window_with_text("File saved to")
                p.last_downloaded_file = nil
                local file = find_book(dir, title)
                c.check(label .. ".file_downloaded", file ~= nil)
                if file then
                    local ok, err = pcall(check, file)
                    if not ok then c.check(label .. ".checks_run", false, err) end
                end
                advance()
            end)
            return "async"
        end
    end

    return {
        function()
            current = "descsave"
            p = plugin()
            close_browser(p)
            dir = fresh_dir()
            previous_dir = G_reader_settings:readSetting("download_dir")
            G_reader_settings:saveSetting("download_dir", dir)
            server = add_server(p, "Mock Descriptions", "/opds/desc")

            local entry = find_menu_entry(p, { "Settings", "Save Description with Downloads" })
            c.check("setting.has_a_menu_entry", entry ~= nil)
            c.check("setting.default_is_on", p:getSetting("save_book_description") == true,
                p:getSetting("save_book_description"))
            if entry then
                c.check("setting.checkbox_is_checked", entry.checked_func() == true)
                reset_toasts()
                entry.callback()
                c.check("setting.toggles_off", p:getSetting("save_book_description") == false
                    and entry.checked_func() == false)
                c.check("setting.says_so_when_off", toast_has("no longer be saved"), toasts[#toasts])
                reset_toasts()
                entry.callback()
                c.check("setting.toggles_on", p:getSetting("save_book_description") == true
                    and entry.checked_func() == true)
                c.check("setting.says_so_when_on", toast_has("will be saved"), toasts[#toasts])
                close_window_with_text("Descriptions will")
            end
        end,
        function()
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Descriptions"))
        end,
        function()
            local books = count(b)
            c.check("feed.lists_the_books", books == 5, books)
            local item = assert(find_item(b, "Desc Book A"))
            item.series, item.series_index = "Description Series", "2"
            item.content = "SERIES: Description Series [2]<br />" .. item.content
        end,
        -- A: html description, the book has none of its own: it is saved as plain text next to the real properties
        download("A", "Desc Book A", single_format, function(file)
            local meta = custom_metadata(file)
            c.check("A.saves_custom_metadata", meta ~= nil)
            if not meta then return end
            local text = meta.custom.description or ""
            emit("descsave.A.saved_text", text)
            c.check("A.description_is_plain_text", text:find("bold", 1, true) and text:find("Second paragraph.", 1, true)
                and not text:find("[<>&]"), text)
            c.check("A.description_has_no_duplicate_series", not text:find("SERIES:", 1, true))
            c.check("A.only_the_description_is_custom", count_keys(meta.custom) == 1, count_keys(meta.custom))
            c.check("A.original_title_kept", meta.original.title == TITLE, meta.original.title)
            c.check("A.original_authors_kept", meta.original.authors == AUTHOR, meta.original.authors)
            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            c.check("A.bookinfo_reads_it", BookInfo.getCustomProp("description", file) == text)
            local shown = fm.bookinfo:getDocProps(file)
            c.check("A.book_information_shows_it", shown.description == text and shown.title == TITLE
                and shown.authors == AUTHOR, tostring(shown.description) .. " / " .. tostring(shown.title))
            file_a = file
        end),
        -- what the reader sees: the Book information page lists the description (marked as customized)
        function()
            if file_a then fm.bookinfo:show(file_a) end
        end,
        function()
            local kvp = fm.bookinfo.kvp_widget
            local row
            for _, pair in ipairs(kvp and kvp.kv_pairs or {}) do
                if type(pair[1]) == "string" and pair[1]:find("Description", 1, true) then row = pair end
            end
            c.check("A.book_information_page_lists_it", row ~= nil and tostring(row[2]):find("Second paragraph.", 1, true)
                ~= nil, row and tostring(row[2]))
            c.check("A.book_information_page_marks_it_customized", row ~= nil and row[1]:find("\u{F040}", 1, true) ~= nil,
                row and row[1])
            close_window_with_text("Documents will be rendered")
            if kvp then kvp:nextPage() end
        end,
        function()
            shot("descsave_book_information")
            local kvp = fm.bookinfo.kvp_widget
            if kvp then UIManager:close(kvp) end
        end,
        -- B: the book already carries a description, so nothing is customized
        download("B", "Desc Book B", single_format, function(file)
            local document = DocumentRegistry:openDocument(file)
            local props = document and document:loadDocument(false) and document:getProps()
            if document then document:close() end
            c.check("B.book_has_a_description_of_its_own", props and (props.description or ""):find("Embedded", 1, true),
                props and props.description)
            c.check("B.own_description_is_kept", custom_metadata(file) == nil)
        end),
        -- A again: whatever is already stored for the book, such as an edit made in KOReader, is never replaced
        function()
            local meta = file_a and custom_metadata(file_a)
            if not meta then
                c.check("A2.edit_saved", false, "A saved no metadata to edit")
                return
            end
            local stored = DocSettings.openSettingsFile(meta.file)
            stored:saveSetting("custom_props", { description = "Edited by the reader." })
            c.check("A2.edit_saved", stored:flushCustomMetadata(file_a) == true)
        end,
        download("A2", "Desc Book A", overwrite, function(file)
            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            local text = BookInfo.getCustomProp("description", file)
            c.check("A2.keeps_the_edit", text == "Edited by the reader.", text)
        end),
        -- C: two formats, so the format dialog is used; with the setting off nothing is saved, with it on it is
        function()
            p:saveSetting("save_book_description", false)
        end,
        download("C.off", "Desc Book C", choose_format, function(file)
            c.check("C.off.saves_nothing", custom_metadata(file) == nil)
            os.remove(file)
        end),
        function()
            p:saveSetting("save_book_description", true)
        end,
        download("C.on", "Desc Book C", choose_format, function(file)
            local meta = custom_metadata(file)
            c.check("C.on.saves_the_description", meta and meta.custom.description == "Catalog text for C.",
                meta and meta.custom.description)
            c.check("C.on.original_title_kept", meta and meta.original.title == TITLE, meta and meta.original.title)
        end),
        -- E: not a real book (bytes that are no zip), which must not get in the way of the download
        download("E", "Desc Book E", single_format, function(file)
            c.check("E.keeps_the_file", (lfs.attributes(file, "size") or 0) > 0)
            c.check("E.reports_no_error", not toast_has("Could not save"), toasts[#toasts])
            local meta = custom_metadata(file)
            emit("descsave.E.metadata", meta
                and (tostring(meta.original.title) .. " / " .. tostring(meta.custom.description)) or "none")
        end),
        -- Files KOReader can't open at all: nothing is saved and nothing is thrown
        function()
            local fixtures = {
                missing = dir .. "/missing.epub",
                garbage_pdf = dir .. "/garbage.pdf",
            }
            local file = assert(io.open(fixtures.garbage_pdf, "w"))
            file:write("%PDF-1.4\nthis is not a pdf\n")
            file:close()
            for name, path in pairs(fixtures) do
                local ok, saved = pcall(DownloadManager.saveDescription, path, "Some description.")
                c.check("unreadable." .. name .. ".does_not_throw", ok, saved)
                c.check("unreadable." .. name .. ".saves_nothing", saved == false and custom_metadata(path) == nil, saved)
            end
            -- Nothing to save for a blank description
            local ok, saved = pcall(DownloadManager.saveDescription, file_a, "  \n ")
            c.check("unreadable.blank_text_is_ignored", ok and saved == false, saved)
        end,
        -- D: queued, then downloaded in a subprocess through the Downloads list
        function(advance)
            reset_toasts()
            local queued = #b.downloads
            b:onMenuSelect(find_item(b, "Desc Book D"))
            c.check("queue.queue_pressed", press_button(b.book_info_dialog, "Queue") == true)
            local record = b.downloads[#b.downloads]
            c.check("queue.adds_one_record", #b.downloads == queued + 1, #b.downloads)
            c.check("queue.record_has_the_description", record and record.info == "Catalog text for D.",
                record and record.info)
            close_browser(p)
            b = open_browser()
            b:onMenuSelect(find_item(b, "Downloads"))
            c.check("queue.list_opens", b.download_list ~= nil)
            b:confirmDownloadDownloadList()
            c.check("queue.download_all_pressed", press_button(window_with_text("Download all books"), "Download") == true)
            wait_for(function() return #b.downloads == queued end, 30, function(done)
                c.check("queue.downloads_the_book", done, #b.downloads)
                c.check("queue.reports_it", toast_has("1 book downloaded"), toasts[#toasts])
                close_window_with_text("downloaded")
                if b.download_list then b.download_list.close_callback() end
                local file = find_book(dir, "Desc Book D")
                c.check("queue.file_downloaded", file ~= nil)
                local meta = file and custom_metadata(file)
                c.check("queue.saves_the_description", meta and meta.custom.description == "Catalog text for D.",
                    meta and meta.custom.description)
                c.check("queue.original_title_kept", meta and meta.original.title == TITLE,
                    meta and meta.original.title)
                advance()
            end)
            return "async"
        end,
        -- Sync: one entry with a description and one without, downloaded in a subprocess as well
        function(advance)
            close_browser(p)
            sync_dir = fresh_dir()
            p.settings.sync_dir = sync_dir
            sync_server = add_server(p, "Mock Description Sync", "/opds/desc_sync", true)
            reset_toasts()
            local original = DownloadManager.downloadPendingSyncs
            local queued = {}
            ---@diagnostic disable-next-line: duplicate-set-field
            DownloadManager.downloadPendingSyncs = function(browser, list)
                for _, record in ipairs(list) do queued[#queued + 1] = { file = record.file, info = record.info } end
                return original(browser, list)
            end
            local function queued_info(fragment)
                for _, record in ipairs(queued) do
                    if record.file:find(fragment, 1, true) then return record.info end
                end
            end
            p:onStartOPDSSyncAllCatalogs()
            wait_for(function()
                return count_files(sync_dir, ".epub") >= 2 and toast_has("2 books downloaded")
            end, 40, function(done)
                DownloadManager.downloadPendingSyncs = original
                c.check("sync.downloads_the_books", done, count_files(sync_dir, ".epub") .. " files")
                c.check("sync.queues_the_description", queued_info("Desc Sync E") == "Catalog text for sync E.",
                    queued_info("Desc Sync E"))
                c.check("sync.queues_nothing_for_a_bare_entry", queued_info("Desc Sync F") == "",
                    queued_info("Desc Sync F"))
                close_window_with_text("books downloaded")
                local with_text, without_text = find_book(sync_dir, "Desc Sync E"), find_book(sync_dir, "Desc Sync F")
                local meta = with_text and custom_metadata(with_text)
                c.check("sync.saves_the_description", meta and meta.custom.description == "Catalog text for sync E.",
                    meta and meta.custom.description)
                c.check("sync.original_title_kept", meta and meta.original.title == TITLE,
                    meta and meta.original.title)
                c.check("sync.bare_entry_saves_nothing", without_text ~= nil and custom_metadata(without_text) == nil)
                advance()
            end)
            return "async"
        end,
        function()
            close_browser(p)
            remove_server(p, server)
            remove_server(p, sync_server)
            p.settings.sync_dir = nil
            p.last_downloaded_file = nil
            p:saveSetting("save_book_description", true)
            if previous_dir then
                G_reader_settings:saveSetting("download_dir", previous_dir)
            else
                G_reader_settings:delSetting("download_dir")
            end
            remove_temp_dir(dir); remove_temp_dir(sync_dir)
            c.finish()
        end,
    }
end

-- Every text shown by a widget and by the children it holds in its array part.
local function texts_below(root)
    local found, seen = {}, {}
    local function walk(widget)
        if type(widget) ~= "table" or seen[widget] then return end
        seen[widget] = true
        if type(widget.text) == "string" then found[#found + 1] = widget.text end
        for _, child in ipairs(widget) do walk(child) end
    end
    walk(root)
    return found
end

local function shows_text(root, fragment)
    for _, text in ipairs(texts_below(root)) do
        if text:find(fragment, 1, true) then return true end
    end
    return false
end

-- Series and every author of a book (#70): what Calibre-Web, Calibre-Web-Automated and Grimmory send for them
-- comes out as a series line in the list, in the book information dialog and in the name of the downloaded file.
local function series_steps()
    local StateManager = require("core.state_manager")
    local InfoMessage = require("ui/widget/infomessage")
    local c = checker("series")
    local GLYPH = "\u{2756}"
    local p, b, dir, previous_dir, previous_save

    -- What the plugin should read from each entry of the mock feed, found by the number of its download link.
    local BOOKS = {
        { dl = 931, label = "calibre_web", author = "Robert Louis Stevenson, Lloyd Osbourne", series = "The Saga",
          index = "3" },
        { dl = 932, label = "calibre_web_series_only_in_the_description", author = "Robert Louis Stevenson" },
        { dl = 933, label = "calibre_web_automated", author = "Frank Herbert", series = "Dune Chronicles",
          index = "2" },
        { dl = 934, label = "grimmory_first", author = "Matt Dinniman", series = "Series One", index = "20" },
        { dl = 935, label = "grimmory_second", author = "Matt Dinniman", series = "Series Two", index = "3.5" },
        { dl = 936, label = "grimmory_without_position", author = "Matt Dinniman", series = "Series Three" },
        { dl = 937, label = "gutenberg_single_author", author = "Homerus" },
        { dl = 938, label = "bare_entry" },
        { dl = 939, label = "escaped_names", author = "Simon & Schuster", series = "Tom & Jerry", index = "2.5" },
    }

    local function find_by_download(number)
        local suffix = "/dl/" .. number .. ".epub"
        for _, item in ipairs(b.item_table) do
            for _, acquisition in ipairs(item.acquisitions or {}) do
                if acquisition.href and acquisition.href:find(suffix, 1, true) then return item end
            end
        end
    end

    local function open_dialog(number)
        b:onMenuSelect(find_by_download(number))
        return b.book_info_dialog
    end

    local function close_dialog()
        if b.book_info_dialog then UIManager:close(b.book_info_dialog) end
    end

    -- Waits for the covers of each page in turn and hands the texts on screen to collect(), then calls done().
    local function visit_pages(collect, done)
        local function visit()
            wait_for(function()
                local want, have = visible_covers(b)
                return want == have
            end, 20, function()
                collect(texts_below(b))
                if b.page < b.page_num then
                    b:onNextPage()
                    visit()
                else
                    done()
                end
            end)
        end
        visit()
    end

    local screen_texts = {}
    local function on_screen(fragment)
        for _, text in ipairs(screen_texts) do
            if text:find(fragment, 1, true) then return true end
        end
        return false
    end
    local function collect(texts)
        for _, text in ipairs(texts) do screen_texts[#screen_texts + 1] = text end
    end

    return {
        function()
            current = "series"
            p = plugin()
            close_window_with_text("Documents will be rendered")
            -- earlier scenarios leave their messages on screen, and they would cover the screenshots
            for i = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[i].widget
                if type(widget) == "table" and widget.modal and type(widget.text) == "string" then
                    UIManager:close(widget)
                end
            end
            close_browser(p)
            StateManager.getInstance():setDisplayMode("list")
            dir = fresh_dir()
            previous_dir = G_reader_settings:readSetting("download_dir")
            G_reader_settings:saveSetting("download_dir", dir)
            previous_save = p:getSetting("save_book_description")
            p:saveSetting("save_book_description", false)
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Library"))
        end,
        function()
            b:onMenuSelect(find_item(b, "Series and authors"))
        end,
        function()
            c.check("feed.lists_every_book", #b.item_table == #BOOKS, #b.item_table)
            for _, book in ipairs(BOOKS) do
                local item = find_by_download(book.dl)
                c.check(book.label .. ".is_listed", item ~= nil)
                if item then
                    c.check(book.label .. ".author", item.author == book.author, item.author)
                    c.check(book.label .. ".series", item.series == book.series, item.series)
                    c.check(book.label .. ".index", item.series_index == book.index, item.series_index)
                end
            end
            local item = find_by_download(931)
            c.check("calibre_web.text_has_every_author", item and item.text == "The Wrong Box - Robert Louis Stevenson, "
                .. "Lloyd Osbourne", item and item.text)
            local bare = find_by_download(938)
            c.check("bare_entry.text_is_the_title", bare and bare.text == "Bare Book", bare and bare.text)
        end,
        -- the list view, page by page
        function(advance)
            screen_texts = {}
            visit_pages(collect, advance)
            return "async"
        end,
        function()
            shot("series_list_last_page")
            emit("series.list.pages", b.page_num)
            c.check("list.is_the_cover_view", b._last_display_mode == "list", b._last_display_mode)
            local expected = {
                { "every_author", "Robert Louis Stevenson, Lloyd Osbourne" },
                { "series_with_position", GLYPH .. " The Saga #3" },
                { "series_from_series_index", GLYPH .. " Dune Chronicles #2" },
                { "first_grimmory_series", GLYPH .. " Series One #20" },
                { "second_grimmory_series", GLYPH .. " Series Two #3.5" },
                { "series_without_position", GLYPH .. " Series Three" },
                { "escaped_series_name", GLYPH .. " Tom & Jerry #2.5" },
            }
            for _, row in ipairs(expected) do
                c.check("list.shows_" .. row[1], on_screen(row[2]), row[2])
            end
            c.check("list.series_without_position_has_no_hash", not on_screen("Series Three #"))
            c.check("list.ignores_series_further_down", not on_screen("Not Here") and not on_screen("Neither Here"))
            local series_lines = 0
            for _, text in ipairs(screen_texts) do
                if text:find(GLYPH, 1, true) then series_lines = series_lines + 1 end
            end
            c.check("list.has_one_series_line_per_series", series_lines == 6, series_lines)
        end,
        function()
            b:onGotoPage(1)
        end,
        function(advance)
            wait_for(function()
                local want, have = visible_covers(b)
                return want == have
            end, 20, advance)
            return "async"
        end,
        function()
            shot("series_list")
        end,
        -- the book information dialog
        function()
            local dialog = open_dialog(931)
            c.check("dialog.opens", dialog ~= nil)
            c.check("dialog.lists_every_author", dialog and shows_text(dialog, "Robert Louis Stevenson, Lloyd Osbourne"))
            c.check("dialog.has_a_series_row", dialog and shows_text(dialog, "Series:") and shows_text(dialog, "The Saga #3"))
            c.check("dialog.description_has_no_duplicate_series", dialog and not shows_text(dialog, "SERIES:"))
            c.check("dialog.keeps_other_fields_and_prose", dialog and shows_text(dialog, "RATING:")
                and shows_text(dialog, "TAGS: Fantasy, Adventure") and shows_text(dialog, "A tale of boxes."))
        end,
        function()
            shot("series_dialog")
            close_dialog()
        end,
        function()
            local item = find_by_download(931)
            b:showDownloads(item)
            c.check("download_dialog.opens_information", press_button(b.download_dialog, "Book information"))
            local viewer = UIManager:getTopmostVisibleWidget()
            c.check("download_dialog.uses_the_same_description", viewer
                and shows_text(viewer, "A tale of boxes.") and not shows_text(viewer, "SERIES:"))
            UIManager:close(viewer)
            UIManager:close(b.download_dialog)
            b.download_dialog = nil
        end,
        function()
            local dialog = open_dialog(933)
            c.check("dialog.separate_metadata_also_deduplicates", dialog and shows_text(dialog, "Dune Chronicles #2")
                and shows_text(dialog, "Spice.") and not shows_text(dialog, "SERIES:"))
            close_dialog()
            dialog = open_dialog(932)
            c.check("dialog.keeps_series_mentions_in_prose", dialog and shows_text(dialog, "SERIES: Not Here")
                and shows_text(dialog, "SERIES: Neither Here"))
            close_dialog()
            dialog = open_dialog(939)
            c.check("dialog.metadata_only_has_no_description", dialog and shows_text(dialog, "Tom & Jerry #2.5")
                and shows_text(dialog, "No description available.") and not shows_text(dialog, "SERIES:"))
            close_dialog()
        end,
        -- two books with one title are told apart by their series
        function()
            local dialog = open_dialog(934)
            c.check("same_title.first_shows_its_series", dialog and shows_text(dialog, "Series One #20")
                and not shows_text(dialog, "Series Two"))
            close_dialog()
        end,
        function()
            local dialog = open_dialog(935)
            c.check("same_title.second_shows_its_series", dialog and shows_text(dialog, "Series Two #3.5")
                and not shows_text(dialog, "Series One"))
            close_dialog()
        end,
        function()
            local dialog = open_dialog(936)
            c.check("dialog.series_without_position", dialog and shows_text(dialog, "Series Three")
                and not shows_text(dialog, "Series Three #"))
            close_dialog()
        end,
        function()
            local dialog = open_dialog(937)
            c.check("dialog.no_series_row_without_a_series", dialog and shows_text(dialog, "Author:")
                and shows_text(dialog, "Homerus") and not shows_text(dialog, "Series:"))
            close_dialog()
        end,
        -- the grid view still works
        function()
            b:toggleViewMode()
        end,
        function(advance)
            close_window_with_text("Switched to")
            wait_for(function()
                local want, have = visible_covers(b)
                return want == have
            end, 20, advance)
            return "async"
        end,
        function(advance)
            shot("series_grid")
            screen_texts = {}
            visit_pages(collect, advance)
            return "async"
        end,
        function()
            c.check("grid.is_the_cover_view", b._last_display_mode == "grid", b._last_display_mode)
            c.check("grid.shows_the_books", on_screen("The Wrong Box") and on_screen("Dune") and on_screen("Bare Book"))
            b:toggleViewMode()
        end,
        -- the file of a book with several authors is named after all of them
        function()
            close_window_with_text("Switched to")
            local item = find_by_download(931)
            c.check("filename.names_every_author", b:getFileName(item) == "Robert Louis Stevenson, Lloyd Osbourne - "
                .. "The Wrong Box", b:getFileName(item))
            reset_toasts()
            open_dialog(931)
            c.check("filename.download_pressed", press_button(b.book_info_dialog, "Download (EPUB)") == true)
        end,
        function(advance)
            wait_for(function() return window_has_text("File saved to") end, 20, function(saved)
                c.check("filename.download_finishes", saved)
                close_window_with_text("File saved to")
                p.last_downloaded_file = nil
                local file = find_book(dir, "The Wrong Box")
                local name = file and file:match("[^/]+$")
                emit("series.filename.saved_as", name or "nil")
                c.check("filename.file_is_named_after_every_author",
                    name == "Robert Louis Stevenson, Lloyd Osbourne - The Wrong Box.epub", name)
                advance()
            end)
            return "async"
        end,
        -- how the series glyph and the book emoji it replaces come out in KOReader's own fonts
        function()
            UIManager:show(InfoMessage:new { text = "series glyph " .. GLYPH .. "   book emoji \u{1F4DA}" })
        end,
        function()
            shot("series_glyphs")
            close_window_with_text("series glyph")
            close_browser(p)
            remove_cache_files()
            p:saveSetting("save_book_description", previous_save ~= false)
            if previous_dir then
                G_reader_settings:saveSetting("download_dir", previous_dir)
            else
                G_reader_settings:delSetting("download_dir")
            end
            remove_temp_dir(dir)
            c.finish()
        end,
    }
end

-- Custom HTTP headers (#94): "Mock Cloudflare" only answers requests that carry its service token headers.
-- They are entered through the real catalog dialogs, then every kind of request has to carry them.
local function customheaders_steps()
    local c = checker("customheaders")
    local ID_LINE, SECRET_LINE = "CF-Access-Client-Id: test-id", "CF-Access-Client-Secret: test-secret"
    local NOTE_VALUE = [[say "hi" \ and 'bye']]
    local ALL = ID_LINE .. "\n" .. SECRET_LINE .. "\nX-Test-Note: " .. NOTE_VALUE
    local OTHER = BASE:gsub("127%.0%.0%.1", "localhost")
    local RequestHeaders, HttpClient, LuaSettings
    local p, b, edit, editor, dir, sync_dir, previous_dir, previous_sync_dir, previous_vk, first_fork, servers_before

    local function server_named(title)
        for _, server in ipairs(p.servers) do
            if server.title == title then return server end
        end
    end

    -- Menu sets item.idx only for the items it displays, and editing a catalog goes by it.
    local function root_item(browser, title)
        for i, item in ipairs(browser.item_table) do
            if item.text == title then
                item.idx = i
                return item
            end
        end
    end

    local function window_titled(title)
        for i = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[i].widget
            if type(widget) == "table" and widget.title == title then return widget end
        end
    end

    local function tap(root, text)
        return root ~= nil and press_button(root, text) == true
    end

    local function header_button(dialog)
        return dialog and dialog.button_table:getButtonById("headers")
    end

    local function same_headers(first, second)
        if type(first) ~= "table" or type(second) ~= "table" or #first ~= #second then return false end
        for i, header in ipairs(first) do
            if header.name ~= second[i].name or header.value ~= second[i].value then return false end
        end
        return true
    end

    local function saved_on_disk(title)
        p:onFlushSettings()
        local stored = LuaSettings:open(p.opds_settings_file):readSetting("servers") or {}
        for _, server in ipairs(stored) do
            if server.title == title then return server end
        end
    end

    local function covers_loaded(browser)
        local want, have = visible_covers(browser)
        return want > 0 and want == have
    end

    local function open_edit_dialog(title)
        b:addEditCatalog(root_item(b, title))
        return window_titled("Edit OPDS catalog")
    end

    local function listing_text()
        local lines = {}
        for _, item in ipairs(b.item_table) do lines[#lines + 1] = (item.text or ""):lower() end
        return table.concat(lines, "\n")
    end

    -- A refused feed shows two popups, the sync reports its result, and KOReader's start-up notice may still be up;
    -- they would cover the screenshots.
    local function dismiss_popups()
        for _, fragment in ipairs({ "Failed to authenticate", "Cannot get catalog info", "Documents will be rendered",
                "books downloaded" }) do
            close_window_with_text(fragment)
        end
    end

    -- What the helper decides, inside real KOReader.
    local function rules()
        local list = RequestHeaders.parse(ID_LINE .. "\r\n\r\nCF-Access-Client-Secret:   test-secret  \n")
        c.check("rules.read_one_header_per_line", list ~= nil and #list == 2 and list[1].name == "CF-Access-Client-Id"
            and list[1].value == "test-id" and list[2].name == "CF-Access-Client-Secret"
            and list[2].value == "test-secret")
        c.check("rules.format_gives_the_text_back", RequestHeaders.format(list) == ID_LINE .. "\n" .. SECRET_LINE)
        local function refused(text, line, reason)
            local result, at, why = RequestHeaders.parse(text)
            return result == nil and at == line and why == reason
        end
        c.check("rules.refuses_a_line_without_colon", refused("X-One: 1\nno colon here", 2, "format"))
        c.check("rules.refuses_a_bad_name", refused("Bad Name: 1", 1, "name"))
        c.check("rules.refuses_framing_headers", refused("Host: elsewhere", 1, "reserved")
            and refused("content-length: 5", 1, "reserved") and refused("Transfer-Encoding: chunked", 1, "reserved"))
        c.check("rules.refuses_accept_encoding", refused("accept-encoding: gzip", 1, "reserved"))
        c.check("rules.refuses_an_empty_value", refused("X-One:   ", 1, "value"))
        c.check("rules.refuses_control_characters", refused("X-One: a\001b", 1, "value")
            and refused("X-One: a\127b", 1, "value") and RequestHeaders.parse("X-One: a\tb") ~= nil)
        c.check("rules.refuses_duplicates_in_any_case", refused("X-One: 1\nx-one: 2", 2, "duplicate"))
        c.check("rules.allows_authorization_and_cookie",
            RequestHeaders.parse("Authorization: Bearer abc\nCookie: a=b; c=d\nUser-Agent: mine") ~= nil)

        local servers = {
            { url = "http://Example.com/opds", headers = { { name = "X-One", value = "1" } } },
            { url = "https://other.org:8443/x" },
        }
        c.check("scope.same_origin_gets_them", RequestHeaders.forUrl(servers, "http://example.com:80/other/path")
            == servers[1].headers)
        c.check("scope.credentials_in_the_url_are_ignored", RequestHeaders.forUrl(servers, "http://user:pw@example.com/")
            == servers[1].headers and RequestHeaders.forUrl(servers, "http://example.com@evil.net/") == nil)
        c.check("scope.other_host_gets_none", RequestHeaders.forUrl(servers, "http://sub.example.com/") == nil)
        c.check("scope.other_scheme_gets_none", RequestHeaders.forUrl(servers, "https://example.com/") == nil)
        c.check("scope.other_port_gets_none", RequestHeaders.forUrl(servers, "http://example.com:8080/") == nil)
        c.check("scope.catalog_without_headers_gives_none", RequestHeaders.forUrl(servers, "https://other.org:8443/x")
            == nil)
        c.check("scope.not_http_gets_none", RequestHeaders.forUrl(servers, "ftp://example.com/") == nil)

        -- Catalogs on one server share the headers of the first one that has any
        local shared = {
            { url = "http://example.com/plain" },
            { url = "http://example.com/a", headers = { { name = "X-One", value = "1" } } },
            { url = "http://example.com/b", headers = { { name = "X-Two", value = "2" } } },
        }
        c.check("scope.first_catalog_with_headers_decides", RequestHeaders.forUrl(shared, "http://example.com/b")
            == shared[2].headers and RequestHeaders.forUrl(shared, "http://example.com/plain") == shared[2].headers)

        local applied = RequestHeaders.apply({ ["accept-encoding"] = "identity", ["X-Mine"] = "plugin" }, {
            { name = "Accept-Encoding", value = "gzip" }, { name = "x-mine", value = "custom" },
            { name = "X-Extra", value = "1" }, { name = "Bad Name", value = "x" },
        })
        c.check("rules.plugin_headers_win_in_any_case", applied["accept-encoding"] == "identity"
            and applied["X-Mine"] == "plugin" and applied["Accept-Encoding"] == nil and applied["x-mine"] == nil)
        c.check("rules.adds_the_rest_and_skips_invalid", applied["X-Extra"] == "1" and applied["Bad Name"] == nil)
        c.check("rules.nothing_to_add_keeps_nil", RequestHeaders.apply(nil, nil) == nil
            and RequestHeaders.apply(nil, {}) == nil)
    end

    return {
        function()
            current = "customheaders"
            p = plugin()
            close_browser(p)
            local ok
            ok, RequestHeaders = pcall(require, "utils.request_headers")
            c.check("setup.helper_module_exists", ok, RequestHeaders)
            HttpClient = require("services.http_client")
            LuaSettings = require("luasettings")
            local cf = server_named("Mock Cloudflare")
            c.check("setup.cloudflare_catalog_has_no_headers", cf ~= nil and cf.url == BASE .. "/cf/feed"
                and cf.headers == nil)
            c.check("setup.other_origin_is_another_host_name", OTHER ~= BASE, OTHER)
            dir, sync_dir = fresh_dir(), fresh_dir()
            previous_dir = G_reader_settings:readSetting("download_dir")
            previous_sync_dir = p.settings.sync_dir
            G_reader_settings:saveSetting("download_dir", dir)
            -- The emulator has a hardware keyboard, so KOReader hides its on-screen one; touch e-readers show it.
            previous_vk = G_reader_settings:readSetting("virtual_keyboard_enabled")
            G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
            dismiss_popups()
            if ok then rules() end
        end,
        -- Without headers the catalog refuses everything, which is the starting point of the issue.
        function()
            reset_toasts()
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Cloudflare"))
        end,
        function()
            c.check("without.feed_is_refused", toast_has("Failed to authenticate"), toasts[#toasts])
            c.check("without.stays_on_the_catalog_list", #b.paths == 0 and b.item_table[1].text == "Downloads")
            dismiss_popups()
            local ok, err = HttpClient.getUrlContent(BASE .. "/cf/cover/1.png")
            c.check("without.cover_is_refused", ok == false, err)
            ok, err = HttpClient.getUrlContent(BASE .. "/cf/dl/1.epub")
            c.check("without.download_is_refused", ok == false, err)
        end,
        -- The catalog dialog: a button next to Cancel and Save opens the headers editor.
        function()
            edit = open_edit_dialog("Mock Cloudflare")
            c.check("dialog.edit_dialog_opens", edit ~= nil)
            local button = header_button(edit)
            c.check("dialog.has_a_headers_button", button ~= nil)
            c.check("dialog.button_has_no_count_yet", button ~= nil and button.text == "Headers",
                button and button.text)
            c.check("dialog.button_shares_the_row_with_cancel_and_save", edit ~= nil and #edit.buttons == 1
                and #edit.buttons[1] == 3)
        end,
        function()
            shot("customheaders_edit_dialog")
            c.check("dialog.button_opens_the_editor", tap(edit, "Headers")
                and window_titled("Custom HTTP headers") ~= nil)
        end,
        function()
            editor = window_titled("Custom HTTP headers")
            shot("customheaders_editor_empty")
            c.check("editor.starts_empty", editor ~= nil and editor:getInputText() == "", editor and editor:getInputText())
            reset_toasts()
            editor:setInputText(ID_LINE .. "\nHost: elsewhere")
            tap(editor, "OK")
            c.check("editor.names_the_refused_line", toast_has("Line 2: Host cannot be set here"), toasts[#toasts])
            c.check("editor.stays_open_to_fix_it", window_titled("Custom HTTP headers") == editor)
            c.check("editor.changes_nothing_when_refused", header_button(edit).text == "Headers")
        end,
        function()
            shot("customheaders_editor_error")
            close_window_with_text("Line 2")
            reset_toasts()
            editor:setInputText("no colon here")
            tap(editor, "OK")
            c.check("editor.explains_the_format", toast_has("Line 1: write the header as Name: value"), toasts[#toasts])
            close_window_with_text("Line 1")
            editor:setInputText(ALL .. "\n")
            c.check("editor.ok_is_pressed", tap(editor, "OK"))
        end,
        function()
            c.check("editor.closes_after_ok", window_titled("Custom HTTP headers") == nil)
            local button = header_button(edit)
            c.check("dialog.button_shows_the_count", button.text == "Headers (3)", button.text)
            local cf = server_named("Mock Cloudflare")
            c.check("dialog.keeps_nothing_before_save", cf.headers == nil)
            shot("customheaders_edit_dialog_count")
        end,
        -- Cancel leaves the catalog as it was, even after the editor was used.
        function()
            -- KOReader rebuilds the whole dialog from its configuration when the keyboard layout changes
            edit:onKeyboardHeightChanged()
            c.check("dialog.rebuild_keeps_the_count", header_button(edit) ~= nil and header_button(edit).text
                == "Headers (3)", header_button(edit) and header_button(edit).text)
            c.check("dialog.rebuild_keeps_the_typed_fields", edit:getFields()[1] == "Mock Cloudflare"
                and edit:getFields()[2] == BASE .. "/cf/feed")
            c.check("dialog.cancel_closes_it", tap(edit, "Cancel") and window_titled("Edit OPDS catalog") == nil)
            c.check("dialog.cancel_keeps_the_catalog", server_named("Mock Cloudflare").headers == nil)
        end,
        function()
            edit = open_edit_dialog("Mock Cloudflare")
            c.check("dialog.reopened_without_headers", header_button(edit).text == "Headers")
            tap(edit, "Headers")
            editor = window_titled("Custom HTTP headers")
            editor:setInputText(ALL)
            tap(editor, "OK")
        end,
        function()
            c.check("dialog.save_is_pressed", tap(edit, "Save"))
            c.check("dialog.closes_on_save", window_titled("Edit OPDS catalog") == nil)
            local saved = server_named("Mock Cloudflare")
            local h = saved and saved.headers or {}
            c.check("save.keeps_the_headers_in_order", #h == 3 and h[1].name == "CF-Access-Client-Id"
                and h[1].value == "test-id" and h[2].name == "CF-Access-Client-Secret" and h[2].value == "test-secret"
                and h[3].name == "X-Test-Note" and h[3].value == NOTE_VALUE, #h)
            c.check("save.keeps_title_and_url", saved.title == "Mock Cloudflare" and saved.url == BASE .. "/cf/feed")
            c.check("save.marks_the_settings_changed", p.updated == true)
            local disk = saved_on_disk("Mock Cloudflare")
            c.check("save.persists_to_the_settings_file", disk ~= nil and same_headers(disk.headers, saved.headers))
            local entry = root_item(b, "Mock Cloudflare")
            c.check("save.catalog_list_entry_carries_them", entry ~= nil and same_headers(entry.headers, saved.headers))
        end,
        -- Opening the dialog again shows what was saved.
        function()
            edit = open_edit_dialog("Mock Cloudflare")
            c.check("edit.button_shows_the_saved_count", header_button(edit).text == "Headers (3)",
                header_button(edit).text)
        end,
        function()
            shot("customheaders_edit_dialog_reopened")
            tap(edit, "Headers")
            editor = window_titled("Custom HTTP headers")
            c.check("edit.editor_shows_the_saved_text", editor ~= nil and editor:getInputText() == ALL,
                editor and editor:getInputText())
        end,
        function()
            shot("customheaders_editor_saved")
            tap(editor, "Cancel")
            c.check("edit.cancelling_the_editor_keeps_them", window_titled("Custom HTTP headers") == nil
                and header_button(edit).text == "Headers (3)")
            tap(edit, "Cancel")
        end,
        -- With the headers: the feed lists, covers load through the subprocess loader.
        function(advance)
            reset_toasts()
            remove_cache_files()
            watch_forks()
            first_fork = #fork_pids + 1
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Cloudflare"))
            wait_for(function() return not b._catalog_job and covers_loaded(b) end, 20, function(ok)
                local books = count(b)
                c.check("with.feed_lists_the_books", books == 10, books)
                c.check("with.no_authentication_error", not toast_has("Failed to authenticate"))
                local want, have = visible_covers(b)
                c.check("with.parallel_covers_load", ok, have .. "/" .. want)
                c.check("with.parallel_covers_use_subprocesses", #fork_pids - first_fork + 1 > 0,
                    #fork_pids - first_fork + 1)
                advance()
            end)
            return "async"
        end,
        function(advance)
            shot("customheaders_browse")
            p:saveSetting("cover_parallel_downloads", false)
            remove_cache_files()
            first_fork = #fork_pids + 1
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Cloudflare"))
            wait_for(function() return not b._catalog_job and covers_loaded(b) end, 20, function(ok)
                local want, have = visible_covers(b)
                c.check("with.serial_covers_load", ok, have .. "/" .. want)
                c.check("with.serial_covers_use_no_subprocess", #fork_pids - first_fork + 1 == 0,
                    #fork_pids - first_fork + 1)
                p:saveSetting("cover_parallel_downloads", true)
                advance()
            end)
            return "async"
        end,
        function()
            reset_toasts()
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Cloudflare"))
        end,
        function(advance)
            b:onMenuSelect(find_item(b, "Book 0003"))
            c.check("with.book_dialog_offers_the_download", tap(b.book_info_dialog, "Download (EPUB)"))
            wait_for(function() return window_has_text("File saved to") end, 20, function(saved)
                c.check("with.download_finishes", saved)
                close_window_with_text("File saved to")
                p.last_downloaded_file = nil
                local file = find_book(dir, "Book 0003")
                c.check("with.file_is_downloaded", file ~= nil)
                local handle = file and io.open(file, "rb")
                local head = handle and handle:read(15) or ""
                if handle then handle:close() end
                c.check("with.file_has_the_book", head == "PK\003\004mock-epub-3", head)
                advance()
            end)
            return "async"
        end,
        function(advance)
            close_browser(p)
            local cf = server_named("Mock Cloudflare")
            cf.sync = true
            p.settings.sync_dir = sync_dir
            reset_toasts()
            p:onStartOPDSSyncAllCatalogs()
            wait_for(function()
                return count_files(sync_dir, ".epub") >= 10 and toast_has("10 books downloaded")
            end, 60, function(ok)
                c.check("with.sync_downloads_every_book", ok, count_files(sync_dir, ".epub") .. " files")
                c.check("with.sync_leaves_no_browser", p.opds_browser == nil)
                close_browser(p)
                cf.sync = nil
                p.settings.sync_dir = previous_sync_dir
                advance()
            end)
            return "async"
        end,
        -- A catalog on the same server gets the headers too: that is what the origin means.
        function()
            dismiss_popups()
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Library"))
        end,
        function()
            b:onMenuSelect(find_item(b, "Echo request headers"))
        end,
        function()
            local all = listing_text()
            c.check("echo.same_origin_gets_the_headers", all:find("cf-access-client-id: test-id", 1, true) ~= nil
                and all:find("cf-access-client-secret: test-secret", 1, true) ~= nil)
            c.check("echo.value_survives_quotes_and_backslash", all:find("x-test-note: " .. NOTE_VALUE, 1, true) ~= nil)
            c.check("echo.plugin_headers_are_still_sent", all:find("accept-encoding: identity", 1, true) ~= nil)
            shot("customheaders_echo")
            close_browser(p)
        end,
        -- Another origin gets none of them; an Authorization header replaces the catalog's basic auth.
        function()
            local ok, body = HttpClient.getUrlContent(OTHER .. "/opds/echo")
            c.check("scope.other_origin_still_reaches_the_server", ok == true and body:find("Echo request headers", 1, true)
                ~= nil, ok and "" or body)
            body = ok and body:lower() or ""
            c.check("scope.other_origin_gets_none_of_the_headers", ok == true and not body:find("cf-access", 1, true)
                and not body:find("x-test-note", 1, true))

            local live = server_named("Mock Cloudflare").headers
            table.insert(live, { name = "Authorization", value = "Bearer custom-token" })
            ok, body = HttpClient.getUrlContent(BASE .. "/opds/echo", nil, nil, "reader", "secret")
            table.remove(live)
            body = ok and body:lower() or ""
            c.check("echo.authorization_header_replaces_basic_auth", body:find("authorization: bearer custom-token", 1, true)
                ~= nil and not body:find("authorization: basic", 1, true))
            ok, body = HttpClient.getUrlContent(BASE .. "/opds/echo", nil, nil, "reader", "secret")
            body = ok and body:lower() or ""
            c.check("echo.basic_auth_is_unchanged_without_it", body:find("authorization: basic", 1, true) ~= nil)
        end,
        -- A catalog added from scratch on another origin sends only its own headers, and the first one keeps its own.
        function()
            b = open_browser()
            servers_before = #p.servers
            b:addEditCatalog()
            edit = window_titled("Add OPDS catalog")
            c.check("add.dialog_opens", edit ~= nil)
            c.check("add.button_has_no_count", header_button(edit) ~= nil and header_button(edit).text == "Headers",
                header_button(edit) and header_button(edit).text)
            edit.input_fields[1]:setText("Mock Other")
            edit.input_fields[2]:setText(OTHER .. "/opds/echo")
            c.check("add.headers_button_is_pressed", tap(edit, "Headers"))
            editor = window_titled("Custom HTTP headers")
            c.check("add.editor_starts_empty", editor ~= nil and editor:getInputText() == "")
            if editor then editor:setInputText("X-Added-Token: added") end
            c.check("add.ok_is_pressed", tap(editor, "OK"))
        end,
        function()
            c.check("add.button_shows_the_count", header_button(edit).text == "Headers (1)", header_button(edit).text)
            shot("customheaders_add_dialog")
            c.check("add.save_is_pressed", tap(edit, "Save"))
            local added = server_named("Mock Other")
            c.check("add.catalog_is_added_with_its_header", #p.servers == servers_before + 1 and added ~= nil
                and added.headers ~= nil and #added.headers == 1 and added.headers[1].name == "X-Added-Token"
                and added.headers[1].value == "added")
            local disk = saved_on_disk("Mock Other")
            c.check("add.settings_file_has_it", disk ~= nil and disk.headers ~= nil and #disk.headers == 1
                and disk.headers[1].value == "added")
            local ok, body = HttpClient.getUrlContent(OTHER .. "/opds/echo")
            body = ok and body:lower() or ""
            c.check("add.its_own_origin_gets_its_header", body:find("x-added-token: added", 1, true) ~= nil)
            c.check("add.its_own_origin_gets_nothing_of_the_others", body ~= "" and not body:find("cf-access", 1, true)
                and not body:find("x-test-note", 1, true))
            ok, body = HttpClient.getUrlContent(BASE .. "/opds/echo")
            body = ok and body:lower() or ""
            c.check("add.first_origin_keeps_its_own", body:find("cf-access-client-id: test-id", 1, true) ~= nil
                and not body:find("x-added-token", 1, true))
            while #p.servers > servers_before do table.remove(p.servers) end
            close_browser(p)
        end,
        -- Saving a sub-catalog copies the headers only when it is on the same origin.
        function()
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Cloudflare"))
        end,
        function()
            servers_before = #p.servers
            b:addSubCatalog(BASE .. "/cf/feed?sub=1")
            local dialog = window_titled("Add OPDS catalog")
            c.check("sub.dialog_opens", dialog ~= nil)
            c.check("sub.save_is_pressed", tap(dialog, "Save"))
            local added, live = p.servers[servers_before + 1], server_named("Mock Cloudflare")
            c.check("sub.catalog_is_added", #p.servers == servers_before + 1 and added ~= nil
                and added.url == BASE .. "/cf/feed?sub=1")
            c.check("sub.same_origin_gets_the_headers", added ~= nil and same_headers(added.headers, live.headers))
            c.check("sub.headers_are_a_copy", added ~= nil and added.headers ~= live.headers
                and added.headers[1] ~= live.headers[1])
            if added and added.headers then
                added.headers[1].value = "changed"
                c.check("sub.changing_the_copy_leaves_the_catalog_alone", live.headers[1].value == "test-id")
            end
            b:addSubCatalog(OTHER .. "/cf/feed?sub=2")
            tap(window_titled("Add OPDS catalog"), "Save")
            local other = p.servers[servers_before + 2]
            c.check("sub.other_origin_is_added", #p.servers == servers_before + 2 and other ~= nil
                and other.url == OTHER .. "/cf/feed?sub=2")
            c.check("sub.other_origin_gets_no_headers", other ~= nil and other.headers == nil)
            while #p.servers > servers_before do table.remove(p.servers) end
            close_browser(p)
        end,
        -- Emptying the editor removes them again.
        function()
            b = open_browser()
            edit = open_edit_dialog("Mock Cloudflare")
            tap(edit, "Headers")
            editor = window_titled("Custom HTTP headers")
            editor:setInputText("")
            c.check("clear.ok_is_pressed", tap(editor, "OK"))
        end,
        function()
            c.check("clear.button_loses_the_count", header_button(edit).text == "Headers", header_button(edit).text)
            c.check("clear.save_is_pressed", tap(edit, "Save"))
            local saved = server_named("Mock Cloudflare")
            c.check("clear.catalog_keeps_no_headers_field", saved ~= nil and saved.headers == nil)
            local disk = saved_on_disk("Mock Cloudflare")
            c.check("clear.settings_file_has_none", disk ~= nil and disk.headers == nil)
            c.check("clear.origin_has_no_headers", RequestHeaders.forUrl(p.servers, BASE .. "/cf/feed") == nil)
            reset_toasts()
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Cloudflare"))
        end,
        function()
            c.check("clear.feed_is_refused_again", toast_has("Failed to authenticate"), toasts[#toasts])
            dismiss_popups()
            local ok = HttpClient.getUrlContent(BASE .. "/cf/cover/1.png")
            c.check("clear.cover_is_refused_again", ok == false)
            close_browser(p)
        end,
        -- Kavita's own requests, captured before they reach LuaSocket: the plugin's own headers win.
        function()
            local saved = server_named("Mock Cloudflare")
            saved.headers = RequestHeaders.parse(ID_LINE .. "\n" .. SECRET_LINE .. "\nauthorization: Basic custom")
            local http = require("socket.http")
            local real_request = http.request
            local png_file = io.open("resources/koreader.png", "rb")
            local png = png_file and png_file:read("*a") or ""
            if png_file then png_file:close() end
            local seen = {}
            http.request = function(reqt)
                seen[#seen + 1] = reqt
                local body = png
                if reqt.method == "POST" then
                    body = '{"token":"tok123","refreshToken":"r"}'
                elseif reqt.url:find("get-progress", 1, true) then
                    body = '{"pageNum":2,"seriesId":9}'
                end
                if reqt.sink then
                    reqt.sink(body)
                    reqt.sink(nil)
                end
                return 1, 200, {}, "HTTP/1.1 200 OK"
            end
            local ok, err = pcall(function()
                require("services.kavita"):streamPages(BASE .. "/cf/api/opds/KEY123/image?chapterId=77&p={pageNumber}"
                    .. "&w={maxWidth}", 3, false, "reader", "secret")
            end)
            http.request = real_request
            c.check("kavita.streams_pages", ok, err)
            local auth, progress, pages = nil, nil, {}
            for _, reqt in ipairs(seen) do
                if reqt.method == "POST" then
                    auth = reqt
                elseif reqt.url:find("get-progress", 1, true) then
                    progress = reqt
                else
                    pages[#pages + 1] = reqt
                end
            end
            emit("customheaders.kavita.requests", #seen .. " (" .. #pages .. " pages)")
            c.check("kavita.authentication_carries_the_headers", auth ~= nil and auth.headers["CF-Access-Client-Id"]
                == "test-id" and auth.headers["CF-Access-Client-Secret"] == "test-secret"
                and auth.headers["Authentication"] == "KEY123")
            c.check("kavita.progress_carries_the_headers", progress ~= nil and progress.headers["CF-Access-Client-Id"]
                == "test-id" and progress.headers["CF-Access-Client-Secret"] == "test-secret")
            c.check("kavita.own_authorization_wins", progress ~= nil and progress.headers["Authorization"]
                == "Bearer tok123" and progress.headers["authorization"] == nil)
            local all_pages = #pages > 0
            for _, reqt in ipairs(pages) do
                all_pages = all_pages and reqt.headers["CF-Access-Client-Id"] == "test-id"
                    and reqt.headers["CF-Access-Client-Secret"] == "test-secret"
                    and reqt.headers["Accept-Encoding"] == "identity"
            end
            c.check("kavita.pages_carry_the_headers", all_pages, #pages)
            c.check("kavita.authorization_applies_where_the_plugin_sets_none", #pages > 0
                and pages[1].headers["authorization"] == "Basic custom")
            saved.headers = nil
        end,
        function()
            -- The viewer is closed one step later: KOReader's ImageViewer fails if it is closed before its first paint.
            for i = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[i].widget
                if type(widget) == "table" and widget.images_list_nb == 3 then UIManager:close(widget) end
            end
            unwatch_forks()
            remove_cache_files()
            close_browser(p)
            dismiss_popups()
            p.settings.sync_dir = previous_sync_dir
            if previous_vk == nil then
                G_reader_settings:delSetting("virtual_keyboard_enabled")
            else
                G_reader_settings:saveSetting("virtual_keyboard_enabled", previous_vk)
            end
            if previous_dir then
                G_reader_settings:saveSetting("download_dir", previous_dir)
            else
                G_reader_settings:delSetting("download_dir")
            end
            p:onFlushSettings()
            remove_temp_dir(dir); remove_temp_dir(sync_dir)
            c.finish()
        end,
    }
end

-- PDF links: a PDF the server already offers as a download link gets one download button. The plugin used to add a
-- second one, with a made-up address ending in ".pdf", next to every PDF link whose address did not end that way.
local function pdflinks_steps()
    local c = checker("pdflinks")
    local p, b

    local function item_named(title)
        for _, item in ipairs(b.item_table) do
            if item.text and item.text:find(title, 1, true) then return item end
        end
    end

    local function hrefs_of(item)
        local hrefs = {}
        for _, acquisition in ipairs(item and item.acquisitions or {}) do hrefs[#hrefs + 1] = acquisition.href end
        return hrefs
    end

    local function ends_with(text, tail)
        return type(text) == "string" and text:sub(-#tail) == tail
    end

    -- How many buttons below `root` have a label for which `matches` is true.
    local function count_buttons(root, matches)
        local found, seen = 0, {}
        local function walk(widget)
            if type(widget) ~= "table" or seen[widget] then return end
            seen[widget] = true
            if type(widget.text) == "string" and type(widget.callback) == "function" and matches(widget.text) then
                found = found + 1
            end
            for _, child in ipairs(widget) do walk(child) end
        end
        walk(root)
        return found
    end

    local function labelled(label)
        return function(text) return text == label end
    end

    local function containing(fragment)
        return function(text) return text:find(fragment, 1, true) ~= nil end
    end

    local function close_dialogs()
        if b.format_dialog then UIManager:close(b.format_dialog) end
        if b.book_info_dialog then UIManager:close(b.book_info_dialog) end
    end

    return {
        function()
            current = "pdflinks"
            p = plugin()
            close_window_with_text("Documents will be rendered")
            -- earlier scenarios leave their messages on screen, and they would cover the screenshots
            for i = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[i].widget
                if type(widget) == "table" and widget.modal and type(widget.text) == "string" then
                    UIManager:close(widget)
                end
            end
            close_browser(p)
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Library"))
        end,
        function()
            b:onMenuSelect(find_item(b, "PDF links"))
        end,
        function()
            c.check("feed.lists_every_entry", #b.item_table == 7, #b.item_table)
            -- a Calibre content server writes the format into the address and gives its links no title
            local hrefs = hrefs_of(item_named("Calibre Content Server"))
            emit("pdflinks.calibre.links", table.concat(hrefs, " "))
            c.check("calibre.has_the_two_links_the_server_sent", #hrefs == 2, #hrefs)
            c.check("calibre.epub_has_the_servers_address", ends_with(hrefs[1], "/get/epub/701/library"), hrefs[1])
            c.check("calibre.pdf_has_the_servers_address", ends_with(hrefs[2], "/get/pdf/701/library"), hrefs[2])
            local titled = hrefs_of(item_named("Titled links"))
            emit("pdflinks.titled.links", table.concat(titled, " "))
            c.check("titled.has_the_two_links_the_server_sent", #titled == 2, #titled)
            c.check("titled.epub_has_the_servers_address", ends_with(titled[1], "/books/707/epub"), titled[1])
            c.check("titled.pdf_has_the_servers_address", ends_with(titled[2], "/books/707/pdf"), titled[2])
            local singles = {
                { "calibre_web", "Calibre-Web", "/opds/download/702/pdf/" },
                { "komga", "Komga", "/opds/v1.2/books/703/file/Book.pdf" },
                { "arxiv", "arXiv", "/pdf/1234.5678v1" },
                -- no other branch takes this link, so its address still gets the ".pdf" the server left out
                { "alternate_only", "Alternate only", "/files/705.pdf" },
            }
            for _, row in ipairs(singles) do
                local links = hrefs_of(item_named(row[2]))
                emit("pdflinks." .. row[1] .. ".links", table.concat(links, " "))
                c.check(row[1] .. ".has_one_link", #links == 1, #links)
                c.check(row[1] .. ".link_address", ends_with(links[1], row[3]), links[1])
            end
            local section = item_named("PDF section")
            c.check("section.opens_a_catalog", section and ends_with(section.url, "/opds/pdflinks/pdf"),
                section and section.url)
            c.check("section.is_not_a_book", section and #section.acquisitions == 0,
                section and #section.acquisitions)
        end,
        -- Calibre's links have no title, so the extra link has no type either and tapping the book drops it: the
        -- dialog never showed it, and it must not start to
        function()
            b:onMenuSelect(item_named("Calibre Content Server"))
            local dialog = b.book_info_dialog
            c.check("calibre_dialog.opens", dialog ~= nil)
            c.check("calibre_dialog.lists_each_format_once", dialog and shows_text(dialog, "EPUB, PDF")
                and not shows_text(dialog, "PDF, PDF"))
            close_dialogs()
        end,
        -- links with a title keep the extra link's type, so the dialog listed the PDF twice
        function()
            b:onMenuSelect(item_named("Titled links"))
            local dialog = b.book_info_dialog
            c.check("titled_dialog.opens", dialog ~= nil)
            c.check("titled_dialog.lists_each_format_once", dialog and shows_text(dialog, "EPUB, PDF")
                and not shows_text(dialog, "PDF, PDF"))
            c.check("titled_dialog.asks_for_a_format", dialog and press_button(dialog, "Download…") == true)
        end,
        function()
            local dialog = b.format_dialog
            c.check("titled_formats.opens", dialog ~= nil)
            c.check("titled_formats.has_one_epub_button", dialog and count_buttons(dialog, labelled("EPUB")) == 1)
            local pdf_buttons = dialog and count_buttons(dialog, labelled("PDF"))
            c.check("titled_formats.has_one_pdf_button", pdf_buttons == 1, pdf_buttons)
            shot("pdflinks_titled_formats")
            close_dialogs()
        end,
        -- arXiv offers a single PDF, so the dialog gets a plain download button and does not ask for a format
        function()
            b:onMenuSelect(item_named("arXiv"))
            local dialog = b.book_info_dialog
            c.check("arxiv_dialog.opens", dialog ~= nil)
            c.check("arxiv_dialog.has_one_pdf_button", dialog and count_buttons(dialog, containing("Download (PDF)")) == 1)
            c.check("arxiv_dialog.does_not_ask_for_a_format", dialog and count_buttons(dialog, containing("Download…")) == 0)
        end,
        function()
            shot("pdflinks_arxiv_dialog")
            close_dialogs()
            close_browser(p)
            c.finish()
        end,
    }
end

-- #100 against a real Calibre-Web(-Automated): the reader only uses the on-screen chevrons, never swipes.
-- Needs HARNESS_CWA_URL (feed address), HARNESS_CWA_USER, HARNESS_CWA_PASS, HARNESS_CWA_TOTAL (entries in the feed).
local function cwapaging_steps()
    local c = checker("cwapaging")
    local p, b, server, orig_request
    local methods = { GET = 0, HEAD = 0 }
    local total = tonumber(os.getenv("HARNESS_CWA_TOTAL") or "0")
    local function enabled(button) return button and button.enabled ~= false and not button.hidden end
    return {
        function()
            current = "cwapaging"
            p = plugin()
            close_browser(p)
            local http = require("socket.http")
            orig_request = http.request
            http.request = function(req, ...)
                if type(req) == "table" and type(req.url) == "string" and req.url:find("/opds/new", 1, true) then
                    methods[req.method or "GET"] = (methods[req.method or "GET"] or 0) + 1
                end
                return orig_request(req, ...)
            end
            server = { title = "Real CWA", url = os.getenv("HARNESS_CWA_URL"),
                username = os.getenv("HARNESS_CWA_USER"), password = os.getenv("HARNESS_CWA_PASS") }
            table.insert(p.servers, server)
            b = open_browser()
            b:onMenuSelect(find_item(b, "Real CWA"))
        end,
        function()
            emit("cwapaging.first_load_items", #b.item_table)
            emit("cwapaging.first_load_pages", b.page_num)
            c.check("opens", #b.item_table > 0, #b.item_table)
            -- the last-page chevron, or the page number dialog, lands on the last page fetched so far
            b.page_info_last_chev.callback()
            emit("cwapaging.after_last.page", b.page .. "/" .. b.page_num)
            emit("cwapaging.after_last.items", #b.item_table)
            c.check("after_last.next_chevron_usable", enabled(b.page_info_right_chev),
                "page " .. b.page .. "/" .. b.page_num)
            shot("cwapaging_after_last")
        end,
        function()
            local taps = 0
            while taps < 400 and enabled(b.page_info_right_chev) do
                b.page_info_right_chev.callback()
                taps = taps + 1
            end
            local books = count(b)
            emit("cwapaging.taps", taps)
            emit("cwapaging.final.page", b.page .. "/" .. b.page_num)
            local http = require("socket.http")
            http.request = orig_request
            emit("cwapaging.requests", "GET " .. methods.GET .. ", HEAD " .. methods.HEAD)
            c.check("no_head_before_feed_pages", methods.HEAD == 0, methods.HEAD)
            c.check("reaches_every_entry", books == total, books .. " of " .. total)
            c.check("ends_on_last_page", b.page == b.page_num, b.page .. "/" .. b.page_num)
            close_browser(p)
            remove_server(p, server)
            c.finish()
        end,
    }
end

-- Names for downloads (server file names without a usable extension) and the default download folder.
local function filenames_steps()
    local c = checker("filenames")
    return {
        function()
            current = "filenames"
            local FeedFetcher = require("core.feed_fetcher")
            local function name(path) return FeedFetcher.getServerFileName(BASE .. path, "epub") end
            local plain = name("/dlnoext/7")
            c.check("no_extension_gets_one", plain == "7.epub", plain)
            local php = name("/dlphp/get.php?id=7")
            c.check("unreadable_extension_gets_one", php == "get.php.epub", php)
            local kept = name("/dl/7.epub")
            c.check("readable_extension_kept", kept == "7.epub", kept)

            local p = plugin()
            close_browser(p)
            local b = open_browser()
            local DownloadManager = require("core.download_manager")
            local saved = {}
            for _, key in ipairs({ "download_dir", "home_dir", "lastdir" }) do
                saved[key] = G_reader_settings:readSetting(key)
            end
            G_reader_settings:delSetting("download_dir")
            G_reader_settings:saveSetting("home_dir", tmp_root .. "/home")
            G_reader_settings:saveSetting("lastdir", tmp_root .. "/last")
            local unset = DownloadManager.getCurrentDownloadDir(b)
            c.check("unset_folder_uses_home", unset == tmp_root .. "/home", unset)
            G_reader_settings:saveSetting("download_dir", tmp_root .. "/chosen")
            local chosen = DownloadManager.getCurrentDownloadDir(b)
            c.check("chosen_folder_wins", chosen == tmp_root .. "/chosen", chosen)
            for _, key in ipairs({ "download_dir", "home_dir", "lastdir" }) do
                if saved[key] then G_reader_settings:saveSetting(key, saved[key]) else G_reader_settings:delSetting(key) end
            end
            close_browser(p)
            c.finish()
        end,
    }
end

-- A real download from Calibre-Web(-Automated) with no download folder set: it lands in the home folder.
local function cwadownload_steps()
    local c = checker("cwadownload")
    local p, b, server, home, saved_dir, saved_home
    return {
        function()
            current = "cwadownload"
            p = plugin()
            close_browser(p)
            home = fresh_dir()
            saved_dir = G_reader_settings:readSetting("download_dir")
            saved_home = G_reader_settings:readSetting("home_dir")
            G_reader_settings:delSetting("download_dir")
            G_reader_settings:saveSetting("home_dir", home)
            server = { title = "Real CWA", url = os.getenv("HARNESS_CWA_URL"),
                username = os.getenv("HARNESS_CWA_USER"), password = os.getenv("HARNESS_CWA_PASS") }
            table.insert(p.servers, server)
            b = open_browser()
            b:onMenuSelect(find_item(b, "Real CWA"))
        end,
        function(advance)
            local book
            for _, item in ipairs(b.item_table) do
                if item.acquisitions and #item.acquisitions > 0 then book = item break end
            end
            c.check("has_a_book", book ~= nil)
            emit("cwadownload.book", book and book.text)
            b:onMenuSelect(book)
            local pressed = press_button(b.book_info_dialog, "Download (EPUB)")
                or (press_button(b.book_info_dialog, "Download…") and press_button(b.format_dialog, "EPUB"))
            c.check("download_pressed", pressed == true)
            wait_for(function() return window_has_text("File saved to") end, 60, function(done)
                c.check("download_finishes", done)
                close_window_with_text("File saved to")
                local file
                for name in require("libs/libkoreader-lfs").dir(home) do
                    if name ~= "." and name ~= ".." and not name:find("%.sdr$") then file = name end
                end
                emit("cwadownload.file", file)
                c.check("lands_in_home_folder", file ~= nil)
                c.check("has_epub_extension", file and file:sub(-5) == ".epub", file)
                local f = file and io.open(home .. "/" .. file, "rb")
                local head = f and f:read(2)
                if f then f:close() end
                c.check("is_a_zip", head == "PK", head)
                p.last_downloaded_file = nil
                close_browser(p)
                remove_server(p, server)
                if saved_dir then G_reader_settings:saveSetting("download_dir", saved_dir) end
                if saved_home then G_reader_settings:saveSetting("home_dir", saved_home)
                else G_reader_settings:delSetting("home_dir") end
                c.finish()
                advance()
            end)
            return "async"
        end,
    }
end

-- One request per feed: no HEAD before the GET, and a feed the server confirms unchanged (304) is shown from
-- the copy kept from last time.
local function condget_steps()
    local c = checker("condget")
    local p, b, server, first_items
    local function cond(action)
        local http = require("socket.http")
        http.TIMEOUT = 5
        local body = http.request(BASE .. "/__cond" .. (action and ("/" .. action) or ""))
        return require("rapidjson").decode(body or "{}") or {}
    end
    return {
        function()
            current = "condget"
            p = plugin()
            close_browser(p)
            cond("reset")
            server = add_server(p, "Mock Conditional", "/opds/cond")
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock Conditional"))
        end,
        function()
            first_items = #b.item_table
            c.check("first_open_lists_the_feed", first_items == 5, first_items)
            b:onReturn()
        end,
        function()
            b:onMenuSelect(find_item(b, "Mock Conditional"))
        end,
        function()
            local stats = cond()
            c.check("second_open_lists_the_feed", #b.item_table == first_items, #b.item_table)
            c.check("no_head_requests", stats.HEAD == nil, stats.HEAD)
            c.check("one_get_per_open", (stats.GET or 0) + (stats["GET 304"] or 0) == 2, stats.GET)
            c.check("second_open_was_not_modified", stats["GET 304"] == 1, stats["GET 304"])
            -- a feed that changed is fetched again
            cond("bump")
            b:onReturn()
        end,
        function()
            b:onMenuSelect(find_item(b, "Mock Conditional"))
        end,
        function()
            local stats = cond()
            c.check("changed_feed_lists_the_feed", #b.item_table == first_items, #b.item_table)
            c.check("changed_feed_fetched_again", stats.GET == 2 and stats["GET 304"] == 1 and stats.HEAD == nil,
                tostring(stats.GET) .. "/" .. tostring(stats["GET 304"]))
            -- a server that only dates its feeds
            local FeedFetcher = require("core.feed_fetcher")
            local first = FeedFetcher.parseFeed(BASE .. "/opds/lmonly")
            local second = FeedFetcher.parseFeed(BASE .. "/opds/lmonly")
            stats = cond()
            c.check("dated_feed_parses_twice", first ~= nil and second ~= nil)
            c.check("dated_feed_was_not_modified", stats["GET 304"] == 2, stats["GET 304"])
            close_browser(p)
            remove_server(p, server)
            c.finish()
        end,
    }
end

-- OPDS 2.0 (JSON) catalogs end to end: navigation, groups with a size, a shelf, paging, facets, search,
-- book details, EPUB and CBZ downloads, in the list and the grid view.
local function opds2_steps()
    local StateManager = require("core.state_manager")
    local c = checker("opds2")
    local p, b, server, dir, previous_dir, previous_mode

    local function texts(widget)
        local found, seen = {}, {}
        local function walk(w)
            if type(w) ~= "table" or seen[w] then return end
            seen[w] = true
            if type(w.text) == "string" then found[#found + 1] = w.text end
            for _, child in ipairs(w) do walk(child) end
        end
        walk(widget)
        return table.concat(found, "\n")
    end

    local function top_window(predicate)
        for i = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[i].widget
            if predicate(widget) then return widget end
        end
    end

    local function find_file(suffix)
        for name in require("libs/libkoreader-lfs").dir(dir) do
            if name:sub(-#suffix) == suffix then return dir .. "/" .. name end
        end
    end

    local function file_head(path)
        local f = path and io.open(path, "rb")
        if not f then return nil end
        local head = f:read(2)
        f:close()
        return head
    end

    local function wait_covers(advance)
        wait_for(function()
            local want, have = visible_covers(b)
            return want > 0 and want == have
        end, 20, advance)
        return "async"
    end

    local function download(label, title, format, suffix)
        return function(advance)
            b:onMenuSelect(find_item(b, title))
            local pressed = press_button(b.book_info_dialog, "Download…") and press_button(b.format_dialog, format)
            c.check(label .. ".download_pressed", pressed == true)
            wait_for(function() return window_has_text("File saved to") end, 20, function(saved)
                c.check(label .. ".download_finishes", saved)
                close_window_with_text("File saved to")
                p.last_downloaded_file = nil
                local file = find_file(suffix)
                emit("opds2." .. label .. ".file", file and file:match("[^/]+$"))
                c.check(label .. ".file_is_a_zip", file_head(file) == "PK", file)
                if b.book_info_dialog then UIManager:close(b.book_info_dialog) end
                advance()
            end)
            return "async"
        end
    end

    return {
        function()
            current = "opds2"
            p = plugin()
            close_browser(p)
            dir = fresh_dir()
            previous_dir = G_reader_settings:readSetting("download_dir")
            G_reader_settings:saveSetting("download_dir", dir)
            previous_mode = StateManager.getInstance():getDisplayMode()
            StateManager.getInstance():setDisplayMode("list")
            server = add_server(p, "Mock OPDS 2", "/opds2/home")
            b = open_browser()
            b:onMenuSelect(find_item(b, "Mock OPDS 2"))
        end,
        function(advance)
            local listed = {}
            for _, item in ipairs(b.item_table) do
                listed[#listed + 1] = (item.text or "?") .. "|" .. tostring(item.mandatory or "")
            end
            emit("opds2.root.items", table.concat(listed, "; "))
            c.check("root.navigation", find_item(b, "All books") ~= nil)
            local latest, picks = find_item(b, "Latest"), find_item(b, "Staff picks")
            c.check("root.group_with_link", latest ~= nil and latest.url == BASE .. "/opds2/books?page=1",
                latest and latest.url)
            c.check("root.group_size", latest and latest.mandatory == "60", latest and latest.mandatory)
            c.check("root.shelf_url", picks ~= nil and picks.url:find("#opdsplus-group=", 1, true) ~= nil,
                picks and picks.url)
            c.check("root.shelf_size", picks and picks.mandatory == "3", picks and picks.mandatory)
            c.check("root.group_navigation", find_item(b, "Fantasy") ~= nil)
            c.check("root.search", b.search_url ~= nil, b.search_url)
            shot("opds2_root_list")
            if picks then b:onMenuSelect(picks) end
            wait_for(function() return find_item(b, "Book 2-0005") ~= nil end, 10, advance)
            return "async"
        end,
        function(advance)
            local books = count(b)
            c.check("shelf.lists_its_books", books == 3 and #b.item_table == 3, books .. "/" .. #b.item_table)
            c.check("shelf.has_no_paging", not (b.item_table.hrefs and b.item_table.hrefs.next))
            shot("opds2_shelf")
            return wait_covers(advance)
        end,
        function(advance)
            c.check("shelf.covers_load", select(2, visible_covers(b)) > 0)
            local book = find_item(b, "Book 2-0005")
            b:onMenuSelect(book)
            local info = texts(b.book_info_dialog)
            emit("opds2.info.has_series", tostring(info:find("Series 1", 1, true) ~= nil))
            c.check("info.publisher", info:find("Mock Press", 1, true) ~= nil)
            c.check("info.published", info:find("2005", 1, true) ~= nil)
            c.check("info.language", info:find("en", 1, true) ~= nil)
            c.check("info.series", info:find("Series 1", 1, true) ~= nil)
            c.check("info.offers_two_formats", info:find("Download…", 1, true) ~= nil)
            shot("opds2_book_info")
            UIManager:close(b.book_info_dialog)
            advance()
            return "async"
        end,
        download("epub", "Book 2-0005", "EPUB", ".epub"),
        download("cbz", "Book 2-0005", "CBZ", ".cbz"),
        function()
            b:onReturn()
        end,
        function()
            c.check("back.returns_to_the_start", find_item(b, "Staff picks") ~= nil)
            b:onMenuSelect(find_item(b, "All books"))
        end,
        function(advance)
            local books, thumbs = count(b)
            c.check("paging.first_page", books == 20, books)
            c.check("paging.covers_have_urls", thumbs == 20, thumbs)
            c.check("paging.has_next", b.item_table.hrefs and b.item_table.hrefs.next ~= nil)
            local first = b.item_table[1]
            c.check("paging.series", first and first.series == "Series 1", first and first.series)
            browse_all(b, 20, function()
                books = count(b)
                c.check("paging.reaches_every_book", books == 60, books)
                c.check("facets.present", b.facet_groups ~= nil)
                b:showFacetMenu()
                local menu = top_window(function(w) return texts(w):find("Fantasy (10)", 1, true) ~= nil end)
                c.check("facets.menu_shows_counts", menu ~= nil)
                c.check("facets.marks_the_active_one", menu and texts(menu):find("✓ All (60)", 1, true) ~= nil,
                    menu and texts(menu))
                local pressed = menu and press_button(menu, "Fantasy (10)")
                c.check("facets.pressed", pressed == true)
                advance()
            end)
            return "async"
        end,
        function()
            local books = count(b)
            c.check("facets.filter", books == 10, books)
            shot("opds2_fantasy_list")
            b:searchCatalog(b.search_url)
            local dialog = top_window(function(w) return w.title == "Search OPDS catalog" end)
            c.check("search.dialog_opens", dialog ~= nil)
            if dialog then
                dialog:setInputText("2-001")
                c.check("search.pressed", press_button(dialog, "Search") == true)
            end
        end,
        function()
            local books = count(b)
            c.check("search.lists_books_in_place", books == 10 and #b.item_table == 10, books .. "/" .. #b.item_table)
            c.check("search.finds_the_book", find_item(b, "Book 2-0010") ~= nil)
            StateManager.getInstance():setDisplayMode("grid")
            b:updateCatalog(b.paths[#b.paths].url, true)
        end,
        function(advance)
            c.check("grid.is_the_view", b._last_display_mode == "grid", b._last_display_mode)
            return wait_covers(advance)
        end,
        function()
            c.check("grid.covers_load", select(2, visible_covers(b)) > 0)
            shot("opds2_search_grid")
            close_browser(p)
            remove_server(p, server)
            StateManager.getInstance():setDisplayMode(previous_mode)
            if previous_dir then G_reader_settings:saveSetting("download_dir", previous_dir)
            else G_reader_settings:delSetting("download_dir") end
            remove_temp_dir(dir)
            c.finish()
        end,
    }
end

-- README screenshots of the showcase catalog (mock_opds_server.py /opds/showcase, covers from make_covers.py).
-- Explicit: screenshots.sh runs it on a small screen and frames the pictures.
local function shots_steps()
    local StateManager = require("core.state_manager")
    local c = checker("shots")
    local p, b, server, previous_mode, menu, depth

    local function pause(seconds, advance)
        UIManager:scheduleIn(seconds, advance)
        return "async"
    end

    local function wait_covers(advance)
        wait_for(function()
            local want, have = visible_covers(b)
            return want > 0 and want == have
        end, 20, function(ok)
            c.check("covers_load." .. (b._last_display_mode or "?"), ok)
            pause(1, advance)
        end)
        return "async"
    end

    -- The items down to the first menu entry whose text holds `text` (KOReader may prefix it with "NEW: ")
    local function find_in_menu(items, text, path)
        for _, item in ipairs(items) do
            local label = item.text or (item.text_func and item.text_func())
            if type(label) == "string" and label:find(text, 1, true) then
                path[#path + 1] = item
                return path
            end
            local sub = item.sub_item_table
            if type(sub) == "table" then
                path[#path + 1] = item
                if find_in_menu(sub, text, path) then return path end
                path[#path] = nil
            end
        end
    end

    local function top_widget()
        local entry = UIManager._window_stack[#UIManager._window_stack]
        return entry and entry.widget
    end

    -- Closes every window shown after the stack had `keep` of them
    local function close_above(keep)
        while #UIManager._window_stack > keep do
            UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        end
    end

    local function changelog_notes()
        local f = io.open(p.path .. "/CHANGELOG.md", "r")
        if not f then return "" end
        local text = f:read("*a")
        f:close()
        local section = text:match("\n## %[%d[^\n]*\n(.-)\n## %[") or ""
        return (section:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    return {
        function()
            current = "shots"
            p = plugin()
            -- KOReader's start-up notices would cover the pictures
            close_window_with_text("rendered in color")
            close_window_with_text("cache database")
            previous_mode = StateManager.getInstance():getDisplayMode()
            StateManager.getInstance():setDisplayMode("list")
            server = add_server(p, "Classics", "/opds/showcase")
            b = open_browser()
            b:onMenuSelect(find_item(b, "Classics"))
        end,
        function(advance)
            local books = count(b)
            c.check("showcase_books", books == 12, books)
            return wait_covers(advance)
        end,
        function(advance)
            shot("list_view")
            depth = #UIManager._window_stack
            b.onLeftButtonTap()
            return pause(1, advance)
        end,
        function()
            c.check("view_menu_opens", window_has_text("Switch to Grid View") or #UIManager._window_stack > depth)
            shot("view_toggle_menu")
            close_above(depth)
            StateManager.getInstance():setDisplayMode("grid")
            b:updateCatalog(b.paths[#b.paths].url, true)
        end,
        function(advance)
            c.check("grid_is_the_view", b._last_display_mode == "grid", b._last_display_mode)
            return wait_covers(advance)
        end,
        function(advance)
            shot("grid_view")
            b:onMenuSelect(find_item(b, "A Study in Scarlet"))
            return pause(2, advance)
        end,
        function()
            c.check("book_details_open", b.book_info_dialog ~= nil)
            shot("book_details")
            if b.book_info_dialog then UIManager:close(b.book_info_dialog) end
            close_browser(p)
            remove_server(p, server)
            StateManager.getInstance():setDisplayMode(previous_mode)
            local fm_menu = require("apps/filemanager/filemanager").instance.menu
            fm_menu:onShowMenu()
            menu = fm_menu.menu_container[1]
            local found
            for tab, tab_items in ipairs(menu.tab_item_table) do
                local path = find_in_menu(tab_items, "OPDS Plus Catalog", {})
                path = path and find_in_menu(path[#path].sub_item_table, "Settings", path)
                if path then
                    menu:switchMenuTab(tab)
                    for _, item in ipairs(path) do menu:onMenuSelect(item) end
                    found = true
                    break
                end
            end
            c.check("settings_menu_found", found == true)
        end,
        function(advance)
            shot("settings_menu")
            require("apps/filemanager/filemanager").instance.menu:onCloseFileManagerMenu()
            local notes = changelog_notes()
            c.check("release_notes_read", notes ~= "")
            require("ui.dialogs.update_dialog").showRelease(p, nil, {
                version = require("opds_plus_version").VERSION,
                notes = notes,
            })
            return pause(1, advance)
        end,
        function()
            local viewer = top_widget()
            local title = viewer and viewer.title
            c.check("update_dialog_opens", type(title) == "string" and title:find("is available", 1, true) ~= nil, title)
            shot("update_available")
            if title then UIManager:close(viewer) end
            StateManager.getInstance():setDisplayMode("list")
            server = add_server(p, "Classics (OPDS 2.0)", "/opds2/showcase")
            b = open_browser()
            b:onMenuSelect(find_item(b, "Classics (OPDS 2.0)"))
        end,
        function(advance)
            c.check("opds2_start_page", find_item(b, "Staff picks") ~= nil and find_item(b, "New arrivals") ~= nil)
            return pause(1, advance)
        end,
        function()
            shot("opds2_shelves")
            StateManager.getInstance():setDisplayMode("grid")
            b:onMenuSelect(find_item(b, "All classics"))
        end,
        function(advance)
            c.check("opds2_books", count(b) == 12, count(b))
            return wait_covers(advance)
        end,
        function(advance)
            depth = #UIManager._window_stack
            b:showFacetMenu()
            return pause(1, advance)
        end,
        function()
            c.check("opds2_facet_menu", window_has_text("Science fiction (3)") or #UIManager._window_stack > depth)
            shot("opds2_facets")
            close_above(depth)
            close_browser(p)
            remove_server(p, server)
            StateManager.getInstance():setDisplayMode(previous_mode)
            c.finish()
        end,
    }
end

local function catalogprofile_steps()
    local c = checker("catalogprofile")
    local FeedFetcher = require("core.feed_fetcher")
    local Parser = require("core.parser")
    local Navigation = require("core.navigation_handler")
    local gettime = require("socket").gettime
    local p, b
    local steps = {
        function()
            current = "catalogprofile"
            p = plugin()
            close_window_with_text("rendered in color")
            close_window_with_text("cache database")
            b = open_browser()
        end,
    }
    for _, format in ipairs({ "atom", "opds2" }) do
        steps[#steps + 1] = function()
            local url = BASE .. (format == "atom"
                and "/opds/paged?size=5000&total=5000&delay=1.2"
                or "/opds2/books?delay=1.2")
            local start = gettime()
            local body, headers = FeedFetcher.fetchFeed(url, false)
            assert(type(body) == "string" and headers, "missing profile feed")
            emit("catalogprofile." .. format .. ".http_ms", math.floor((gettime() - start) * 1000))
            if format == "opds2" then
                -- The server's JSON fixture has 20 publications; expand only the CPU/serialization sample.
                local feed = Parser:parse(body, headers["content-type"])
                for index = 21, 5000 do feed.publications[index] = feed.publications[(index - 1) % 20 + 1] end
                body = require("json").encode(feed)
            end
            emit("catalogprofile." .. format .. ".payload_bytes", #body)
            start = gettime()
            local parsed = Parser:parse(body, headers["content-type"])
            emit("catalogprofile." .. format .. ".decode_ms", math.floor((gettime() - start) * 1000))
            start = gettime()
            local items = Navigation.genItemTableFromCatalog(parsed, url, require("core.browser_context").fromBrowser(b))
            emit("catalogprofile." .. format .. ".map_ms", math.floor((gettime() - start) * 1000))
            c.check(format .. ".all_entries_preserved", #items == 5000, #items)
            start = gettime()
            b:switchItemTable("Catalog profile", items)
            emit("catalogprofile." .. format .. ".widgets_ms", math.floor((gettime() - start) * 1000))
            require("services.cover_loader").stopLoading(b)
        end
    end
    steps[#steps + 1] = function()
        close_browser(p)
        c.finish()
    end
    return steps
end

local function catalogloading_steps()
    local c = checker("catalogloading")
    local gettime = require("socket").gettime
    local p, b
    local steps = {
        function()
            current = "catalogloading"
            p = plugin()
            close_window_with_text("rendered in color")
            close_window_with_text("cache database")
            b = open_browser()
        end,
        function(advance)
            local last, max_gap, ticks = gettime(), 0, 0
            local pulse
            pulse = function()
                local now = gettime()
                max_gap = math.max(max_gap, now - last)
                last, ticks = now, ticks + 1
                UIManager:scheduleIn(0.025, pulse)
            end
            UIManager:scheduleIn(0.025, pulse)
            UIManager:scheduleIn(0.05, function()
                b:openCatalog({ text = "Large slow catalog",
                    url = BASE .. "/opds/paged?size=5000&total=5000&delay=1.2" })
            end)
            wait_for(function() return #b.item_table == 5000 end, 15, function(done)
                max_gap = math.max(max_gap, gettime() - last)
                UIManager:unschedule(pulse)
                require("services.cover_loader").stopLoading(b)
                emit("catalogloading.ui_max_gap_ms", math.floor(max_gap * 1000))
                c.check("loads_all_entries", done and #b.item_table == 5000, #b.item_table)
                c.check("ui_remains_responsive", max_gap < 0.35 and ticks > 3, max_gap)
                advance()
            end)
            return "async"
        end,
    }
    for _, action in ipairs({ "back", "replace", "close" }) do
        steps[#steps + 1] = function(advance)
            if action == "back" then
                b:onGotoPage(3)
                UIManager:forceRePaint()
                shot("catalog_before_loading")
            end
            watch_forks(true)
            local first = #fork_pids + 1
            local old_items, old_paths, old_title = b.item_table, b.paths, b.catalog_title
            local old_depth = #b.paths
            local old_page = b.page
            local old_focus = b:getFocusedItemNumber()
            b:openCatalog({ text = "Obsolete", url = BASE .. "/opds/paged?size=7&total=7&delay=3" })
            UIManager:scheduleIn(0.1, function()
                if action == "back" then
                    shot("catalog_loading")
                    local start = gettime()
                    UIManager:handleInputEvent(require("ui/event"):new("KeyPress", require("device/key"):new("Back", {})))
                    c.check("back.cancels_promptly", not b._catalog_job and gettime() - start < 0.35)
                    c.check("back.keeps_listing_and_position", b.item_table == old_items and b.page == old_page
                        and old_page == 3 and b:getFocusedItemNumber() == old_focus)
                    c.check("back.keeps_history_and_title", b.paths == old_paths and #b.paths == old_depth
                        and b.catalog_title == old_title)
                elseif action == "replace" then
                    b:openCatalog({ text = "Replacement", url = BASE .. "/opds2/home" })
                else
                    close_browser(p)
                    c.check("close.cancels_request", not b._catalog_job and not p.opds_browser)
                end
                wait_for(function() return alive_children(first) == 0 and not b._catalog_job end, 10, function(clean)
                    c.check(action .. ".reaps_workers", clean)
                    c.check(action .. ".no_temporary_files", count_lua_tmp() == 0)
                    if action == "replace" then
                        c.check("replace.rejects_obsolete_result", find_item(b, "Staff picks") ~= nil
                            and b.catalog_title == "Replacement")
                        c.check("replace.adds_only_one_history_entry", #b.paths == old_depth + 1)
                    elseif action == "back" then
                        c.check("back.no_late_changes", b.item_table == old_items and #b.paths == old_depth)
                    else
                        c.check("close.no_late_changes", b.item_table == old_items and not p.opds_browser)
                    end
                    unwatch_forks()
                    advance()
                end)
            end)
            return "async"
        end
    end
    steps[#steps + 1] = function(advance)
        b = open_browser()
        local roots = b.item_table
        b:openCatalog({ text = "Missing", url = BASE .. "/missing-catalog" })
        wait_for(function() return not b._catalog_job end, 5, function(done)
            c.check("error.is_visible", done and window_has_text("Catalog not found"))
            c.check("error.keeps_root_state", b.item_table == roots and #b.paths == 0 and b.catalog_title == nil)
            close_window_with_text("Catalog not found")
            close_window_with_text("Cannot get catalog info")
            advance()
        end)
        return "async"
    end
    steps[#steps + 1] = function()
        local FFIUtil = require("ffi/util")
        local real_fork = FFIUtil.runInSubProcess
        ---@diagnostic disable-next-line: duplicate-set-field
        FFIUtil.runInSubProcess = function() return nil end
        b:openCatalog({ text = "Foreground fallback", url = BASE .. "/opds/paged?size=30&total=30" })
        FFIUtil.runInSubProcess = real_fork
        local prompt = UIManager:getTopmostVisibleWidget()
        c.check("fork_failure.asks_before_blocking", prompt and prompt.text
            and prompt.text:find("Background catalog loading is unavailable", 1, true) and #b.paths == 0)
        c.check("fork_failure.foreground_action_works", press_button(prompt, "Load") and #b.item_table == 30)
        close_browser(p)
        c.finish()
    end
    return steps
end

local EXTRA = {
    { name = "shots", steps = shots_steps, explicit = true },
    { name = "opds2", steps = opds2_steps },
    { name = "condget", steps = condget_steps },
    { name = "catalogprofile", steps = catalogprofile_steps, explicit = true },
    { name = "catalogloading", steps = catalogloading_steps },
    { name = "cwapaging", steps = cwapaging_steps, explicit = true },
    { name = "cwadownload", steps = cwadownload_steps, explicit = true },
    { name = "filenames", steps = filenames_steps },
    { name = "prefetch", steps = prefetch_steps },
    { name = "nontouch", steps = nontouch_steps },
    { name = "listcover", steps = listcover_steps },
    { name = "parcovers", steps = parcovers_steps },
    { name = "inputfairness", steps = inputfairness_steps },
    { name = "covermemory", steps = covermemory_steps },
    { name = "coverprefetch", steps = coverprefetch_steps },
    { name = "covergate", steps = covergate_steps },
    { name = "covers", steps = covers_steps },
    { name = "cachelib", steps = cachelib_steps },
    { name = "rels", steps = rels_steps },
    { name = "syncgesture", steps = syncgesture_steps },
    { name = "syncguards", steps = syncguards_steps },
    { name = "defaultcat", steps = defaultcat_steps },
    { name = "navcovers", steps = navcovers_steps },
    { name = "coverown", steps = coverown_steps },
    { name = "descsave", steps = descsave_steps },
    { name = "series", steps = series_steps },
    { name = "pdflinks", steps = pdflinks_steps },
    { name = "customheaders", steps = customheaders_steps },
    { name = "delsettings", steps = delsettings_steps },
    { name = "parandroid", steps = parandroid_steps },
}

local function selected(name)
    return not wanted or (("," .. wanted .. ","):find("," .. name .. ",", 1, true))
end

local function run_all()
    local steps = {}
    for _, sc in ipairs(SCENARIOS) do
        if selected(sc.name) then
            for _, s in ipairs(scenario_steps(sc)) do steps[#steps + 1] = s end
        end
    end
    for _, extra in ipairs(EXTRA) do
        if selected(extra.name) and (wanted or not extra.explicit) then
            for _, s in ipairs(extra.steps()) do steps[#steps + 1] = s end
        end
    end
    local i = 0
    local function nextstep()
        i = i + 1
        local step = steps[i]
        if not step then
            emit("done", 1)
            out:close()
            UIManager:quit(0)
            return
        end
        -- Sync steps continue automatically; steps returning "async" must call advance() themselves.
        local advanced = false
        local function advance()
            if advanced then return end
            advanced = true
            UIManager:scheduleIn(0.3, function()
                local p = find_plugin()
                local browser = p and p.opds_browser
                if browser and browser._catalog_job then
                    wait_for(function() return not browser._catalog_job end, 30, function(done)
                        if not done then
                            emit(current .. ".error", "catalog loading timed out")
                            browser:cancelCatalogLoad()
                        end
                        nextstep()
                    end)
                else
                    nextstep()
                end
            end)
        end
        local ok, res = xpcall(step, debug.traceback, advance)
        if not ok then
            emit(current .. ".error", res)
            advance()
        elseif res ~= "async" then
            advance()
        end
    end
    nextstep()
end

UIManager:scheduleIn(3, function()
    if not find_plugin() then
        emit("fatal", "opdsplus plugin instance not found on FileManager")
        out:close()
        UIManager:quit(1)
        return
    end
    if plugin():getSetting("ota_auto_check") ~= false then
        emit("fatal", "catalog kit requires automatic update checks to be disabled")
        out:close()
        UIManager:quit(1)
        return
    end
    emit("plugin_version", require("opds_plus_version").VERSION)
    run_all()
end)
