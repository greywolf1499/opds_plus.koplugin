# Updating

From version 1.4.0 on, OPDS Plus updates itself. Versions before 1.4.0 can't, so install 1.4.0 or later by hand
once, as described in [Installation](Installation).

## Update from within KOReader

1. Open **OPDS Plus Catalog → Settings → Updates** and tap **Check for updates**.
2. If there is a newer release, its release notes are shown. Tap **Install**, **Skip this version** or
   **Later**.
3. Restart KOReader when asked.

The update is downloaded from GitHub, its checksum is compared with the one published with the release, and
every file in it is checked before anything is changed. The installed version is then swapped for the new one,
and kept next to it as `opds_plus.koplugin.bak`.

![An update is available](https://raw.githubusercontent.com/greywolf1499/opds_plus.koplugin/main/.github/screenshots/update_available.png)

## Weekly check

**Automatic update check (weekly)** is on by default. At most once a week, when you open OPDS Plus and the
device is already online, it checks for a new release and tells you about it once with a short notice. It never
installs anything by itself. A version you skipped is not announced again. **About OPDS Plus**, at the
bottom of **Settings**, shows when the last check was made.

## Roll back

After an update, **Roll back to previous version** puts the version before it back, and keeps the newer one so
you can switch again. Restart KOReader afterwards.

If the device lost power in the middle of an update and OPDS Plus is gone from the menu, open KOReader's
`plugins` folder and rename `opds_plus.koplugin.bak` back to `opds_plus.koplugin`.

## Development installs

A plugin folder that is a link, or has a `.git` folder in it, is a development install: update it with
`git pull`. **Allow updating a development install** lets the updater replace it anyway. A linked folder is then
moved aside as the backup, and the folder it points to is not changed.

## What a check sends

A check is one request to `api.github.com` for the latest release of this repository, with the user agent
`OPDSPlus/<version>`. GitHub sees your IP address, as with any request. Nothing else is sent, and OPDS Plus has
no server of its own. The [security policy](https://github.com/greywolf1499/opds_plus.koplugin/blob/main/SECURITY.md)
describes how the updater checks connections and archives.

## When an update fails

| Message | What to do |
| --- | --- |
| Could not reach GitHub | Check the Wi-Fi connection and try again. |
| The secure connection to GitHub failed | Correct the device's date and time if they are wrong, then try again. |
| GitHub answered with an error | Try again later. GitHub limits how often a device may ask. |
| The plugins folder can't be written to / not enough free space | Free some space, or install by hand. |
| This KOReader can't open zip archives | Install the update by hand from the release page. |
| The downloaded update did not match its checksum | Nothing was changed. Try again; if it keeps failing, install by hand. |

In every case the installed version is kept.
