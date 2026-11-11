local http = require("socket.http")
local HttpClient = require("services.http_client")
local CatalogUtils = require("utils.catalog_utils")
local UriTemplate = require("utils.uri_template")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JsonDecode = require("utils.json_decode")
local logger = require("logger")
local ltn12 = require("ltn12")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local socket = require("socket")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local url = require("socket.url")
local _ = require("gettext")

local OPDSPSE = { MAX_SAVED_STREAMS = 500 }

local function kavitaStream(remote_url)
    local parsed = type(remote_url) == "string" and url.parse(remote_url)
    if not parsed or not parsed.host or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        return nil
    end
    local prefix, api_key = (parsed.path or ""):match("^(.-)/api/opds/([^/]+)/image$")
    if not prefix then return nil end
    local chapter = parsed.query and ("&" .. parsed.query):match("&chapterId=([^&]+)")
    if not chapter or not chapter:match("^%d+$") or not CatalogUtils.pageNumber(chapter) then
        return nil, "Invalid Kavita chapter identity"
    end
    return {
        base = url.build { scheme = parsed.scheme, authority = parsed.authority, path = prefix },
        api_key = UriTemplate.expand("{key}", { key = url.unescape(api_key) }),
        chapter = chapter,
    }
end

-- This function attempts to pull chapter progress from Kavita.
function OPDSPSE:getLastPage(remote_url, username, password)
    local provider, err = kavitaStream(remote_url)
    if not provider then
        if err then logger.warn("OPDSPSE:getLastPage:", err) end
        logger.dbg("OPDSPSE:getLastPage: no Kavita progress endpoint")
        return 0
    end
    local progress_url = provider.base .. "/api/Reader/get-progress?chapterId=" .. provider.chapter
    local auth_url = provider.base .. "/api/Plugin/authenticate?apiKey=" .. provider.api_key .. "&pluginName=KOReader-OPDS"

    -- Do an HTTP POST to get the Bearer Token for authentication of the /api/Reader/get-progress endpoint
    local auth_data = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local auth_code = socket.skip(1, http.request {
        method = "POST",
        url = auth_url,
        redirect = false,
        headers = HttpClient.withCustomHeaders(auth_url, {
            ["Accept-Encoding"] = "identity",
            ["Authentication"] = url.unescape(provider.api_key),
        }),
        sink = ltn12.sink.table(auth_data),
        user = username,
        password = password,
    })
    socketutil:reset_timeout()
    if auth_code ~= 200 then
        logger.warn("OPDSPSE:getLastPage: authentication request failed")
        return 0
    end

    local auth = JsonDecode.decode(table.concat(auth_data))
    if type(auth) ~= "table" or type(auth.token) ~= "string" or auth.token == "" then
        logger.warn("OPDSPSE:getLastPage: invalid authentication response")
        return 0
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    -- HttpClient keeps the token and credentials on their original server across redirects.
    local code, headers, status, info = socket.skip(1, HttpClient.request({
        url = progress_url,
        headers = {
            ["Accept-Encoding"] = "identity",
            ["Authorization"] = "Bearer " .. auth.token,
        },
        user = username,
        password = password,
    }))
    socketutil:reset_timeout()
    if not headers or code ~= 200 then
        logger.warn("OPDSPSE:getLastPage: progress request failed:", status or code)
        return 0
    end
    local progress = JsonDecode.decode(info.body)
    local page = type(progress) == "table" and progress.pageNum
    if type(page) ~= "number" or not CatalogUtils.pageNumber(page + 1) then
        logger.warn("OPDSPSE:getLastPage: invalid progress response")
        return 0
    end
    return page
end

function OPDSPSE:openBook(browser, item, acquisition, choose_page, use_feed_position)
    if type(acquisition.href) ~= "string" then
        return self:streamPages(acquisition.href, acquisition.count, choose_page)
    end
    local settings = browser.settings
    if type(settings) ~= "table" then
        logger.warn("OPDSPSE: local resume storage is unavailable")
        return self:streamPages(acquisition.href, acquisition.count, choose_page,
            browser.root_catalog_username, browser.root_catalog_password, acquisition.last_read)
    end
    if settings.stream_progress ~= nil and type(settings.stream_progress) ~= "table" then
        logger.warn("OPDSPSE: invalid local resume storage")
        settings.stream_progress = nil
    end
    local records = settings.stream_progress or {}
    local identity = type(item.id) == "string" and item.id ~= "" and item.id or acquisition.href
    local key = require("ffi/sha2").sha256(table.concat({
        browser.root_catalog_url or acquisition.href, browser.root_catalog_username or "", identity,
    }, "\0"))
    local saved = records[key]
    local position = acquisition.last_read
    if not use_feed_position and type(saved) == "table" then
        local saved_page = CatalogUtils.pageNumber(saved.page)
        if not saved_page then logger.warn("OPDSPSE: invalid saved stream position") end
        position = saved_page or position
    end
    local dirty = false
    return self:streamPages(acquisition.href, acquisition.count, choose_page,
        browser.root_catalog_username, browser.root_catalog_password, position, {
            on_page = function(page)
                records[key] = { page = page, updated = os.time() }
                settings.stream_progress = records
                dirty = true
                local size = 0
                for record_key in pairs(records) do
                    if record_key ~= key then size = size + 1 end
                end
                while size >= self.MAX_SAVED_STREAMS do
                    local oldest, oldest_time
                    for record_key, record in pairs(records) do
                        local stamp = type(record) == "table" and tonumber(record.updated) or 0
                        stamp = stamp or 0
                        if record_key ~= key and (not oldest or stamp < oldest_time) then
                            oldest, oldest_time = record_key, stamp
                        end
                    end
                    records[oldest] = nil
                    size = size - 1
                end
            end,
            on_flush = function()
                if dirty then
                    if browser._manager then
                        browser._manager:saveSetting("stream_progress", records)
                    else
                        logger.warn("OPDSPSE: local progress could not be flushed without a settings manager")
                    end
                    dirty = false
                end
            end,
        })
