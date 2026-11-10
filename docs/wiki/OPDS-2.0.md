# OPDS 2.0 Catalogs

From version 1.5.0, OPDS Plus reads OPDS 2.0 catalogs (the JSON format) as well as OPDS 1 catalogs (the Atom
format). You add an OPDS 2.0 catalog the same way as any other. There is nothing to set: OPDS Plus tells the two
formats apart by the feed the server sends.

## Which servers send OPDS 2.0

| Server | OPDS 2.0 address | Notes |
| --- | --- | --- |
| Komga | `https://<server>/opds/v2/catalog` | Log in with your Komga username and password. Komga's OPDS 1 address (`/opds/v1.2/catalog`) still works too. |
| test.opds.io | `https://test.opds.io/2.0/home.json` | A public sample catalog, handy to try the feature. |
| Any other OPDS 2.0 server | the server's start feed | Username and password (Basic) login only. |

Calibre-Web, Calibre-Web-Automated, Kavita, COPS and the default catalogs send OPDS 1. They keep working as before.

## What you see

- **Navigation** links open like folders.
- **Groups** with a link of their own (for example "Latest" or "On deck") open that link. When the catalog says
  how many books the group holds, the number shows next to it in List View.
- **Shelves** are groups of books that a catalog lists on its start page without a link of their own, such as a
  "Staff picks" or "Keep reading" row. They open as their own folder with their book count, so the start page
  stays short. Search results that come only in such groups, as Komga sends them, are listed straight away.
- **Books** show their authors, series and number in it, cover, description, publisher, publication date and
  language when the catalog provides them. Every downloadable format is offered: EPUB, PDF, CBZ, CBR and so on.
- **Paging**: the next page is fetched as you scroll or tap the next page button, until the end of the feed.
- **Facets** (filters such as genre or read status) are in the menu at the top left, with their counts, and the
  active one is ticked.
- **Search** is in the same menu when the catalog offers it.

## How OPDS Plus asks for OPDS 2.0

Catalog requests carry an `Accept` header that lists OPDS 2.0 first and OPDS 1 after it, so a server that offers
both sends the newer one. If a server refuses such a request, OPDS Plus asks again without the header until
KOReader restarts. A catalog's own **Accept** header, set under its custom headers, always wins: set it to
`application/atom+xml` to keep a server on OPDS 1.

## Troubleshooting

- **"This address is a web page, not an OPDS catalog"**: the address leads to a login page or the server's web
  reader. Use the OPDS address from the table above or from the server's documentation.
- **A shelf is empty**: the catalog changed since its start page was opened. Go back and open the start page again.
- **A book has no download button**: the catalog lists it without a file KOReader can open (an audiobook, or a
  book that can only be read in the browser).
- **Login keeps failing**: OPDS Plus sends a username and password (Basic authentication). Catalogs that need an
  OPDS 2.0 authentication document or OAuth are not supported yet.
