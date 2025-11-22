local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local util = require("util")
local _ = require("gettext")

local UIUtils = {}

-- Parse title and author from entry data
function UIUtils.parseTitleAuthor(entry)
	local title = entry.title
	local author = entry.author

	if not title or title == "" then
		if entry.text then
			local title_part, author_part = entry.text:match("^(.+)%s*%-%s*(.+)$")
			if title_part and author_part then
				title = title_part
				if not author or author == "" then
					author = author_part
				end
			else
				title = entry.text
			end
		end
	end

	return title or _("Unknown"), author
end

-- Create a placeholder cover widget
function UIUtils.createPlaceholderCover(width, height, status)
	local placeholder_bg_color = Blitbuffer.COLOR_LIGHT_GRAY
	local text_color = Blitbuffer.COLOR_DARK_GRAY

	local display_text
	local icon

	if status == "loading" then
		icon = "⏳"
		display_text = _("Loading...")
	elseif status == "error" then
		icon = "⚠"
		display_text = _("Failed")
	else
		icon = "📖"
		display_text = _("No Cover")
	end

	-- Standardize font scaling (logic combined from grid/list)
	local font_size = math.floor(height / 10)
	if font_size < 10 then font_size = 10 end
	if font_size > 14 then font_size = 14 end

	local icon_widget = TextWidget:new {
		text = icon,
		face = Font:getFace("infofont", font_size * 2),
		fgcolor = text_color,
	}

	local text_widget = TextWidget:new {
		text = display_text,
		face = Font:getFace("smallinfofont", font_size),
		fgcolor = text_color,
	}

	return FrameContainer:new {
		width = width,
		height = height,
		padding = 0,
		margin = 0,
		bordersize = Size.border.default or 2,
		background = placeholder_bg_color,
		CenterContainer:new {
			dimen = Geom:new {
				w = width,
				h = height,
			},
			VerticalGroup:new {
				align = "center",
				icon_widget,
				VerticalSpan:new { width = font_size / 2 },
				text_widget,
			},
		},
	}
end

-- Helper function to truncate text with ellipsis using binary search
function UIUtils.truncateText(text, face, max_width)
	if not text or text == "" then
		return text
	end

	local measured_width = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text).x

	if measured_width <= max_width then
		return text
	end

	local ellipsis = "…"
	local ellipsis_width = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, ellipsis).x
	local available_width = max_width - ellipsis_width

	local left, right = 1, #text
	local best_length = 1

	while left <= right do
		local mid = math.floor((left + right) / 2)
		local test_text = util.splitToChars(text)
		local truncated = ""
		for i = 1, mid do
			truncated = truncated .. (test_text[i] or "")
		end

		local test_width = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, truncated).x

		if test_width <= available_width then
			best_length = mid
			left = mid + 1
		else
			right = mid - 1
		end
	end

	local result_chars = util.splitToChars(text)
	local result = ""
	for i = 1, best_length do
		result = result .. (result_chars[i] or "")
	end

	-- Try to break at word boundary
	local last_space = result:reverse():find(" ")
	if last_space and last_space < 15 then
		result = result:sub(1, -(last_space + 1))
	end

	return result .. ellipsis
end

-- Format series information
function UIUtils.formatSeriesInfo(series, series_index)
	if not series or series == "" then
		return nil
	end

	if series_index and series_index ~= "" then
		return series .. " #" .. series_index
	end

	return series
end

return UIUtils
