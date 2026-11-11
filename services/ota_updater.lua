-- In-app updater: finds the latest stable GitHub release, downloads and verifies its zip, stages it next
-- to the installed plugin and swaps it in with two renames, keeping the old version as a backup.
--
-- Trust model: TLS with verify="peer" against KOReader's CA bundle and a check of the certificate's names
-- against the host (services/tls_hostname.lua), HTTPS only with manual redirects restricted to GitHub
-- hosts, and the asset's SHA-256 from the release API (or the .sha256 sidecar). Nothing from the archive
-- reaches the plugins folder before every entry name has been checked and the staged tree has been
-- validated.
--
-- Every outside dependency can be injected through OtaUpdater.new(deps), so specs run it against temp dirs.
-- Deletion is limited to three exact paths: the staging folder, the backup folder (both siblings of the
-- installed plugin) and the downloaded zip.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ArchivePaths = require("utils.archive_paths")
local FileUtils = require("utils.file_utils")
local HttpClient = require("services.http_client")
local Semver = require("utils.semver")
local TlsHostname = require("services.tls_hostname")

local OtaUpdater = {}

OtaUpdater.REPOSITORY = "greywolf1499/opds_plus.koplugin"
OtaUpdater.LATEST_URL = "https://api.github.com/repos/" .. OtaUpdater.REPOSITORY .. "/releases/latest"
OtaUpdater.RELEASES_URL = "https://github.com/" .. OtaUpdater.REPOSITORY .. "/releases/latest"
OtaUpdater.ASSET_NAME = "opds_plus.koplugin.zip"
OtaUpdater.SIDECAR_NAME = OtaUpdater.ASSET_NAME .. ".sha256"
OtaUpdater.ARCHIVE_PREFIX = "opds_plus.koplugin"
OtaUpdater.MAX_ASSET_SIZE = 16 * 1024 * 1024
OtaUpdater.MAX_API_BYTES = 1024 * 1024
OtaUpdater.MAX_REDIRECTS = 4
OtaUpdater.SPACE_FACTOR = 3
OtaUpdater.REQUIRED_FILES = { "_meta.lua", "main.lua", "opds_plus_version.lua" }
OtaUpdater.CA_FILE = "data/ca-bundle.crt"

OtaUpdater.Errors = {
	NETWORK = "NETWORK",
	TLS = "TLS",
	RATE_LIMITED = "RATE_LIMITED",
	HTTP_ERROR = "HTTP_ERROR",
	BAD_RESPONSE = "BAD_RESPONSE",
	NO_ASSET = "NO_ASSET",
	NO_DIGEST = "NO_DIGEST",
	TOO_LARGE = "TOO_LARGE",
	DIGEST_MISMATCH = "DIGEST_MISMATCH",
	DEV_INSTALL = "DEV_INSTALL",
	READ_ONLY = "READ_ONLY",
	LOW_SPACE = "LOW_SPACE",
	ARCHIVE_UNSUPPORTED = "ARCHIVE_UNSUPPORTED",
	INVALID_ARCHIVE = "INVALID_ARCHIVE",
	VALIDATION_FAILED = "VALIDATION_FAILED",
	KOREADER_TOO_OLD = "KOREADER_TOO_OLD",
	SWAP_FAILED = "SWAP_FAILED",
	NO_BACKUP = "NO_BACKUP",
	BAD_INSTALL_PATH = "BAD_INSTALL_PATH",
}
local E = OtaUpdater.Errors

-- Set once an update or a rollback has replaced the files on disk: the running code is the old version,
-- and must not lazily require files from the new one. Entry points check it and ask for a restart.
OtaUpdater.restart_pending = false

local ALLOWED_HOSTS = { ["github.com"] = true, ["api.github.com"] = true }

--- Whether the updater may connect to a host: GitHub and its asset CDN only
-- @param host string Lower-cased host name
function OtaUpdater.isAllowedHost(host)
	return ALLOWED_HOSTS[host] == true or host:match("^[%w%-]+%.githubusercontent%.com$") ~= nil
end

local function log(...)
	logger.info("OPDS+ OTA:", ...)
end

local function warn(...)
	logger.warn("OPDS+ OTA:", ...)
end

local function defaultJsonDecode(text)
	local ok, rapidjson = pcall(require, "rapidjson")
	if ok and rapidjson then
		return rapidjson.decode(text)
	end
	return require("json").decode(text)
end

local function defaultSha256(data)
	return require("ffi/sha2").sha256(data)
end