end

function OPDSPSE:streamPages(remote_url, count, continue, username, password, last_page_read, options)
    local stream_address = type(remote_url) == "string" and url.parse(remote_url)
    if not stream_address or not stream_address.host or
        (stream_address.scheme ~= "http" and stream_address.scheme ~= "https") then
        logger.warn("OPDSPSE:streamPages: invalid stream URL")
        UIManager:show(InfoMessage:new { text = _("Invalid stream URL.") })
        return
    end
    count = CatalogUtils.pageNumber(count)
    if not count then
        logger.warn("OPDSPSE: invalid stream page count")
        UIManager:show(InfoMessage:new { text = _("Invalid stream page count.") })
        return
    end
    if count > 1 and not remote_url:find("{pageNumber}", 1, true) then
        logger.warn("OPDSPSE: missing page-number template")
        UIManager:show(InfoMessage:new { text = _("Invalid stream URL.") })
        return
    end
    local provider, provider_error = kavitaStream(remote_url)
    if provider_error then
        logger.warn("OPDSPSE:", provider_error)
        UIManager:show(InfoMessage:new { text = _("Invalid stream URL.") })
        return
    end
    if continue then
        self:jumpToPage(nil, count, function(page)
            self:streamPages(remote_url, count, false, username, password, page, options)
        end)
        return
    end
    local initial_page = CatalogUtils.pageNumber(last_page_read)
    if last_page_read ~= nil and not initial_page then logger.warn("OPDSPSE: invalid resume position") end
    if not initial_page and provider then
        local ok, page = pcall(self.getLastPage, self, remote_url, username, password)
        if ok then
            initial_page = CatalogUtils.pageNumber(page + 1)
        else
            logger.warn("OPDSPSE: progress lookup failed; starting at the first page")
        end
    end
    initial_page = initial_page or 1
    if initial_page > count then
        logger.warn("OPDSPSE: resume position exceeds page count")
        initial_page = count
    end
    -- ImageViewer asks for index 1 during initialization, before we can set its resume cursor.
    local initializing, closed, loaded_page = true, false, nil
    local request_generation = 0
    local page_table = {image_disposable = true}
    setmetatable(page_table, {__index = function (_pages, key)
        if type(key) ~= "number" then return nil end
        if not CatalogUtils.pageNumber(key) or key > count then
            logger.warn("OPDSPSE: page outside stream bounds")
            return nil
        end
        local page = initializing and key == 1 and initial_page or key
        request_generation = request_generation + 1
        local generation = request_generation
        local index = string.format("%.0f", page - 1)
        local page_url
        if provider then
            -- Kavita's OPDS image GET writes progress, even in versions accepting saveProgress=false.
            page_url = provider.base .. "/api/Reader/image?chapterId=" .. provider.chapter
                .. "&page=" .. index .. "&apiKey=" .. provider.api_key .. "&extractPdf=true"
        else
            page_url = remote_url:gsub("{pageNumber}", index)
            page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
        end
        logger.dbg("OPDSPSE: streaming page", page)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code, headers, status, info = socket.skip(1, HttpClient.request({
            url = page_url,
            headers = { ["Accept-Encoding"] = "identity" },
            user = username,
            password = password,
        }))
        socketutil:reset_timeout()
        local data = info.body or ""
        local image = code == 200 and headers and RenderImage:renderImageData(data, #data, false)
        loaded_page = image and page or nil
        if image then return image end
        logger.warn("OPDSPSE: page could not be loaded", code, status)
        UIManager:nextTick(function()
            if not closed and generation == request_generation then
                UIManager:show(InfoMessage:new { text = _("Could not load this page. Reading progress was not changed.") })
            end
        end)
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end})
    local ImageViewer = require("ui/widget/imageviewer")
    local viewer = ImageViewer:new{
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false, -- instead set page_table image_disposable to true
        images_list_nb = count,
    }
    initializing = false
    viewer._images_list_cur = initial_page
    if initial_page ~= 1 then viewer:update() end
    local recorded_page
    function viewer:paintTo(...)
        ImageViewer.paintTo(self, ...)
        if options and options.on_page and loaded_page == self._images_list_cur and recorded_page ~= loaded_page then
            recorded_page = loaded_page
            options.on_page(loaded_page)
        end
    end
    function viewer:onSuspend()
        if options and options.on_flush then options.on_flush() end
    end
    function viewer:onCloseWidget()
        closed = true
        self:onSuspend()
        return ImageViewer.onCloseWidget(self)
    end
    UIManager:show(viewer)
    return viewer
end

-- Shows a page number dialog for page streaming.
function OPDSPSE:jumpToPage(viewer, count, on_select)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Enter page number"),
        input_type = "number",
        input_hint = "(" .. "1 - " .. count .. ")",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Stream"),
                    is_enter_default = true,
                    callback = function()
                        local page_num = CatalogUtils.pageNumber(input_dialog:getInputText())
                        if page_num and page_num <= count then
                            UIManager:close(input_dialog)
                            if on_select then on_select(page_num) else viewer:switchToImageNum(page_num) end
                        else
                            UIManager:show(InfoMessage:new { text = _("Enter a whole page number within the displayed range.") })
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return OPDSPSE
