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
