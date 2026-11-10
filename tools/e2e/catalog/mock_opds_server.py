#!/usr/bin/env python3
"""Mock OPDS server used to verify OPDS Plus behaviour without real servers.

Endpoints (GET and HEAD):
  /opds/                  root navigation feed (crawlable entry, paged entries, nav, echo)
  /opds/all               acquisition feed behind a rel=crawlable link
  /opds/paged             paginated acquisition feed
                          ?page=N &size=S (entries/page) &total=T &sc=K (every K-th entry has <content type="text"/>)
                          &delay=SECONDS
  /opds/nav               navigation feed whose entries carry thumbnails (for #24)
  /opds/series            books as Calibre-Web, Calibre-Web-Automated and Grimmory describe their series and
                          authors, plus a Gutenberg style single author and a bare entry (for #70)
  /opds/pdflinks          books whose PDF is linked the way Calibre's content server, Calibre-Web, Komga and arXiv
                          do it (for the duplicate PDF download button)
  /opds/echo              feed that lists the request headers it received
  /opds/desc, /opds/desc_sync
                          books with a catalog description (html or text) whose files are real EPUBs: one without
                          a description of its own, one that has it, one offered in two formats (for #85)
  /opds/sync, /opds/sync_mixed, /opds/gut_root (+ /opds/gut_sub.opds)
                          small newest-first feeds for the sync scenarios (plain, link-less first entry,
                          Project Gutenberg style with a one-book sub-feed)
  /cf/feed, /cf/cover/N.png, /cf/dl/N.epub
                          same data but 403 unless CF-Access-Client-Id/-Secret headers match
  /cover/N.png /thumb/N.png /dl/N.epub   media (?delay=SECONDS, ?fail=1 answers HTTP 500)
  /dl/real_no_desc.epub, /dl/real_desc.epub   valid EPUBs; the second one carries <dc:description>
  /opds2/home             OPDS 2.0 start page: navigation, a group with a link and a size, a shelf (a group of
                          publications without a link), a navigation group, a templated search link
  /opds2/books            OPDS 2.0 publications, 20 a page (?page=N), with series, publisher, language, two image
                          sizes, an EPUB and for every fifth book a CBZ, next/previous/first/last and a Genre facet
                          (?genre=fantasy narrows it to one page of 10)
  /opds2/search?query=Q   OPDS 2.0 search results the way Komga sends them: one group of publications, no link
  /dl/N.cbz               a small valid CBZ
  /opds/showcase          public-domain books for the README screenshots (see showcase.py); with --covers DIR
                          their covers are DIR/N.png (make_covers.py draws them), served as /showcase/cover/N.png
  /opds2/showcase, /opds2/showcase/books?genre=G
                          the same books as an OPDS 2.0 catalog: a start page with a group and a shelf, and the
                          list of books with a Genre facet
  /__stats, /__stats/reset  JSON counters for cover/thumb requests: current and max in-flight, request count,
                          requests that carried an Authorization header
Every request is appended to --log as one JSON line (method, path, headers).
"""
import argparse
import io
import json
import os
import struct
import threading
import time
import zipfile
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from xml.sax.saxutils import escape

from showcase import GENRES, SHOWCASE, YEARS

ATOM_NS = ('xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog" '
           'xmlns:dc="http://purl.org/dc/terms/" xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/"')
NAV = "application/atom+xml;profile=opds-catalog;kind=navigation"
ACQ = "application/atom+xml;profile=opds-catalog;kind=acquisition"
CF_ID, CF_SECRET = "test-id", "test-secret"

LOG_LOCK = threading.Lock()
LOG_PATH = None
COVERS_DIR = None

# Media concurrency stats for the parallel cover tests (GET /__stats, GET /__stats/reset).
STATS_LOCK = threading.Lock()
COND_LOCK = threading.Lock()
COND = {}
STATS = {"inflight": 0, "max_inflight": 0, "requests": 0, "with_auth": 0}


def is_media(path):
    base = path.split("?", 1)[0]
    if base.startswith("/cf/"):
        base = base[3:]
    return base.startswith(("/cover/", "/thumb/"))


def stats_start(headers):
    with STATS_LOCK:
        STATS["inflight"] += 1
        STATS["requests"] += 1
        STATS["max_inflight"] = max(STATS["max_inflight"], STATS["inflight"])
        if headers.get("Authorization"):
            STATS["with_auth"] += 1


def stats_end():
    with STATS_LOCK:
        STATS["inflight"] -= 1


def stats_reset():
    with STATS_LOCK:
        STATS.update(max_inflight=STATS["inflight"], requests=0, with_auth=0)


