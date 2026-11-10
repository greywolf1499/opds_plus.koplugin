# Calibre-Web and Calibre-Web-Automated

Calibre-Web and Calibre-Web-Automated serve an OPDS 1 catalog of your Calibre library.

## Add the catalog

| Field | Value |
| --- | --- |
| Catalog URL | `https://<server>/opds` (or `http://<server>:8083/opds` on a home network) |
| Username and password | your Calibre-Web login |

Calibre-Web's OPDS feed must be reachable with that login. If you put the server behind Cloudflare Access or a
similar gateway, add its headers to the catalog (see
[Views and Features](Views-and-Features#custom-http-headers)).

## What you get

- The start page lists Calibre-Web's sections: recently added, authors, series, shelves, languages and so on.
- Books show their series and number in it, such as "❖ Dune Chronicles #2", read from the `SERIES:` line
  that Calibre-Web puts in the description, and their language in the book details.
- Long shelves are paged: the next part of the feed is fetched as you go, to the last book.

## Tips

- **Use server filenames** (in the catalog's **Edit** dialog) keeps the file name that Calibre-Web gives a download,
  instead of naming it "Author - Title".
- Tick **Sync catalog** in the same dialog to include the catalog in **Sync all catalogs** (see
  [Views and Features](Views-and-Features#sync)).
