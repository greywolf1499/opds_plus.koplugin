# End-to-end kits

These scripts run the plugin inside a real KOReader, headless under `xvfb-run`, so they catch what the busted
specs cannot: KOReader's own widgets, its plugin loader, real downloads and restarts. CI does not run them;
run the ones that touch your change before opening a pull request.

All of them need `xvfb-run`, `python3` and KOReader in `KOREADER_DIR` (default `/usr/lib/koreader`). Each run
works in a fresh `mktemp` directory under `/tmp/opds_plus_test_*` (its own `KO_HOME`, `HOME` and `TMPDIR`),
checks that the directory is the one it made before removing it, and leaves the rest of the system alone.
The catalog driver also redirects `os.tmpname()` into its validated private temporary directory: native
Lua temporary names do not honor `TMPDIR`.

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

The `parandroid` scenario checks both temporary-name exceptions and a missing
temporary path: covers must still load serially without starting a subprocess.

### Cover scheduling regression

```bash
tools/e2e/catalog/run.sh inputfairness,covergate,parcovers,parandroid
tools/e2e/catalog/run.sh nontouch,covers,descsave
```

`inputfairness` queues high-level key events through KOReader's input loop while six grid covers load,
adds 80 ms to each real image decode, and verifies that every key moves focus. It requires at most one
decode/widget update before input is handled and p95 enqueue-to-handler delay below 350 ms.
The before/after measurements below use the same emulator workload, with `9bcdd21` as the baseline:

| Covers | Before p50 / p95 | After p50 / p95 | Maximum decodes/updates before input |
| --- | --- | --- | --- |
| Cached unique URLs | 115 / 180 ms | 85 / 87 ms | 2 → 1 |
| Cached duplicate URLs | 366 / 560 ms | 82 / 86 ms | 6 → 1 |
| Cold downloads | 209 / 274 ms | 83 / 84 ms | 2 → 1 |

These are six-key samples with an injected decode cost, **not physical Kindle/e-ink measurements**.
One slow decode still blocks until it returns, and disabling parallel downloads still makes HTTP
synchronous. The scheduler yields after repaint before doing the next expensive unit of work;
`nextTick` alone is not an input yield.

`covergate` also closes a dialog before its delayed cover arrives and verifies cancellation, no late
decode, no remaining child and no temporary-file leak. `parcovers` checks parallel limits, cancellation
and stale fallback; `parandroid` checks serial fallback. Deterministic scheduler/ownership regressions
are in `spec/unit/image_loader_spec.lua`, with fake subprocesses and guarded temporary files.

Some scenarios are explicit (only run when named): `shots`, `catalogprofile`, and `cwapaging` and `cwadownload`, which need a
Calibre-Web-Automated server (`HARNESS_CWA_URL`, `HARNESS_CWA_USER`, `HARNESS_CWA_PASS`, plus
`HARNESS_CWA_TOTAL` for `cwapaging`; see the comments above them in `driver.lua`).

### Decoded cover memory

```bash
tools/e2e/catalog/run.sh covermemory
```

At the harness's default 1264×1680 / 300 dpi, `covermemory` browses sixteen grid pages and measures each
retained source bitmap's actual `stride * h`, including padding and pixel format. Against the merged
`e287a7c` baseline:

| Page | Before, bytes | After, bytes |
| --- | --- | --- |
| 1 | 1,114,470 | 1,114,470 |
| 8 | 8,915,760 | 8,358,525 |
| 16 | 17,831,520 | 8,358,525 |

The decoded cache stays below its production 8 MiB (8,388,608 byte) budget. It may exceed the budget
only for buffers that still have users; the bound is the larger of the budget and pinned source bytes.
This measures retained decoded pixels, **not process RSS**. KOReader's additional visible-widget scaling
buffers are not part of this cache; they are explicitly freed on widget replacement and close.

The scenario also forces a 256 KiB budget while a dialog borrows an off-screen cover, checks disk-only
redecoding and list/grid reuse, verifies actual freeing of high-resolution and scaled bitmaps, and paints
a dialog after its underlying menu closes. Catalog replacement and the final close leave no owned buffers
or stale-entry registry. Fake-buffer eviction and pinning tests live in `spec/unit/cover_memory_spec.lua`.

