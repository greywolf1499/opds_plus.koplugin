# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Neighboring Cover Prefetch**: An off-by-default Cover Settings option warms the disk cache for one neighboring display page while the current covers are ready and input is idle. It requires caching and parallel downloads, never decodes or draws speculative images, and cancels on navigation, dialogs and close. Thanks to @iav for the prefetch work proposed in issue #117.
- **User Guide**: The [wiki](https://github.com/greywolf1499/opds_plus.koplugin/wiki) explains installing and updating OPDS Plus, its views and settings, setting up Calibre-Web, Kavita and Komga, OPDS 2.0 catalogs, and what to do about each error message.

### Changed

- **Formatted Release Notes**: Render update notes with KOReader's native Markdown viewer, or its existing converter and HTML scroller on v2025.10. Preserve Install / Skip / Later, keyboard scrolling and complete long notes. If rendering fails, explain it and offer the original plain text; do not fetch remote images or open links in notes.
- **Cancellable Catalog Loading**: Fetch, parse and map catalogs in the background while keeping the current page visible. Tap or press a key to cancel without changing the listing or history. If background processes are unavailable, ask before loading in the foreground, where input will pause. Catalog caching, search and sequential feed-page fetching are preserved.
- **Screenshots**: The README shows the book details, the update dialog and an OPDS 2.0 catalog's shelves and facets, all taken from a mock catalog of public-domain classics.
- **Editor Diagnostics**: Add a reproducible LuaLS check with accurate Busted assertions and KOReader module resolution, without disabling production warnings.

### Fixed

- **Catalog Credentials**: Keep usernames and passwords on their source catalog's scheme, host and port, including the first request to a feed link, cover, download or stream. Preserve destination-scoped custom headers and provider-owned tokens. Saved subcatalogs on another origin no longer inherit the source login. Older download-queue entries without a recorded origin withhold Basic credentials and explain how to re-add authenticated downloads.
- **Responsive Page Streaming**: Move image requests and fallback Kavita progress lookup into cancellable background workers. Keep the current image until its replacement is decoded; reject stale results and preserve painted-page progress on cancellation, failure, close and suspend. Bound requests with an overall watchdog and report unavailable workers instead of silently blocking in the foreground.
- **Streaming Resume**: Use standard PSE positions in both default stream actions and remember displayed pages locally, including rewinds. Validate page counts/choices and clamp stale positions; do not fetch page 1 before a resumed page or record failed/speculative requests. Use Kavita's read-only reader-image API rather than its progress-writing OPDS image endpoint. Keep up to 500 catalog/account-scoped local positions and flush on close/suspend; two-way server writes remain a separate feature.
- **Responsive Update Checks**: Move connectivity probes and release requests off the UI thread, retaining parent-side settings and notifications. Manual checks can be cancelled; automatic checks pass input through when interrupted and never wake Wi-Fi. Reject stale results, coalesce duplicate checks, bound stalled workers and cancel on suspend/close/install. Ask before any manual foreground fallback.
- **Series Descriptions**: Show a matching Calibre-style `SERIES:` metadata line only in the series field, not again in the description. Book details, download information and newly saved descriptions use the same cleanup. Keep rating/tags, prose, malformed or mismatched fields, and existing downloaded-book metadata unchanged.
- **Shared Cover Workers**: Visible and prefetched covers share a two-worker limit rather than starting two workers per batch. If subprocesses are unavailable, speculative warming is skipped instead of falling back to blocking network requests.
- **Decoded Cover Memory**: Keep an 8 MiB least-recently-used cover budget instead of retaining every visited page. Visible and dialog-borrowed images stay pinned, even when they exceed that budget. Release high-resolution dialog images and widget-scaled copies when their users close or are rebuilt.
- **Cover Loading and Keys**: Yield between cover decodes and widget updates, including cache hits and repeated cover URLs. Key and touch activity postpones expensive cover work without killing and restarting downloads. Thanks to @iav for the input-deferral work behind issue #117.
- **Closing Book Details**: Cancel a pending high-resolution cover when its dialog closes, instead of decoding it later or repainting a replacement dialog.
- **Invalid Book Addresses**: Empty download, cover and page-stream addresses report an error instead of crashing or opening a broken viewer. An invalid download address leaves any existing destination file untouched.
- **Update Validation**: If the staged version file becomes unreadable during validation, the update reports the failure and keeps the installed plugin instead of throwing a Lua error.
- **Kavita Resume**: Read complete JSON responses regardless of field order or network chunk boundaries. Invalid tokens and page numbers are reported without crashing, and generic page streams no longer attempt Kavita authentication.

## [1.5.0] - 2026-11-10

**Update from within KOReader**: **OPDS Plus Catalog → Settings → Updates → Check for updates**, or install by hand as before.

### Added
- **OPDS 2.0 Catalogs**: Catalogs that serve OPDS 2.0 (JSON) feeds open like any other: navigation, groups, books with their authors, series, covers and downloads, facets, pagination and search. OPDS Plus tells the two formats apart by the feed itself, so there is nothing to set.
- **Shelves**: Groups of books that an OPDS 2.0 catalog shows on its start page without a link of their own (like the samples on test.opds.io) open as folders, next to the groups that have a link, with the number of books they hold. Search results that come only in such groups are still listed straight away.
- **More Book Details**: The book details dialog shows the publisher, the publication date and the language when the catalog gives them, from OPDS 2.0 feeds and from the Dublin Core elements of OPDS 1 feeds (Calibre-Web sends the language).

### Changed
- **Catalog Requests Ask for OPDS 2.0 First**: Catalog requests now say which formats OPDS Plus reads, OPDS 2.0 first and then OPDS 1, so a server that has both can send the newer one. A server that refuses such a request is asked again the old way, and a catalog's own **Accept** header (in its custom headers) still wins.
- **Clearer Message for a Web Page**: An address that leads to a web page (a login page, a web reader) now says that it is not an OPDS catalog, instead of showing an empty or broken list.

### Fixed
- Comic books that servers label `application/x-cbr`, `application/x-rar-compressed` or similar are offered for download as `.cbr`, and types with parameters (`application/epub+zip; charset=utf-8`) are recognized.

## [1.4.0] - 2026-11-10

**Install this version by hand, as before.** From 1.4.0 on, OPDS Plus can update itself.

### Added
- **Updates from Within KOReader**: **OPDS Plus Catalog → Settings → Updates** has **Check for updates**, which shows the notes of a newer release and installs it after you tap **Install**. The download can be cancelled with a tap, and KOReader asks to restart once the new version is in place. **Skip this version** keeps the weekly check quiet about that release until a newer one comes out.
- **Weekly Update Check**: Once a week, when OPDS Plus is opened and the device is already online, it asks GitHub whether there is a newer release, and says so once with a short notice. It never turns Wi-Fi on, never installs anything by itself, and stays quiet when the check fails. Turn it off with **Automatic update check (weekly)**.
- **Roll Back**: The version an update replaced is kept, and **Roll back to previous version** puts it back. The newer one is kept in turn, so you can switch back.
- **Security Policy**: `SECURITY.md` explains how to report a vulnerability privately, and what OPDS Plus does and doesn't protect: saved passwords, catalog connections, and how updates are checked.

### Update Safety
- Updates come only from this repository's releases on GitHub, over HTTPS. The certificate is checked against KOReader's certificate bundle and must name the server it came from.
- The downloaded archive must match the size and SHA-256 checksum that GitHub publishes for it. Every file in it is checked before anything is unpacked, and the unpacked plugin must load and carry the version it claims before it replaces the installed one.
- The new version is unpacked next to the installed one and swapped in with two renames, so a failed update leaves the installed version as it was. A plugin folder that is a link or has a `.git` folder is treated as a development install and is not updated, unless you allow it in **Settings → Updates**.
- An update that needs a newer KOReader than yours is not installed.

### Changed
- **Release Archive**: The `opds_plus.koplugin.zip` of a release now holds only the files the plugin runs on. It no longer carries the repository's own files (`.gitignore`, `.luacheckrc`, `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`). It is built by `scripts/build_release.py`, and the tests run on the very archive that gets published.
- **Automated Tests**: A test suite that runs without KOReader (`scripts/test.sh`), and a check of the release archive, now run next to luacheck on every pull request and every push to `main`. See CONTRIBUTING.md.

### Fixed
- **Redirects**: A request that a server redirects is now followed by OPDS Plus itself instead of by KOReader's HTTP library, for catalog pages, covers, downloads, sync and Kavita page streaming. KOReader's library got four things wrong. A redirect to another place on the same server dropped the saved username and password, so a catalog page asked you to add credentials you had already saved, and covers and downloads were refused. A redirect to another server carried the catalog's custom headers (Issue #94), and the Kavita token, along with it; they now go only to the catalog's own server. A permanent redirect (HTTP 308) was not followed. And with "Use server filenames", looking up the name of a file whose download address redirects repeated the request as a full download instead of asking for the headers only, so the whole book could be fetched just to read its name.
- **Catalog Address Checks**: Adding or editing a catalog no longer turns down an address that is fine: one typed with an upper-case protocol such as `HTTPS://`, one whose host name has an underscore (common for Docker and NAS names), or one with an IPv6 address in brackets, though some servers may still turn away the request KOReader sends to an IPv6 address. Spaces around the address are dropped, since a pasted address often comes with one. A port that is not a number from 1 to 65535 is reported on the spot instead of failing later.
- **Editing a Catalog Keeps Its Sync Point**: Saving the edit dialog forgot where the last sync had stopped, so the next sync no longer said "Up to date!". It went through the whole feed again and ran into the books it had already downloaded. The sync point is kept now, unless you changed the address.
- **Sync File Types**: The file types to sync are matched without regard to case, so `EPUB, PDF` works, and so does a server whose links end in `.EPUB`. A field holding only spaces or commas filters nothing, instead of blocking every download.
- **Books Counted After a Sync**: When a sync came across books that were already on the device, the "books downloaded" message came out too low, by one for each of them.
- **Description Next to an Empty Content Tag**: A book entry with an empty `<content/>` tag as well as a `<summary>` showed no description. The summary is used now.
- **Search Without a Usable Description**: A catalog whose OpenSearch description can't be fetched or read no longer offers a search that only reloads the catalog.
- **Odd Feeds and Servers**: A character reference that is not a number, such as `&#xZZ;`, no longer fails the whole feed, and neither does a title that is an empty XHTML `<div/>`. A redirect without a `Location` header, from a faulty server or proxy, is reported like any other failed request instead of causing an error while opening a catalog or downloading a book. With "Use server filenames", a file name taken from a redirect no longer keeps the query string or the percent-escapes of the address, and a redirect to an address with no file name no longer gives a file called `.epub`. Downloading to a folder that can't be written to fails at once, with the reason, instead of after asking the server for the book.
- **Kavita Page Streaming**: When Kavita's reply to the progress request has no page number in it, page streaming starts from the first page instead of failing after the viewer has opened.

## [1.3.1] - 2026-11-09

### Changed
- **One Request per Catalog Page**: Opening a catalog page asked the server for its headers first and then for the page, so a server that builds the whole feed for both, like Calibre-Web, did the work twice. Each page is now a single request: a server that tags or dates its feeds answers "not modified" when the copy kept on the device is still current, and any other server just sends the page.

### Fixed
- **Rest of a Long Feed Unreachable**: Jumping to the last page with the end chevron or the page number dialog landed on the last page fetched so far and left the next page button greyed out, so the books after it, such as the rest of a Calibre-Web shelf, could only be reached with a swipe. The next part of the feed is now fetched when you land there, and the button stays usable to the end of the feed (Issue #100).
- **Downloads Without a File Extension**: A book whose download address has no extension, such as `/download/7`, or ends in one KOReader cannot open, such as `get.php`, was saved under that name and could not be opened. The extension of the chosen format is now added.
- **Where to Set the Sync Folder**: The message shown when syncing without a sync folder now says where to set one: in the menu at the top left of the list of catalogs, under **Set sync folder**.
- **Download Folder When None Is Set**: Without a download folder picked with **Choose folder** in the download dialog, books were saved to the last folder opened in the file browser, which on a first start is KOReader's hidden help folder. They now go to the home folder, as in KOReader's own OPDS browser, and fall back to the last folder only when no home folder is known.
- **Duplicate PDF Download Buttons**: A PDF link whose address does not end in `.pdf` or `/pdf/` was added to the book a second time, with `.pdf` tacked on to an address the server never sent. When the link has a title, as in arXiv's feeds, the book info dialog listed the format twice ("EPUB, PDF, PDF"), the format chooser showed two PDF buttons, and a book with a single PDF asked which format to download. A link that is already a download is no longer added again. A catalog entry titled "pdf" also stays a catalog instead of turning into a book.

## [1.3.0] - 2026-11-09

### Added
- **Custom HTTP Headers**: A catalog can send extra HTTP headers with its requests, such as the `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers that a server behind Cloudflare Access (Zero Trust) asks for. Tap **Headers** when adding or editing a catalog and write one `Name: value` per line. They go with the catalog's feeds, covers, downloads and sync, and only to that catalog's own server (same scheme, host and port). A custom `Authorization` header replaces the catalog's username and password. Headers are saved as plain text, like the password (Issue #94).
- **Series Info**: Books show the series they belong to and their number in it, such as "❖ Dune Chronicles #2", under the author in list view and as a Series row in the book info dialog, so books that share a title can be told apart. The series is read from the `SERIES: Name [3]` line that Calibre and Calibre-Web put in the description, from `dc:series` with `dc:series_index` or `dc:seriesPosition`, and from the collection metadata that Grimmory sends. Grid view is unchanged (Issue #70).
- **Description Saved with Downloads**: The description a catalog gives for a book is saved with the downloaded file as KOReader custom book metadata, so it shows in Book information. This covers single downloads, the download queue and sync. A description the book already has, or custom metadata you edited yourself, is never replaced. "Save Description with Downloads" under Settings turns this off (Issue #85).
- **Thumbnails on Navigation Entries**: Entries that only open a sub-catalog, such as a series in a comic server's feed, now show their thumbnail in list and grid view when the server provides one. "Thumbnails on Navigation Entries" under Settings > Cover Settings turns this off (Issue #24).
- **Default Catalog**: Settings > Default Catalog picks the catalog that opens as soon as you browse catalogs. It opens on top of the list of catalogs, so Back returns to the list to pick another one. Choosing "None" starts from the list as before (Issue #89).
- **Parallel Cover Downloads**: Covers are downloaded in background processes, two at a time, so pages of covers fill in faster and a slow server no longer freezes the screen while a cover downloads. "Parallel Cover Downloads" under Settings > Cover Settings turns this off. Where a background process can't be started, covers are downloaded one at a time as before (PR #98 by @demrom).
- **Keyboard and D-pad Navigation**: Devices with hardware keys can browse without the touchscreen. Back walks up one catalog level, Home closes the browser, the D-pad moves the focus item by item (cell by cell in the grid) with an underline showing where it is, and Enter opens the focused item. List covers are slightly smaller on these devices to leave room for the underline (PR #93 by @iav).

### Changed
- **Switching Views**: Toggling between list and grid view keeps you on the same item instead of reloading the catalog and going back to the first page (PR #93 by @iav).
- **Page Counter**: The page counter in the footer is KOReader's own button again instead of a plain label (PR #93 by @iav).
- **Fetching Ahead**: Paging forward no longer asks the server for another page of the catalog on every tap. The next page is requested when you are one screen from the end of what has been loaded, so long catalogs page smoothly and you never reach the end of the list while more is available (PR #92 by @iav).

### Fixed
- **Covers After Switching Views**: Covers no longer turn into coloured noise after you switch between list and grid view and then page through or switch back. The views were freeing cover images that the catalog still needed.
- **Books With Several Authors**: A book with more than one author now lists all of them, such as "Robert Louis Stevenson, Lloyd Osbourne", in the list, the book info dialog and the file name instead of only the last one, as KOReader's own OPDS browser does (koreader/koreader#16303). A Force sync downloads such books once more under their new file name.

## [1.2.1] - 2026-11-09

### Changed
- **CI Maintenance**: Updated GitHub Actions dependencies for checkout and release publishing (PRs #81 and #88).

### Fixed
- **Cover Cache on Kindle**: The cover cache directory now resolves to an absolute path, so covers are cached on devices where KOReader runs from a relative directory (Issue #86, PR #87 by @cardoso42).
- **Cover Cache Keys**: Cache file names no longer change between LuaJIT's interpreter and compiled code, which made cached covers miss and download again (PR #97 by @demrom).
- **Cover Cache Robustness**: Falls back to KOReader's standard data directory when `getFullDataDir()` is missing or returns nothing, creates relative cache directories in place, and writes cached covers atomically so an interrupted write can no longer leave a truncated cover.
- **Local Hostnames**: Catalog URLs whose host has no dot, such as `http://booktrove:8083/opds`, are no longer rejected as an invalid hostname (Issue #91, PR #95 by @439qi).
- **Crawlable Catalogs**: Entries that link to a catalog with the OPDS `crawlable` relation, like the Standard Ebooks "All Ebooks" feed, now open instead of failing with "Cannot get catalog info from nil" (Issue #83).
- **Truncated Listings**: Entries with an empty `<content/>` tag no longer swallow the entries after them, which cut some listings short (Issue #100).
- **Sync All Gesture**: "Sync all catalogs" and "Force sync all catalogs" now say when no catalog has "Sync catalog" ticked instead of reporting "Up to date!", and the gesture versions wait for the network like the menu entries do (Issue #96).
- **Sync Failures**: A sync that fails no longer leaves "Synchronizing lists…" on screen, and the error is shown instead of being lost. Feeds with a link-less entry, such as a notice above the book list, and Project Gutenberg style catalogs with a single-book sub-feed now sync instead of failing (Issue #96).
- **Delete Plugin Settings**: KOReader's plugin manager can now delete OPDS Plus's settings and cover cache with "Disable plugin and delete settings" and "Delete plugin and settings". Downloaded books are kept (Issue #82).

### Notes
- Covers cached by earlier versions are downloaded once more after updating, because the cache file naming changed.

## [1.2.0] - 2026-03-19

### Added
- **Book Info Dialog**: Added a dedicated dialog with at-a-glance book metadata and improved cover handling.
- **Direct Sync Gesture Actions**: Added action-oriented gesture events for faster sync and navigation workflows.
- **Improved Cover Pipeline**: Added higher-quality cover loading with disk-backed cache and lifecycle-safe image handling.
- **New Cover Settings**:
  - Prefer Large Covers (quality-first source selection)
  - Enable Cover Cache toggle
  - Advanced cache controls: max size, TTL, and manual cache clear
- **Sync Dispatcher Integration**:
  - Added explicit dispatcher actions for `Sync all catalogs` and `Force sync all catalogs`
  - Supports direct invocation from KOReader gesture/action mapping

### Changed
- **Debug Architecture Refactor**:
  - Standardized debug logging through shared utility usage.
  - Extended state manager integration across UI menu components.
  - Removed obsolete facade/dead code and simplified loader signatures.
- **CI Maintenance**:
  - Updated GitHub Actions dependencies for checkout and artifact upload/download workflows.

### Fixed
- **Gesture Registration**: Fixed gesture registration failures (Issue #58).
- **Duplicate PDF Entries**: Prevented duplicate PDF files from being shown in results (Issue #57).
- **Book Info Dialog Stability**:
  - Fixed filename capture timing to avoid nil values.
  - Corrected cover widget and related dialog behavior.
  - Removed invalid imports and corrected build wiring.

### Notes
- This release includes merged community and maintenance pull requests together with issue-resolution fixes.
- Packaging layout improvements from prior releases are retained and compatible with the current codebase structure.
- New settings are available under **OPDS Plus Catalog → Settings → Cover Settings**.
- Sync actions can be used from catalog long-press workflows or mapped through KOReader dispatcher actions.

## [1.1.0] - 2025-01-18

### Added
- **Debug Mode Toggle**: Added developer setting to enable/disable verbose logging for troubleshooting
- **Version Display**: Plugin version now shown in settings menu ("About OPDS Plus v1.1.0")
- **Smart Text Truncation**: Titles and authors now display with ellipsis (…) when truncated
  - UTF-8 safe truncation for international characters
  - Word-aware truncation attempts to break at word boundaries
  - Binary search algorithm for optimal text fitting
- **Optimized Space Utilization**:
  - List view now dynamically adjusts cover sizes to minimize whitespace
  - Grid view automatically fits maximum rows based on available screen height
  - Smart calculations ensure complete items/tiles are always shown
  - Adaptive sizing works across all device screen sizes

### Changed
- **Improved List View Sizing**:
  - Preset sizes now target specific items per page (3, 4, 6, or 8 items)
  - Dynamically calculates optimal cover height to fill available space
  - Reduces wasted whitespace at bottom of screen
- **Improved Grid View Sizing**:
  - Preset layouts now target specific row counts for consistency
  - Automatically adds additional rows when space is available
  - No hardcoded row limits - scales infinitely on large displays
  - Grid borders and spacing optimized for better visual balance
- **Cleaned Up Debug Logging**:
  - Removed excessive debug output (banner separators, verbose logging)
  - All debug logging now conditional based on debug mode setting
  - Critical errors still logged regardless of debug mode
  - Significantly reduced log spam in production use

### Fixed
- **Release Package Structure**: GitHub Actions workflow now creates clean zip without nested directories
- **Template String Formatting**: Fixed `%%` appearing in confirmation dialogs (now displays as single `%`)
- **Loop Variable Conflicts**:
  - Fixed crashes in Grid Layout settings menu
  - Fixed crashes in Grid Border settings menu
  - Resolved variable name conflicts between gettext `_()` function and loop variables
- **Version Module Naming**: Renamed internal version module to avoid conflicts
- **Font Method Calls**: Corrected text width measurement to use proper KOReader API (`RenderText:sizeUtf8Text()`)

### Technical Improvements
- Conditional debug logging via `_debugLog()` method in all core modules
- Improved error handling and logging consistency
- Better separation of production vs. development logging
- Enhanced code maintainability with cleaner function signatures

### Performance
- Reduced UI lag from excessive logging in production
- Optimized text truncation algorithm using binary search
- Improved rendering performance with better whitespace calculations

### Notes
- Debug mode can be toggled in: **OPDS Plus Catalog → Settings → Developer → Debug Mode**
- Changes to view settings (cover sizes, grid layouts) apply when next browsing a catalog
- Compatible with all KOReader-supported devices and screen sizes
- Tested on e-readers, tablets, and desktop displays

---

## [1.0.0] - 2025-11-17
### Added
- Initial public release of OPDS Plus plugin.
- Extended OPDS browsing with cover display support (list & grid view).
- Grid view with customizable columns, border styles, thickness, and color.
- Font customization for titles and information text (family, size, weight, color).
- Cover size presets and custom sizing.
- Default catalog list (Gutenberg, Standard Ebooks, ManyBooks, Internet Archive, textos.info, Gallica).
- Persistent settings storage and retrieval.

### Notes
- Derivative of KOReader's built-in OPDS plugin with major UI/UX enhancements.
- Licensed under AGPLv3 consistent with KOReader.

[1.5.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.5.0
[1.4.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.4.0
[1.3.1]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.3.1
[1.3.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.3.0
[1.2.1]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.2.1
[1.2.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.2.0
[1.1.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.1.0
[1.0.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.0.0
