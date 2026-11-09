-- Custom HTTP request headers for catalogs
-- A catalog's headers are an ordered list of { name = "...", value = "..." } pairs.
-- They can carry credentials (tokens, cookies), so they are only ever sent to the origin
-- (scheme, host and port) of the catalog they belong to.

local RequestHeaders = {}

-- Headers that frame the request or that the plugin needs to control; changing them breaks requests
local RESERVED = {
	["accept-encoding"] = true, -- the plugin reads uncompressed bodies only
	["connection"] = true,
	["content-length"] = true,
	["host"] = true,
	["keep-alive"] = true,
	["proxy-connection"] = true,
	["te"] = true,
	["trailer"] = true,
	["transfer-encoding"] = true,
	["upgrade"] = true,
}

local DEFAULT_PORTS = { http = 80, https = 443 }

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Settings can be edited by hand, so entries may be anything
local function isHeader(header)
	return type(header) == "table" and type(header.name) == "string" and type(header.value) == "string"
end

--- Check one header
-- @param name string Header name
-- @param value string Header value
-- @return boolean, string|nil True when usable, otherwise false and why: "name", "reserved" or "value"
function RequestHeaders.validate(name, value)
	if type(name) ~= "string" or not name:match("^[A-Za-z0-9!#$%%&'*+%-%.%^_`|~]+$") then
		return false, "name"
	end
	if RESERVED[name:lower()] then
		return false, "reserved"
	end
	-- Control characters other than a tab could end the header line and smuggle in another one
	if type(value) ~= "string" or value:match("^%s*$") or value:find("[%z\1-\8\10-\31\127]") then
		return false, "value"
	end
	return true
end

--- Turn text with one "Name: value" per line into a header list
-- @param text string Text typed by the user
-- @return table|nil, number|nil, string|nil, string|nil The list; or nil, line number, reason ("format",
-- "name", "reserved", "value" or "duplicate") and the header name when it is known
function RequestHeaders.parse(text)
	local list, seen = {}, {}
	local line_number = 0
	text = (text or ""):gsub("\r\n?", "\n")
	for line in (text .. "\n"):gmatch("(.-)\n") do
		line_number = line_number + 1
		if not line:match("^%s*$") then
			local name, value = line:match("^([^:]*):(.*)$")
			if not name then
				return nil, line_number, "format"
			end
			name, value = trim(name), trim(value)
			local ok, reason = RequestHeaders.validate(name, value)
			if not ok then
				return nil, line_number, reason, name
			end
			local key = name:lower()
			if seen[key] then
				return nil, line_number, "duplicate", name
			end
			seen[key] = true
			table.insert(list, { name = name, value = value })
		end
	end
	return list
end

--- Turn a header list into text with one "Name: value" per line
-- @param list table|nil Header list
-- @return string
function RequestHeaders.format(list)
	local lines = {}
	for _, header in ipairs(list or {}) do
		if isHeader(header) then
			table.insert(lines, header.name .. ": " .. header.value)
		end
	end
	return table.concat(lines, "\n")
end

--- Copy a header list, so the copy can be changed without touching the original
-- @param list table|nil Header list
-- @return table|nil
function RequestHeaders.copy(list)
	if type(list) ~= "table" then
		return nil
	end
	local copy = {}
	for _, header in ipairs(list) do
		if isHeader(header) then
			table.insert(copy, { name = header.name, value = header.value })
		end
	end
	return copy
end

--- Get the origin of a URL: scheme, host and port, with default ports and letter case normalised
-- @param url string URL to look at
-- @return string|nil e.g. "https://example.com:443", nil when it is not an http(s) URL
function RequestHeaders.originKey(url)
	if type(url) ~= "string" then
		return nil
	end
	local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
	scheme = scheme and scheme:lower()
	if not DEFAULT_PORTS[scheme] then
		return nil
	end
	local authority = rest:match("^[^/?#]*"):gsub("^.*@", "") -- without any user:password@
	local host, port
	if authority:sub(1, 1) == "[" then
		local after
		host, after = authority:match("^(%[[^%]]+%])(.*)$")
		port = after and (after == "" and "" or after:match("^:(%d*)$"))
	else
		host, port = authority:match("^([^:]+):?(%d*)$")
	end
	if not host or not port then
		return nil
	end
	return scheme .. "://" .. host:lower() .. ":" .. (tonumber(port) or DEFAULT_PORTS[scheme])
end

--- Find the custom headers of the catalog a URL belongs to
-- @param servers table|nil List of catalogs
-- @param url string URL a request goes to
-- @return table|nil Header list of the first catalog with headers on the same origin as the URL
function RequestHeaders.forUrl(servers, url)
	local key = RequestHeaders.originKey(url)
	if not key or type(servers) ~= "table" then
		return nil
	end
	for _, server in ipairs(servers) do
		if type(server) == "table" and type(server.headers) == "table" and #server.headers > 0
			and RequestHeaders.originKey(server.url) == key then
			return server.headers
		end
	end
	return nil
end

--- Add custom headers to the headers of a request
-- Headers the request already sets are never replaced, whatever the letter case of their names.
-- Entries that are not valid (for instance after the settings file was edited by hand) are skipped.
-- @param headers table|nil Headers of the request
-- @param list table|nil Custom header list
-- @return table|nil The headers, which stay nil when the request had none and nothing applies
function RequestHeaders.apply(headers, list)
	if type(list) ~= "table" then
		return headers
	end
	local present = {}
	for name in pairs(headers or {}) do
		present[tostring(name):lower()] = true
	end
	for _, header in ipairs(list) do
		if type(header) == "table" and RequestHeaders.validate(header.name, header.value) then
			local key = header.name:lower()
			if not present[key] then
				present[key] = true
				headers = headers or {}
				headers[header.name] = header.value
			end
		end
	end
	return headers
end

return RequestHeaders
