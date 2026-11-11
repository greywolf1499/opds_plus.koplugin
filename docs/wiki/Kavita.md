# Kavita

Kavita serves an OPDS 1 catalog of its libraries, and lets OPDS Plus stream comics and manga page by page.

## Add the catalog

1. An administrator turns OPDS on in Kavita's server settings.
2. In your Kavita account settings, copy the **OPDS URL**. It looks like `https://<server>/api/opds/<api key>`.
3. In OPDS Plus, add a catalog with that address. Kavita needs no username or password here: the API key in the
   address identifies you.

Treat the OPDS URL like a password. Anyone who has it can read your libraries, and OPDS Plus saves it as plain
text in `opdsplus.lua`.

## Page streaming

Kavita offers comics, manga and other books as a stream of pages, so you can read them without downloading the
file. The book's download dialog then shows:

- **Page stream**: opens the stream where you left off in Kavita, or at the first page.
- **Stream from page**: asks for a page number first.
- **Resume stream from page N**: shown when the catalog says which page you last read.

The book details list the stream as **Stream (N pages)** next to the formats you can download.

Pages are fetched one at a time as you turn them, with the catalog's custom headers. If Kavita's reply about
your progress is missing or cannot be read, the stream starts at the first page.

### Resume in development builds

The default **Stream / Page stream** action first uses the position saved on this device, then the
catalog's standard PSE `lastRead` position. Only a recognized Kavita stream without either position needs
a Kavita progress lookup. A local rewind is respected; the largest page number does not automatically win.
The explicit **Resume ... N** button still selects the position named by the catalog.

**Stream from page** validates your choice before fetching any image. Positions are one-based in the
viewer and PSE metadata; page-image URLs are zero-based. Resume positions beyond a changed page count
are clamped to its last page. Invalid counts are refused.

Local progress changes only after a successfully loaded page is painted, not on speculative requests or
failed/invalid images. It is saved with the plugin settings on viewer close or suspend. The latest
position for up to 500 books is retained, scoped by catalog, account and feed identity (or the exact
stream URL when the feed has no identity). Older entries are evicted first. Stored keys are hashed;
this is not encryption of the settings file or catalog credentials.

Kavita's OPDS image endpoint itself can update progress when an image is fetched. Development builds
instead use its read-only `/api/Reader/image` endpoint, including PDF image extraction, without falling
back to the writing endpoint. A failed page is reported and does not advance local progress.
Explicit two-way server synchronization is a separate, not-yet-implemented feature. These changes do
not synchronize downloaded EPUBs or other local documents.
