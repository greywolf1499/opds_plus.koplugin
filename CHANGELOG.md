# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.1.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.1.0
[1.0.0]: https://github.com/greywolf1499/opds_plus.koplugin/releases/tag/v1.0.0