def png(n, w=120, h=180):
    color = bytes(((n * 37) % 256, (n * 91) % 256, (n * 53) % 256))
    raw = b"".join(b"\x00" + color * w for _ in range(h))

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def feed(title, self_href, kind, entries, links=""):
    return (f'<?xml version="1.0" encoding="utf-8"?>\n<feed {ATOM_NS}>\n'
            f"  <id>urn:mock:{self_href}</id>\n  <title>{title}</title>\n"
            f"  <updated>2026-07-01T00:00:00Z</updated>\n"
            f'  <link rel="self" href="{self_href}" type="{kind}"/>\n'
            f'  <link rel="start" href="/opds/" type="{NAV}"/>\n{links}{"".join(entries)}</feed>\n')


def nav_entry(title, href, rel="subsection", kind=ACQ, content="", thumb=None):
    thumb_xml = (f'\n    <link rel="http://opds-spec.org/image/thumbnail" href="{thumb}" type="image/png"/>'
                 if thumb else "")
    return (f"\n  <entry>\n    <title>{title}</title>\n    <id>urn:mock:nav:{title}</id>\n"
            f"    <updated>2026-07-01T00:00:00Z</updated>\n    <content type=\"text\">{content}</content>\n"
            f'    <link rel="{rel}" href="{href}" type="{kind}"/>{thumb_xml}\n  </entry>')


def book_entry(n, sc=0, prefix=""):
    content = ('<content type="text"/>' if sc and n % sc == 0
               else f'<content type="text">Summary of book {n}.</content>')
    return (f"\n  <entry>\n    <title>Book {n:04d}</title>\n    <id>urn:mock:book:{n}</id>\n"
            f"    <updated>2026-01-01T00:00:00Z</updated>\n    <author><name>Author {n % 17}</name></author>\n"
            f"    {content}\n"
            f'    <link rel="http://opds-spec.org/image" href="{prefix}/cover/{n}.png" type="image/png"/>\n'
            f'    <link rel="http://opds-spec.org/image/thumbnail" href="{prefix}/thumb/{n}.png" type="image/png"/>\n'
            f'    <link rel="http://opds-spec.org/acquisition" href="{prefix}/dl/{n}.epub" '
            f'type="application/epub+zip"/>\n  </entry>')


def paged_feed(q, path="/opds/paged", prefix=""):
    page = int(q.get("page", ["1"])[0])
    size = int(q.get("size", ["50"])[0])
    total = int(q.get("total", ["250"])[0])
    sc = int(q.get("sc", ["0"])[0])
    first = (page - 1) * size + 1
    last = min(page * size, total)
    extra = "".join(f"&{k}={v[0]}" for k, v in q.items() if k not in ("page",))
    links = ""
    if last < total:
        links += f'  <link rel="next" href="{path}?page={page + 1}{extra}" type="{ACQ}"/>\n'
    if page > 1:
        links += f'  <link rel="previous" href="{path}?page={page - 1}{extra}" type="{ACQ}"/>\n'
    links += f"  <opensearch:totalResults>{total}</opensearch:totalResults>\n"
    links += f"  <opensearch:itemsPerPage>{size}</opensearch:itemsPerPage>\n"
    entries = [book_entry(n, sc, prefix) for n in range(first, last + 1)]
    return feed(f"Paged books (page {page})", f"{path}?page={page}", ACQ, entries, links)


def root_feed():
    entries = [
        nav_entry("All Mock Books", "/opds/all", rel="http://opds-spec.org/crawlable",
                  content="Crawlable all-books feed (Standard Ebooks style)"),
        nav_entry("Paged 250 (50 per page)", "/opds/paged?page=1&size=50&total=250"),
        nav_entry("Paged 250 (100 per page)", "/opds/paged?page=1&size=100&total=250"),
        nav_entry("Paged 250 with 10% empty content", "/opds/paged?page=1&size=50&total=250&sc=10"),
        nav_entry("Paged 250 (100 per page, 10% empty content)", "/opds/paged?page=1&size=100&total=250&sc=10"),
        nav_entry("Navigation with thumbnails", "/opds/nav", kind=NAV),
        nav_entry("Series and authors", "/opds/series"),
        nav_entry("PDF links", "/opds/pdflinks"),
        nav_entry("Echo request headers", "/opds/echo"),
    ]
    return feed("Mock OPDS Root", "/opds/", NAV, entries)


def nav_feed():
    entries = [nav_entry(f"Category {i}", f"/opds/paged?page=1&size=20&total=40", content=f"Category {i}",
                         thumb=f"/thumb/{i}.png") for i in range(1, 7)]
    return feed("Navigation with thumbnails", "/opds/nav", NAV, entries)


def echo_feed(headers):
    entries = [nav_entry(f"{k}: {v}", "/opds/echo", content="header") for k, v in sorted(headers.items())]
    return feed("Echo request headers", "/opds/echo", ACQ, entries)


