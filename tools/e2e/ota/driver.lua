-- KOReader user patch for the OTA e2e run: tools/e2e/ota/run.sh installs it as patches/2-ota-e2e.lua.
--
-- It drives the real update UI of the installed plugin against tools/e2e/ota/mock_github.py and writes one
-- line per check to $OTA_E2E_OUT: "PASS <name>" or "FAIL <name>: <why>", then "DONE".
-- OTA_E2E_PHASE picks the checks: "update" (first start), "rollback" (after the update), "rolled_back".
--
-- Only updater requests are sent to the mock: they are the ones made with OtaUpdater.isAllowedHost as the
-- host policy. Nothing here deletes anything; the launcher owns the work directory.
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local PHASE = os.getenv("OTA_E2E_PHASE")
local BASE = os.getenv("OTA_E2E_BASE")
local OUT = os.getenv("OTA_E2E_OUT")
local WORK = os.getenv("OTA_E2E_WORK")
local OLD = os.getenv("OTA_E2E_OLD_VERSION")
local NEW = os.getenv("OTA_E2E_NEW_VERSION")
if not (PHASE and BASE and OUT and WORK and OLD and NEW) then
	return
end
-- The launcher's work dir is the only place this patch may touch
assert(WORK:match("^/tmp/opds_plus_test_e2e%.[%w]+$"), "unexpected work dir " .. WORK)

local out = assert(io.open(OUT, "a"))
local function report(line)
	out:write(line, "\n")
	out:flush()
	logger.info("OTA e2e:", line)
end

local failures = 0
local function check(name, ok, why)
	if ok then
		report("PASS " .. name)
	else
		failures = failures + 1
		report("FAIL " .. name .. ": " .. tostring(why))
	end
end

local function finish()
	report(failures == 0 and "DONE" or ("DONE with " .. failures .. " failures"))
	out:close()
	UIManager:quit(0)
end

local function setMode(mode)
	local http = require("socket.http")
	local body, code = http.request(BASE .. "/__mode?m=" .. mode)
	assert(code == 200, "mock did not take mode " .. mode .. ": " .. tostring(body))
end

local function versionIn(dir)
	local chunk = loadfile(dir .. "/opds_plus_version.lua")
	if not chunk then
		return nil
	end
	local ok, value = pcall(chunk)
	return ok and type(value) == "table" and value.VERSION or nil
end

local function exists(path)
	return lfs.symlinkattributes(path, "mode") ~= nil
end

-- Runs the steps in order; a step may return a function, which is polled every 200 ms until it returns
-- true (or for `limit` seconds), before the next step starts
local function sequence(steps)
	local index = 0
	local function nextStep()
		index = index + 1
		local step = steps[index]
		if not step then
			return finish()
		end
		local ok, wait, limit = pcall(step.run)
		if not ok then
			check(step.name, false, "raised: " .. tostring(wait))
			return UIManager:scheduleIn(0.2, nextStep)
		end
		if type(wait) ~= "function" then
			return UIManager:scheduleIn(0.2, nextStep)
		end
		local deadline = os.time() + (limit or 60)
		local function poll()
			local done_ok, done = pcall(wait)
			if done_ok and done then
				return UIManager:scheduleIn(0.2, nextStep)
			end
			if not done_ok or os.time() > deadline then
				check(step.name, false, done_ok and "timed out" or ("raised: " .. tostring(done)))
				return UIManager:scheduleIn(0.2, nextStep)
			end
			UIManager:scheduleIn(0.2, poll)
		end
		UIManager:scheduleIn(0.2, poll)
	end
	nextStep()
end

