# OPDS 1.x fixtures

Hand-written feeds modelled on what the servers OPDS Plus talks to send: Calibre-Web, the Calibre
content server, Komga/Kavita (page streaming), COPS, and a plain navigation root. They are **not**
verbatim captures: titles, ids and hosts are invented, and only the structure that matters to the
parser and to `genItemTableFromCatalog` (link relations, types, attribute names, content markup,
relative hrefs) is kept faithful.

When a server starts sending something new, add a fixture that reproduces the bug before fixing it.
Real captures belong here only after removing credentials, API keys and personal data.

| File | Models | Exercises |
| --- | --- | --- |
| `navigation_root.xml` | A catalog root | `subsection`/sort/untyped-rel navigation links, an `alternate` HTML link, an OpenSearch description, an empty `<content/>` |
| `calibre_web_acquisition.xml` | Calibre-Web `/opds/new` | Acquisition and cover links, a `{searchTerms}` template next to an OpenSearch description, pagination links, `dcterms`, entities, a PDF that must be listed once |
| `calibre_content_server.xml` | Calibre content server | XHTML `<content>` with `SERIES:` lines, two authors, mixed entities |
| `series_shapes.xml` | Calibre-Web-Automated, dir2opds, Grimmory | Every way a series name and index reach an entry |
| `komga_pse.xml` | Komga, Kavita | Page-streaming (`pse:count`, `pse:lastRead`) next to a download, a sub-catalog with artwork |
| `cops_relative_links.xml` | COPS | Relative hrefs without a leading slash, `&amp;` in query strings, HTML `<content>` |
