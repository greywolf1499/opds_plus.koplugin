-- The in-app updater's UI: manual check, release dialog, install with a cancellable download, roll back,
-- the weekly automatic check and the restart gate. The work itself is in services/ota_updater.lua.
--
-- main.lua requires this module (and with it the updater) at startup, so nothing here is loaded from the
-- new files after an update has replaced them.

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Constants = require("models.constants")
local OtaUpdater = require("services.ota_updater")

local UpdateDialog = {}

local E = OtaUpdater.Errors

-- Setting keys
UpdateDialog.AUTO_CHECK = "ota_auto_check"
UpdateDialog.LAST_CHECK = "ota_last_check"
UpdateDialog.ETAG = "ota_etag"
UpdateDialog.SKIPPED = "ota_skipped_version"
UpdateDialog.NOTIFIED = "ota_notified_version"
UpdateDialog.ALLOW_DEV = "ota_allow_dev"

local CANCELLED = "cancelled"

--- An updater for the running plugin
-- @return table|nil updater, or nil and an error code
function UpdateDialog.newUpdater(plugin)
	return OtaUpdater.new({
		plugin_dir = plugin.path,
		cache_dir = DataStorage:getDataDir() .. "/cache",
		total_timeout = true,
	})
end

--- What to tell the user about an updater error
-- @param err string OtaUpdater.Errors value
-- @param detail any What came with it
-- @param release table|nil The release it was about, for its page link
function UpdateDialog.errorText(err, detail, release)
	local page = release and release.html_url or OtaUpdater.RELEASES_URL
	if err == E.NETWORK then
		return _("Could not reach GitHub. Check the connection and try again.")
	elseif err == E.TLS then
		return _("The secure connection to GitHub failed. If the date and time of this device are wrong, correct them and try again.")
	elseif err == E.RATE_LIMITED then
		if type(detail) == "number" then
			return T(_("GitHub's limit on update checks has been reached. Try again after %1."), os.date("%H:%M", detail))
		end
		return _("GitHub's limit on update checks has been reached. Try again in an hour.")
	elseif err == E.HTTP_ERROR then
		return T(_("GitHub answered with an error (%1). Try again later."), tostring(detail))
	elseif err == E.BAD_RESPONSE then
		return _("GitHub's answer could not be read. Try again later.")
	elseif err == E.NO_ASSET or err == E.NO_DIGEST then
		return T(_("This release can't be installed from here. Download it from its release page instead:\n%1"), page)
	elseif err == E.TOO_LARGE then
		return _("The update is larger than expected and was not installed.")
	elseif err == E.DIGEST_MISMATCH then
		return _("The downloaded update did not match its checksum and was deleted. Nothing was changed.")
	elseif err == E.DEV_INSTALL then
		return _("OPDS Plus is installed from a development checkout (a link, or a folder with .git in it). Update it with git, or allow updating a development install in Settings → Updates.")
	elseif err == E.READ_ONLY then
		return _("The plugins folder can't be written to, so the update can't be installed.")
	elseif err == E.LOW_SPACE then
		return _("There is not enough free space to install the update.")
	elseif err == E.ARCHIVE_UNSUPPORTED then
		return T(_("This KOReader can't open zip archives. Install the update by hand from:\n%1"), page)
	elseif err == E.INVALID_ARCHIVE or err == E.VALIDATION_FAILED then
		return _("The update is not valid and was not installed. Nothing was changed.")
	elseif err == E.KOREADER_TOO_OLD then
		return T(_("This update needs KOReader %1 or newer. Update KOReader first."), tostring(detail))
	elseif err == E.SWAP_FAILED then
		return _("The update could not be put in place. The installed version was kept.")
	elseif err == E.NO_BACKUP then
		return _("There is no previous version to roll back to.")
	elseif err == E.BAD_INSTALL_PATH then
		return _("OPDS Plus can't tell where it is installed, so it can't update itself.")
	elseif err == CANCELLED then
		return _("Update cancelled. Nothing was changed.")
	end
	return T(_("The update failed: %1"), tostring(err))
