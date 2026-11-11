local helper = require("helper")
local socketutil_stub = require("support.socketutil")
local ui_stub = require("support.ui")

describe("UpdateDialog", function()
	local UpdateDialog, OtaUpdater, ui, network, plugin, updater, restarts, socketutil
	local E

	local RELEASE = { version = "1.4.0", notes = "Fixes", html_url = "https://github.com/x/releases/tag/v1.4.0" }

	local function fake_plugin()
		local settings = {}
		return {
			path = "/plugins/opds_plus.koplugin",
			settings = settings,
			getSetting = function(_, key)
				return settings[key]
			end,
			saveSetting = function(_, key, value)
				settings[key] = value
			end,
		}
	end

	-- An updater that records calls and answers what the spec scripts
	local function fake_updater()
		local fake = { calls = {}, current_version = "1.3.1", answers = {} }
		local function record(name)
			return function(_, ...)
				fake.calls[#fake.calls + 1] = { name = name, args = { ... } }
				local answer = fake.answers[name]
				if type(answer) == "function" then
					return answer(...)
				end
				if answer then
					return unpack(answer)
				end
				return true
			end
		end
		for _, name in ipairs({ "check", "preflight", "fetch", "apply", "cleanup", "rollback", "hasBackup" }) do
			-- Generated method fields coexist with this fixture's string/table data fields.
			---@diagnostic disable-next-line: assign-type-mismatch
			fake[name] = record(name)
		end
		function fake:called(name)
			local found = {}
			for _, call in ipairs(self.calls) do
				if call.name == name then
					found[#found + 1] = call
				end
			end
			return found
		end
		return fake
	end

	before_each(function()
		helper.reset()
		ui = ui_stub.new()
		ui.TextViewer.html_text_formats = { md = true }
		restarts = {}
		function ui.UIManager:askForRestart(message)
			restarts[#restarts + 1] = message
		end
		network = { connected = true, online = true, ran = 0 }
		function network:isConnected()
			return self.connected
		end
		function network:isOnline()
			return self.online
		end
		function network:beforeWifiAction(callback)
			self.ran = self.ran + 1
			self.callback = callback
		end
		socketutil = socketutil_stub.new()
		local stubs = {
			["ui/network/manager"] = network,
			["ui/widget/notification"] = ui.InfoMessage,
			["socketutil"] = socketutil,
			["datastorage"] = require("support.datastorage").new(helper.tmpdir()),
			["apps/filemanager/filemanagerconverter"] = { mdToHtml = function() return "" end },
		}
		for name, value in pairs(ui.stubs) do
			stubs[name] = value
		end
		stubs["ui/widget/trapwidget"] = {
			new = function(_self, options)
				options.dismiss_callback = function() end
				return options
			end,
			onCloseWidget = function() end,
			_dismissAndResend = function(self, kind, event)
				self.dismiss_callback()
				ui.UIManager:close(self)
				if self.resend_event then ui.replayed = { kind, event } end
				return true
			end,
		}
		UpdateDialog = helper.load("ui.dialogs.update_dialog", stubs)
		OtaUpdater = require("services.ota_updater")
		OtaUpdater.restart_pending = false
		E = OtaUpdater.Errors
		plugin = fake_plugin()
		updater = fake_updater()
		UpdateDialog.newUpdater = function()
			return updater
		end
	end)

	after_each(function()
		helper.reset()
	end)

	describe("autoCheck", function()
		local NOW = 1800000000
		local WEEK = 7 * 24 * 60 * 60

		it("checks once a week when online, and announces a new version once", function()
			updater.answers.check = { { status = "update", release = RELEASE, etag = '"e1"' } }
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW))
			assert.equal(NOW, plugin.settings.ota_last_check)
			assert.equal('"e1"', plugin.settings.ota_etag)
			assert.equal("1.4.0", plugin.settings.ota_notified_version)
			assert.matches("1.4.0 is available", ui:last().text)

			assert.is_false(UpdateDialog.autoCheck(plugin, NOW + WEEK - 1))
			local shown = #ui:texts()
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW + WEEK))
			assert.equal(shown, #ui:texts())
		end)

		it("sends the stored ETag and skipped version", function()
			plugin.settings.ota_etag = '"e0"'
			plugin.settings.ota_skipped_version = "1.3.5"
			updater.answers.check = { { status = "not_modified" } }
			UpdateDialog.autoCheck(plugin, NOW)
			assert.same({ etag = '"e0"', skipped_version = "1.3.5" }, updater:called("check")[1].args[1])
			assert.same({}, ui:texts())
		end)

		it("uses short timeouts and puts them back", function()
			updater.answers.check = function()
				assert.equal(10, socketutil.block_timeout)
				return { status = "up_to_date" }
			end
			UpdateDialog.autoCheck(plugin, NOW)
			assert.equal(socketutil.DEFAULT_BLOCK_TIMEOUT, socketutil.block_timeout)
		end)

		it("does nothing when turned off, offline, or waiting for a restart", function()
			plugin.settings.ota_auto_check = false
			assert.is_false(UpdateDialog.autoCheck(plugin, NOW))
			plugin.settings.ota_auto_check = nil
			network.online = false
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW))
			network.online, network.connected = true, false
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW))
			network.connected = true
			OtaUpdater.restart_pending = true
			assert.is_false(UpdateDialog.autoCheck(plugin, NOW))
			assert.equal(0, #updater:called("check"))
			assert.equal(0, network.ran)
			assert.is_nil(plugin.settings.ota_last_check)
		end)

		it("checks again when the clock went backwards", function()
			plugin.settings.ota_last_check = NOW + WEEK
			updater.answers.check = { { status = "up_to_date" } }
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW))
		end)

		it("only logs errors", function()
			updater.answers.check = { nil, E.NETWORK }
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW))
			assert.same({}, ui:texts())
			assert.equal(NOW, plugin.settings.ota_last_check)
		end)
	end)

	describe("background checks", function()
		local workers
		local function finish(index, packet)
			local ok, err = coroutine.resume(workers[index].co, true, packet)
			assert(ok, err)
		end

		before_each(function()
			workers = {}
			ui.Trapper.wrap = function(_self, run)
				local co = coroutine.create(run)
				local ok, err = coroutine.resume(co)
				assert(ok, err)
			end
			ui.Trapper.dismissableRunInSubprocess = function(_self, run, widget)
				local co = coroutine.running()
				workers[#workers + 1] = { co = co, run = run, widget = widget }
				widget.dismiss_callback = function()
					local ok, err = coroutine.resume(co, false)
					assert(ok, err)
				end
				return coroutine.yield()
			end
		end)

		it("defers probes and requests, publishing settings only after the parent receives a result", function()
			local probes = 0
			network.isOnline = function() probes = probes + 1; return true end
			updater.answers.check = { { status = "update", release = RELEASE, etag = '"fresh"' } }
			assert.is_true(UpdateDialog.autoCheck(plugin))
			assert.is_false(UpdateDialog.autoCheck(plugin))
			assert.equal(0, probes)
			assert.equal(0, #updater:called("check"))
			assert.equal(1, #workers)
			local packet = workers[1].run()
			assert.equal(1, probes)
			assert.same({}, plugin.settings)
			finish(1, packet)
			assert.equal('"fresh"', plugin.settings.ota_etag)
			assert.equal(RELEASE.version, plugin.settings.ota_notified_version)
			assert.is_nil(UpdateDialog._check_job)
		end)

		it("replaces automatic work with one manual owner and rejects its obsolete result", function()
			updater.answers.check = { { status = "update", release = RELEASE, etag = '"old"' } }
			UpdateDialog.autoCheck(plugin)
			local packet = workers[1].run()
			workers[1].widget.dismiss_callback = function() end -- delayed worker cancellation
			UpdateDialog.checkNow(plugin)
			UpdateDialog.checkNow(plugin)
			assert.equal(2, #workers)
			finish(1, packet)
			assert.same({}, plugin.settings)
			assert.same(workers[2].widget, UpdateDialog._check_job.widget)
			finish(2, { checked = true, result = { status = "up_to_date", etag = '"new"' } })
			assert.equal('"new"', plugin.settings.ota_etag)
			assert.is_nil(plugin.settings.ota_notified_version)
		end)

		it("forwards the input that interrupts an automatic check without marking it checked", function()
			for index, kind in ipairs({ "KeyPress", "KeyRepeat", "Gesture" }) do
				UpdateDialog.autoCheck(plugin)
				local event = { ges = "pan" }
				workers[index].widget:handleEvent({ handler = "on" .. kind, args = { event } })
				assert.same({ kind, event }, ui.replayed)
				assert.same({}, plugin.settings)
				assert.same({}, ui:texts())
				assert.is_nil(UpdateDialog._check_job)
			end
		end)

		it("bounds a stalled worker and explains a manual timeout", function()
			UpdateDialog.checkNow(plugin)
			UpdateDialog._check_job.timeout()
			assert.is_nil(UpdateDialog._check_job)
			assert.same({}, plugin.settings)
			assert.matches("Could not reach GitHub", ui:last().text)
			assert.equal("dead", coroutine.status(workers[1].co))
		end)

		it("does not run a deferred Wi-Fi callback after cancellation", function()
			network.connected = false
			UpdateDialog.checkNow(plugin)
			finish(1, workers[1].run())
			assert.equal(1, network.ran)
			assert.equal(0, #updater:called("check"))
			local callback = network.callback
			UpdateDialog.cancelCheck()
			network.connected = true
			callback()
			assert.equal(1, #workers)
			assert.same({}, plugin.settings)
		end)

		it("keeps the manual Wi-Fi action in the parent and checks after connection", function()
			network.connected = false
			updater.answers.check = { { status = "up_to_date" } }
			UpdateDialog.checkNow(plugin)
			local packet = workers[1].run()
			assert.equal(0, network.ran)
			finish(1, packet)
			assert.equal(1, network.ran)
			network.connected = true
			network.callback()
			assert.equal(2, #workers)
			assert.is_nil(plugin.settings.ota_last_check)
			finish(2, workers[2].run())
			assert.is_number(plugin.settings.ota_last_check)
			assert.matches("is up to date", ui:last().text)
		end)

		it("rechecks current skip preferences and ignores results after an install", function()
			UpdateDialog.autoCheck(plugin)
			plugin.settings.ota_skipped_version = RELEASE.version
			finish(1, { checked = true, result = { status = "update", release = RELEASE } })
			assert.is_nil(plugin.settings.ota_notified_version)
			plugin.settings.ota_last_check = nil
			UpdateDialog.autoCheck(plugin)
			OtaUpdater.restart_pending = true
			finish(2, { checked = true, result = { status = "up_to_date" } })
			assert.is_nil(plugin.settings.ota_last_check)
		end)

		it("reports missing or malformed worker output instead of claiming up to date", function()
			UpdateDialog.checkNow(plugin)
			finish(1, nil)
			assert.matches("could not be read", ui:last().text)
			UpdateDialog.checkNow(plugin)
			finish(2, { checked = true, result = { status = "update" } })
			assert.matches("could not be read", ui:last().text)
		end)

		it("never blocks an automatic check and asks before a manual foreground fallback", function()
			ui.Trapper.dismissableRunInSubprocess = function() return false end
			UpdateDialog.autoCheck(plugin)
			assert.same({}, ui:texts())
			assert.is_nil(UpdateDialog._check_job)
			UpdateDialog.checkNow(plugin)
			local stale = ui:last()
			assert.matches("Input will pause", stale.text)
			UpdateDialog.cancelCheck()
			stale.ok_callback()
			assert.equal(0, #updater:called("check"))
			updater.answers.check = { { status = "up_to_date" } }
			UpdateDialog.checkNow(plugin)
			ui:last().ok_callback()
			assert.equal(1, #updater:called("check"))
			assert.matches("is up to date", ui:last().text)
		end)

		it("coalesces scheduled checks and invalidates their callbacks on cancellation", function()
			UpdateDialog.scheduleAutoCheck(plugin)
			local old = UpdateDialog._scheduled_check
			UpdateDialog.scheduleAutoCheck(plugin)
			assert.equal(1, #ui.scheduled)
			old()
			assert.equal(0, #workers)
			UpdateDialog.cancelCheck()
			assert.equal(0, #ui.scheduled)
		end)
	end)

	describe("checkNow", function()
		it("shows the release, even a skipped one, and installs it", function()
			plugin.settings.ota_skipped_version = "1.4.0"
			updater.answers.check = { { status = "skipped", release = RELEASE } }
			updater.answers.fetch = { "abc", 42 }
			UpdateDialog.checkNow(plugin)
			assert.same({}, updater:called("check")[1].args[1])
			local viewer = ui:last()
			assert.equal("TextViewer", viewer.kind)
			assert.equal("Fixes", viewer.text)
			assert.equal("md", viewer.text_format)
			ui:press(viewer, "Install")
			assert.same({ RELEASE, "abc", 42 }, updater:called("apply")[1].args)
			assert.is_nil(plugin.settings.ota_skipped_version)
			assert.matches("1.4.0 is installed", restarts[1])
		end)

		it("says when the plugin is up to date", function()
			updater.answers.check = { { status = "up_to_date" } }
			UpdateDialog.checkNow(plugin)
			assert.equal("OPDS Plus 1.3.1 is up to date.", ui:last().text)
		end)

		it("points at the release page when the release can't be installed from here", function()
			updater.answers.check = { nil, E.NO_ASSET, RELEASE }
			UpdateDialog.checkNow(plugin)
			assert.matches("releases/tag/v1.4.0", ui:last().text)
		end)

		it("can skip a version", function()
			updater.answers.check = { { status = "update", release = RELEASE } }
			UpdateDialog.checkNow(plugin)
			ui:press(ui:last(), "Skip this version")
			assert.equal("1.4.0", plugin.settings.ota_skipped_version)
			assert.equal(0, #updater:called("fetch"))
		end)

		it("offers the original text after a renderer failure without installing or skipping", function()
			local new = ui.TextViewer.new
			ui.TextViewer.new = function(self, options)
				if options.text_format == "md" then error("injected renderer failure") end
				return new(self, options)
			end
			UpdateDialog.showRelease(plugin, updater, RELEASE)
			local confirm = ui:last()
			assert.equal("ConfirmBox", confirm.kind)
			assert.matches("could not be formatted", confirm.text)
			assert.equal("View as plain text", confirm.ok_text)
			assert.is_nil(plugin.settings.ota_skipped_version)
			assert.equal(0, #updater:called("fetch"))

			confirm.ok_callback()
			local viewer = ui:last()
			assert.equal(RELEASE.notes, viewer.text)
			assert.is_true(viewer.force_txt)
			ui:press(viewer, "Skip this version")
			assert.equal(RELEASE.version, plugin.settings.ota_skipped_version)
			assert.equal(0, #updater:called("fetch"))
		end)

		it("keeps an explicit message when the release has no notes", function()
			UpdateDialog.showRelease(plugin, updater, { version = RELEASE.version, notes = "" })
			assert.equal("No release notes.", ui:last().text)
			ui:press(ui:last(), "Later")
			assert.is_nil(plugin.settings.ota_skipped_version)
			assert.equal(0, #updater:called("fetch"))
		end)

		it("explains an empty compatibility conversion instead of showing blank notes", function()
			ui.TextViewer.html_text_formats = nil
			UpdateDialog.showRelease(plugin, updater, RELEASE)
			assert.matches("could not be formatted", ui:last().text)
			ui:last().ok_callback()
			assert.equal(RELEASE.notes, ui:last().text)
			assert.is_true(ui:last().force_txt)
		end)
	end)

	describe("install", function()
		it("stops at the preflight and says why", function()
			updater.answers.preflight = { nil, E.DEV_INSTALL }
			UpdateDialog.install(plugin, updater, RELEASE)
			assert.matches("development checkout", ui:last().text)
			assert.equal(0, #updater:called("fetch"))
		end)

		it("passes the developer override to the preflight", function()
			plugin.settings.ota_allow_dev = true
			updater.answers.preflight = { nil, E.LOW_SPACE }
			UpdateDialog.install(plugin, updater, RELEASE)
			assert.same({ allow_dev = true }, updater:called("preflight")[1].args[2])
		end)

		it("cleans up and changes nothing when the download is cancelled", function()
			ui.interrupted = true
			updater.answers.fetch = { "abc", 42 }
			UpdateDialog.install(plugin, updater, RELEASE)
			assert.equal(1, #updater:called("cleanup"))
			assert.equal(0, #updater:called("apply"))
			assert.equal("Update cancelled. Nothing was changed.", ui:last().text)
		end)

		it("cleans up after a failed download", function()
			updater.answers.fetch = { nil, E.TLS }
			UpdateDialog.install(plugin, updater, RELEASE)
			assert.equal(1, #updater:called("cleanup"))
			assert.matches("date and time", ui:last().text)
		end)

		it("reports a failed install without asking for a restart", function()
			updater.answers.fetch = { "abc", 42 }
			updater.answers.apply = { nil, E.DIGEST_MISMATCH }
			UpdateDialog.install(plugin, updater, RELEASE)
			assert.matches("checksum", ui:last().text)
			assert.equal(0, #restarts)
		end)
	end)

	describe("rollback", function()
		it("asks first, then rolls back and asks for a restart", function()
			UpdateDialog.rollback(plugin)
			assert.equal(0, #updater:called("rollback"))
			ui:last().ok_callback()
			assert.equal(1, #updater:called("rollback"))
			assert.equal(1, #restarts)
		end)
	end)

	describe("restartGate", function()
		it("asks for a restart instead of running once the files were replaced", function()
			assert.is_false(UpdateDialog.restartGate())
			OtaUpdater.restart_pending = true
			UpdateDialog.checkNow(plugin)
			assert.equal(0, network.ran)
			assert.equal(1, #restarts)
		end)
	end)

	it("explains every updater error in its own words", function()
		local generic = UpdateDialog.errorText("SOMETHING_ELSE")
		for _, err in pairs(E) do
			local text = UpdateDialog.errorText(err, 1, RELEASE)
			assert.is_string(text)
			assert.not_equal((generic:gsub("SOMETHING_ELSE", err)), text, err)
		end
	end)
end)
