# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Description Saved with Downloads**: The description a catalog gives for a book is saved with the downloaded file as KOReader custom book metadata, so it shows in Book information. This covers single downloads, the download queue and sync. A description the book already has, or custom metadata you edited yourself, is never replaced. "Save Description with Downloads" under Settings turns this off (Issue #85).
- **Thumbnails on Navigation Entries**: Entries that only open a sub-catalog, such as a series in a comic server's feed, now show their thumbnail in list and grid view when the server provides one. "Thumbnails on Navigation Entries" under Settings > Cover Settings turns this off (Issue #24).
- **Default Catalog**: Settings > Default Catalog picks the catalog that opens as soon as you browse catalogs. It opens on top of the list of catalogs, so Back returns to the list to pick another one. Choosing "None" starts from the list as before (Issue #89).
- **Parallel Cover Downloads**: Covers are downloaded in background processes, two at a time, so pages of covers fill in faster and a slow server no longer freezes the screen while a cover downloads. "Parallel Cover Downloads" under Settings > Cover Settings turns this off. Where a background process can't be started, covers are downloaded one at a time as before (PR #98 by @demrom).
- **Keyboard and D-pad Navigation**: Devices with hardware keys can browse without the touchscreen. Back walks up one catalog level, Home closes the browser, the D-pad moves the focus item by item (cell by cell in the grid) with an underline showing where it is, and Enter opens the focused item. List covers are slightly smaller on these devices to leave room for the underline (PR #93 by @iav).

### Changed
- **Switching Views**: Toggling between list and grid view keeps you on the same item instead of reloading the catalog and going back to the first page (PR #93 by @iav).
- **Page Counter**: The page counter in the footer is KOReader's own button again instead of a plain label (PR #93 by @iav).
- **Fetching Ahead**: Paging forward no longer asks the server for another page of the catalog on every tap. The next page is requested when you are one screen from the end of what has been loaded, so long catalogs page smoothly and you never reach the end of the list while more is available (PR #92 by @iav).

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

[1.2.1]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.2.1
[1.2.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.2.0
[1.1.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.1.0
[1.0.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.0.0
