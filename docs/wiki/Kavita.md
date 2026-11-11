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
viewer and standard PSE metadata; page-image URLs are zero-based. Kavita instead publishes its
zero-based cursor in `lastRead`, so recognized Kavita links are normalized before displaying the
Resume button or opening a page. A completed chapter still resumes at its final page. Resume positions
beyond a changed page count are clamped to its last page. Invalid counts are refused.

Local progress changes only after a successfully loaded page is painted, not on speculative requests or
failed/invalid images. It is saved with the plugin settings on viewer close or suspend. The latest
position for up to 500 books is retained, scoped by catalog, account and feed identity (or the exact
stream URL when the feed has no identity). Older entries are evicted first. Stored keys are hashed;
this is not encryption of the settings file or catalog credentials.

Kavita's OPDS image endpoint itself can update progress when an image is fetched. Development builds
instead use its read-only `/api/Reader/image` endpoint, including PDF image extraction, without falling
back to the writing endpoint. A failed page is reported and does not advance local progress.
Server writes require the separate opt-in below. Downloaded EPUBs and other local documents are not synchronized.

Page-image requests and fallback Kavita progress lookup run in a cancellable background process.
While **Loading page...** is shown, a tap, gesture or key cancels that request; the cancellation input
is consumed, not passed through to the viewer. An already displayed image remains usable until its
replacement is decoded. Cancelling or suspending before the first image returns to the browser.
Requests have a 60-second overall watchdog. Close/suspend cancels pending work, and late results cannot
replace a newer page or advance progress. If a worker cannot start, the plugin explains the failure
rather than silently freezing input with a foreground retry; downloading the book remains an alternative.
Image decoding and drawing still happen on the UI thread, so this is not a guarantee against slow rendering.

![Cancellable loading over a synthetic page in the emulator](https://raw.githubusercontent.com/greywolf1499/opds_plus.koplugin/main/.github/screenshots/stream_loading.png)

### Two-way progress in development builds

Long-press the catalog, choose **Edit**, enable **Sync streaming progress**, and save. This is **off by
default** and separate from **Sync catalog**, which downloads books. Saving an enabled catalog asks
for confirmation explaining the server-side effects. Imported catalogs do not inherit this permission.

Supported links are Kavita's chapter PSE streams and Komga's OPDS 1.2 book-page streams, on the same
server and application path as the catalog. Kavita's API key must match the catalog's key. Generic or
foreign linked streams remain local-only, with an explanation. The provider verifies book/chapter
identity and page count; a changed count requires refreshing the catalog.

- Opening checks the server before choosing a position. A change on just one side is reconciled using
  the last acknowledged state; changes on both sides ask which to keep. Existing local positions
  without a baseline also ask when they differ. Explicit page choices ask if they differ from the
  current server position. **Read locally without syncing** leaves server state alone for this session.
- A selected remote or device position takes effect only after its image is actually painted.
  Failed or cancelled image loads retain the previous saved position.
- New painted-page changes are saved locally and coalesced for two seconds before sending. Server
  requests do not trap page-turn input. An older acknowledgement cannot clear a newer pending page.
- Sending the final page marks a book complete on either provider. Sending Kavita's first page can
  mark the chapter unread. Rewinds are allowed. Merely reopening the server's current position
  preserves its state, including unread or not-yet-completed status.
- Closing or suspending cancels pending requests, including writes. There is no hidden close-time
  upload. The latest pending page survives in settings and is reconciled on reopening (or resume).
  An unavailable progress API pauses synchronization with a visible message; it does not prevent
  local reading if images are still accessible. Page images are not an offline download cache.
- A cancelled or timed-out write may already have reached the server. Reopening checks before retrying,
  avoiding duplicate writes when the server already has the desired position.
- Changes to credentials, configured headers, stream links or page counts invalidate synchronization
  baselines, **not local saved pages**. A differing local position needs a fresh conflict choice.
  The header fingerprint is conservative: changing another catalog's headers may also require this.
  Baselines contain only positions, completion state, a bounded server revision and an opaque scope;
  they do not store API tokens or credentials.

These APIs do **not** offer atomic compare-and-swap. OPDS Plus reads immediately before writing and
confirms afterward, but another reader can still update between those requests. Do not use this as
a guarantee against simultaneous edits. Validation uses fake endpoints and the KOReader emulator;
no unauthorized progress writes are made to public/demo servers.