def plain_entry(title):
    return (f"\n  <entry>\n    <title>{title}</title>\n    <id>urn:mock:plain:{title}</id>\n"
            f"    <updated>2026-07-01T00:00:00Z</updated>\n    <content type=\"text\">No links here.</content>\n"
            f"  </entry>")


def sync_feed(kind):
    """Small newest-first feeds used by the sync scenarios (books 9xx never overlap the paged ones)."""
    if kind == "sync":
        return feed("Sync feed", "/opds/sync", ACQ, [book_entry(n) for n in (903, 902, 901)])
    if kind == "mixed":
        # First entry has no links at all, so it has neither acquisitions nor a URL.
        entries = [plain_entry("Notice without links")] + [book_entry(n) for n in (912, 911)]
        return feed("Sync feed with a link-less first entry", "/opds/sync_mixed", ACQ, entries)
    if kind == "gut_root":
        return feed("Gutenberg style root", "/opds/gut_root", NAV,
                    [nav_entry("Gutenberg style book", "/opds/gut_sub.opds", content="sub-feed with one book")])
    if kind == "gut_sub":
        return feed("Gutenberg style sub-feed", "/opds/gut_sub.opds", ACQ, [book_entry(921)])
    return None


def cf_feed():
    q = {"page": ["1"], "size": ["10"], "total": ["10"]}
    return paged_feed(q, path="/cf/feed", prefix="/cf")


EPUB_MIME = "application/epub+zip"
REAL_BOOK_TITLE, REAL_BOOK_AUTHOR = "Real Book Title", "Real Author"
REAL_BOOK_DESCRIPTION = "Embedded description of the real book."


def make_epub(description=None):
    """A small but valid EPUB, so KOReader can open it and read its metadata; the description is optional."""
    container = ('<?xml version="1.0"?>\n'
                 '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
                 '  <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>'
                 '</rootfiles>\n</container>\n')
    description_xml = f"\n    <dc:description>{description}</dc:description>" if description else ""
    opf = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">\n'
           '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n'
           f'    <dc:title>{REAL_BOOK_TITLE}</dc:title>\n'
           f'    <dc:creator opf:role="aut">{REAL_BOOK_AUTHOR}</dc:creator>\n'
           '    <dc:language>en</dc:language>\n'
           f'    <dc:identifier id="bookid">urn:uuid:5d3c5f0e-6a2b-4d0a-9f55-0c6f3f7a1b11</dc:identifier>'
           f'{description_xml}\n  </metadata>\n'
           '  <manifest>\n'
           '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
           '    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>\n'
           '  </manifest>\n  <spine toc="ncx"><itemref idref="c1"/></spine>\n</package>\n')
    ncx = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
           '  <head><meta name="dtb:uid" content="urn:uuid:5d3c5f0e-6a2b-4d0a-9f55-0c6f3f7a1b11"/></head>\n'
           f'  <docTitle><text>{REAL_BOOK_TITLE}</text></docTitle>\n'
           '  <navMap><navPoint id="n1" playOrder="1"><navLabel><text>Chapter 1</text></navLabel>'
           '<content src="c1.xhtml"/></navPoint></navMap>\n</ncx>\n')
    chapter = ('<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml">\n'
               f'<head><title>{REAL_BOOK_TITLE}</title></head>\n'
               f'<body><h1>{REAL_BOOK_TITLE}</h1><p>A very short mock chapter.</p></body>\n</html>\n')
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), EPUB_MIME)  # must come first and stay uncompressed
        for name, data in (("META-INF/container.xml", container), ("content.opf", opf), ("toc.ncx", ncx),
                           ("c1.xhtml", chapter)):
            archive.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    return buf.getvalue()


EPUBS = {"/dl/real_no_desc.epub": make_epub(), "/dl/real_desc.epub": make_epub(REAL_BOOK_DESCRIPTION)}


def desc_entry(title, content, formats):
    """Book entry for the description tests; `formats` lists (href, mime type, title) acquisition links."""
    links = "".join(f'\n    <link rel="http://opds-spec.org/acquisition" href="{href}" type="{mime}" title="{label}"/>'
                    for href, mime, label in formats)
    return (f"\n  <entry>\n    <title>{title}</title>\n    <id>urn:mock:desc:{title}</id>\n"
            f"    <updated>2026-01-01T00:00:00Z</updated>\n    <author><name>Ann Author</name></author>\n"
            f"    {content}{links}\n  </entry>")


