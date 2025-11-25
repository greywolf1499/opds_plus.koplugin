-- Download Manager for OPDS Browser
-- Handles all file download operations, queuing, and progress tracking

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Constants = require("models.constants")

local DownloadManager = {}

-- Extract filetype from an acquisition link
-- @param link table Acquisition link with href and type
-- @return string|nil File extension or nil if unsupported
function DownloadManager.getFiletype(link)
	local filetype = util.getFileNameSuffix(link.href)
	if not DocumentRegistry:hasProvider("dummy." .. filetype) then
		filetype = nil
	end
	if not filetype and DocumentRegistry:hasProvider(nil, link.type) then
		filetype = DocumentRegistry:mimeToExt(link.type)
	end
	return filetype
end

-- Get the current download directory based on context
-- @param browser table OPDSBrowser instance
-- @return string Download directory path
function DownloadManager.getCurrentDownloadDir(browser)
	if browser.sync then
		return browser.settings.sync_dir
	else
		return G_reader_settings:readSetting("download_dir") or G_reader_settings:readSetting("lastdir")
	end
end

-- Build local download path for a file
-- @param browser table OPDSBrowser instance
-- @param filename string|nil Desired filename (nil to use server filename)
-- @param filetype string File extension
-- @param remote_url string URL to download from
-- @return string Local file path
function DownloadManager.getLocalDownloadPath(browser, filename, filetype, remote_url)
	local download_dir = DownloadManager.getCurrentDownloadDir(browser)

	filename = filename and filename .. "." .. filetype:lower()
		or browser:getServerFileName(remote_url, filetype)
	filename = util.getSafeFilename(filename, download_dir)
	filename = (download_dir ~= "/" and download_dir or "") .. '/' .. filename
	return util.fixUtf8(filename, "_")
end

-- Download a file from remote URL to local path
-- @param browser table OPDSBrowser instance
-- @param local_path string Local file path to save to
-- @param remote_url string URL to download from
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param caller_callback function|nil Callback function on success
-- @return boolean True if download succeeded
function DownloadManager.downloadFile(browser, local_path, remote_url, username, password, caller_callback)
	logger.dbg("Downloading file", local_path, "from", remote_url)
	local code, headers, status
	local parsed = url.parse(remote_url)

	if parsed.scheme == "http" or parsed.scheme == "https" then
		socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
		code, headers, status = socket.skip(1, http.request {
			url      = remote_url,
			headers  = {
				["Accept-Encoding"] = "identity",
			},
			sink     = ltn12.sink.file(io.open(local_path, "w")),
			user     = username,
			password = password,
		})
		socketutil:reset_timeout()
	else
		UIManager:show(InfoMessage:new {
			text = T(_("Invalid protocol:\n%1"), parsed.scheme),
		})
		return false
	end

	if code == 200 then
		logger.dbg("File downloaded to", local_path)
		if caller_callback then
			caller_callback(local_path)
		end
		return true
	elseif code == Constants.HTTP_STATUS.FOUND and remote_url:match("^https") and headers.location:match("^http[^s]") then
		util.removeFile(local_path)
		UIManager:show(InfoMessage:new {
			text = T(_("Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
				BD.url(remote_url), BD.url(headers.location)),
			icon = "notice-warning",
		})
	else
		util.removeFile(local_path)
		logger.dbg("DownloadManager:downloadFile: Request failed:", status or code)
		logger.dbg("DownloadManager:downloadFile: Response headers:", headers)
		UIManager:show(InfoMessage:new {
			text = T(_("Could not save file to:\n%1\n%2"),
				BD.filepath(local_path),
				status or code or "network unreachable"),
		})
	end

	return false
end

-- Check if file exists and prompt user, then download
-- @param browser table OPDSBrowser instance
-- @param local_path string Local file path to save to
-- @param remote_url string URL to download from
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param caller_callback function|nil Callback function on success
function DownloadManager.checkDownloadFile(browser, local_path, remote_url, username, password, caller_callback)
	local function download()
		UIManager:scheduleIn(Constants.UI_TIMING.DOWNLOAD_SCHEDULE_DELAY, function()
			DownloadManager.downloadFile(browser, local_path, remote_url, username, password, caller_callback)
		end)
		UIManager:show(InfoMessage:new {
			text = _("Downloading…"),
			timeout = Constants.UI_TIMING.NOTIFICATION_TIMEOUT,
		})
	end

	if lfs.attributes(local_path) then
		UIManager:show(ConfirmBox:new {
			text = T(_("The file %1 already exists. Do you want to overwrite it?"), BD.filepath(local_path)),
			ok_text = _("Overwrite"),
			ok_callback = function()
				download()
			end,
		})
	else
		download()
	end
end

-- Download all items in the download queue
-- @param browser table OPDSBrowser instance
-- @return number Count of successfully downloaded files
function DownloadManager.downloadDownloadList(browser)
	local info = InfoMessage:new { text = _("Downloading… (tap to cancel)") }
	UIManager:show(info)
	UIManager:forceRePaint()

	local completed, downloaded = Trapper:dismissableRunInSubprocess(function()
		local dl = {}
		for _, item in ipairs(browser.downloads) do
			if DownloadManager.downloadFile(browser, item.file, item.url, item.username, item.password) then
				dl[item.file] = true
			end
		end
		return dl
	end, info)

	if completed then
		UIManager:close(info)
	end

	local dl_count = #browser.downloads
	for i = dl_count, 1, -1 do
		local item = browser.downloads[i]
		if downloaded and downloaded[item.file] then
			table.remove(browser.downloads, i)
		else -- if subprocess has been interrupted, check for the downloaded file
			local attr = lfs.attributes(item.file)
			if attr then
				if attr.size > 0 then
					table.remove(browser.downloads, i)
				else -- incomplete download
					os.remove(item.file)
				end
			end
		end
	end

	dl_count = dl_count - #browser.downloads
	if dl_count > 0 then
		browser:updateDownloadListItemTable()
		browser.download_list_updated = true
		browser._manager.updated = true
		UIManager:show(InfoMessage:new {
			text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count)
		})
	end

	return dl_count