end

local function showError(err, detail, release)
	UIManager:show(InfoMessage:new({ text = UpdateDialog.errorText(err, detail, release) }))
end

--- Stops entry points from loading code once the files on disk are a different version
-- @return boolean true when a restart is needed (and was asked for)
function UpdateDialog.restartGate()
	if not OtaUpdater.restart_pending then
		return false
	end
	UIManager:askForRestart(_("OPDS Plus was updated. Restart KOReader to finish updating."))
	return true
end

-- Checks with short timeouts, keeping what the answer says for the next check
local function runCheck(plugin, updater, state, now)
	socketutil:set_timeout(Constants.OTA.CHECK_BLOCK_TIMEOUT, Constants.OTA.CHECK_TOTAL_TIMEOUT)
	local ok, result, err, detail = pcall(updater.check, updater, state)
	socketutil:reset_timeout()
	if not ok then
		logger.warn("OPDS+ OTA: check raised", result)
		return nil, E.NETWORK
	end
	plugin:saveSetting(UpdateDialog.LAST_CHECK, now or os.time())
	if result and result.etag then
		plugin:saveSetting(UpdateDialog.ETAG, result.etag)
	end
	return result, err, detail
end

--- Installs a release: preflight, download in a subprocess the user can cancel, then verify and swap here,
-- where nothing can interrupt the renames
function UpdateDialog.install(plugin, updater, release)
	if UpdateDialog.restartGate() then
		return
	end
	local ready, err, detail = updater:preflight(release, { allow_dev = plugin:getSetting(UpdateDialog.ALLOW_DEV) == true })
	if not ready then
		showError(err, detail, release)
		return
	end
	Trapper:wrap(function()
		local info = InfoMessage:new({ text = _("Downloading update… (tap to cancel)") })
		UIManager:show(info)
		UIManager:forceRePaint()
		local completed, digest, size, fetch_detail = Trapper:dismissableRunInSubprocess(function()
			return updater:fetch(release)
		end, info)
		if completed then
			UIManager:close(info)
		end
		if not completed or not digest then
			updater:cleanup()
			if completed then
				showError(size, fetch_detail, release)
			else
				showError(CANCELLED)
			end
			return
		end
		local installed, apply_err, apply_detail = updater:apply(release, digest, size)
		if not installed then
			showError(apply_err, apply_detail, release)
			return
		end
		plugin:saveSetting(UpdateDialog.SKIPPED, nil)
		UIManager:askForRestart(T(_("OPDS Plus %1 is installed. Restart KOReader to finish updating."), release.version))
	end)
end

--- Shows a release: its notes, and Install / Skip this version / Later
function UpdateDialog.showRelease(plugin, updater, release)
	local viewer
	viewer = TextViewer:new({
		title = T(_("OPDS Plus %1 is available"), release.version),
		text = release.notes ~= "" and release.notes or _("No release notes."),
		buttons_table = {
			{
				{
					text = _("Later"),
					callback = function()
						UIManager:close(viewer)
					end,
				},
				{
					text = _("Skip this version"),
					callback = function()
						plugin:saveSetting(UpdateDialog.SKIPPED, release.version)
						UIManager:close(viewer)
					end,
				},
				{
					text = _("Install"),
					callback = function()
						UIManager:close(viewer)
						UpdateDialog.install(plugin, updater, release)
					end,
				},
			},
		},
	})
	UIManager:show(viewer)
end

--- "Check for updates": asks to go online if needed, always gets a fresh answer, and shows a skipped
-- version too, since the user asked
function UpdateDialog.checkNow(plugin)
	if UpdateDialog.restartGate() then
		return
	end
	local updater, new_err = UpdateDialog.newUpdater(plugin)
	if not updater then
		showError(new_err)
		return
	end
	NetworkMgr:runWhenOnline(function()
		local info = InfoMessage:new({ text = _("Checking for updates…") })
		UIManager:show(info)
		UIManager:forceRePaint()
		local result, err, detail = runCheck(plugin, updater, {})
		UIManager:close(info)
		if not result then
			showError(err, detail, type(detail) == "table" and detail or nil)
		elseif result.status == "update" or result.status == "skipped" then
			UpdateDialog.showRelease(plugin, updater, result.release)
		else
			UIManager:show(InfoMessage:new({
				text = T(_("OPDS Plus %1 is up to date."), updater.current_version),
				timeout = 3,
			}))
		end
	end)