def desc_feed(path):
    plain = ("/dl/real_no_desc.epub", EPUB_MIME, "EPUB")
    if path == "/opds/desc_sync":
        entries = [desc_entry("Desc Sync E", '<content type="text">Catalog text for sync E.</content>', [plain]),
                   desc_entry("Desc Sync F", "", [plain])]
        return feed("Description sync feed", path, ACQ, entries)
    entries = [
        desc_entry("Desc Book A", '<content type="html">&lt;p&gt;A &lt;b&gt;bold&lt;/b&gt; tale of the sea.&lt;/p&gt;'
                                  '&lt;p&gt;Second paragraph.&lt;/p&gt;</content>', [plain]),
        desc_entry("Desc Book B", '<content type="text">Catalog text for B.</content>',
                   [("/dl/real_desc.epub", EPUB_MIME, "EPUB")]),
        desc_entry("Desc Book C", '<content type="text">Catalog text for C.</content>',
                   [plain, ("/dl/real_no_desc.fb2", "application/x-fictionbook+xml", "FB2")]),
        desc_entry("Desc Book D", '<content type="text">Catalog text for D.</content>', [plain]),
        desc_entry("Desc Book E", '<content type="text">Catalog text for E.</content>',
                   [("/dl/905.epub", EPUB_MIME, "EPUB")]),
    ]
    return feed("Description feed", path, ACQ, entries)


def series_entry(n, title, authors, body):
    """Book entry for the series tests; `authors` and `body` are the raw XML a real server sends for them."""
    return (f"\n  <entry>\n    <title>{title}</title>\n    <id>urn:mock:series:{n}</id>\n"
            f"    <updated>2026-01-01T00:00:00Z</updated>\n{authors}{body}\n"
            f'    <link rel="http://opds-spec.org/image" href="/cover/{n}.png" type="image/png"/>\n'
            f'    <link rel="http://opds-spec.org/image/thumbnail" href="/thumb/{n}.png" type="image/png"/>\n'
            f'    <link rel="http://opds-spec.org/acquisition" href="/dl/{n}.epub" type="application/epub+zip"/>\n'
            f"  </entry>")


def cw_authors(*names):
    """One pretty-printed <author> per name, as Calibre-Web's feed.xml template prints them."""
    return "".join(f"    <author>\n        <name>{name}</name>\n    </author>\n" for name in names)


def cw_content(lines, description=""):
    """The <content> of a Calibre-Web entry: label lines ended by <br/> with the template's leftover whitespace."""
    text = "".join(f"      {line}<br/>\n    \n" for line in lines)
    paragraph = f"        <p>{description}</p>\n" if description else ""
    return f'    <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">\n{text}{paragraph}    </div></content>'


def grimmory_body(series, position, publisher="Ace Books", description="A description."):
    """What Grimmory (formerly BookLore) appends to an entry; the position is printed raw, e.g. 20.0."""
    meta = ""
    if series:
        meta += f'    <meta property="belongs-to-collection" id="series">{series}</meta>\n'
        if position:
            meta += f'    <meta property="group-position" refines="#series">{position}</meta>\n'
    return (f"    <dc:publisher>{publisher}</dc:publisher>\n    <dc:language>en</dc:language>\n"
            f'    <category term="Fantasy"/>\n    <summary>{description}</summary>\n'
            f"    <dc:identifier>urn:isbn:0000000000</dc:identifier>\n{meta}")


def series_feed():
    gutenberg_author = ("    <author><name>Homerus</name><uri>http://example.org/authors/homerus</uri></author>\n")
    entries = [
        # Calibre-Web: two <author> elements and a "SERIES: Name [n]" line after the RATING and TAGS lines
        series_entry(931, "The Wrong Box", cw_authors("Robert Louis Stevenson", "Lloyd Osbourne"),
                     cw_content(["RATING: \u2605\u2605\u2605\u2605", "TAGS: Fantasy, Adventure",
                                 "SERIES: The Saga [3]"], "A tale of boxes.")),
        # no series line; the description only mentions one further down
        series_entry(932, "Treasure Island", cw_authors("Robert Louis Stevenson"),
                     cw_content(["TAGS: Adventure", "Pages: 240", "Language: English", "SERIES: Not Here [9]"],
                                "SERIES: Neither Here [8]")),
        # Calibre-Web-Automated with <dc:series> and <dc:series_index> next to the Calibre-Web content
        series_entry(933, "Dune", cw_authors("Frank Herbert"),
                     "    <dc:series>Dune Chronicles</dc:series>\n    <dc:series_index>2.0</dc:series_index>\n"
                     + cw_content(["SERIES: Dune Chronicles [2]"], "Spice.")),
        # Grimmory: two books with one title, told apart by their series
        series_entry(934, "Omnibus", "    <author><name>Matt Dinniman</name></author>\n",
                     grimmory_body("Series One", "20.0")),
        series_entry(935, "Omnibus", "    <author><name>Matt Dinniman</name></author>\n",
                     grimmory_body("Series Two", "3.5")),
        # Grimmory book of a series without a number
        series_entry(936, "Numberless", "    <author><name>Matt Dinniman</name></author>\n",
                     grimmory_body("Series Three", None)),
        # Project Gutenberg: a single author with an <uri>, no series
        series_entry(937, "The Odyssey", gutenberg_author, '    <content type="text">An epic.</content>'),
        # nothing but a title
        series_entry(938, "Bare Book", "", ""),
        # escaped characters in names
        series_entry(939, "Escaped Names", cw_authors("Simon &amp; Schuster"),
                     cw_content(["SERIES: Tom &amp; Jerry [2.50]"])),
    ]
    return feed("Series formats", "/opds/series", ACQ, entries)


