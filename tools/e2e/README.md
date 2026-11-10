# End-to-end kits

These scripts run the plugin inside a real KOReader, headless under `xvfb-run`, so they catch what the busted
specs cannot: KOReader's own widgets, its plugin loader, real downloads and restarts. CI does not run them;
run the ones that touch your change before opening a pull request.

All of them need `xvfb-run`, `python3` and KOReader in `KOREADER_DIR` (default `/usr/lib/koreader`). Each run
works in a fresh `mktemp` directory under `/tmp/opds_plus_test_*` (its own `KO_HOME`, `HOME` and `TMPDIR`),
checks that the directory is the one it made before removing it, and leaves the rest of the system alone.

| Kit | Network | What it checks |
|-----|---------|----------------|
| `catalog/run.sh` | loopback only | Catalog browsing against a mock OPDS server: paging, covers, grid and list views, series, downloads, sync, custom headers, OPDS 2.0 (groups, shelves, facets, search) and more |
| `catalog/screenshots.sh` | loopback only | Regenerates the README screenshots in `.github/screenshots/` |
| `ota/run.sh` | loopback only | The self-updater against a mock of GitHub's API: update, rollback, restart, bad digest, read-only and development installs |
| `ota/real_dryrun.sh` | GitHub | Before tagging: the updater fetches the latest real release, checks its digest and swaps it into a throwaway copy |
| `opds/live.sh` | the internet | Smoke run against real public catalogs, optionally the Komga demo and your own Calibre-Web-Automated |

## catalog

```bash
tools/e2e/catalog/run.sh                    # every scenario except the explicit ones (a few minutes)
tools/e2e/catalog/run.sh opds2,series       # only these
HARNESS_KEEP=1 tools/e2e/catalog/run.sh p50 # keep the work dir: ko.log, requests.jsonl, shots/
```

`run.sh` starts `mock_opds_server.py` on a free loopback port, seeds the plugin's settings with
`opdsplus_seed.lua` (two catalogs on that server, automatic update checks off), links the repository in as the
plugin and installs `driver.lua` as a KOReader user patch. The driver works through the scenarios and writes
`<scenario>.<check>=ok|FAIL` lines; the script prints them with a summary of the requests the server saw, and
exits 1 when a scenario fails or the run does not finish. The scenario list is at the end of `driver.lua`; the
server's routes are listed at the top of `mock_opds_server.py`.

Some scenarios are explicit (only run when named): `shots`, and `cwapaging` and `cwadownload`, which need a
Calibre-Web-Automated server (`HARNESS_CWA_URL`, `HARNESS_CWA_USER`, `HARNESS_CWA_PASS`, plus
`HARNESS_CWA_TOTAL` for `cwapaging`; see the comments above them in `driver.lua`).

### Screenshots

```bash
.tools/venv/bin/pip install pillow   # once; .tools/venv comes from scripts/setup_test_env.sh
tools/e2e/catalog/screenshots.sh     # rewrites .github/screenshots/*.png
```

The pictures show a mock catalog of public-domain classics (`showcase.py`), served as OPDS 1 and as OPDS 2.0,
whose covers `make_covers.py` draws, so no real cover art or server ends up in the repository. The `shots`
scenario takes them on a 600×800 screen without the emulator's keyboard shortcuts, and `frame.py` puts them in
a 730×958 e-reader frame.

## ota

```bash
tools/e2e/ota/run.sh              # update, rollback and restart against the mock GitHub
OTA_E2E_KEEP=1 tools/e2e/ota/run.sh
tools/e2e/ota/real_dryrun.sh      # against the real latest release
```

The updater moves and deletes plugin directories, so these kits install the built release archive as a plain
copy; the repository is never linked into their `KO_HOME`.

## opds

```bash
tools/e2e/opds/live.sh
OPDS_LIVE_KOMGA=user:password tools/e2e/opds/live.sh
OPDS_LIVE_CWA_URL=http://localhost:8083/opds OPDS_LIVE_CWA=user:password tools/e2e/opds/live.sh
```

Opens each catalog, follows a few folders and runs a search, at most one request per second. Logins are only
read from the environment, and the run fails if one shows up in KOReader's log.