local function defaultArchiver()
	local ok, archiver = pcall(require, "ffi/archiver")
	if ok and type(archiver) == "table" and archiver.Reader then
		return archiver
	end
	return nil
end

local function defaultFreeSpace(path)
	local ok, util = pcall(require, "ffi/util")
	if not ok or not util.df then
		return nil
	end
	local ok_df, _, free = pcall(util.df, path)
	return ok_df and free or nil
end

local function defaultKoreaderSupports(min_version)
	local ok, Version = pcall(require, "version")
	if not ok then
		return true
	end
	local wanted = Version:getNormalizedVersion(min_version)
	local running = Version:getNormalizedCurrentVersion()
	if not wanted or not running then
		return true
	end
	return running >= wanted
end

--- Creates an updater
-- @param deps table
--   plugin_dir string        Absolute path of the installed plugin folder (required)
--   cache_dir string         Where the zip is downloaded (required)
--   current_version string   Installed version (default: opds_plus_version.VERSION)
--   archiver table           ffi/archiver (default: required lazily)
--   sha256 function          data -> lowercase hex (default: ffi/sha2.sha256)
--   json_decode function     text -> table (default: rapidjson, else KOReader's json)
--   free_space function      path -> free bytes or nil (default: ffi/util.df)
--   koreader_supports function  min_version -> boolean (default: version module)
--   rename function          os.rename, injectable to test the rollback paths
--   ca_file string           CA bundle for verify="peer" (default: KOReader's data/ca-bundle.crt)
--   total_timeout boolean    Stop API answers that outlast socketutil's total timeout
-- @return table|nil updater, or nil and E.BAD_INSTALL_PATH
function OtaUpdater.new(deps)
	deps = deps or {}
	local plugin_dir = type(deps.plugin_dir) == "string" and deps.plugin_dir:gsub("/+$", "") or nil
	if not plugin_dir or plugin_dir:sub(1, 1) ~= "/" or not plugin_dir:match("[^/]%.koplugin$") then
		return nil, E.BAD_INSTALL_PATH
	end
	for component in plugin_dir:gmatch("[^/]+") do
		if component == "." or component == ".." then
			return nil, E.BAD_INSTALL_PATH
		end
	end
	if type(deps.cache_dir) ~= "string" or deps.cache_dir:sub(1, 1) ~= "/" then
		return nil, E.BAD_INSTALL_PATH
	end

	local self = setmetatable({}, { __index = OtaUpdater })
	self.plugin_dir = plugin_dir
	self.staging_dir = plugin_dir .. ".new"
	self.backup_dir = plugin_dir .. ".bak"
	self.download_path = deps.cache_dir:gsub("/+$", "") .. "/" .. OtaUpdater.ASSET_NAME
	self.current_version = deps.current_version or require("opds_plus_version").VERSION
	self.archiver = deps.archiver
	self.sha256 = deps.sha256 or defaultSha256
	self.json_decode = deps.json_decode or defaultJsonDecode
	self.free_space = deps.free_space or defaultFreeSpace
	self.koreader_supports = deps.koreader_supports or defaultKoreaderSupports
	self.rename = deps.rename or os.rename
	self.ca_file = deps.ca_file or OtaUpdater.CA_FILE
	self.total_timeout = deps.total_timeout
	return self
end

-- Removes one of the three paths the updater owns, and nothing else
function OtaUpdater:removeOwned(path)
	if path ~= self.staging_dir and path ~= self.backup_dir and path ~= self.download_path then
		error("OPDS+ OTA: refusing to remove a path it does not own: " .. tostring(path))
	end
	return FileUtils.removeTree(path)
end

local function exists(path)
	return lfs.symlinkattributes(path, "mode") ~= nil
end

--- Whether the installed plugin is a development checkout: a link, or a folder with .git in it
function OtaUpdater:isDevInstall()
	return lfs.symlinkattributes(self.plugin_dir, "mode") == "link"
		or lfs.attributes(self.plugin_dir .. "/.git", "mode") ~= nil
end

--- Whether a previous version is kept and can be restored
function OtaUpdater:hasBackup()
	local mode = lfs.symlinkattributes(self.backup_dir, "mode")
	if mode == "link" then
		return lfs.attributes(self.backup_dir .. "/_meta.lua", "mode") == "file"
	end
	return mode == "directory" and lfs.attributes(self.backup_dir .. "/_meta.lua", "mode") == "file"
end

--- Removes what an interrupted update left behind: the staging folder and the downloaded zip
function OtaUpdater:cleanup()
	for _, path in ipairs({ self.staging_dir, self.download_path }) do
		if exists(path) then
			local ok, err = self:removeOwned(path)
			if not ok then
				warn("could not remove leftover", path, err)
			end
		end
	end
end

-- TLS settings for every request: verify the chain against the CA bundle, and the host against the
-- certificate
function OtaUpdater:tlsOptions()
	local tls = { verify = "peer", cafile = self.ca_file }
	tls.create = TlsHostname.create(tls)
	return tls
end

local function classifyNetworkError(err)
	local text = tostring(err):lower()
	if text:find("certificate", 1, true) or text:find("ssl", 1, true) or text:find("tls", 1, true) then
		return E.TLS
	end
	return E.NETWORK
end

function OtaUpdater:request(url, extra, options)
	if lfs.attributes(self.ca_file, "mode") ~= "file" then
		return nil, E.TLS, "no CA bundle at " .. tostring(self.ca_file)
	end
	local request = self:tlsOptions()
	request.url = url
	request.method = "GET"
	request.headers = {
		["User-Agent"] = "OPDSPlus/" .. tostring(self.current_version),
	}
	for name, value in pairs(extra or {}) do
		request.headers[name] = value
	end
	options = options or {}
	options.https_only = true
	options.allow_host = OtaUpdater.isAllowedHost
	options.custom_headers = false
	options.max_redirects = OtaUpdater.MAX_REDIRECTS
	local ok, code, headers, _, info = HttpClient.request(request, options)
	if not ok then
		if code == HttpClient.ErrorCodes.TOO_LARGE then
			return nil, E.TOO_LARGE, url
		end
		if HttpClient.ErrorCodes[code] then
			return nil, E.NETWORK, code
		end
		return nil, classifyNetworkError(code), tostring(code)
	end
	return code, headers or {}, info
end

local function rateLimitError(code, headers)
	if (code == 403 or code == 429) and (headers["x-ratelimit-remaining"] == "0" or headers["retry-after"]) then
		return tonumber(headers["x-ratelimit-reset"]) or true
	end
	return nil
end

local function findAsset(assets, name)
	if type(assets) ~= "table" then
		return nil
	end
	for _, asset in ipairs(assets) do
		if type(asset) == "table" and asset.name == name then
			return asset
		end
	end
	return nil
end

local function parseDigest(value)
	if type(value) ~= "string" then
		return nil
	end
	local hex = value:match("^sha256:(%x+)$") or value:match("^(%x+)$")
	if hex and #hex == 64 then
		return hex:lower()
	end
	return nil
end

--- Reads a release from the GitHub API
-- @return table|nil { version, tag, name, notes, html_url, asset_url, asset_size, digest, sidecar_url }
-- @return string|nil error code
function OtaUpdater.parseRelease(release)
	if type(release) ~= "table" or type(release.tag_name) ~= "string" then
		return nil, E.BAD_RESPONSE
	end
	if release.draft == true or release.prerelease == true then
		return nil, E.BAD_RESPONSE
	end
	local version = Semver.normalize(release.tag_name)
	if not version then
		return nil, E.BAD_RESPONSE
	end
	local parsed = {
		version = version,
		tag = release.tag_name,
		name = type(release.name) == "string" and release.name or release.tag_name,
		notes = type(release.body) == "string" and release.body or "",
		html_url = type(release.html_url) == "string" and release.html_url or OtaUpdater.RELEASES_URL,
	}
	local asset = findAsset(release.assets, OtaUpdater.ASSET_NAME)
	if not asset or type(asset.browser_download_url) ~= "string" then
		return parsed, E.NO_ASSET
	end
	parsed.asset_url = asset.browser_download_url
	parsed.asset_size = tonumber(asset.size)
	parsed.digest = parseDigest(asset.digest)
	local sidecar = findAsset(release.assets, OtaUpdater.SIDECAR_NAME)
	if sidecar and type(sidecar.browser_download_url) == "string" then
		parsed.sidecar_url = sidecar.browser_download_url
	end
	if not parsed.digest and not parsed.sidecar_url then
		return parsed, E.NO_DIGEST
	end
	if parsed.asset_size and parsed.asset_size > OtaUpdater.MAX_ASSET_SIZE then
		return parsed, E.TOO_LARGE
	end
	return parsed
end

--- Asks GitHub for the latest stable release
-- @param state table|nil { etag = string, skipped_version = string }
-- @return table|nil { status = "update"|"up_to_date"|"not_modified"|"skipped", release = table, etag = string }
-- @return string|nil error code
-- @return any detail (for RATE_LIMITED: the reset time, or true)
function OtaUpdater:check(state)
	state = state or {}
	local headers = {
		["Accept"] = "application/vnd.github+json",
		["X-GitHub-Api-Version"] = "2022-11-28",
	}
	if type(state.etag) == "string" and state.etag ~= "" then
		headers["If-None-Match"] = state.etag
	end
	local code, response, info = self:request(OtaUpdater.LATEST_URL, headers, {
		max_bytes = OtaUpdater.MAX_API_BYTES,
		total_timeout = self.total_timeout,
	})
	if not code then
		warn("check failed", response, info)
		return nil, response, info
	end
	if code == 304 then
		return { status = "not_modified", etag = state.etag }
	end
	local reset = rateLimitError(code, response)
	if reset then
		return nil, E.RATE_LIMITED, reset
	end
	if code ~= 200 then
		return nil, E.HTTP_ERROR, code
	end
	local ok, decoded = pcall(self.json_decode, info.body or "")
	if not ok or type(decoded) ~= "table" then
		return nil, E.BAD_RESPONSE
	end
	local release, err = OtaUpdater.parseRelease(decoded)
	if not release then
		return nil, err
	end
	local etag = type(response.etag) == "string" and response.etag or nil
	local order = Semver.compare(release.version, self.current_version)
	if order == nil or order <= 0 then
		return { status = "up_to_date", release = release, etag = etag }
	end
	if err then
		return nil, err, release
	end
	if state.skipped_version and Semver.compare(release.version, state.skipped_version) == 0 then
		return { status = "skipped", release = release, etag = etag }
	end
	log("update available", release.version)
	return { status = "update", release = release, etag = etag }
end

-- The digest from the sidecar, when the API gave none
function OtaUpdater:sidecarDigest(release)
	local code, _, info = self:request(release.sidecar_url, { ["Accept"] = "application/octet-stream" },
		{ max_bytes = 4096 })
	if code ~= 200 then
		return nil
	end
	local hex = (info.body or ""):match("^%s*(%x+)")
	if hex and #hex == 64 then
		return hex:lower()
	end
	return nil
end

-- Downloads the asset to download_path
function OtaUpdater:download(release, progress)
	local file, written
	local function sink()
		if file then
			file:close()
		end
		file = io.open(self.download_path, "wb")
		written = 0
		if not file then
			return nil, E.READ_ONLY
		end
		return function(chunk)
			if chunk == nil then
				return 1
			end
			written = written + #chunk
			if written > OtaUpdater.MAX_ASSET_SIZE then
				return nil, E.TOO_LARGE
			end
			if progress and progress(written, release.asset_size) == false then
				return nil, "cancelled"
			end
			return file:write(chunk) and 1 or nil
		end
	end
	local code, err, detail = self:request(release.asset_url, { ["Accept"] = "application/octet-stream" }, { sink = sink })
	if file then
		file:close()
	end
	if not code then
		return nil, err, detail
	end
	if code ~= 200 then
		return nil, E.HTTP_ERROR, code
	end
	return written
end

local function readFile(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local data = file:read("*a")
	file:close()
	return data
end

-- Lists the archive with the archiver and checks every entry
function OtaUpdater:listArchive()
	local reader = self.archiver.Reader:new()
	if not reader:open(self.download_path) then
		return nil, E.INVALID_ARCHIVE, reader.err
	end
	local entries = {}
	for entry in reader:iterate() do
		entries[#entries + 1] = { path = entry.path, mode = entry.mode, size = entry.size }
	end
	reader:close()
	local checked, total = ArchivePaths.validate(entries, OtaUpdater.ARCHIVE_PREFIX)
	if not checked then
		return nil, E.INVALID_ARCHIVE, total
	end
	return checked
end

local function mkdirs(base, rel)
	local current = base
	for component in rel:gmatch("[^/]+") do
		current = current .. "/" .. component
		local mode = lfs.symlinkattributes(current, "mode")
		if mode == nil then
			if not lfs.mkdir(current) then
				return nil
			end
		elseif mode ~= "directory" then
			return nil
		end
	end
	return true
end

-- Extracts the checked entries into the staging folder, on a fresh reader
function OtaUpdater:extract(checked)
	local by_path = {}
	for _, entry in ipairs(checked) do
		by_path[entry.path] = entry
	end
	local reader = self.archiver.Reader:new()
	if not reader:open(self.download_path) then
		return nil, E.INVALID_ARCHIVE, reader.err
	end
	local ok, err, detail = true, nil, nil
	for entry in reader:iterate() do
		local known = by_path[entry.path]
		if not known or known.mode ~= entry.mode then
			ok, err, detail = nil, E.INVALID_ARCHIVE, "archive changed while reading it"
			break
		end
		if known.mode == "directory" then
			if not mkdirs(self.staging_dir, known.rel) then
				ok, err, detail = nil, E.READ_ONLY, known.rel
				break
			end
		else
			local parent = known.rel:match("^(.*)/[^/]*$")
			if parent and not mkdirs(self.staging_dir, parent) then
				ok, err, detail = nil, E.READ_ONLY, parent
				break
			end
			if not reader:extractToPath(entry.path, self.staging_dir .. "/" .. known.rel) then
				ok, err, detail = nil, E.INVALID_ARCHIVE, reader.err or known.rel
				break
			end
		end
	end
	reader:close()
	return ok, err, detail
end

local function luaFiles(dir, prefix, found)
	for name in lfs.dir(dir) do
		if name ~= "." and name ~= ".." then
			local path = dir .. "/" .. name
			local mode = lfs.symlinkattributes(path, "mode")
			if mode == "directory" then
				luaFiles(path, prefix .. name .. "/", found)
			elseif mode == "file" and name:match("%.lua$") then
				found[#found + 1] = prefix .. name
			end
		end
	end
	return found
end

-- Checks the staged tree: required files, syntax, version and KOReader requirement
function OtaUpdater:validateStaged(release)
	for _, name in ipairs(OtaUpdater.REQUIRED_FILES) do
		if lfs.symlinkattributes(self.staging_dir .. "/" .. name, "mode") ~= "file" then
			return nil, E.VALIDATION_FAILED, "missing " .. name
		end
	end
	for _, name in ipairs(luaFiles(self.staging_dir, "", {})) do
		local chunk, err = loadfile(self.staging_dir .. "/" .. name)
		if not chunk then
			return nil, E.VALIDATION_FAILED, err
		end
	end
	local chunk, err = loadfile(self.staging_dir .. "/opds_plus_version.lua")
	if not chunk then
		return nil, E.VALIDATION_FAILED, err
	end
	setfenv(chunk, {})
	local ok, staged = pcall(chunk)
	if not ok or type(staged) ~= "table" or Semver.compare(staged.VERSION, release.version) ~= 0 then
		return nil, E.VALIDATION_FAILED, "version does not match " .. release.version
	end
	if type(staged.MIN_KOREADER) == "string" and not self.koreader_supports(staged.MIN_KOREADER) then
		return nil, E.KOREADER_TOO_OLD, staged.MIN_KOREADER
	end
	return true
end

-- Swaps the staged tree in: plugin -> .bak, .new -> plugin; puts the plugin back if the second rename fails
function OtaUpdater:swap()
	if exists(self.backup_dir) then
		local removed, err = self:removeOwned(self.backup_dir)
		if not removed then
			return nil, E.SWAP_FAILED, err
		end
	end
	local moved, err = self.rename(self.plugin_dir, self.backup_dir)
	if not moved then
		return nil, E.SWAP_FAILED, err
	end
	local placed, place_err = self.rename(self.staging_dir, self.plugin_dir)
	if not placed then
		local restored, restore_err = self.rename(self.backup_dir, self.plugin_dir)
		if not restored then
			warn("could not put the plugin back; rename", self.backup_dir, "to", self.plugin_dir, restore_err)
		end
		return nil, E.SWAP_FAILED, place_err
	end
	return true
end

--- Checks that an update can be installed at all, before anything is downloaded
-- @param release table From check()
-- @param options table|nil { allow_dev = boolean }
function OtaUpdater:preflight(release, options)
	options = options or {}
	if not exists(self.plugin_dir) then
		return nil, E.BAD_INSTALL_PATH
	end
	if self:isDevInstall() and not options.allow_dev then
		return nil, E.DEV_INSTALL
	end
	self.archiver = self.archiver or defaultArchiver()
	if not self.archiver then
		return nil, E.ARCHIVE_UNSUPPORTED
	end
	local free = self.free_space(self.plugin_dir:match("^(.*)/[^/]*$") or "/")
	local needed = (release.asset_size or OtaUpdater.MAX_ASSET_SIZE) * OtaUpdater.SPACE_FACTOR
	if free and free < needed then
		return nil, E.LOW_SPACE, needed
	end
	-- Creating the staging folder doubles as the check that the plugins folder can be written
	if exists(self.staging_dir) then
		local removed, err = self:removeOwned(self.staging_dir)
		if not removed then
			return nil, E.READ_ONLY, err
		end
	end
	if not lfs.mkdir(self.staging_dir) then
		return nil, E.READ_ONLY, self.staging_dir
	end
	return true
end

--- Finds the digest the download must match: GitHub's, else the .sha256 file attached to the release
-- @return string|nil Lowercase hex
-- @return string|nil error code
function OtaUpdater:resolveDigest(release)
	local digest = release.digest
	if not digest and release.sidecar_url then
		digest = self:sidecarDigest(release)
	end
	if not digest then
		return nil, E.NO_DIGEST
	end
	return digest
end

--- Downloads the release's zip; safe to run in a subprocess that may be killed, as it writes nothing but
-- the zip in the cache folder
-- @param progress function|nil function(bytes, total) -> false to cancel
-- @return string|nil digest
-- @return number|string size, or error code
-- @return any detail
function OtaUpdater:fetch(release, progress)
	local digest, err = self:resolveDigest(release)
	if not digest then
		return nil, err
	end
	local size, download_err, detail = self:download(release, progress)
	if not size then
		return nil, download_err, detail
	end
	return digest, size
end

--- Verifies a downloaded zip, stages it and swaps it in; removes the staging folder and the zip whatever
-- happens
-- @return boolean|nil true when installed; the update takes effect after a restart
-- @return string|nil error code
-- @return any detail
function OtaUpdater:apply(release, digest, size)
	local ok, err, detail = self:applyStaged(release, digest, size)
	self:cleanup()
	if not ok then
		warn("install failed", err, detail)
		return nil, err, detail
	end
	OtaUpdater.restart_pending = true
	log("installed", release.version)
	return true
end

--- Downloads, verifies, stages and installs a release, in one go
-- @param release table From check()
-- @param options table|nil { allow_dev = boolean, progress = function(bytes, total) -> false to cancel }
-- @return boolean|nil true when installed; the update takes effect after a restart
-- @return string|nil error code
-- @return any detail
function OtaUpdater:install(release, options)
	options = options or {}
	local ok, err, detail = self:preflight(release, options)
	if not ok then
		return nil, err, detail
	end
	local digest, size
	digest, size, detail = self:fetch(release, options.progress)
	if not digest then
		self:cleanup()
		warn("download failed", size, detail)
		return nil, size, detail
	end
	return self:apply(release, digest, size)
end

function OtaUpdater:applyStaged(release, digest, size)
	if release.asset_size and size ~= release.asset_size then
		return nil, E.DIGEST_MISMATCH, "size"
	end
	local data = readFile(self.download_path)
	if not data or self.sha256(data):lower() ~= digest then
		return nil, E.DIGEST_MISMATCH
	end
	data = nil -- luacheck: ignore 311
	local checked, err, detail = self:listArchive()
	if not checked then
		return nil, err, detail
	end
	local extracted
	extracted, err, detail = self:extract(checked)
	if not extracted then
		return nil, err, detail
	end
	local valid
	valid, err, detail = self:validateStaged(release)
	if not valid then
		return nil, err, detail
	end
	return self:swap()
end

--- Puts the previous version back; the current one becomes the backup
-- @return boolean|nil true when rolled back
-- @return string|nil error code
function OtaUpdater:rollback()
	if not self:hasBackup() then
		return nil, E.NO_BACKUP
	end
	if exists(self.staging_dir) then
		local removed, err = self:removeOwned(self.staging_dir)
		if not removed then
			return nil, E.SWAP_FAILED, err
		end
	end
	-- plugin -> .new, .bak -> plugin, .new -> .bak
	local moved, err = self.rename(self.plugin_dir, self.staging_dir)
	if not moved then
		return nil, E.SWAP_FAILED, err
	end
	local placed, place_err = self.rename(self.backup_dir, self.plugin_dir)
	if not placed then
		self.rename(self.staging_dir, self.plugin_dir)
		return nil, E.SWAP_FAILED, place_err
	end
	local kept, keep_err = self.rename(self.staging_dir, self.backup_dir)
	if not kept then
		warn("rolled back, but could not keep the newer version as the backup", keep_err)
	end
	OtaUpdater.restart_pending = true
	log("rolled back")
	return true
end

return OtaUpdater
