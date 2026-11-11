# Komga

Komga serves both an OPDS 1 and an OPDS 2.0 catalog. OPDS Plus reads either; the OPDS 2.0 one has shelves,
facets and richer book details.

## Add the catalog

| Field | OPDS 2.0 (recommended) | OPDS 1 |
| --- | --- | --- |
| Catalog URL | `https://<server>/opds/v2/catalog` | `https://<server>/opds/v1.2/catalog` |
| Username and password | your Komga login | your Komga login |

## What you get with OPDS 2.0

- Komga's start page sections, such as "Keep reading" and "On deck", open as folders. Sections without a link
  of their own open as shelves with their book count.
- Search is in the menu at the top left. Komga sends search results in groups; OPDS Plus lists them straight
  away.
- Books show their series, number, authors, publisher, publication date and language when Komga gives them.

See [OPDS 2.0](OPDS-2.0) for everything that works with OPDS 2.0 catalogs.

## Notes

If Komga's OPDS 1 feed offers a book as a page stream, the stream buttons described on the [Kavita](Kavita)
page show for it too. In v1.5.0, use the explicit **Resume ...** button for a PSE position; the default
**Page stream** action starts at the first page.

Development builds also use standard PSE `lastRead` and local saved positions for the default stream
action. Local rewinds, validated page selection and persistence are described in the
[streaming guide](Kavita#resume-in-development-builds). This does not yet write progress back to Komga
or add page streaming to OPDS 2.0 feeds that provide no PSE stream.
