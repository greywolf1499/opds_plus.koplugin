local http = require("socket.http")
local HttpClient = require("services.http_client")
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

local OPDSPSE = {}

-- This function attempts to pull chapter progress from Kavita.
function OPDSPSE:getLastPage(remote_url, username, password)
    local parsed = type(remote_url) == "string" and url.parse(remote_url)
    if not parsed or not parsed.host or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        logger.warn("OPDSPSE:getLastPage: invalid stream URL")
        return 0
    end
    local prefix, api_key = (parsed.path or ""):match("^(.-)/api/opds/([^/]+)/image$")
    local chapter = parsed.query and ("&" .. parsed.query):match("&chapterId=([^&]+)")
    if not prefix or not api_key or not chapter or not chapter:match("^%d+$") then
        logger.dbg("OPDSPSE:getLastPage: no Kavita progress endpoint")
        return 0
    end
    local base = url.build { scheme = parsed.scheme, authority = parsed.authority, path = prefix }
    local progress_url = base .. "/api/Reader/get-progress?chapterId=" .. chapter
    local auth_url = base .. "/api/Plugin/authenticate?apiKey=" .. api_key .. "&pluginName=KOReader-OPDS"

    -- Do an HTTP POST to get the Bearer Token for authentication of the /api/Reader/get-progress endpoint
    local auth_data = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local auth_code = socket.skip(1, http.request {
        method = "POST",
        url = auth_url,
        redirect = false,
        headers = HttpClient.withCustomHeaders(auth_url, {
            ["Accept-Encoding"] = "identity",
            ["Authentication"] = api_key,
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
    if type(page) ~= "number" or page < 0 or page % 1 ~= 0 then
        logger.warn("OPDSPSE:getLastPage: invalid progress response")
        return 0
    end
    return page
end

function OPDSPSE:streamPages(remote_url, count, continue, username, password, last_page_read)
    local stream_address = type(remote_url) == "string" and url.parse(remote_url)
    if not stream_address or not stream_address.host or
        (stream_address.scheme ~= "http" and stream_address.scheme ~= "https") then
        logger.warn("OPDSPSE:streamPages: invalid stream URL")
        UIManager:show(InfoMessage:new { text = _("Invalid stream URL.") })
        return
    end
    -- attempt to pull chapter progress from Kavita if user pressed
    -- "Page Stream" button.
    -- We have to pull the progress here, otherwise the creation of the page_table
    -- will overwrite the book progress before we pull it, making it always 0.
    local ok, last_page = pcall(function() return self:getLastPage(remote_url, username, password) end)
    if not ok then
        logger.warn("Couldn't pull progress, defaulting to Page 0.")
        last_page = 0
    end
    local page_table = {image_disposable = true}
    setmetatable(page_table, {__index = function (_, key)
        if type(key) ~= "number" then
            local error_bb = RenderImage:renderImageFile("resources/koreader.png", false)
            return error_bb
        else
            local index = key - 1
            local page_url = remote_url:gsub("{pageNumber}", tostring(index))
            page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
            local page_data

            logger.dbg("Streaming page from", page_url)
            local code, headers, status
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local info
            code, headers, status, info = socket.skip(1, HttpClient.request({
                url         = page_url,
                headers     = { ["Accept-Encoding"] = "identity" },
                user        = username,
                password    = password,
            }))
            page_data = info.body
            socketutil:reset_timeout()

            local data = page_data or ""
            if code == 200 then
                local page_bb = RenderImage:renderImageData(data, #data, false)
                             or RenderImage:renderImageFile("resources/koreader.png", false)
                return page_bb
            else
                logger.dbg("OPDSBrowser:streamPages: Request failed:", status or code)
                logger.dbg("OPDSBrowser:streamPages: Response headers:", headers)
                local error_bb = RenderImage:renderImageFile("resources/koreader.png", false)
                return error_bb
            end
        end
    end})
    local ImageViewer = require("ui/widget/imageviewer")
    local viewer = ImageViewer:new{
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false, -- instead set page_table image_disposable to true
        images_list_nb = count,
    }
    UIManager:show(viewer)
    if continue then
        self:jumpToPage(viewer, count)
    elseif last_page_read then
        viewer:switchToImageNum(last_page_read)
    else
        -- add 1 since Kavita's Page count is zero based
        -- and ImageViewer is not.
        viewer:switchToImageNum(last_page+1)
    end
end

-- Shows a page number dialog for page streaming.
function OPDSPSE:jumpToPage(viewer, count)
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
                        local page_num = input_dialog:getInputValue()
                        if page_num then
                            UIManager:close(input_dialog)
                            viewer:switchToImageNum(math.min(math.max(1, page_num), count))
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