### Neighboring-cover prefetch

```bash
tools/e2e/catalog/run.sh coverprefetch
```

`coverprefetch` verifies the default-off setting and its menu toggle, waits for visible work, and warms just
one neighboring display page. On the default six-cover grid, a duplicate URL and one fresh cached cover
leave four network requests. Warming causes no decode or menu repaint, and opening that page then uses only
the cache. Disabling disk caching or parallel downloads prevents speculative requests.

The scenario cancels active warming on reversal, layout/catalog change, dialog opening and close, checking
owned child reaping and temporary-file cleanup. Concurrent visible and speculative batches share at most
two workers. Injected temporary-name and subprocess failures produce two expected `OPDS+ ERROR` warnings:
neither may fall back to synchronous speculative HTTP. These warnings are not Lua crashes.

The mock server's sleeping handlers can outlive a cancelled client. Concurrency is therefore measured on
uncancelled batches after earlier server handlers finish, separately from client cleanup. Scheduling specs
in `spec/unit/cover_loader_spec.lua` cover idle gates, direction resets, modal rearming and avoiding repeated
warming after completion. These emulator checks do not certify physical e-reader timing.

### Catalog loading

```bash
tools/e2e/catalog/run.sh catalogloading,condget,opds2,prefetch,defaultcat,customheaders
tools/e2e/catalog/run.sh catalogprofile  # explicit synchronous stage profiling
```

`catalogloading` fetches all 5,000 Atom entries from a feed delayed by 1.2 seconds. A 25 ms UI pulse measures
the largest timer gap, with a 350 ms limit and no truncation allowed. The synchronous baseline at `c4fcb6f`
had a 1,840 ms gap; background-loading runs measured 77–90 ms, including an isolated cold start at 600×800.
This measures emulator timer responsiveness, **not physical key/e-ink latency or total loading time**.
One slow render or a user-selected foreground fallback can still block input.

The scenario sends a real Back key during loading on page 3, checks listing/focus/history preservation,
replaces a slow request, closes during a request, verifies eventual child reaping and temporary-file cleanup,
and exercises HTTP failure and an unavailable-worker prompt followed by foreground loading.
It captures `catalog_before_loading.png` and `catalog_loading.png`; use `HARNESS_SHOTS_OUT` with an existing
directory to keep them, or `HARNESS_KEEP=1` to keep the private run directory.
KOReader's Trapper collects cancelled workers after its cleanup grace period, not synchronously at dismissal.
`defaultcat` also verifies that a late Wi-Fi callback cannot reopen a closed browser. The ordinary navigation
driver waits for catalog completion, and cover-only worker counts exclude Trapper's piped catalog workers.

`catalogprofile` times HTTP, decoding, mapping and widget creation separately. Baseline stages in milliseconds:

| Sample | HTTP | Decode | Map | Widgets | Payload bytes |
| --- | --- | --- | --- | --- | --- |
| Atom, 5,000 entries | 1,213 | 346 | 279 | 7 | 2,527,202 |
| OPDS 2 CPU sample, 5,000 entries | 1,202 | 71 | 283 | 3 | 2,708,607 |

The JSON HTTP fixture contains **20 publications**, expanded to 5,000 only for CPU profiling; its HTTP
measurement is not a 5,000-publication download. Fetch/parse/map move to the worker, while returned cache
validators, remembered Accept refusals and errors are applied in the parent and widgets stay on the UI
thread. Focused state-transfer and cancellation specs cover those boundaries. The new Trapper/TrapWidget
methods and serialization interface were also checked against KOReader v2025.10's source; emulator runs use
the installed version, not a physical minimum-version device.

The kit refuses to start if automatic update checks are enabled. Its seed sets `ota_auto_check = false` at
the storage root, not in a nested `settings` table. Profiling caught the old seed allowing an unrelated
blocking updater connectivity probe during cold-start measurements; those mixed measurements are not used
for the catalog comparison.

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
