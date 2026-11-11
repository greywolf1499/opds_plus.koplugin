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
page show for it too.

From 1.6.0, standard PSE `lastRead` and local saved positions are used for the default stream
action. Local rewinds, validated page selection and persistence are described in the
[streaming guide](Kavita#resume). There is also
[opt-in two-way progress](Kavita#two-way-streaming-progress) for Komga's OPDS 1.2 page streams.
This does not add page streaming to OPDS 2.0 feeds without a PSE stream or synchronize downloaded books.
Sending the final page marks the book complete; rewinding can mark it in progress again.