end

--- The weekly check: only when it is on, a week has passed and the device is already online. Errors are
-- only logged; a new version is announced once, with a toast.
-- @param now number|nil os.time(), for specs
-- @return boolean whether a check was made
function UpdateDialog.autoCheck(plugin, now)
	now = now or os.time()
	if plugin:getSetting(UpdateDialog.AUTO_CHECK) == false or OtaUpdater.restart_pending then
		return false
	end
	local last = tonumber(plugin:getSetting(UpdateDialog.LAST_CHECK)) or 0
	if last <= now and now - last < Constants.OTA.CHECK_INTERVAL_SECONDS then
		return false
	end
	if not NetworkMgr:isConnected() or not NetworkMgr:isOnline() then
		return false
	end
	local updater = UpdateDialog.newUpdater(plugin)
	if not updater then
		return false
	end
	local result, err, detail = runCheck(plugin, updater, {
		etag = plugin:getSetting(UpdateDialog.ETAG),
		skipped_version = plugin:getSetting(UpdateDialog.SKIPPED),
	}, now)
	if not result then
		logger.info("OPDS+ OTA: automatic check failed", err, detail)
		return true
	end
	if result.status == "update" and plugin:getSetting(UpdateDialog.NOTIFIED) ~= result.release.version then
		plugin:saveSetting(UpdateDialog.NOTIFIED, result.release.version)
		UIManager:show(Notification:new({
			text = T(_("OPDS Plus %1 is available. Install it from Settings → Updates."), result.release.version),
		}))
	end
	return true
end

--- Schedules the weekly check once the catalog is on screen
function UpdateDialog.scheduleAutoCheck(plugin)
	UIManager:scheduleIn(Constants.OTA.AUTO_CHECK_DELAY_SECONDS, function()
		local ok, err = pcall(UpdateDialog.autoCheck, plugin)
		if not ok then
			logger.warn("OPDS+ OTA: automatic check raised", err)
		end
	end)
end

--- "Roll back to previous version"
function UpdateDialog.rollback(plugin)
	if UpdateDialog.restartGate() then
		return
	end
	local updater, new_err = UpdateDialog.newUpdater(plugin)
	if not updater then
		showError(new_err)
		return
	end
	UIManager:show(ConfirmBox:new({
		text = _("Roll back to the previous version of OPDS Plus?\n\nThe current version is kept as the backup, so you can switch back."),
		ok_text = _("Roll back"),
		ok_callback = function()
			local ok, err, detail = updater:rollback()
			if not ok then
				showError(err, detail)
				return
			end
			UIManager:askForRestart(_("The previous version of OPDS Plus is back. Restart KOReader to finish."))
		end,
	}))
end

--- Whether a previous version is kept, for enabling "Roll back"
function UpdateDialog.hasBackup(plugin)
	local updater = UpdateDialog.newUpdater(plugin)
	return updater ~= nil and updater:hasBackup()
end

--- Removes what an interrupted update left behind; called at startup
function UpdateDialog.cleanupLeftovers(plugin)
	local updater = UpdateDialog.newUpdater(plugin)
	if updater then
		updater:cleanup()
	end
end

--- "Last checked: …" for the menu
function UpdateDialog.lastCheckedText(plugin)
	local last = tonumber(plugin:getSetting(UpdateDialog.LAST_CHECK))
	if not last then
		return _("Last checked: never")
	end
	return T(_("Last checked: %1"), os.date("%Y-%m-%d %H:%M", last))
end

return UpdateDialog