end

-- Download pending sync items
-- @param browser table OPDSBrowser instance
-- @param dl_list table List of items to download
-- @return table|nil List of duplicate files or nil
function DownloadManager.downloadPendingSyncs(browser, dl_list)
	local function dismissable_download()
		local info = InfoMessage:new { text = _("Downloading… (tap to cancel)") }
		UIManager:show(info)
		UIManager:forceRePaint()

		local completed, downloaded, duplicate_list = Trapper:dismissableRunInSubprocess(function()
			local dl = {}
			local dupe_list = {}
			for _, item in ipairs(dl_list) do
				if browser.sync_server_list[item.catalog] then
					if lfs.attributes(item.file) and not browser.sync_force then
						table.insert(dupe_list, item)
					else
						if DownloadManager.downloadFile(browser, item.file, item.url, item.username, item.password) then
							dl[item.file] = true
						end
					end
				end
			end
			return dl, dupe_list
		end, info)

		if completed then
			UIManager:close(info)
		end

		local dl_count = 0
		local dl_size = #dl_list
		for i = dl_size, 1, -1 do
			local item = dl_list[i]
			if downloaded and downloaded[item.file] then
				dl_count = dl_count + 1
				table.remove(dl_list, i)
			else -- if subprocess has been interrupted, check for the downloaded file
				local attr = lfs.attributes(item.file)
				if attr then
					if attr.size > 0 then
						table.remove(dl_list, i)
						-- Only count files touched within the freshness window
						if attr.modification > os.time() - Constants.SYNC.DOWNLOAD_FRESHNESS_SECONDS then
							dl_count = dl_count + 1
						end
					else -- incomplete download
						os.remove(item.file)
					end
				end
			end
		end

		local duplicate_count = duplicate_list and #duplicate_list or 0
		dl_count = dl_count - duplicate_count

		-- Make downloaded count timeout if there's a duplicate file prompt
		local timeout = nil
		if duplicate_count > 0 then
			timeout = Constants.UI_TIMING.DUPLICATE_NOTIFICATION_TIMEOUT
		end

		if dl_count > 0 then
			UIManager:show(InfoMessage:new {
				text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count),
				timeout = timeout,
			})
		end

		browser._manager.updated = true
		return duplicate_list
	end

	return dismissable_download()
end

-- Add item to download queue
-- @param browser table OPDSBrowser instance
-- @param download_item table Item with file, url, username, password, info, catalog
function DownloadManager.addToDownloadQueue(browser, download_item)
	table.insert(browser.downloads, download_item)
	browser._manager.updated = true
end

-- Remove item from download queue
-- @param browser table OPDSBrowser instance
-- @param index number Index of item to remove
function DownloadManager.removeFromDownloadQueue(browser, index)
	table.remove(browser.downloads, index)
	browser._manager.updated = true
end

-- Clear all items from download queue
-- @param browser table OPDSBrowser instance
function DownloadManager.clearDownloadQueue(browser)
	for i in ipairs(browser.downloads) do
		browser.downloads[i] = nil
	end
	browser.download_list_updated = true
	browser._manager.updated = true
end

return DownloadManager
