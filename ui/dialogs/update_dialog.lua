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
local TrapWidget = require("ui/widget/trapwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Constants = require("models.constants")
local OtaUpdater = require("services.ota_updater")
local ReleaseNotes = require("ui.dialogs.release_notes")

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
local check_generation = 0

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

-- Only plain data crosses the worker boundary. Settings and dialogs stay in the parent.
local function prepareCheck(updater, state)
	socketutil:set_timeout(Constants.OTA.CHECK_BLOCK_TIMEOUT, Constants.OTA.CHECK_TOTAL_TIMEOUT)
	local ok, packet = pcall(function()
		local connected = not not NetworkMgr:isConnected()
		if not connected or not NetworkMgr:isOnline() then
			return { offline = true, connected = connected }
		end
		local result, err, detail = updater:check(state)
		return { checked = true, result = result, error = err, detail = detail }
	end)
	socketutil:reset_timeout()
	if not ok then
		return { error = E.NETWORK, detail = packet }
	end
	return packet
end

function UpdateDialog.cancelCheck()
	check_generation = check_generation + 1
	if UpdateDialog._scheduled_check then
		UIManager:unschedule(UpdateDialog._scheduled_check)
		UpdateDialog._scheduled_check = nil
	end
	if UpdateDialog._check_job then UpdateDialog._check_job:cancel() end
end

local function startCheck(plugin, automatic, now)
	local updater, new_err = UpdateDialog.newUpdater(plugin)
	if not updater then
		logger.warn("OPDS+ OTA: cannot initialize check", new_err)
		if not automatic then showError(new_err) end
		return false
	end
	check_generation = check_generation + 1
	local generation = check_generation
	local job = { running = true, automatic = automatic }
	local widget = TrapWidget:new {
		text = not automatic and _("Checking for updates... (tap or press a key to cancel)") or nil,
		resend_event = automatic,
	}
	local state = automatic and {
		etag = plugin:getSetting(UpdateDialog.ETAG),
		skipped_version = plugin:getSetting(UpdateDialog.SKIPPED),
	} or {}
	job.widget = widget
	UpdateDialog._check_job = job

	function job:cancel()
		if self.cancelled then return end
		self.cancelled = true
		if UpdateDialog._check_job == self then UpdateDialog._check_job = nil end
		UIManager:unschedule(self.timeout)
		if self.running then widget.dismiss_callback() end
		if self.fallback then UIManager:close(self.fallback) end
	end
	function widget:_dismissAndResend(...)
		job.cancelled = true
		return TrapWidget._dismissAndResend(self, ...)
	end
	function widget:handleEvent(event)
		-- The native trap lists only some gestures; automatic checks must also yield pan and repeat events.
		if automatic and (event.handler == "onKeyPress" or event.handler == "onKeyRepeat"
			or event.handler == "onGesture") then
			return self:_dismissAndResend(event.handler:sub(3), event.args[1])
		end
		return TrapWidget.handleEvent(self, event)
	end
	function widget:onCloseWidget()
		if job.running then job:cancel() end
		return TrapWidget.onCloseWidget(self)
	end

	local function failed(err, detail)
		logger.warn("OPDS+ OTA: update check failed", err, detail)
		if not automatic then showError(err, detail, type(detail) == "table" and detail or nil) end
	end
	local function deliver(packet)
		if UpdateDialog._check_job ~= job then return end
		UpdateDialog._check_job = nil
		if job.cancelled or generation ~= check_generation or OtaUpdater.restart_pending then return end
		if type(packet) ~= "table" then
			failed(E.BAD_RESPONSE, "No result from update worker")
			return
		end
		if packet.offline then
			if not automatic then
				if not packet.connected then
					NetworkMgr:beforeWifiAction(function()
						if generation == check_generation and not OtaUpdater.restart_pending then
							UpdateDialog.checkNow(plugin)
						end
					end)
				else
					NetworkMgr:beforeWifiAction()
				end
			end
			return
		end
		if packet.checked then plugin:saveSetting(UpdateDialog.LAST_CHECK, now or os.time()) end
		local result = packet.result
		if not result then
			failed(packet.error or E.BAD_RESPONSE, packet.detail)
			return
		end
		if type(result) ~= "table" or (result.status ~= "update" and result.status ~= "skipped"
			and result.status ~= "up_to_date" and result.status ~= "not_modified") then
			failed(E.BAD_RESPONSE, "Invalid update worker result")
			return
		end
		if (result.status == "update" or result.status == "skipped")
			and (type(result.release) ~= "table" or type(result.release.version) ~= "string"
				or type(result.release.notes) ~= "string") then
			failed(E.BAD_RESPONSE, "Invalid release from update worker")
			return
		end
		if result.etag then plugin:saveSetting(UpdateDialog.ETAG, result.etag) end
		if automatic then
			if result.status == "update" and plugin:getSetting(UpdateDialog.AUTO_CHECK) ~= false
				and plugin:getSetting(UpdateDialog.SKIPPED) ~= result.release.version
				and plugin:getSetting(UpdateDialog.NOTIFIED) ~= result.release.version then
				plugin:saveSetting(UpdateDialog.NOTIFIED, result.release.version)
				UIManager:show(Notification:new {
					text = T(_("OPDS Plus %1 is available. Install it from Settings → Updates."), result.release.version),
				})
			end
		elseif result.status == "update" or result.status == "skipped" then
			UpdateDialog.showRelease(plugin, updater, result.release)
		else
			UIManager:show(InfoMessage:new {
				text = T(_("OPDS Plus %1 is up to date."), updater.current_version),
				timeout = 3,
			})
		end
	end
	job.timeout = function()
		if UpdateDialog._check_job ~= job then return end
		job:cancel()
		failed(E.NETWORK, "Update check timed out")
	end
	Trapper:wrap(function()
		UIManager:show(widget)
		if not automatic then UIManager:forceRePaint() end
		UIManager:scheduleIn(Constants.OTA.CHECK_TOTAL_TIMEOUT, job.timeout)
		local completed, packet = Trapper:dismissableRunInSubprocess(function()
			return prepareCheck(updater, state)
		end, widget)
		job.running = false
		UIManager:unschedule(job.timeout)
		UIManager:close(widget)
		if job.cancelled then
			if UpdateDialog._check_job == job then UpdateDialog._check_job = nil end
		elseif completed then
			deliver(packet)
		elseif automatic then
			UpdateDialog._check_job = nil
			failed(E.NETWORK, "Could not start update worker")
		else
			logger.warn("OPDS+ OTA: could not start update worker")
			job.fallback = ConfirmBox:new {
				text = _("Background update checking is unavailable. Check in the foreground instead? Input will pause until checking finishes."),
				ok_text = _("Check"),
				ok_callback = function()
					if not job.cancelled and generation == check_generation then
						deliver(prepareCheck(updater, state))
					end
				end,
				cancel_callback = function() job:cancel() end,
			}
			UIManager:show(job.fallback)
		end
	end)
	return true
end

--- Installs a release: preflight, download in a subprocess the user can cancel, then verify and swap here,
-- where nothing can interrupt the renames
function UpdateDialog.install(plugin, updater, release)
	if UpdateDialog.restartGate() then
		return
	end
	UpdateDialog.cancelCheck()
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
	local options = {
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
	}
	local ok, rendered = pcall(ReleaseNotes.new, options)
	if ok then
		viewer = rendered
		UIManager:show(viewer)
	else
		logger.warn("OPDS+ OTA: release notes rendering failed", rendered)
		UIManager:show(ConfirmBox:new {
			text = _("The release notes could not be formatted. View the original notes as plain text?"),
			ok_text = _("View as plain text"),
			ok_callback = function()
				options.text_format, options.force_txt = nil, true
				viewer = TextViewer:new(options)
				UIManager:show(viewer)
			end,
		})
	end
end

--- "Check for updates": asks to go online if needed, always gets a fresh answer, and shows a skipped
-- version too, since the user asked
function UpdateDialog.checkNow(plugin)
	if UpdateDialog.restartGate() then
		return
	end
	if UpdateDialog._check_job and not UpdateDialog._check_job.automatic then return end
	UpdateDialog.cancelCheck()
	startCheck(plugin, false)
end

--- The weekly check: only when it is on, a week has passed and the device is already online. Errors are
-- only logged; a new version is announced once, with a toast.
-- @param now number|nil os.time(), for specs
-- @return boolean whether a background check was started
function UpdateDialog.autoCheck(plugin, now)
	now = now or os.time()
	if plugin:getSetting(UpdateDialog.AUTO_CHECK) == false or OtaUpdater.restart_pending or UpdateDialog._check_job then
		return false
	end
	local last = tonumber(plugin:getSetting(UpdateDialog.LAST_CHECK)) or 0
	if last <= now and now - last < Constants.OTA.CHECK_INTERVAL_SECONDS then
		return false
	end
	return startCheck(plugin, true, now)
end

--- Schedules the weekly check once the catalog is on screen
function UpdateDialog.scheduleAutoCheck(plugin)
	if UpdateDialog._scheduled_check then UIManager:unschedule(UpdateDialog._scheduled_check) end
	local scheduled
	scheduled = function()
		if UpdateDialog._scheduled_check ~= scheduled then return end
		UpdateDialog._scheduled_check = nil
		local ok, err = pcall(UpdateDialog.autoCheck, plugin)
		if not ok then
			logger.warn("OPDS+ OTA: automatic check raised", err)
		end
	end
	UpdateDialog._scheduled_check = scheduled
	UIManager:scheduleIn(Constants.OTA.AUTO_CHECK_DELAY_SECONDS, scheduled)
end

--- "Roll back to previous version"
function UpdateDialog.rollback(plugin)
	if UpdateDialog.restartGate() then
		return
	end
	UpdateDialog.cancelCheck()
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
