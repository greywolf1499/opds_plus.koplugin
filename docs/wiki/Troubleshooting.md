# Troubleshooting

## Messages when opening a catalog

| Message | What it means and what to do |
| --- | --- |
| Authentication required for catalog. Please add a username and password. | The server wants a login. Long-press the catalog, tap **Edit** and fill in the username and password. |
| Failed to authenticate. Please check your username and password. | The server refused the login. Check both in the catalog's **Edit** dialog. |
| Catalog not found. | The server has nothing at that address. Check the URL against the server guides: [Calibre-Web](Calibre-Web), [Kavita](Kavita), [Komga](Komga). |
| This address is a web page, not an OPDS catalog | The address leads to a login page or the server's web reader. Use the server's OPDS address. |
| Cannot get catalog. Server response status: … | The server answered with an error. Try again later, or check the server's log. |
| Cannot get catalog. Server refuses to serve uncompressed content. | The server, or a proxy in front of it, only sends compressed pages. Change its configuration to allow uncompressed replies. |
| Insecure HTTPS → HTTP downgrade attempted by redirect | An `https` address was redirected to `http`. OPDS Plus refuses this; tell the server's administrator, or use the address it redirects to if you trust the network. |
| Background catalog loading is unavailable. Load in the foreground instead? | Development builds could not start a background worker. Cancel to keep browsing, or choose **Load** knowing input will pause until the request finishes. Changing the cover-download setting does not affect this. |
| Catalog loading failed. Please try again. | The background worker failed or returned no usable result. Retry, and include the corresponding log lines if it recurs. |

## A server behind Cloudflare Access or another gateway

If the catalog opens in a browser that is logged in to the gateway but not in OPDS Plus, the gateway needs its
own headers. Add them in the catalog's **Edit** dialog under **Headers**: see
[Views and Features](Views-and-Features#custom-http-headers).

## Covers

- **No covers at all**: some catalogs don't provide cover images. If a catalog that has covers shows none, turn
  off **Settings → Cover Settings → Parallel Cover Downloads** and open the page again.
- **Old covers**: **Settings → Cover Settings → Advanced → Clear Cover Cache**.
- **Slow keys while covers arrive**: keep **Parallel Cover Downloads** enabled if your device supports it.
  Development builds yield between cover updates and pause new decoding briefly during key/touch activity;
  downloads already in progress continue. A single slow decode or screen refresh still takes time.
  With parallel downloads disabled, a network request can still block input.
- **Neighboring covers are not prefetched** (development builds): this is off by default. Enable **Prefetch
  Neighboring Covers**, **Enable Cover Cache** and **Parallel Cover Downloads**. Warming only runs while the
  cover view is foreground, its visible covers are ready, and input is idle. It is skipped when background
  processes are unavailable; normal visible-cover loading still has its serial fallback.

## Downloads

- **Could not save file to: …**: the download folder can't be written to. Choose another folder in the download
  dialog.
- **A book has no download button**: the catalog lists it without a file KOReader can open, such as an audiobook
  or a book that can only be read in a browser.
- **Downloads have odd file names**: untick **Use server filenames** in the catalog's **Edit** dialog to name
  them "Author - Title".

## Sync

- **Sync does nothing**: sync needs a folder (**Set sync folder** in the menu at the top left of the list of
  catalogs) and only covers catalogs with **Sync catalog** ticked in their **Edit** dialog.

## Updates

See [Updating](Updating#when-an-update-fails) for the update messages. If OPDS Plus disappeared after an update
was interrupted, rename `opds_plus.koplugin.bak` back to `opds_plus.koplugin` in KOReader's `plugins` folder.

## Reporting a problem

1. Turn on **Settings → Developer → Debug Mode** for more detailed logging.
2. Repeat what went wrong.
3. Open an [issue](https://github.com/greywolf1499/opds_plus.koplugin/issues) with your KOReader and OPDS Plus
   versions (**Settings → About OPDS Plus**), the server you use, and the lines of KOReader's `crash.log` from
   that moment. Remove passwords, API keys and private addresses from the log first.

Security problems go through private reporting, as described in the
[security policy](https://github.com/greywolf1499/opds_plus.koplugin/blob/main/SECURITY.md).
