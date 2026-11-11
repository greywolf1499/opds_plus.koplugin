local JsonDecode = require("utils.json_decode")
local RequestHeaders = require("utils.request_headers")
local _ = require("gettext")
local T = require("ffi/util").template

local Document = {
    TYPE = "application/opds-authentication+json",
    REL = "http://opds-spec.org/auth/document",
    MAX_BYTES = 256 * 1024,
}

local function mediaType(value)
    local name = type(value) == "string" and value:match("^%s*([^;%s]+)")
    return name and name:lower() or ""
end

local function text(value, maximum)
    return type(value) == "string" and value:find("%S") and #value <= maximum
        and not value:find("[%z\1-\8\11\12\14-\31\127]")
end

-- A declared document is an error when malformed, not an empty catalog.
function Document.parse(body, content_type)
    local declared = mediaType(content_type) == Document.TYPE
    if type(body) ~= "string" or #body > Document.MAX_BYTES then
        return nil, declared, _("The authentication document is missing or too large.")
    end
    if body:sub(1, 3) == "\239\187\191" then body = body:sub(4) end
    if not declared and (not body:match("^%s*{") or not body:find('"authentication"%s*:')) then return nil, false end
    local data = JsonDecode.decode(body)
    local identified = type(data) == "table" and data.authentication ~= nil and data.id ~= nil and data.title ~= nil
    if not declared and not identified then return nil, false end
    if type(data) ~= "table" or not text(data.id, 2048) or not RequestHeaders.originKey(data.id)
        or not text(data.title, 200)
        or type(data.authentication) ~= "table" or #data.authentication < 1 or #data.authentication > 16
        or (data.description ~= nil and data.description ~= "" and not text(data.description, 2000)) then
        return nil, true, _("Invalid OPDS authentication document.")
    end
    local flows = {}
    for __, flow in ipairs(data.authentication) do
        if type(flow) ~= "table" or not text(flow.type, 256) then
            return nil, true, _("Invalid OPDS authentication document.")
        end
        local labels = type(flow.labels) == "table" and flow.labels or {}
        flows[#flows + 1] = {
            type = flow.type,
            login = text(labels.login, 80) and labels.login or nil,
            password = text(labels.password, 80) and labels.password or nil,
        }
    end
    return { title = data.title, description = data.description, flows = flows }, true
end

function Document.describe(document)
    local parts = { T(_("Authentication information: %1"), document.title) }
    if document.description then parts[#parts + 1] = document.description end
    for __, flow in ipairs(document.flows) do
        if flow.type == "http://opds-spec.org/auth/basic" then
            parts[#parts + 1] = T(_("Basic authentication: edit this catalog's username (%1) and password (%2)."),
                flow.login or _("Username"), flow.password or _("Password"))
        elseif flow.type:find("^http://opds%-spec%.org/auth/oauth/") then
            parts[#parts + 1] = _("OAuth login is not supported. No login or token request has been sent.")
        else
            parts[#parts + 1] = T(_("Unsupported authentication method: %1"), flow.type)
        end
    end
    parts[#parts + 1] = _("This is server-provided information, not permission to send credentials to advertised links.")
    return table.concat(parts, "\n\n")
end

local function hasRel(value)
    if type(value) == "table" then
        for __, rel in ipairs(value) do if rel == Document.REL then return true end end
    elseif type(value) == "string" then
        for rel in value:gmatch("%S+") do if rel == Document.REL then return true end end
    end
    return false
end

function Document.feedLink(feed)
    local root = type(feed.feed) == "table" and feed.feed or feed
    local links = root.links or root.link
    if type(links) ~= "table" then return end
    if links.href then links = { links } end
    for __, link in ipairs(links) do
        if type(link) == "table" and hasRel(link.rel) and mediaType(link.type) == Document.TYPE
            and text(link.href, 2048) and not link.templated then return link.href end
    end
end

-- Read RFC 8288 parameters without treating quoted commas/semicolons as link boundaries.
function Document.headerLink(header)
    if type(header) ~= "string" or #header > 16384 then return end
    local position = 1
    while position <= #header do
        local first, last, href = header:find("^%s*<([^>]+)>", position)
        if not first then return end
        position = last + 1
        local params = {}
        while true do
            local start, finish, name = header:find("^%s*;%s*([%w%-]+)%s*=%s*", position)
            if not start then break end
            position = finish + 1
            local value
            if header:sub(position, position) == '"' then
                position = position + 1
                local chars, closed = {}, false
                while position <= #header do
                    local char = header:sub(position, position)
                    position = position + 1
                    if char == '"' then closed = true; break end
                    if char == "\\" then
                        char = header:sub(position, position)
                        position = position + 1
                    end
                    chars[#chars + 1] = char
                end
                if not closed then return end
                value = table.concat(chars)
            else
                local token_start, token_end
                token_start, token_end, value = header:find("^([^%s;,]+)", position)
                if not token_start then return end
                position = token_end + 1
            end
            params[name:lower()] = value
        end
        if hasRel(params.rel) and mediaType(params.type) == Document.TYPE and text(href, 2048) then return href end
        local start, finish = header:find("^%s*,", position)
        if not start then return end
        position = finish + 1
    end
end

return Document