def pdf_entry(n, title, links):
    """Book entry for the PDF link tests; `links` is the raw XML of the download links a real server sends."""
    return (f"\n  <entry>\n    <title>{title}</title>\n    <id>urn:mock:pdf:{n}</id>\n"
            f"    <updated>2026-01-01T00:00:00Z</updated>\n    <author><name>Author {n}</name></author>\n"
            f"{links}  </entry>")


def pdf_feed():
    acq = "http://opds-spec.org/acquisition"
    entries = [
        # Calibre content server: formats live at /get/<format>/<book id>/<library> and the links carry no title
        pdf_entry(701, "Calibre Content Server",
                  f'    <link rel="{acq}" href="/get/epub/701/library" type="application/epub+zip"/>\n'
                  f'    <link rel="{acq}" href="/get/pdf/701/library" type="application/pdf"/>\n'),
        # Calibre-Web: the format is the last path segment and the links carry a title
        pdf_entry(702, "Calibre-Web",
                  f'    <link rel="{acq}" href="/opds/download/702/pdf/" type="application/pdf" title="PDF"/>\n'),
        # Komga: the file name ends in .pdf
        pdf_entry(703, "Komga",
                  f'    <link rel="{acq}" href="/opds/v1.2/books/703/file/Book.pdf" type="application/pdf"/>\n'),
        # arXiv: the PDF is a related link named "pdf" and its address has no .pdf
        pdf_entry(704, "arXiv",
                  '    <link title="pdf" href="/pdf/1234.5678v1" rel="related" type="application/pdf"/>\n'
                  '    <link href="/abs/1234.5678v1" rel="alternate" type="text/html"/>\n'),
        # a PDF offered only as an alternate link: nothing else picks it up, so its address gets ".pdf"
        pdf_entry(705, "Alternate only",
                  '    <link href="/files/705" rel="alternate" type="application/pdf"/>\n'),
        # a catalog section that happens to be called "pdf": it opens a catalog and is not a book
        pdf_entry(706, "PDF section",
                  f'    <link rel="subsection" title="pdf" href="/opds/pdflinks/pdf" type="{NAV}"/>\n'),
        # titled links whose addresses end in the format name, without a file extension or a trailing slash
        pdf_entry(707, "Titled links",
                  f'    <link rel="{acq}" href="/books/707/epub" type="application/epub+zip" title="EPUB"/>\n'
                  f'    <link rel="{acq}" href="/books/707/pdf" type="application/pdf" title="PDF"/>\n'),
    ]
    return feed("PDF links", "/opds/pdflinks", ACQ, entries)


OPDS2 = "application/opds+json"
OPDS2_TOTAL, OPDS2_PAGE, OPDS2_FANTASY = 60, 20, 10


def opds2_publication(n):
    links = [{"rel": "http://opds-spec.org/acquisition", "href": f"/dl/{n}.epub", "type": "application/epub+zip"}]
    if n % 5 == 0:
        links.append({"rel": "http://opds-spec.org/acquisition", "href": f"/dl/{n}.cbz",
                      "type": "application/vnd.comicbook+zip; charset=binary"})
    return {
        "metadata": {
            "title": f"Book 2-{n:04d}",
            "author": [{"name": f"Author {n % 7}"}, "Co Writer"] if n % 4 == 0 else {"name": f"Author {n % 7}"},
            "belongsTo": {"series": {"name": f"Series {(n - 1) // 10 + 1}", "position": (n - 1) % 10 + 1}},
            "publisher": "Mock Press",
            "published": f"20{n % 25:02d}-03-04T00:00:00Z",
            "language": "en",
            "description": f"<p>Summary of <b>book {n}</b>.</p>",
        },
        "links": links,
        "images": [
            {"href": f"/cover/{n}.png", "type": "image/png", "width": 240, "height": 360},
            {"href": f"/thumb/{n}.png", "type": "image/png", "width": 120, "height": 180},
        ],
        "readingOrder": [{"href": f"/chapter/{n}/{i}", "type": "text/html"} for i in range(50)],
    }


def opds2_search_link():
    return {"rel": "search", "href": "/opds2/search{?query}", "type": OPDS2, "templated": True}


