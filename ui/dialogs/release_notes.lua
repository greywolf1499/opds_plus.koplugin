local TextViewer = require("ui/widget/textviewer")

local ReleaseNotes = {}

function ReleaseNotes.new(options)
	if TextViewer.html_text_formats and TextViewer.html_text_formats.md then
		options.text_format = "md"
		return TextViewer:new(options)
	end

	-- v2025.10 has the converter and HTML scroller, but not a Markdown TextViewer.
	local Converter = require("apps/filemanager/filemanagerconverter")
	local html = Converter:mdToHtml(options.text, "")
	assert(type(html) == "string" and html:find("%S"), "Markdown conversion returned no HTML")

	local Blitbuffer = require("ffi/blitbuffer")
	local ButtonTable = require("ui/widget/buttontable")
	local CenterContainer = require("ui/widget/container/centercontainer")
	local Device = require("device")
	local FrameContainer = require("ui/widget/container/framecontainer")
	local Geom = require("ui/geometry")
	local GestureRange = require("ui/gesturerange")
	local InputContainer = require("ui/widget/container/inputcontainer")
	local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
	local Size = require("ui/size")
	local TitleBar = require("ui/widget/titlebar")
	local UIManager = require("ui/uimanager")
	local VerticalGroup = require("ui/widget/verticalgroup")
	local Screen = Device.screen

	local viewer = InputContainer:new(options)
	local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
	local width = screen_w - Screen:scaleBySize(30)
	local height = screen_h - Screen:scaleBySize(30)
	local inner_width = width - 2 * Size.border.window
	local padding = Size.padding.large
	local text_types = G_reader_settings:readSetting("textviewer_text_types")
	local style = text_types and text_types.general or TextViewer.text_types.general
	local titlebar = TitleBar:new {
		width = inner_width,
		title = options.title,
		title_shrink_font_to_fit = true,
		close_callback = function() UIManager:close(viewer) end,
	}
	viewer.button_table = ButtonTable:new {
		buttons = options.buttons_table,
		width = inner_width,
		show_parent = viewer,
	}
	viewer.scroll_widget = ScrollHtmlWidget:new {
		html_body = html,
		css = [[
			@page { margin: 0; }
			body { margin: 0; line-height: 1.3;
		]] .. (style.justified and "text-align: justify;" or "")
			.. (style.monospace_font and "font-family: monospace;" or "") .. "}",
		default_font_size = Screen:scaleBySize(style.font_size),
		width = inner_width - 2 * padding,
		height = height - 2 * Size.border.window - titlebar:getHeight()
			- viewer.button_table:getSize().h - 2 * padding,
		dialog = viewer,
	}
	viewer.frame = FrameContainer:new {
		padding = 0,
		margin = 0,
		bordersize = Size.border.window,
		radius = Size.radius.window,
		background = Blitbuffer.COLOR_WHITE,
		VerticalGroup:new {
			align = "center",
			titlebar,
			FrameContainer:new {
				padding = padding,
				margin = 0,
				bordersize = 0,
				viewer.scroll_widget,
			},
			viewer.button_table,
		},
	}
	viewer[1] = CenterContainer:new {
		dimen = Geom:new { w = screen_w, h = screen_h },
		viewer.frame,
	}

	if Device:hasKeys() then
		viewer.key_events.Close = { { Device.input.group.Back } }
	end
	if Device:isTouchDevice() then
		viewer.ges_events.TapClose = {
			GestureRange:new {
				ges = "tap",
				range = Geom:new { w = screen_w, h = screen_h },
			},
		}
	end
	function viewer:onTapClose(arg, ges)
		if ges.pos:notIntersectWith(self.frame.dimen) then self:onClose() end
		return true
	end
	function viewer:onClose()
		UIManager:close(self)
		return true
	end
	function viewer:onShow()
		UIManager:setDirty(self, function() return "partial", self.frame.dimen end)
		return true
	end
	function viewer:onCloseWidget()
		UIManager:setDirty(nil, function() return "partial", self.frame.dimen end)
	end
	return viewer
end

return ReleaseNotes
