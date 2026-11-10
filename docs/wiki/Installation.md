# Installation

OPDS Plus needs KOReader v2025.10 or later.

## Install the release

1. Download `opds_plus.koplugin.zip` from the
   [latest release](https://github.com/greywolf1499/opds_plus.koplugin/releases/latest).
2. Extract it into the `plugins` folder of KOReader. The archive holds one folder, `opds_plus.koplugin`, which
   must keep that exact name. Where the `plugins` folder is depends on the device:

   | Device | `plugins` folder |
   | --- | --- |
   | Kindle, Kobo, PocketBook and similar | `koreader/plugins/` on the device's storage |
   | Android | `koreader/plugins/` on the internal storage |
   | Linux | `~/.config/koreader/plugins/` |
   | macOS | `~/Library/Application Support/koreader/plugins/` |

   The [KOReader wiki](https://github.com/koreader/koreader/wiki#installationupgrading) has the details for
   every platform.
3. Restart KOReader.
4. In the File Browser, open the top menu: **OPDS Plus Catalog** is in it. KOReader may show it as
   **NEW: OPDS Plus Catalog** until you sort it into a menu of your own.

Once installed, later versions can be installed from within KOReader: see [Updating](Updating).

## Install from git (for development)

```bash
cd ~/.config/koreader/plugins/   # the plugins folder of your KOReader
git clone https://github.com/greywolf1499/opds_plus.koplugin.git
```

A plugin folder that is a link, or has a `.git` folder in it, is a development install. The in-app updater
leaves it alone unless you allow it (see [Updating](Updating)); use `git pull` instead.

## First steps

1. Open **OPDS Plus Catalog → Browse Catalogs**. Six public catalogs are already there: Project Gutenberg,
   Standard Ebooks, ManyBooks, Internet Archive, textos.info (Spanish) and Gallica (French).
2. To add your own server, tap the menu at the top left of the list of catalogs and tap **Add catalog**. Enter
   a name, the catalog's OPDS address and, if the server needs it, a username and password.
3. Tap a catalog to browse it, and a book to see its details and download it.

The server guides list the right address for [Calibre-Web](Calibre-Web), [Kavita](Kavita) and [Komga](Komga).

## If the plugin does not show up

- Check that the folder is named exactly `opds_plus.koplugin` and that `_meta.lua` and `main.lua` are directly
  inside it (not in a second `opds_plus.koplugin` folder).
- Check that KOReader is v2025.10 or later.
- Look in KOReader's `crash.log` for errors that mention `opds_plus`.