local function start()
	local FileManager = require("apps/filemanager/filemanager")
	local plugin = FileManager.instance and FileManager.instance.opds_plus
	if not plugin then
		check("plugin loaded", false, "FileManager.instance.opds_plus is missing")
		return finish()
	end
	local UpdateDialog = package.loaded["ui.dialogs.update_dialog"]
	local OtaUpdater = package.loaded["services.ota_updater"]
	local HttpClient = package.loaded["services.http_client"]
	if not (UpdateDialog and OtaUpdater and HttpClient) then
		check("plugin modules", false, "update modules are not loaded")
		return finish()
	end

	local plugin_dir = plugin.path
	local backup_dir = plugin_dir .. ".bak"
	local staging_dir = plugin_dir .. ".new"
	assert(plugin_dir:sub(1, #WORK + 1) == WORK .. "/", "plugin is not inside the work dir: " .. plugin_dir)

	-- Loopback instead of GitHub, for updater requests only
	local FFIUtil = require("ffi/util")
	local gettime = require("socket").gettime
	local parent_pid = tonumber(require("ffi").C.getpid())
	local probe_delay, request_delay = 0, 0
	local function delayed(stage, seconds)
		if seconds == 0 then return end
		local handle = assert(io.open(WORK .. "/check_workers.log", "a"))
		handle:write(stage, " ", tostring(tonumber(require("ffi").C.getpid())), "\n")
		handle:close()
		FFIUtil.usleep(seconds * 1000000)
	end
	local real_request = HttpClient.request
	local updater_requests = 0
	HttpClient.request = function(request, options)
		if options and options.allow_host == OtaUpdater.isAllowedHost then
			updater_requests = updater_requests + 1
			if request.url == OtaUpdater.LATEST_URL then delayed("request", request_delay) end
			request.url = request.url:gsub("^https://api%.github%.com/", BASE .. "/api/")
				:gsub("^https://github%.com/", BASE .. "/gh/")
			request.create, request.verify, request.cafile = nil, nil, nil
			options.https_only = false
			options.allow_host = function(host)
				return host == "127.0.0.1"
			end
		end
		return real_request(request, options)
	end

	-- The emulator has no Wi-Fi to ask about
	local NetworkMgr = require("ui/network/manager")
	local connected, online, wifi_actions = true, true, 0
	NetworkMgr.isConnected = function()
		return connected
	end
	NetworkMgr.isOnline = function()
		delayed("probe", probe_delay)
		return online
	end
	NetworkMgr.beforeWifiAction = function()
		wifi_actions = wifi_actions + 1
	end

	-- Record what the user would see; a restart prompt is recorded, never shown (it would restart KOReader)
	local shown, restarts = {}, {}
	local real_show = UIManager.show
	UIManager.show = function(self, widget, ...)
		shown[#shown + 1] = widget
		return real_show(self, widget, ...)
	end
	UIManager.askForRestart = function(_, message)
		restarts[#restarts + 1] = message
	end
	local function lastText(pattern)
		for index = #shown, 1, -1 do
			local text = shown[index].text
			if type(text) == "string" and text:find(pattern) then
				return text
			end
		end
	end
	local function topmost(kind_field)
		for index = #UIManager._window_stack, 1, -1 do
			local widget = UIManager._window_stack[index].widget
			if widget[kind_field] then
				return widget
			end
		end
	end
	local function press(viewer, label)
		for _, row in ipairs(viewer.buttons_table or {}) do
			for _, button in ipairs(row) do
				if button.text == label then
					return button.callback()
				end
			end
		end
		error("no button " .. label)
	end
	local function noLeftovers()
		local cache = require("datastorage"):getDataDir() .. "/cache/opds_plus.koplugin.zip"
		return not exists(staging_dir) and not exists(cache)
	end

	local steps = {}
	local function step(name, run)
		steps[#steps + 1] = { name = name, run = run }
	end

	if PHASE == "update" then
		step("installed version", function()
			check("installed version", versionIn(plugin_dir) == OLD, versionIn(plugin_dir))
		end)

		local Device = require("device")
		local Event = require("ui/event")
		local Key = require("device/key")
		local FocusManager = require("ui/widget/focusmanager")
		local TextViewer = require("ui/widget/textviewer")
		local notes = "# Release highlights\n\n"
			.. "- **Readable notes** with headings and lists.\n"
			.. "- Keep the `Install`, `Skip this version` and `Later` controls.\n\n"
			.. "[Release page](" .. BASE .. "/notes-resource-link)\n\n"
			.. "![Remote image](" .. BASE .. "/notes-resource.png)\n\n"
			.. string.rep("## More changes\n\nLong notes remain complete and can be read with the page keys.\n\n", 40)
			.. "End of release notes.\n"
		local release = { version = NEW, notes = notes }
		local notes_updater = assert(UpdateDialog.newUpdater(plugin))

		local function withNotesUI(mode, run)
			local formats = TextViewer.html_text_formats
			local text_types = G_reader_settings:readSetting("textviewer_text_types")
			local keys, dpad, touch = Device.hasKeys, Device.hasDPad, Device.isTouchDevice
			local focus = FocusManager.FOCUS_ONLY_ON_NT
			Device.hasKeys, Device.hasDPad = function() return true end, function() return true end
			Device.isTouchDevice = function() return false end
			FocusManager.FOCUS_ONLY_ON_NT = 0
			local key_mapper = FocusManager:new {}
			key_mapper:onPhysicalKeyboardConnected()
			if mode == "compat" then
				TextViewer.html_text_formats = nil
				G_reader_settings:saveSetting("textviewer_text_types", {
					general = { font_size = 21, justified = true, monospace_font = true },
				})
			end
			local ok, err = pcall(run)
			TextViewer.html_text_formats = formats
			G_reader_settings:saveSetting("textviewer_text_types", text_types)
			Device.hasKeys, Device.hasDPad, Device.isTouchDevice = keys, dpad, touch
			FocusManager.FOCUS_ONLY_ON_NT = focus
			key_mapper:onPhysicalKeyboardDisconnected()
			assert(ok, err)
		end
		local function key(viewer, name)
			return viewer:handleEvent(Event:new("KeyPress", Key:new(name, {})))
		end
		local function pageText(box, number)
			local page = box.document:openPage(number)
			local lines = page:getPageText()
			page:close()
			local words = {}
			for _, line in ipairs(lines) do
				for _, word in ipairs(line) do words[#words + 1] = word.word end
			end
			return table.concat(words, " ")
		end

		for _, mode in ipairs({ "native", "compat" }) do
			step("release notes " .. mode, function()
				withNotesUI(mode, function()
					UpdateDialog.showRelease(plugin, notes_updater, release)
					local viewer = topmost("buttons_table")
					local box = assert(viewer.scroll_widget.htmlbox_widget, "not an HTML viewer")
					local text = pageText(box, 1)
					check(mode .. " Markdown text", text:find("Release highlights", 1, true)
						and text:find("Readable notes", 1, true) and not text:find("**", 1, true), text)
					check(mode .. " long notes", box.page_count > 5
						and pageText(box, box.page_count):find("End of release notes.", 1, true), box.page_count)
					check(mode .. " links inactive", not box.html_link_tapped_callback
						and not viewer.scroll_widget.html_resource_directory)
					if mode == "compat" then
						check("compat font preferences", viewer.scroll_widget.default_font_size == Device.screen:scaleBySize(21)
							and viewer.scroll_widget.css:find("monospace", 1, true)
							and viewer.scroll_widget.css:find("justify", 1, true))
					end
					for index = #UIManager._window_stack, 1, -1 do
						local widget = UIManager._window_stack[index].widget
						if type(widget.text) == "string" and widget.text:find("Documents will be rendered", 1, true) then
							UIManager:close(widget)
						end
					end
					UIManager:forceRePaint()
					check(mode .. " fits screen", viewer.frame.dimen.y >= 0
						and viewer.frame.dimen.y + viewer.frame.dimen.h <= Device.screen:getHeight())
					Device.screen:shot(WORK .. "/release_notes_" .. mode .. ".png")
					key(viewer, Device.input.group.PgFwd[1])
					check(mode .. " keyboard forward", box.page_number == 2, box.page_number)
					key(viewer, Device.input.group.PgBack[1])
					check(mode .. " keyboard backward", box.page_number == 1, box.page_number)
					press(viewer, "Later")
					check(mode .. " Later keeps version", not plugin:getSetting(UpdateDialog.SKIPPED)
						and versionIn(plugin_dir) == OLD)

					UpdateDialog.showRelease(plugin, notes_updater, release)
					viewer = topmost("buttons_table")
					UIManager:forceRePaint()
					viewer.button_table:moveFocusTo(1, #viewer.button_table.layout)
					key(viewer, "Right")
					check(mode .. " keyboard focus moves", viewer.button_table.selected.x == 2,
						viewer.button_table.selected.x)
					key(viewer, "Press")
					check(mode .. " keyboard Skip", plugin:getSetting(UpdateDialog.SKIPPED) == NEW)
					plugin:saveSetting(UpdateDialog.SKIPPED, nil)

					local install, installed = UpdateDialog.install, false
					UpdateDialog.install = function(p, u, r)
						installed = p == plugin and u == notes_updater and r == release
					end
					local ok, err = pcall(function()
						UpdateDialog.showRelease(plugin, notes_updater, release)
						press(topmost("buttons_table"), "Install")
					end)
					UpdateDialog.install = install
					assert(ok, err)
					check(mode .. " Install dispatch", installed)
					check(mode .. " dispatch test changes nothing", versionIn(plugin_dir) == OLD)

					UpdateDialog.showRelease(plugin, notes_updater, release)
					viewer = topmost("buttons_table")
					key(viewer, "Back")
					local closed = true
					for _, entry in ipairs(UIManager._window_stack) do
						if entry.widget == viewer then closed = false end
					end
					check(mode .. " Back closes", closed)
				end)
			end)

			step("release notes error " .. mode, function()
				withNotesUI(mode, function()
					local Converter = require("apps/filemanager/filemanagerconverter")
					local convert = Converter.mdToHtml
					Converter.mdToHtml = function() error("injected Markdown rendering failure") end
					local ok, err = pcall(UpdateDialog.showRelease, plugin, notes_updater, release)
					Converter.mdToHtml = convert
					assert(ok, err)
					local confirm = topmost("ok_callback")
					check(mode .. " render failure explained", confirm and confirm.text:find("could not be formatted"))
					confirm.ok_callback()
					UIManager:close(confirm)
					local viewer = topmost("buttons_table")
					check(mode .. " explicit plain text", viewer.force_txt and viewer.text == notes
						and viewer.scroll_widget.text_widget and not viewer.scroll_widget.htmlbox_widget)
					UIManager:forceRePaint()
					if mode == "native" then Device.screen:shot(WORK .. "/release_notes_plain.png") end
					press(viewer, "Later")
				end)
			end)
		end

		local live_workers = {}
		local spawned = 0
		local real_spawn, real_done = FFIUtil.runInSubProcess, FFIUtil.isSubProcessDone
		-- Instrument owned workers; restore both native functions in the final collection step.
		---@diagnostic disable-next-line: duplicate-set-field
		FFIUtil.runInSubProcess = function(...)
			local pid, fd = real_spawn(...)
			if pid then live_workers[pid], spawned = true, spawned + 1 end
			return pid, fd
		end
		---@diagnostic disable-next-line: duplicate-set-field
		FFIUtil.isSubProcessDone = function(pid)
			local done = real_done(pid)
			if done then live_workers[pid] = nil end
			return done
		end
		local function heartbeat()
			local ticks, gap, last = 0, 0, gettime()
			local tick
			tick = function()
				local now = gettime()
				ticks, gap, last = ticks + 1, math.max(gap, now - last), now
				UIManager:scheduleIn(0.02, tick)
			end
			UIManager:scheduleIn(0.02, tick)
			return function(label)
				UIManager:unschedule(tick)
				report("INFO " .. label .. " timer gap ms: " .. math.floor(gap * 1000))
				check(label .. " timer remains responsive", ticks >= 10 and gap <= 0.35, gap)
			end
		end
		for _, mode in ipairs({ "automatic", "manual" }) do
			step(mode .. " slow check", function()
				setMode("same")
				plugin:saveSetting(UpdateDialog.LAST_CHECK, 0)
				probe_delay, request_delay = 0.4, 0.6
				local stop = heartbeat()
				local started = gettime()
				if mode == "automatic" then UpdateDialog.autoCheck(plugin) else UpdateDialog.checkNow(plugin) end
				check(mode .. " check returns promptly", gettime() - started <= 0.35)
				local count = spawned
				if mode == "automatic" then UpdateDialog.autoCheck(plugin) else UpdateDialog.checkNow(plugin) end
				check(mode .. " duplicate check coalesced", spawned == count)
				return function()
					if UpdateDialog._check_job then return false end
					stop(mode)
					check(mode .. " check publishes parent state", plugin:getSetting(UpdateDialog.LAST_CHECK) > 0)
					probe_delay, request_delay = 0, 0
					return true
				end
			end)
		end
		step("check work stays in children", function()
			local handle = assert(io.open(WORK .. "/check_workers.log", "r"))
			local trace = handle:read("*a")
			handle:close()
			local count, child_only = 0, true
			for pid in trace:gmatch("%a+ (%d+)") do
				count = count + 1
				if tonumber(pid) == parent_pid then child_only = false end
			end
			check("probes and requests use workers", count == 4 and child_only, trace)
		end)
		for _, kind in ipairs({ "KeyPress", "Gesture" }) do
			step("automatic interruption preserves " .. kind, function()
				local InputContainer = require("ui/widget/container/inputcontainer")
				local received = 0
				local receiver = InputContainer:new { invisible = true, modal = true }
				function receiver:onKeyPress(key_event)
					if key_event:match({ "Down" }) then received = received + 1 end
					return true
				end
				function receiver:onGesture(gesture)
					if gesture.ges == "pan" then received = received + 1 end
					return true
				end
				UIManager:show(receiver)
				plugin:saveSetting(UpdateDialog.LAST_CHECK, 0)
				probe_delay = 2
				UpdateDialog.autoCheck(plugin)
				local event = kind == "KeyPress" and Key:new("Down", {}) or { ges = "pan" }
				UIManager:handleInputEvent(Event:new(kind, event))
				return function()
					if received == 0 then return false end
					check("automatic " .. kind .. " forwarded exactly once", received == 1)
					check("automatic check cancelled", not UpdateDialog._check_job)
					check("cancelled check leaves state alone", plugin:getSetting(UpdateDialog.LAST_CHECK) == 0)
					probe_delay = 0
					UIManager:close(receiver)
					return true
				end
			end)
		end
		step("offline check never wakes networking", function()
			connected, online = false, false
			plugin:saveSetting(UpdateDialog.LAST_CHECK, 0)
			UpdateDialog.autoCheck(plugin)
			return function()
				if UpdateDialog._check_job then return false end
				check("offline check never wakes networking", wifi_actions == 0)
				check("offline check leaves state alone", plugin:getSetting(UpdateDialog.LAST_CHECK) == 0)
				connected, online = true, true
				return true
			end
		end)
		step("suspend cancels a manual check", function()
			for index = #UIManager._window_stack, 1, -1 do
				local widget = UIManager._window_stack[index].widget
				if type(widget.text) == "string" and widget.text:find("is up to date", 1, true) then
					UIManager:close(widget)
				end
			end
			probe_delay = 2
			plugin:saveSetting(UpdateDialog.LAST_CHECK, 0)
			UpdateDialog.checkNow(plugin)
			local job = assert(UpdateDialog._check_job)
			check("manual check has cancellation feedback", job.widget.text:find("cancel", 1, true))
			Device.screen:shot(WORK .. "/update_checking.png")
			plugin:onSuspend() -- Only the plugin hook; never suspend the host/device in this kit.
			check("suspend cancels manual check", not UpdateDialog._check_job and job.cancelled)
			check("suspend leaves check state alone", plugin:getSetting(UpdateDialog.LAST_CHECK) == 0)
			probe_delay = 0
		end)

		step("up to date", function()
			setMode("same")
			UpdateDialog.checkNow(plugin)
			return function()
				if UpdateDialog._check_job then return false end
				check("up to date", lastText("is up to date"), "no up-to-date message")
				return true
			end
		end)

		step("auto check toast", function()
			setMode("good")
			plugin:saveSetting(UpdateDialog.LAST_CHECK, 0)
			local checked = UpdateDialog.autoCheck(plugin)
			return function()
				if UpdateDialog._check_job then return false end
				check("auto check toast", checked and lastText(NEW .. " is available"), "no toast")
				check("auto check notified once", plugin:getSetting(UpdateDialog.NOTIFIED) == NEW)
				check("auto check keeps etag", type(plugin:getSetting(UpdateDialog.ETAG)) == "string")
				check("auto check waits a week", UpdateDialog.autoCheck(plugin) == false)
				return true
			end
		end)

		step("read-only install", function()
			-- chmod changes permissions only; the path was checked to be inside the work dir above
			local parent = plugin_dir:match("^(.*)/[^/]+$")
			assert(os.execute("chmod 555 '" .. parent .. "'") == 0)
			local updater = UpdateDialog.newUpdater(plugin)
			local result = updater:check({})
			UpdateDialog.install(plugin, updater, result.release)
			os.execute("chmod 755 '" .. parent .. "'")
			check("read-only install", lastText("can't be written") or lastText("read%-only"), shown[#shown].text)
			check("read-only changes nothing", versionIn(plugin_dir) == OLD and not exists(backup_dir))
		end)

		step("development install", function()
			assert(lfs.mkdir(plugin_dir .. "/.git"))
			local updater = UpdateDialog.newUpdater(plugin)
			local result = updater:check({})
			UpdateDialog.install(plugin, updater, result.release)
			lfs.rmdir(plugin_dir .. "/.git")
			check("development install", lastText("development"), shown[#shown].text)
			check("development changes nothing", versionIn(plugin_dir) == OLD and not exists(backup_dir))
		end)

		step("bad digest", function()
			setMode("bad_digest")
			UpdateDialog.checkNow(plugin)
			local before
			return function()
				if not before then
					if UpdateDialog._check_job then return false end
					local viewer = assert(topmost("buttons_table"), "no release viewer")
					before = #shown
					press(viewer, "Install")
				end
				for index = before + 1, #shown do
					local text = shown[index].text
					if type(text) == "string" and text:find("checksum") then
						check("bad digest", true)
						check("bad digest changes nothing", versionIn(plugin_dir) == OLD and not exists(backup_dir))
						check("bad digest cleans up", noLeftovers())
						check("bad digest needs no restart", #restarts == 0)
						return true
					end
				end
			end
		end)

		step("update", function()
			setMode("good")
			UpdateDialog.checkNow(plugin)
			local installing = false
			return function()
				if not installing then
					if UpdateDialog._check_job then return false end
					local viewer = assert(topmost("buttons_table"), "no release viewer")
					check("release notes shown", viewer.text:find("e2e release " .. NEW, 1, true), viewer.text)
					installing = true
					press(viewer, "Install")
				end
				if #restarts == 0 then
					return false
				end
				check("update", versionIn(plugin_dir) == NEW, versionIn(plugin_dir))
				check("update keeps backup", versionIn(backup_dir) == OLD, versionIn(backup_dir))
				check("update cleans up", noLeftovers())
				check("update asks for restart", restarts[1]:find(NEW, 1, true), restarts[1])
				return true
			end, 90
		end)

		step("restart gate", function()
			local before = #restarts
			plugin:onShowOPDSPlusCatalog()
			check("restart gate", #restarts == before + 1 and not plugin.opds_browser, "catalog opened after update")
		end)
		step("check workers collected", function()
			return function()
				if next(live_workers) then return false end
				check("check workers collected", true)
				FFIUtil.runInSubProcess, FFIUtil.isSubProcessDone = real_spawn, real_done
				return true
			end, 15
		end)
	elseif PHASE == "rollback" then
		step("runs the new version", function()
			check("runs the new version", package.loaded["opds_plus_version"].VERSION == NEW,
				package.loaded["opds_plus_version"].VERSION)
			check("settings kept", plugin:getSetting(UpdateDialog.NOTIFIED) == NEW)
			check("backup offered", UpdateDialog.hasBackup(plugin))
		end)

		step("rollback", function()
			UpdateDialog.rollback(plugin)
			local confirm = topmost("ok_callback")
			confirm.ok_callback()
			check("rollback", versionIn(plugin_dir) == OLD, versionIn(plugin_dir))
			check("rollback keeps the newer as backup", versionIn(backup_dir) == NEW, versionIn(backup_dir))
			check("rollback asks for restart", #restarts == 1)
		end)
	elseif PHASE == "rolled_back" then
		step("runs the old version", function()
			check("runs the old version", package.loaded["opds_plus_version"].VERSION == OLD,
				package.loaded["opds_plus_version"].VERSION)
			check("cleanup kept the backup", UpdateDialog.hasBackup(plugin))
		end)
	end

	step("only updater requests went to the mock", function()
		check("updater requests", PHASE ~= "update" or updater_requests > 0, updater_requests)
	end)

	sequence(steps)
end

UIManager:scheduleIn(3, function()
	local ok, err = pcall(start)
	if not ok then
		check("driver", false, err)
		finish()
	end
end)
