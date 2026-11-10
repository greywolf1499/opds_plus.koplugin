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
		function network:runWhenOnline(callback)
			self.ran = self.ran + 1
			callback()
		end
		socketutil = socketutil_stub.new()
		local stubs = {
			["ui/network/manager"] = network,
			["ui/widget/notification"] = ui.InfoMessage,
			["socketutil"] = socketutil,
			["datastorage"] = require("support.datastorage").new(helper.tmpdir()),
		}
		for name, value in pairs(ui.stubs) do
			stubs[name] = value
		end
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
			local shown = #ui.shown
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW + WEEK))
			assert.equal(shown, #ui.shown)
		end)

		it("sends the stored ETag and skipped version", function()
			plugin.settings.ota_etag = '"e0"'
			plugin.settings.ota_skipped_version = "1.3.5"
			updater.answers.check = { { status = "not_modified" } }
			UpdateDialog.autoCheck(plugin, NOW)
			assert.same({ etag = '"e0"', skipped_version = "1.3.5" }, updater:called("check")[1].args[1])
			assert.equal(0, #ui.shown)
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
			assert.is_false(UpdateDialog.autoCheck(plugin, NOW))
			network.online, network.connected = true, false
			assert.is_false(UpdateDialog.autoCheck(plugin, NOW))
			network.connected = true
			OtaUpdater.restart_pending = true
			assert.is_false(UpdateDialog.autoCheck(plugin, NOW))
			assert.equal(0, #updater:called("check"))
		end)

		it("checks again when the clock went backwards", function()
			plugin.settings.ota_last_check = NOW + WEEK
			updater.answers.check = { { status = "up_to_date" } }
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW))
		end)

		it("only logs errors", function()
			updater.answers.check = { nil, E.NETWORK }
			assert.is_true(UpdateDialog.autoCheck(plugin, NOW))
			assert.equal(0, #ui.shown)
			assert.equal(NOW, plugin.settings.ota_last_check)
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
