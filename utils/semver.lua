-- Semantic Versioning 2.0.0 (https://semver.org): reading a version and ordering two of them.
-- Used to compare a release tag with the installed version. Pure Lua, no KOReader modules.

local Semver = {}

-- The numbers of a version stay below 2^31, so they are exact and format the same on 32-bit devices
local MAX_CORE_DIGITS = 9

--- Compares two values with the usual ordering
-- @return number -1, 0 or 1
local function order(a, b)
	if a == b then
		return 0
	end
	return a < b and -1 or 1
end

local function isNumeric(identifier)
	return identifier:find("^[0-9]+$") ~= nil
end

--- A number without leading zeros, kept short enough to be exact
-- @return number|nil
local function parseCoreNumber(text)
	if #text > MAX_CORE_DIGITS or (#text > 1 and text:sub(1, 1) == "0") then
		return nil
	end
	return tonumber(text)
end

--- Splits dot-separated identifiers
-- @return table|nil The identifiers, nil when one is empty or has a character that is not allowed
local function parseIdentifiers(text, allow_leading_zero)
	local identifiers = {}
	for identifier in (text .. "."):gmatch("([^.]*)%.") do
		if not identifier:find("^[0-9A-Za-z-]+$") then
			return nil
		end
		if not allow_leading_zero and isNumeric(identifier) and #identifier > 1 and identifier:sub(1, 1) == "0" then
			return nil
		end
		identifiers[#identifiers + 1] = identifier
	end
	return identifiers
end

--- Reads a version
-- @param text string A version such as "1.4.0", "v1.4.0" or "1.4.0-rc.1+build.5"
-- @return table|nil { major, minor, patch, prerelease, build }; the numbers are numbers and the identifiers
--   of prerelease and build are strings. nil when text is not a semantic version
function Semver.parse(text)
	if type(text) ~= "string" then
		return nil
	end
	text = text:match("^%s*(.-)%s*$"):gsub("^[vV]", "")

	local rest, build = text, nil
	local plus = rest:find("+", 1, true)
	if plus then
		rest, build = rest:sub(1, plus - 1), rest:sub(plus + 1)
	end
	local prerelease
	local hyphen = rest:find("-", 1, true)
	if hyphen then
		rest, prerelease = rest:sub(1, hyphen - 1), rest:sub(hyphen + 1)
	end

	local major, minor, patch = rest:match("^([0-9]+)%.([0-9]+)%.([0-9]+)$")
	if not major then
		return nil
	end
	local version = {
		major = parseCoreNumber(major),
		minor = parseCoreNumber(minor),
		patch = parseCoreNumber(patch),
		prerelease = {},
		build = {},
	}
	if not (version.major and version.minor and version.patch) then
		return nil
	end
	if prerelease then
		version.prerelease = parseIdentifiers(prerelease, false)
		if not version.prerelease then
			return nil
		end
	end
	if build then
		version.build = parseIdentifiers(build, true)
		if not version.build then
			return nil
		end
	end
	return version
end

--- Numeric identifiers have no leading zeros, so the longer one is the larger
local function compareNumeric(a, b)
	if #a ~= #b then
		return #a < #b and -1 or 1
	end
	return order(a, b)
end

--- Numeric identifiers rank below the ones with letters; two of a kind compare with each other
local function compareIdentifiers(a, b)
	local a_numeric, b_numeric = isNumeric(a), isNumeric(b)
	if a_numeric and b_numeric then
		return compareNumeric(a, b)
	end
	if a_numeric ~= b_numeric then
		return a_numeric and -1 or 1
	end
	return order(a, b)
end

--- Orders two versions by SemVer 2.0.0 precedence. Build metadata does not count.
-- Raw string comparison is by byte in LuaJIT, which is the ASCII order the specification asks for.
-- @param a string A version, as Semver.parse reads it
-- @param b string
-- @return number|nil -1 when a is the lower version, 0 when they rank the same, 1 when a is higher;
--   nil when either one is not a version, which is never newer than anything
function Semver.compare(a, b)
	local left, right = Semver.parse(a), Semver.parse(b)
	if not (left and right) then
		return nil
	end

	for _, field in ipairs({ "major", "minor", "patch" }) do
		local result = order(left[field], right[field])
		if result ~= 0 then
			return result
		end
	end

	-- A pre-release ranks below the release it leads up to
	local left_pre, right_pre = left.prerelease, right.prerelease
	if #left_pre == 0 and #right_pre == 0 then
		return 0
	elseif #left_pre == 0 then
		return 1
	elseif #right_pre == 0 then
		return -1
	end
	for index = 1, math.min(#left_pre, #right_pre) do
		local result = compareIdentifiers(left_pre[index], right_pre[index])
		if result ~= 0 then
			return result
		end
	end
	-- Equal as far as both go: the longer pre-release is the higher one
	return order(#left_pre, #right_pre)
end

--- Writes a version the usual way, without the leading v or the whitespace
-- @param text string
-- @return string|nil nil when text is not a semantic version
function Semver.normalize(text)
	local version = Semver.parse(text)
	if not version then
		return nil
	end
	local result = string.format("%d.%d.%d", version.major, version.minor, version.patch)
	if #version.prerelease > 0 then
		result = result .. "-" .. table.concat(version.prerelease, ".")
	end
	if #version.build > 0 then
		result = result .. "+" .. table.concat(version.build, ".")
	end
	return result
end

return Semver
