-- Stand-ins for the KOReader UI modules that plugin code reaches for, for specs.
--
--   local ui = require("support.ui").new()
--   local FeedFetcher = helper.load("core.feed_fetcher", ui.stubs)
--   ... exercise it ...
--   assert.same({ "Catalog not found." }, ui:texts())
--
-- Widgets are plain tables: InfoMessage:new{ text = "x" } returns the options plus `kind`, and
-- UIManager:show records the widget instead of drawing it. Callbacks given to UIManager:scheduleIn and
-- :nextTick are queued, so the test decides when "later" happens: ui:run_scheduled(). Dialogs with
-- buttons are tapped with ui:press(dialog, "Save").
local M = {}

-- `methods` are copied into every instance, which stands in for the class behaviour a widget has.
local function widget_class(kind, methods)
	local class = { kind = kind }

	function class:new(options)
		local instance = {}
		for name, method in pairs(methods or {}) do
			instance[name] = method
		end
		for key, value in pairs(options or {}) do
			instance[key] = value
		end
		instance.kind = kind
		return instance
	end

	return class
end

local function identity(text)
	return text
end

function M.new()
	local ui = { shown = {}, closed = {}, scheduled = {} }

	local UIManager = {}
	function UIManager:show(widget)
		ui.shown[#ui.shown + 1] = widget
	end
	function UIManager:close(widget)
		ui.closed[#ui.closed + 1] = widget
	end
	function UIManager:scheduleIn(seconds, callback)
		ui.scheduled[#ui.scheduled + 1] = { seconds = seconds, callback = callback }
	end
	function UIManager:nextTick(callback)
		ui.scheduled[#ui.scheduled + 1] = { seconds = 0, callback = callback }
	end
	function UIManager:tickAfterNext(callback)
		local wrapper = function() self:nextTick(callback) end
		self:nextTick(wrapper)
		return wrapper
	end
	function UIManager:unschedule(callback)
		for index = #ui.scheduled, 1, -1 do
			if ui.scheduled[index].callback == callback then
				table.remove(ui.scheduled, index)
			end
		end
	end
	function UIManager:setDirty() end
	function UIManager:forceRePaint() end

	-- The text wrappers of the real ui/bidi; without the Unicode marks they add, they return the text as is.
	local BD = {}
	for _, name in ipairs({ "ltr", "rtl", "auto", "default", "nowrap", "wrap", "filename", "filepath", "directory", "dirpath", "path", "url" }) do
		BD[name] = identity
	end

	ui.UIManager = UIManager
	ui.InfoMessage = widget_class("InfoMessage")
	ui.TrapWidget = widget_class("TrapWidget")
	function ui.TrapWidget:handleEvent() end
	function ui.TrapWidget:onCloseWidget() end
	ui.ConfirmBox = widget_class("ConfirmBox")
	ui.ButtonDialog = widget_class("ButtonDialog")
	ui.SpinWidget = widget_class("SpinWidget")
	ui.InputDialog = widget_class("InputDialog", {
		-- What the user typed, which a test sets as `typed`; the field starts with `input`
		getInputText = function(self)
			return self.typed or self.input or ""
		end,
		onShowKeyboard = function(self)
			self.keyboard_shown = true
		end,
	})
	ui.TextViewer = widget_class("TextViewer", {
		onClose = function(self)
			UIManager:close(self)
		end,
	})
	ui.BD = BD

	-- Runs the work in-process, as a subprocess that finishes. KOReader forks for it, so nothing the work
	-- shows, closes or schedules reaches the UI of the parent: those effects are dropped here. Set
	-- ui.interrupted = true to have the user "tap to cancel": the work still runs, but reports as not completed.
	local function truncate(list, length)
		for index = #list, length + 1, -1 do
			list[index] = nil
		end
	end
	ui.Trapper = {}
	function ui.Trapper:wrap(work)
		return work()
	end
	function ui.Trapper:dismissableRunInSubprocess(work, _trap_widget)
		local shown, closed, scheduled = #ui.shown, #ui.closed, #ui.scheduled
		local function finish(...)
			truncate(ui.shown, shown)
			truncate(ui.closed, closed)
			truncate(ui.scheduled, scheduled)
			if ui.interrupted then
				return false
			end
			return true, ...
		end
		return finish(work())
	end

	-- Stand-ins by require() name, for helper.load
	ui.stubs = {
		["ui/uimanager"] = UIManager,
		["ui/widget/infomessage"] = ui.InfoMessage,
		["ui/widget/trapwidget"] = ui.TrapWidget,
		["ui/widget/confirmbox"] = ui.ConfirmBox,
		["ui/widget/buttondialog"] = ui.ButtonDialog,
		["ui/widget/spinwidget"] = ui.SpinWidget,
		["ui/widget/inputdialog"] = ui.InputDialog,
		["ui/widget/textviewer"] = ui.TextViewer,
		["ui/bidi"] = BD,
		["ui/trapper"] = ui.Trapper,
	}

	--- Taps the button labelled `text` of a dialog, searching its `buttons` and `buttons_table` rows.
	function ui:press(widget, text)
		for _, rows in ipairs({ widget.buttons or {}, widget.buttons_table or {} }) do
			for _, row in ipairs(rows) do
				for _, button in ipairs(row) do
					if button.text == text then
						return button.callback()
					end
				end
			end
		end
		error("no button labelled " .. tostring(text), 2)
	end

	--- The text of every widget shown so far, in order.
	function ui:texts()
		local texts = {}
		for _, widget in ipairs(self.shown) do
			if widget.text ~= nil then
				texts[#texts + 1] = widget.text
			end
		end
		return texts
	end

	--- The widget shown last, or nil.
	function ui:last()
		return self.shown[#self.shown]
	end

	--- Runs the callbacks queued by scheduleIn/nextTick, including any they queue in turn.
	function ui:run_scheduled()
		while #self.scheduled > 0 do
			table.remove(self.scheduled, 1).callback()
		end
	end

	return ui
end

return M
