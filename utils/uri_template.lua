-- Expands URI templates (RFC 6570, levels 1 to 3), as OPDS 2.0 uses for templated search links.
--
-- Values are strings or numbers. Level 4 modifiers (":n" prefixes and "*" explode) are accepted and
-- ignored, so a template that uses them still expands with the whole value.

local UriTemplate = {}

-- How each operator joins and encodes its variables (RFC 6570 appendix A)
local OPERATORS = {
	[""]  = { first = "",  sep = ",", named = false, ifemp = "",  reserved = false },
	["+"] = { first = "",  sep = ",", named = false, ifemp = "",  reserved = true },
	["#"] = { first = "#", sep = ",", named = false, ifemp = "",  reserved = true },
	["."] = { first = ".", sep = ".", named = false, ifemp = "",  reserved = false },
	["/"] = { first = "/", sep = "/", named = false, ifemp = "",  reserved = false },
	[";"] = { first = ";", sep = ";", named = true,  ifemp = "",  reserved = false },
	["?"] = { first = "?", sep = "&", named = true,  ifemp = "=", reserved = false },
	["&"] = { first = "&", sep = "&", named = true,  ifemp = "=", reserved = false },
}

local UNRESERVED = "A-Za-z0-9%-%._~"
local RESERVED = ":/%?#%[%]@!%$&'%(%)%*%+,;="

local function percentEncode(char)
	return string.format("%%%02X", char:byte())
end

local function encode(value, allow_reserved)
	if allow_reserved then
		-- Keep reserved characters and existing %XX triplets; encode everything else
		local out = {}
		local i = 1
		while i <= #value do
			local char = value:sub(i, i)
			if char == "%" and value:sub(i + 1, i + 2):match("^%x%x$") then
				out[#out + 1] = value:sub(i, i + 2)
				i = i + 3
			else
				if char:match("[" .. UNRESERVED .. RESERVED .. "]") then
					out[#out + 1] = char
				else
					out[#out + 1] = percentEncode(char)
				end
				i = i + 1
			end
		end
		return table.concat(out)
	end
	return (value:gsub("[^" .. UNRESERVED .. "]", percentEncode))
end

-- Splits "a,b:3,c*" into variable names, dropping level 4 modifiers
local function variableNames(spec)
	local names = {}
	for varspec in spec:gmatch("[^,]+") do
		local name = varspec:match("^%s*([%w_%.%%]+)")
		if name then
			names[#names + 1] = name
		end
	end
	return names
end

local function splitExpression(expression)
	local op = expression:sub(1, 1)
	if OPERATORS[op] then
		return op, expression:sub(2)
	end
	return "", expression
end

local function expandExpression(expression, variables)
	local op, spec = splitExpression(expression)
	local rules = OPERATORS[op]
	local parts = {}
	for _, name in ipairs(variableNames(spec)) do
		local value = variables[name]
		if type(value) == "number" then
			value = tostring(value)
		end
		if type(value) == "string" then
			local encoded = encode(value, rules.reserved)
			if rules.named then
				parts[#parts + 1] = encode(name, false) .. (value == "" and rules.ifemp or "=" .. encoded)
			else
				parts[#parts + 1] = encoded
			end
		end
	end
	if #parts == 0 then
		return ""
	end
	return rules.first .. table.concat(parts, rules.sep)
end

--- Expands a URI template
-- @param template string The template, for example "/search{?query,author}"
-- @param variables table Variable values by name; a variable that is absent is left out
-- @return string The expanded URI
function UriTemplate.expand(template, variables)
	variables = variables or {}
	return (template:gsub("{([^{}]*)}", function(expression)
		return expandExpression(expression, variables)
	end))
end

--- Lists the variable names a template uses, in order of first appearance
-- @param template string The template
-- @return table A list of names
function UriTemplate.variables(template)
	local names, seen = {}, {}
	for expression in template:gmatch("{([^{}]*)}") do
		local _, spec = splitExpression(expression)
		for _, name in ipairs(variableNames(spec)) do
			if not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
	end
	return names
end

--- Whether a string contains a template expression
-- @param href string
-- @return boolean
function UriTemplate.isTemplated(href)
	return type(href) == "string" and href:find("{[^{}]*}") ~= nil
end

-- Variable names OPDS 2.0 catalogs use for the search terms, most common first
local SEARCH_VARIABLES = { "query", "searchTerms", "q", "term", "search", "title" }

-- Expanded in place of the search terms, then swapped for %s. Letters only, so no operator encodes it.
local SENTINEL = "OPDSPLUSSEARCHTERMS"

--- Turns a templated search link into a URL with "%s" where the search terms go
-- @param template string The link's href, for example "/search{?query}"
-- @return string|nil The URL with "%s", or nil when no variable takes the search terms
function UriTemplate.toSearchUrl(template)
	if type(template) ~= "string" then
		return nil
	end
	local names = UriTemplate.variables(template)
	local search_variable
	for _, candidate in ipairs(SEARCH_VARIABLES) do
		for _, name in ipairs(names) do
			if name == candidate then
				search_variable = name
				break
			end
		end
		if search_variable then break end
	end
	if not search_variable and #names == 1 then
		search_variable = names[1]
	end
	if not search_variable then
		return nil
	end
	-- Callers substitute the encoded terms with gsub("%%s", ...). A literal "%s" cannot occur in a valid
	-- template, as a % there must start a hex escape.
	local expanded = UriTemplate.expand(template, { [search_variable] = SENTINEL })
	return (expanded:gsub(SENTINEL, "%%s"))
end

return UriTemplate