def opds2_home():
    return {
        "metadata": {"title": "Mock OPDS 2"},
        "links": [{"rel": "self", "href": "/opds2/home", "type": OPDS2}, opds2_search_link()],
        "navigation": [{"title": "All books", "href": "/opds2/books?page=1", "type": OPDS2}],
        "groups": [
            {"metadata": {"title": "Latest", "numberOfItems": OPDS2_TOTAL},
             "links": [{"rel": "self", "href": "/opds2/books?page=1", "type": OPDS2}],
             "publications": [opds2_publication(n) for n in (1, 2)]},
            {"metadata": {"title": "Staff picks"},
             "publications": [opds2_publication(n) for n in (5, 12, 33)]},
            {"metadata": {"title": "Browse"},
             "navigation": [{"title": "Fantasy", "href": "/opds2/books?genre=fantasy", "type": OPDS2}]},
        ],
    }


def opds2_books(q):
    genre = q.get("genre", [None])[0]
    page = int(q.get("page", ["1"])[0])
    total = OPDS2_FANTASY if genre else OPDS2_TOTAL
    pages = (total + OPDS2_PAGE - 1) // OPDS2_PAGE
    extra = f"&genre={genre}" if genre else ""
    first = (page - 1) * OPDS2_PAGE + 1
    numbers = range(first, min(page * OPDS2_PAGE, total) + 1)
    if genre:
        numbers = [n * 3 for n in numbers]
    links = [{"rel": "self", "href": f"/opds2/books?page={page}{extra}", "type": OPDS2},
             {"rel": "first", "href": f"/opds2/books?page=1{extra}", "type": OPDS2},
             {"rel": "last", "href": f"/opds2/books?page={pages}{extra}", "type": OPDS2},
             opds2_search_link()]
    if page < pages:
        links.append({"rel": ["next"], "href": f"/opds2/books?page={page + 1}{extra}", "type": OPDS2})
    if page > 1:
        links.append({"rel": "previous", "href": f"/opds2/books?page={page - 1}{extra}", "type": OPDS2})
    facet = {"metadata": {"title": "Genre"}, "links": [
        {"title": "All", "href": "/opds2/books?page=1", "type": OPDS2,
         "properties": {"numberOfItems": OPDS2_TOTAL}, **({} if genre else {"rel": "self"})},
        {"title": "Fantasy", "href": "/opds2/books?genre=fantasy", "type": OPDS2,
         "properties": {"numberOfItems": OPDS2_FANTASY}, **({"rel": "self"} if genre else {})},
    ]}
    return {
        "metadata": {"title": "Fantasy" if genre else "All books", "numberOfItems": total,
                     "itemsPerPage": OPDS2_PAGE, "currentPage": page},
        "links": links,
        "facets": [facet],
        "publications": [opds2_publication(n) for n in numbers],
    }


def opds2_search(q):
    query = q.get("query", [""])[0].lower()
    found = [n for n in range(1, OPDS2_TOTAL + 1) if query and query in f"book 2-{n:04d}"]
    return {
        "metadata": {"title": "Search results"},
        "links": [{"rel": "start", "href": "/opds2/home", "type": OPDS2}, opds2_search_link()],
        "groups": [{"metadata": {"title": "Books"}, "publications": [opds2_publication(n) for n in found]}],
    }


def showcase_feed():
    entries = []
    for n, (title, author, series, number) in enumerate(SHOWCASE, start=1):
        body = (f"    <summary>{escape(title)}, by {escape(author)}. A public-domain classic.</summary>\n"
                f"    <dc:language>en</dc:language>\n")
        if series:
            body += (f'    <meta property="belongs-to-collection" id="series">{escape(series)}</meta>\n'
                     f'    <meta property="group-position" refines="#series">{number}</meta>\n')
        cover = f"/showcase/cover/{n}.png"
        entries.append(f"\n  <entry>\n    <title>{escape(title)}</title>\n    <id>urn:mock:showcase:{n}</id>\n"
                       f"    <updated>2026-01-01T00:00:00Z</updated>\n{cw_authors(escape(author))}{body}"
                       f'    <link rel="http://opds-spec.org/image" href="{cover}" type="image/png"/>\n'
                       f'    <link rel="http://opds-spec.org/image/thumbnail" href="{cover}" type="image/png"/>\n'
                       f'    <link rel="http://opds-spec.org/acquisition" href="/dl/{n}.epub" '
                       f'type="application/epub+zip"/>\n  </entry>')
    return feed("Classics", "/opds/showcase", ACQ, entries)


def showcase_cover(n):
    if COVERS_DIR:
        try:
            with open(os.path.join(COVERS_DIR, f"{n}.png"), "rb") as fh:
                return fh.read()
        except OSError:
            pass
    return png(n, 400, 600)


