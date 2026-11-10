-- Real-API dry run of the updater: tools/e2e/ota/real_dryrun.sh runs it with KOReader's luajit, from the
-- KOReader directory, as: luajit <this file> <repo> <work dir> <pretend version>
--
-- Checks the latest release on GitHub (TLS with the hostname check), downloads the asset, verifies its
-- digest, then stages and swaps it over <work>/plugins/opds_plus.koplugin, as an installed <pretend version>.
local repo, work, pretend = arg[1], arg[2], arg[3]
assert(work and work:match("^/tmp/opds_plus_test_dryrun%.[%w]+$"), "unexpected work dir " .. tostring(work))

package.path = table.concat({ repo .. "/?.lua", "common/?.lua", "frontend/?.lua", package.path }, ";")
package.cpath = table.concat({ "common/?.so", "libs/?.so", package.cpath }, ";")
require("ffi/loadlib")

local OtaUpdater = require("services.ota_updater")

local function versionIn(dir)
	local chunk = loadfile(dir .. "/opds_plus_version.lua")
	return chunk and chunk().VERSION
end

local plugin_dir = work .. "/plugins/opds_plus.koplugin"
local updater = assert(OtaUpdater.new({
	plugin_dir = plugin_dir,
	cache_dir = work .. "/cache",
	current_version = pretend,
}))

local result, err, detail = updater:check({})
assert(result, "check failed: " .. tostring(err) .. " " .. tostring(detail))
print("check", result.status, result.release and result.release.tag, result.release and result.release.digest)
assert(result.status == "update", "expected an update over " .. pretend)

local ok, install_err, install_detail = updater:install(result.release)
assert(ok, "install failed: " .. tostring(install_err) .. " " .. tostring(install_detail))
print("installed", versionIn(plugin_dir), "backup", versionIn(plugin_dir .. ".bak"))
assert(versionIn(plugin_dir) == result.release.version, "the plugin dir does not hold the release")
assert(updater:hasBackup(), "no backup kept")
assert(not io.open(updater.download_path), "the download was left behind")
print("DRY RUN OK")
