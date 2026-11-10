# OPDS 2.0 fixtures

Trimmed captures of public test catalogs plus one synthetic feed. The captures keep the servers'
structure verbatim (keys, link relations, types, absolute hrefs); only the number of entries is cut
down and long descriptions are shortened. They hold no credentials: the Komga demo is public and its
responses carry none.

Re-capture with the dual Accept header KOReader sends
(`application/opds+json, application/atom+xml;profile=opds-catalog, */*`) and trim the same way.

| File | Captured from | Exercises |
| --- | --- | --- |
| `test_opds_home.json` | `https://test.opds.io/2.0/home.json` | Navigation, a group with a `self` link, a navigation group, a group of inline publications without a link (listed in place), an object author |
| `test_opds_publications.json` | `https://test.opds.io/2.0/publications.json` | Sized images, `belongsTo.series` with an integer position and a plain `collection`, string and list authors |
| `komga_catalog.json` | Komga demo, `/opds/v2/catalog` | Groups with both a link and inline navigation, a templated search link, `rel` without `type` |
| `komga_latest_books.json` | Komga demo, `/opds/v2/libraries/books/latest` | `contributor` lists, series lists with float positions, one image without rel or size, manifest and progression links that are not books, `readingOrder` and friends (pruned) |
| `komga_search.json` | Komga demo, `/opds/v2/search?query=the` | Search results that come only as a group of publications without a link |
| `edge_cases.json` | Synthetic | Nulls, localized strings, `rel` lists, relative links, pagination, facets with counts and an active one, borrow, indirect acquisition, a readable link without `rel`, images chosen by rel, fractional and string series positions, empty and link-less groups |