def opds2_showcase_publication(n):
    title, author, series, number = SHOWCASE[n - 1]
    metadata = {"title": title, "author": {"name": author}, "language": "en",
                "published": f"{YEARS[n - 1]}-01-01", "publisher": "Public Domain",
                "description": f"<p>{escape(title)}, by {escape(author)}. A public-domain classic.</p>"}
    if series:
        metadata["belongsTo"] = {"series": {"name": series, "position": number}}
    cover = f"/showcase/cover/{n}.png"
    return {"metadata": metadata,
            "links": [{"rel": "http://opds-spec.org/acquisition", "href": f"/dl/{n}.epub",
                       "type": "application/epub+zip"}],
            "images": [{"href": cover, "type": "image/png", "width": 400, "height": 600}]}


def opds2_showcase_home():
    books = "/opds2/showcase/books"
    return {
        "metadata": {"title": "Classics"},
        "links": [{"rel": "self", "href": "/opds2/showcase", "type": OPDS2}],
        "navigation": [{"title": "All classics", "href": books, "type": OPDS2}],
        "groups": [
            {"metadata": {"title": "New arrivals", "numberOfItems": len(SHOWCASE)},
             "links": [{"rel": "self", "href": books, "type": OPDS2}],
             "publications": [opds2_showcase_publication(n) for n in (12, 11)]},
            {"metadata": {"title": "Staff picks"},
             "publications": [opds2_showcase_publication(n) for n in (7, 3, 10, 1)]},
            {"metadata": {"title": "Genres"},
             "navigation": [{"title": genre, "href": f"{books}?genre={genre.replace(' ', '+')}", "type": OPDS2}
                            for genre in GENRES]},
        ],
    }


def opds2_showcase_books(q):
    genre = q.get("genre", [None])[0]
    numbers = GENRES.get(genre) or range(1, len(SHOWCASE) + 1)
    books = "/opds2/showcase/books"
    facet_links = [{"title": "All", "href": books, "type": OPDS2, "properties": {"numberOfItems": len(SHOWCASE)},
                    **({} if genre in GENRES else {"rel": "self"})}]
    for name, members in GENRES.items():
        facet_links.append({"title": name, "href": f"{books}?genre={name.replace(' ', '+')}", "type": OPDS2,
                            "properties": {"numberOfItems": len(members)},
                            **({"rel": "self"} if name == genre else {})})
    return {
        "metadata": {"title": genre if genre in GENRES else "All classics", "numberOfItems": len(numbers)},
        "links": [{"rel": "self", "href": books, "type": OPDS2}],
        "facets": [{"metadata": {"title": "Genre"}, "links": facet_links}],
        "publications": [opds2_showcase_publication(n) for n in numbers],
    }


