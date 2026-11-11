-- Stand-in for the parts of KOReader's frontend/util.lua that the plugin's non-UI code calls.
--
-- The function bodies are copied from koreader/koreader (frontend/util.lua, v2026.07.1, AGPL-3.0,
-- the same licence as this plugin) so that specs see the behaviour of the real module. The real
-- util.lua can't be loaded in CI because it needs native libraries (utf8proc).
--
-- Deliberate differences from the original:
--   * util.getFilesystemType() always answers "ext4" (the original parses `mount`); specs can
--     replace it to exercise the VFAT branch of util.getSafeFilename().
--   * getSafeFilename() never takes the Android branch.
--
-- spec/contract/koreader_contract_spec.lua compares this file with the real module whenever a
-- KOReader install is available (KOREADER_DIR), so drift is caught locally.
local bit = require("bit")
local lfs = require("lfs")

local band = bit.band
local bor = bit.bor
local rshift = bit.rshift

local util = {}

function util.trim(s)
	local from = s:match("^%s*()")
	return from > #s and "" or s:match(".*%S", from)
end

--[[
Author: Peter Odding
License: MIT/X11
Source: http://snippets.luacode.org/snippets/String_splitting_130
]]
function util.gsplit(str, pattern, capture, capture_empty_entity)
	pattern = pattern and tostring(pattern) or "%s+"
	if (""):find(pattern) then
		error("pattern matches empty string!", 2)
	end
	return coroutine.wrap(function()
		local index = 1
		repeat
			local first, last = str:find(pattern, index)
			if first and last then
				if index < first or (index == first and capture_empty_entity) then
					coroutine.yield(str:sub(index, first - 1))
				end
				if capture then
					coroutine.yield(str:sub(first, last))
				end
				index = last + 1
			else
				if index <= #str then
					coroutine.yield(str:sub(index))
				end
				break
			end
		until index > #str
	end)
end

