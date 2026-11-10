-- The updater end to end against temp dirs: GitHub through fake_http, zips from zipbuilder read by
-- fake_archiver, and the real filesystem only inside helper.tmpdir().
local helper = require("helper")
local fake_http = require("support.fake_http")
local fake_archiver = require("support.fake_archiver")
local zipbuilder = require("support.zipbuilder")
local sha256 = require("support.sha256_stub").sha256
local dkjson = require("dkjson")
local lfs = require("lfs")

describe("OTA updater", function()
	local OtaUpdater, http, archiver
	local root, plugins, plugin_dir, cache_dir, ca_file

	local ASSET_URL = "https://github.com/greywolf1499/opds_plus.koplugin/releases/download/v1.4.0/opds_plus.koplugin.zip"
	local CDN_URL = "https://objects.githubusercontent.com/asset/1"
	local SIDECAR_URL = ASSET_URL .. ".sha256"

	local function write(path, content)
		local file = assert(io.open(path, "wb"))
		file:write(content)
		file:close()
	end

	local function read(path)
		local file = io.open(path, "rb")
		if not file then
			return nil
		end
		local content = file:read("*a")
		file:close()
		return content
	end

	local function mode(path)
		return lfs.symlinkattributes(path, "mode")
	end

	local function plugin_files(version, extra)
		local files = {
			["_meta.lua"] = 'return { name = "opdsplus" }\n',
			["main.lua"] = "return {}\n",
			["opds_plus_version.lua"] = 'return { VERSION = "' .. version .. '" }\n',
			["services/new_module.lua"] = "return 1\n",
		}
		for name, content in pairs(extra or {}) do
			files[name] = content or nil
		end
		return files
	end

	local function install_old_plugin()
		lfs.mkdir(plugin_dir)
		write(plugin_dir .. "/_meta.lua", 'return { name = "opdsplus" }\n')
		write(plugin_dir .. "/main.lua", "return {}\n")
		write(plugin_dir .. "/opds_plus_version.lua", 'return { VERSION = "1.3.1" }\n')
	end

	local function release_json(zip, overrides)
		overrides = overrides or {}
		local release = {
			tag_name = "v1.4.0",
			name = "1.4.0",
			body = "notes",
			html_url = "https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.4.0",
			draft = false,
			prerelease = false,
			assets = {
				{
					name = "opds_plus.koplugin.zip",
					size = #zip,
					digest = "sha256:" .. sha256(zip),
					browser_download_url = ASSET_URL,
				},
			},
		}
		for key, value in pairs(overrides) do
			release[key] = value
		end
		return dkjson.encode(release)
	end

	-- GitHub serves `zip` as the latest release, the download redirecting to the CDN as it does for real
	local function serve(zip, overrides, headers)
		http:on(OtaUpdater.LATEST_URL, { code = 200, body = release_json(zip, overrides), headers = headers })
		http:on(ASSET_URL, { code = 302, headers = { location = CDN_URL } })
		http:on(CDN_URL, { code = 200, body = zip })
	end

	local function updater(deps)
		deps = deps or {}
		deps.plugin_dir = deps.plugin_dir or plugin_dir
		deps.cache_dir = cache_dir
		deps.current_version = deps.current_version or "1.3.1"
		deps.archiver = deps.archiver or archiver
		deps.sha256 = sha256
		deps.json_decode = dkjson.decode
		deps.free_space = deps.free_space or function()
			return 1024 * 1024 * 1024
		end
		deps.ca_file = ca_file
		return assert(OtaUpdater.new(deps))
	end

	local function check_and_install(ota, options)
		local result = assert(ota:check())
		assert.equal("update", result.status)
		return ota:install(result.release, options)
	end

	before_each(function()
		helper.reset()
		http = fake_http.new()
		helper.stub("socket.http", http)
		archiver = fake_archiver.new()
		OtaUpdater = require("services.ota_updater")
		OtaUpdater.restart_pending = false
		root = helper.tmpdir()
		plugins = root .. "/plugins"
		plugin_dir = plugins .. "/opds_plus.koplugin"
		cache_dir = root .. "/cache"
		ca_file = root .. "/ca-bundle.crt"
		lfs.mkdir(plugins)
		lfs.mkdir(cache_dir)
		write(ca_file, "test bundle\n")
		install_old_plugin()
	end)

	after_each(function()
		helper.reset()
	end)

	describe("new", function()
		it("refuses install paths it can't own safely", function()
			for _, path in ipairs({ "relative/opds_plus.koplugin", "/", "/plugins", "/a/../opds_plus.koplugin", 42 }) do
				local ota, err = OtaUpdater.new({ plugin_dir = path, cache_dir = cache_dir })
				assert.is_nil(ota)
				assert.equal(OtaUpdater.Errors.BAD_INSTALL_PATH, err)
			end
		end)

		it("only ever removes its staging folder, its backup and its download", function()
			local ota = updater()
			assert.equal(plugin_dir .. ".new", ota.staging_dir)
			assert.equal(plugin_dir .. ".bak", ota.backup_dir)
			assert.has_error(function()
				ota:removeOwned(plugin_dir)
			end)
			assert.has_error(function()
				ota:removeOwned(plugins)
			end)
			assert.equal("directory", mode(plugin_dir))
		end)
	end)

	describe("check", function()
		it("asks GitHub for the latest release over verified TLS", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")), nil, { etag = '"abc"' })
			local result = assert(updater():check())
			assert.equal("update", result.status)
			assert.equal("1.4.0", result.release.version)
			assert.equal('"abc"', result.etag)
			local request = http:requests_to(OtaUpdater.LATEST_URL)[1]
			assert.equal("application/vnd.github+json", request.headers["Accept"])
			assert.equal("OPDSPlus/1.3.1", request.headers["User-Agent"])
			assert.equal("peer", request.raw.verify)
			assert.equal(ca_file, request.raw.cafile)
			assert.is_function(request.raw.create)
		end)

		it("sends the ETag it was given and reports a 304", function()
			http:on(OtaUpdater.LATEST_URL, { code = 304 })
			local result = assert(updater():check({ etag = '"abc"' }))
			assert.equal("not_modified", result.status)
			assert.equal('"abc"', http.requests[1].headers["If-None-Match"])
		end)

		it("is up to date on the same or an older version", function()
			serve(zipbuilder.plugin(plugin_files("1.3.1")), { tag_name = "v1.3.1" })
			assert.equal("up_to_date", updater():check().status)
			assert.equal("up_to_date", updater({ current_version = "1.5.0" }):check().status)
		end)

		it("respects a skipped version", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			assert.equal("skipped", updater():check({ skipped_version = "1.4.0" }).status)
		end)

		it("reports the rate limit", function()
			http:on(OtaUpdater.LATEST_URL, {
				code = 403,
				headers = { ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = "1700000000" },
			})
			local result, err, reset = updater():check()
			assert.is_nil(result)
			assert.equal(OtaUpdater.Errors.RATE_LIMITED, err)
			assert.equal(1700000000, reset)
		end)

		it("refuses a release without the plugin zip, keeping the release page link", function()
			serve("zip", { assets = { { name = "other.zip", browser_download_url = ASSET_URL } } })
			local result, err, release = updater():check()
			assert.is_nil(result)
			assert.equal(OtaUpdater.Errors.NO_ASSET, err)
			assert.matches("releases/tag/v1.4.0", release.html_url)
		end)

		it("refuses a zip with no digest and no sidecar", function()
			serve("zip", { assets = { { name = "opds_plus.koplugin.zip", size = 3, browser_download_url = ASSET_URL } } })
			local _, err = updater():check()
			assert.equal(OtaUpdater.Errors.NO_DIGEST, err)
		end)

		it("refuses an asset over the size cap", function()
			serve("zip", {
				assets = { {
					name = "opds_plus.koplugin.zip",
					size = OtaUpdater.MAX_ASSET_SIZE + 1,
					digest = "sha256:" .. string.rep("a", 64),
					browser_download_url = ASSET_URL,
				} },
			})
			local _, err = updater():check()
			assert.equal(OtaUpdater.Errors.TOO_LARGE, err)
		end)

		it("ignores drafts, pre-releases and tags that are not versions", function()
			for _, overrides in ipairs({ { prerelease = true }, { draft = true }, { tag_name = "nightly" } }) do
				http = fake_http.new()
				helper.stub("socket.http", http)
				serve("zip", overrides)
				local _, err = updater():check()
				assert.equal(OtaUpdater.Errors.BAD_RESPONSE, err)
			end
		end)

		it("refuses a body that is not JSON", function()
			http:on(OtaUpdater.LATEST_URL, { code = 200, body = "<html>" })
			local _, err = updater():check()
			assert.equal(OtaUpdater.Errors.BAD_RESPONSE, err)
		end)

		it("does not connect without the CA bundle", function()
			ca_file = root .. "/missing.crt"
			local _, err = updater():check()
			assert.equal(OtaUpdater.Errors.TLS, err)
			assert.equal(0, #http.requests)
		end)

		it("only connects to GitHub hosts", function()
			assert.is_true(OtaUpdater.isAllowedHost("api.github.com"))
			assert.is_true(OtaUpdater.isAllowedHost("objects.githubusercontent.com"))
			assert.is_false(OtaUpdater.isAllowedHost("evil.com"))
			assert.is_false(OtaUpdater.isAllowedHost("github.com.evil.com"))
			assert.is_false(OtaUpdater.isAllowedHost("x.githubusercontent.com.evil.com"))
		end)
	end)

	describe("install", function()
		it("downloads, verifies, stages and swaps in the release, keeping a backup", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			assert.is_true(check_and_install(updater()))
			assert.matches('"1.4.0"', read(plugin_dir .. "/opds_plus_version.lua"))
			assert.equal("return 1\n", read(plugin_dir .. "/services/new_module.lua"))
			assert.matches('"1.3.1"', read(plugin_dir .. ".bak/opds_plus_version.lua"))
			assert.is_nil(mode(plugin_dir .. ".new"))
			assert.is_nil(mode(cache_dir .. "/opds_plus.koplugin.zip"))
			assert.is_true(OtaUpdater.restart_pending)
		end)

		it("does not follow the download off GitHub", function()
			local zip = zipbuilder.plugin(plugin_files("1.4.0"))
			http:on(OtaUpdater.LATEST_URL, { code = 200, body = release_json(zip) })
			http:on(ASSET_URL, { code = 302, headers = { location = "https://evil.example.com/zip" } })
			local _, err = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.NETWORK, err)
			assert.equal(0, #http:requests_to("https://evil.example.com/zip"))
			assert.matches('"1.3.1"', read(plugin_dir .. "/opds_plus_version.lua"))
		end)

		it("uses the sidecar digest when the API gives none", function()
			local zip = zipbuilder.plugin(plugin_files("1.4.0"))
			serve(zip, {
				assets = {
					{ name = "opds_plus.koplugin.zip", size = #zip, browser_download_url = ASSET_URL },
					{ name = "opds_plus.koplugin.zip.sha256", browser_download_url = SIDECAR_URL },
				},
			})
			http:on(SIDECAR_URL, { code = 200, body = sha256(zip) .. "  opds_plus.koplugin.zip\n" })
			assert.is_true(check_and_install(updater()))
			assert.matches('"1.4.0"', read(plugin_dir .. "/opds_plus_version.lua"))
		end)

		it("leaves the plugin alone when the digest does not match", function()
			local zip = zipbuilder.plugin(plugin_files("1.4.0"))
			http:on(OtaUpdater.LATEST_URL, {
				code = 200,
				body = release_json(zip, {
					assets = { {
						name = "opds_plus.koplugin.zip",
						size = #zip,
						digest = "sha256:" .. string.rep("0", 64),
						browser_download_url = ASSET_URL,
					} },
				}),
			})
			http:on(ASSET_URL, { code = 200, body = zip })
			local ok, err = check_and_install(updater())
			assert.is_nil(ok)
			assert.equal(OtaUpdater.Errors.DIGEST_MISMATCH, err)
			assert.matches('"1.3.1"', read(plugin_dir .. "/opds_plus_version.lua"))
			assert.is_nil(mode(plugin_dir .. ".new"))
			assert.is_nil(mode(plugin_dir .. ".bak"))
			assert.is_nil(mode(cache_dir .. "/opds_plus.koplugin.zip"))
			assert.is_false(OtaUpdater.restart_pending)
		end)

		it("refuses an archive with an entry that escapes the plugin folder", function()
			local zip = zipbuilder.build({
				{ path = "opds_plus.koplugin/", mode = "directory" },
				{ path = "opds_plus.koplugin/main.lua", mode = "file", content = "return {}\n" },
				{ path = "opds_plus.koplugin/../escaped.lua", mode = "file", content = "x" },
			})
			serve(zip)
			local _, err = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.INVALID_ARCHIVE, err)
			assert.is_nil(mode(plugins .. "/escaped.lua"))
			assert.equal(0, #archiver.extracted)
		end)

		it("refuses an archive with a link in it", function()
			local zip = zipbuilder.build({
				{ path = "opds_plus.koplugin/", mode = "directory" },
				{ path = "opds_plus.koplugin/main.lua", mode = "link", content = "/etc/passwd" },
			})
			serve(zip)
			local _, err = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.INVALID_ARCHIVE, err)
		end)

		it("refuses a release whose files say another version", function()
			serve(zipbuilder.plugin(plugin_files("1.3.9")))
			local _, err = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.VALIDATION_FAILED, err)
			assert.matches('"1.3.1"', read(plugin_dir .. "/opds_plus_version.lua"))
			assert.is_nil(mode(plugin_dir .. ".new"))
		end)

		it("refuses a release with a Lua file that does not load", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0", { ["ui/broken.lua"] = "return {" })))
			local _, err, detail = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.VALIDATION_FAILED, err)
			assert.matches("broken.lua", detail)
		end)

		it("refuses a release missing a required file", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0", { ["_meta.lua"] = false })))
			local _, err, detail = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.VALIDATION_FAILED, err)
			assert.matches("_meta.lua", detail)
		end)

		it("refuses a release that needs a newer KOReader", function()
			local files = plugin_files("1.4.0")
			files["opds_plus_version.lua"] = 'return { VERSION = "1.4.0", MIN_KOREADER = "v2099.01" }\n'
			serve(zipbuilder.plugin(files))
			local _, err, detail = check_and_install(updater({
				koreader_supports = function(min_version)
					return min_version ~= "v2099.01"
				end,
			}))
			assert.equal(OtaUpdater.Errors.KOREADER_TOO_OLD, err)
			assert.equal("v2099.01", detail)
		end)

		it("stops when the archive can't be extracted", function()
			archiver = fake_archiver.new({ fail_extract = { ["opds_plus.koplugin/main.lua"] = true } })
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local _, err = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.INVALID_ARCHIVE, err)
			assert.is_nil(mode(plugin_dir .. ".new"))
		end)

		it("refuses a development install unless allowed", function()
			lfs.mkdir(plugin_dir .. "/.git")
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local ota = updater()
			local _, err = check_and_install(ota)
			assert.equal(OtaUpdater.Errors.DEV_INSTALL, err)
			assert.equal(0, #http:requests_to(CDN_URL))
			assert.is_true(check_and_install(ota, { allow_dev = true }))
		end)

		it("refuses a plugin folder that is a link", function()
			local checkout = root .. "/checkout.koplugin"
			assert(os.rename(plugin_dir, checkout))
			os.execute(string.format("ln -s '%s' '%s'", checkout, plugin_dir))
			assert.equal("link", mode(plugin_dir))
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local _, err = check_and_install(updater())
			assert.equal(OtaUpdater.Errors.DEV_INSTALL, err)
			assert.equal("link", mode(plugin_dir))
		end)

		it("refuses to start without room for the download and the staged copy", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local _, err = check_and_install(updater({
				free_space = function()
					return 10
				end,
			}))
			assert.equal(OtaUpdater.Errors.LOW_SPACE, err)
			assert.equal(0, #http:requests_to(CDN_URL))
		end)

		it("refuses when there is no archiver", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local ota = updater()
			ota.archiver = nil
			helper.stub("ffi/archiver", false)
			local _, err = check_and_install(ota)
			assert.equal(OtaUpdater.Errors.ARCHIVE_UNSUPPORTED, err)
		end)

		it("refuses a plugins folder it can't write to", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			os.execute(string.format("chmod 555 '%s'", plugins))
			local ok, err = check_and_install(updater())
			os.execute(string.format("chmod 755 '%s'", plugins))
			if ok then
				pending("running as root: permissions are not enforced")
				return
			end
			assert.equal(OtaUpdater.Errors.READ_ONLY, err)
			assert.equal(0, #http:requests_to(CDN_URL))
		end)

		it("replaces a stale backup and staging folder", function()
			lfs.mkdir(plugin_dir .. ".bak")
			write(plugin_dir .. ".bak/stale.lua", "old")
			lfs.mkdir(plugin_dir .. ".new")
			write(plugin_dir .. ".new/half.lua", "half")
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			assert.is_true(check_and_install(updater()))
			assert.is_nil(mode(plugin_dir .. ".bak/stale.lua"))
			assert.matches('"1.3.1"', read(plugin_dir .. ".bak/opds_plus_version.lua"))
			assert.is_nil(mode(plugin_dir .. "/half.lua"))
		end)

		it("puts the plugin back when the staged copy can't be moved in", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local renames = {}
			local ota = updater({
				rename = function(from, to)
					renames[#renames + 1] = from .. " -> " .. to
					if from == plugin_dir .. ".new" then
						return nil, "fake rename failure"
					end
					return os.rename(from, to)
				end,
			})
			local ok, err = check_and_install(ota)
			assert.is_nil(ok)
			assert.equal(OtaUpdater.Errors.SWAP_FAILED, err)
			assert.same({
				plugin_dir .. " -> " .. plugin_dir .. ".bak",
				plugin_dir .. ".new -> " .. plugin_dir,
				plugin_dir .. ".bak -> " .. plugin_dir,
			}, renames)
			assert.matches('"1.3.1"', read(plugin_dir .. "/opds_plus_version.lua"))
			assert.is_nil(mode(plugin_dir .. ".new"))
			assert.is_false(OtaUpdater.restart_pending)
		end)

		it("can be cancelled from the progress callback", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local ok = check_and_install(updater(), {
				progress = function()
					return false
				end,
			})
			assert.is_nil(ok)
			assert.matches('"1.3.1"', read(plugin_dir .. "/opds_plus_version.lua"))
			assert.is_nil(mode(cache_dir .. "/opds_plus.koplugin.zip"))
		end)
	end)

	describe("rollback", function()
		it("puts the previous version back and keeps the newer one as the backup", function()
			serve(zipbuilder.plugin(plugin_files("1.4.0")))
			local ota = updater()
			assert.is_true(check_and_install(ota))
			assert.is_true(ota:hasBackup())
			OtaUpdater.restart_pending = false
			assert.is_true(ota:rollback())
			assert.matches('"1.3.1"', read(plugin_dir .. "/opds_plus_version.lua"))
			assert.matches('"1.4.0"', read(plugin_dir .. ".bak/opds_plus_version.lua"))
			assert.is_nil(mode(plugin_dir .. ".new"))
			assert.is_true(OtaUpdater.restart_pending)
		end)

		it("does nothing without a backup", function()
			local ok, err = updater():rollback()
			assert.is_nil(ok)
			assert.equal(OtaUpdater.Errors.NO_BACKUP, err)
			assert.equal("directory", mode(plugin_dir))
		end)
	end)

	describe("cleanup", function()
		it("removes what an interrupted update left behind, and keeps the backup", function()
			lfs.mkdir(plugin_dir .. ".new")
			write(plugin_dir .. ".new/x.lua", "x")
			lfs.mkdir(plugin_dir .. ".bak")
			write(plugin_dir .. ".bak/_meta.lua", "return {}")
			write(cache_dir .. "/opds_plus.koplugin.zip", "partial")
			updater():cleanup()
			assert.is_nil(mode(plugin_dir .. ".new"))
			assert.is_nil(mode(cache_dir .. "/opds_plus.koplugin.zip"))
			assert.equal("file", mode(plugin_dir .. ".bak/_meta.lua"))
			assert.equal("directory", mode(plugin_dir))
		end)
	end)
end)