def make_cbz(n):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("001.png", png(n))
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        pass

    def _log(self):
        if not LOG_PATH:
            return
        rec = {"t": round(time.time(), 3), "method": self.command, "path": self.path,
               "headers": {k: v for k, v in self.headers.items()}}
        with LOG_LOCK:
            with open(LOG_PATH, "a") as fh:
                fh.write(json.dumps(rec) + "\n")

    def _route(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        path = url.path
        delay = float(q.get("delay", ["0"])[0])
        if delay:
            time.sleep(delay)
        if q.get("fail"):
            return 500, "text/plain", b"mock failure"
        hdr = {k: v for k, v in self.headers.items()}
        if path.startswith("/cf/"):
            # header names are case-insensitive; LuaSocket sends them in lower case
            if self.headers.get("CF-Access-Client-Id") != CF_ID or self.headers.get("CF-Access-Client-Secret") != CF_SECRET:
                return 403, "text/html", b"<html><body>Forbidden (mock Cloudflare Access)</body></html>"
            if path == "/cf/feed":
                return 200, "application/atom+xml", cf_feed().encode()
            url_path = path[3:]
            if not url_path.startswith(("/cover/", "/thumb/", "/dl/")):
                return 404, "text/plain", b"not found"
        else:
            url_path = path
        if url_path in ("/opds/", "/opds"):
            return 200, NAV, root_feed().encode()
        if url_path == "/opds/all":
            qq = {"page": q.get("page", ["1"]), "size": ["50"], "total": ["120"]}
            return 200, ACQ, paged_feed(qq, "/opds/all").encode()
        if url_path == "/opds/paged":
            return 200, ACQ, paged_feed(q).encode()
        if url_path == "/opds/nav":
            return 200, NAV, nav_feed().encode()
        if url_path == "/opds/echo":
            return 200, ACQ, echo_feed(hdr).encode()
        sync_kinds = {"/opds/sync": "sync", "/opds/sync_mixed": "mixed", "/opds/gut_root": "gut_root",
                      "/opds/gut_sub.opds": "gut_sub"}
        if url_path in sync_kinds:
            return 200, ACQ, sync_feed(sync_kinds[url_path]).encode()
        if url_path in ("/opds/desc", "/opds/desc_sync"):
            return 200, ACQ, desc_feed(url_path).encode()
        if url_path == "/opds/series":
            return 200, ACQ, series_feed().encode()
        if url_path == "/opds/pdflinks":
            return 200, ACQ, pdf_feed().encode()
        if url_path == "/opds/showcase":
            return 200, ACQ, showcase_feed().encode()
        if url_path.startswith("/showcase/cover/") and url_path.endswith(".png"):
            return 200, "image/png", showcase_cover(int(url_path.rsplit("/", 1)[1].split(".")[0]))
        if url_path == "/opds2/showcase":
            return 200, OPDS2, json.dumps(opds2_showcase_home()).encode()
        if url_path == "/opds2/showcase/books":
            return 200, OPDS2, json.dumps(opds2_showcase_books(q)).encode()
        if url_path == "/opds2/home":
            return 200, OPDS2, json.dumps(opds2_home()).encode()
        if url_path == "/opds2/books":
            return 200, OPDS2, json.dumps(opds2_books(q)).encode()
        if url_path == "/opds2/search":
            return 200, OPDS2, json.dumps(opds2_search(q)).encode()
        if url_path.startswith("/dl/") and url_path.endswith(".cbz"):
            n = int(url_path.rsplit("/", 1)[1].split(".")[0])
            return 200, "application/vnd.comicbook+zip", make_cbz(n)
        if url_path in EPUBS:
            return 200, EPUB_MIME, EPUBS[url_path]
        if url_path.startswith(("/cover/", "/thumb/")) and url_path.endswith(".png"):
            n = int(url_path.rsplit("/", 1)[1].split(".")[0])
            return 200, "image/png", png(n)
        if url_path.startswith("/dl/") and url_path.endswith(".epub"):
            n = int(url_path.rsplit("/", 1)[1].split(".")[0])
            return 200, "application/epub+zip", (b"PK\x03\x04mock-epub-%d" % n) * 64
        # a book whose address has no usable extension, and no Content-Disposition to name it
        if url_path.startswith("/dlnoext/") or url_path == "/dlphp/get.php":
            return 200, "application/epub+zip", b"PK\x03\x04mock-epub-noext" * 64
        # feeds with validators: /opds/cond sends an ETag and a Last-Modified, /opds/lmonly a Last-Modified only
        if url_path in ("/opds/cond", "/opds/lmonly"):
            with COND_LOCK:
                version = q.get("v", [str(COND.get("version", 1))])[0]
            etag = '"feed-v%s"' % version
            last_modified = "Mon, 0%s Nov 2026 10:00:00 GMT" % version
            validators = {"Last-Modified": last_modified}
            if url_path == "/opds/cond":
                validators["ETag"] = etag
                unchanged = self.headers.get("If-None-Match") == etag
            else:
                unchanged = self.headers.get("If-Modified-Since") == last_modified
            with COND_LOCK:
                key = self.command + (" 304" if unchanged else "")
                COND[key] = COND.get(key, 0) + 1
            if unchanged:
                return 304, ACQ, b"", validators
            feed = paged_feed({"page": ["1"], "size": ["5"], "total": ["5"]}, url_path)
            return 200, ACQ, feed.encode(), validators
        return 404, "text/plain", b"not found"

    def _send(self, with_body):
        self._log()
        tracked = is_media(self.path)
        if tracked:
            stats_start(self.headers)
        try:
            routed = self._route()
            status, ctype, body = routed[:3]
            extra = routed[3] if len(routed) > 3 else {}
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for name, value in extra.items():
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            if with_body:
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        finally:
            if tracked:
                stats_end()

    def do_GET(self):
        if self.path == "/__quit":
            self._send(True)
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if self.path in ("/__cond", "/__cond/reset", "/__cond/bump"):
            with COND_LOCK:
                if self.path.endswith("/reset"):
                    COND.clear()
                if self.path.endswith("/bump"):
                    COND["version"] = COND.get("version", 1) + 1
                body = json.dumps(COND).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in ("/__stats", "/__stats/reset"):
            if self.path.endswith("/reset"):
                stats_reset()
            with STATS_LOCK:
                body = json.dumps(STATS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        self._send(True)

    def do_HEAD(self):
        self._send(False)


def main():
    global LOG_PATH, COVERS_DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--log", default=None)
    ap.add_argument("--covers", default=None, help="directory of the showcase covers, N.png")
    args = ap.parse_args()
    LOG_PATH = args.log
    COVERS_DIR = args.covers
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    srv.daemon_threads = True
    print(f"mock OPDS server on http://127.0.0.1:{args.port}/opds/", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