function util.stringEndsWith(str, ending)
	return ending == "" or str:sub(-#ending) == ending
end

function util.makePath(path)
	if lfs.attributes(path, "mode") == "directory" then
		return true
	end

	local components
	if path:sub(1, 1) == "/" then
		components = "/"
	else
		components = ""
	end

	local success, err
	for component in path:gmatch("([^/]+)") do
		components = components .. component .. "/"
		if lfs.attributes(components, "mode") == nil then
			success, err = lfs.mkdir(components)
			if not success then
				return nil, err .. " (creating `" .. components .. "` for `" .. path .. "`)"
			end
		end
	end

	return success, err
end

function util.removeFile(file)
	if file and lfs.attributes(file, "mode") == "file" then
		return os.remove(file)
	elseif file then
		return nil, file .. " is not a file"
	else
		return nil, "file is nil"
	end
end

function util.replaceAllInvalidChars(str)
	if str then
		str = str:gsub('[\\/:*?"<>|]', "_")
		str = str:gsub("[.%s]+$", "")
		return str
	end
end

local function replaceSlashChar(str)
	if str then
		return str:gsub("%/", "_")
	end
end

-- Replaced by the original with a parse of `mount`; see the header.
function util.getFilesystemType(_path)
	return "ext4"
end

function util.splitFilePathName(file)
	if file == nil or file == "" then
		return "", ""
	end
	if string.find(file, "/") == nil then
		return "", file
	end
	return file:match("(.*/)(.*)")
end

function util.splitFileNameSuffix(file)
	if file == nil or file == "" then
		return "", ""
	end
	if string.find(file, "%.") == nil then
		return file, ""
	end
	return file:match("(.*)%.(.*)")
end

function util.getFileNameSuffix(file)
	local _, suffix = util.splitFileNameSuffix(file)
	return suffix
end

function util.fixUtf8(str, replacement)
	local pos = 1
	local len = #str
	while pos <= len do
		if str:find("^[%z\1-\127]", pos) then
			pos = pos + 1
		elseif str:find("^[\194-\223][\128-\191]", pos) then
			pos = pos + 2
		elseif
			str:find("^\224[\160-\191][\128-\191]", pos)
			or str:find("^[\225-\236][\128-\191][\128-\191]", pos)
			or str:find("^\237[\128-\159][\128-\191]", pos)
			or str:find("^[\238-\239][\128-\191][\128-\191]", pos)
		then
			pos = pos + 3
		elseif
			str:find("^\240[\144-\191][\128-\191][\128-\191]", pos)
			or str:find("^[\241-\243][\128-\191][\128-\191][\128-\191]", pos)
			or str:find("^\244[\128-\143][\128-\191][\128-\191]", pos)
		then
			pos = pos + 4
		else
			str = str:sub(1, pos - 1) .. replacement .. str:sub(pos + 1)
			pos = pos + #replacement
			len = len + #replacement - 1
		end
	end
	return str
end

function util.unicodeCodepointToUtf8(c)
	if c < 0x80 then
		return string.char(c)
	elseif c < 0x800 then
		return string.char(bor(0xC0, rshift(c, 6)), bor(0x80, band(c, 0x3F)))
	elseif c < 0x10000 then
		if c >= 0xD800 and c <= 0xDFFF then
			return "\u{FFFD}" -- Surrogates -> U+FFFD REPLACEMENT CHARACTER
		end
		return string.char(bor(0xE0, rshift(c, 12)), bor(0x80, band(rshift(c, 6), 0x3F)), bor(0x80, band(c, 0x3F)))
	elseif c < 0x110000 then
		return string.char(
			bor(0xF0, rshift(c, 18)),
			bor(0x80, band(rshift(c, 12), 0x3F)),
			bor(0x80, band(rshift(c, 6), 0x3F)),
			bor(0x80, band(c, 0x3F))
		)
	else
		return "\u{FFFD}" -- Invalid -> U+FFFD REPLACEMENT CHARACTER
	end
end

-- An array of arrays keeps the replacements ordered as written.
local HTML_ENTITIES_TO_UTF8 = {
	{ "&lt;", "<" },
	{ "&gt;", ">" },
	{ "&quot;", '"' },
	{ "&lsquo;", "\u{2018}" },
	{ "&rsquo;", "\u{2019}" },
	{ "&ldquo;", "\u{201C}" },
	{ "&rdquo;", "\u{201D}" },
	{ "&mdash;", "\u{2014}" },
	{ "&apos;", "'" },
	{ "&nbsp;", "\u{00A0}" },
	{
		"&#(%d+);",
		function(x)
			return util.unicodeCodepointToUtf8(tonumber(x))
		end,
	},
	{
		"&#x(%x+);",
		function(x)
			return util.unicodeCodepointToUtf8(tonumber(x, 16))
		end,
	},
	{ "&amp;", "&" }, -- must be last
}

function util.htmlEntitiesToUtf8(text)
	for _, t in ipairs(HTML_ENTITIES_TO_UTF8) do
		text = text:gsub(t[1], t[2])
	end
	return text
end

function util.htmlToPlainText(text)
	text = text:gsub("%s*<%s*br%s*/?>%s*", "\n") -- <br> and <br/>
	text = text:gsub("%s*</%s*p%s*>%s*", "\n") -- </p>
	text = text:gsub("%s*<%s*p%s*/>%s*", "\n") -- standalone <p/>
	text = text:gsub("%s*<%s*p%s*>%s*", "\n\t") -- <p>
	text = text:gsub("<[^>]*>", "")
	text = util.htmlEntitiesToUtf8(text)
	text = text:gsub("^[\n%s]*", "")
	text = text:gsub("[\n%s]*$", "")
	return text
end

function util.htmlToPlainTextIfHtml(text)
	local is_html = false
	local _, nb_tags
	_, nb_tags = text:gsub("<%w+.->", "")
	if nb_tags > 0 then
		is_html = true
	else
		local nb_encoded_tags
		_, nb_encoded_tags = text:gsub("&lt;%a+&gt;", "")
		if nb_encoded_tags > 0 then
			is_html = true
			text = util.htmlEntitiesToUtf8(text)
		end
	end

	if is_html then
		text = util.htmlToPlainText(text)
	else
		text = text:gsub("]]>%s*$", "")
	end
	return text
end

function util.getSafeFilename(str, path, limit, limit_ext)
	local filename, suffix = util.splitFileNameSuffix(str)
	local replaceFunc = util.replaceAllInvalidChars
	local safe_filename
	limit = limit or 240
	limit_ext = limit_ext or 10

	if path then
		local file_system = util.getFilesystemType(path)
		if file_system ~= "vfat" and file_system ~= "fuse.fsp" then
			replaceFunc = replaceSlashChar
		end
	end

	if suffix:len() > limit_ext then
		-- probably not an actual file extension, so strip the whole string
		filename = str
		suffix = nil
	end

	filename = filename:gsub("\r?\n", " "):gsub("\t", " ")
	filename = util.htmlToPlainTextIfHtml(filename)
	filename = filename:sub(1, limit)
	-- the limit might result in broken UTF-8, which we don't want in the result
	filename = util.fixUtf8(filename, "")

	if suffix and suffix ~= "" then
		safe_filename = replaceFunc(filename) .. "." .. replaceFunc(suffix)
	else
		safe_filename = replaceFunc(filename)
	end

	return safe_filename
end

function util.urlEncode(url, preserve_chars)
	local char_to_hex = function(c)
		return string.format("%%%02X", string.byte(c))
	end
	preserve_chars = preserve_chars or ""
	local pattern_base = "^%w%-%._~"
	local pattern = string.format("([%s%s])", pattern_base, preserve_chars)
	if url == nil then
		return
	end
	url = url:gsub("\n", "\r\n")
	url = url:gsub(pattern, char_to_hex)
	return url
end

return util
