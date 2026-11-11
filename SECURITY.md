# Security Policy

## Supported versions

Only the latest 1.x release of OPDS Plus gets security fixes. Please update before reporting, either from
**OPDS Plus → Settings → Updates → Check for updates** (1.4.0 and later) or from the
[releases page](https://github.com/greywolf1499/opds_plus.koplugin/releases/latest).

| Version        | Supported |
| -------------- | --------- |
| latest 1.x     | Yes       |
| anything older | No        |

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:
**[Report a vulnerability](https://github.com/greywolf1499/opds_plus.koplugin/security/advisories/new)**
(the *Security* tab of this repository). Do not open a public issue for a security problem.

OPDS Plus is maintained by one person in their spare time, so acknowledgement and fixes are best effort.
Once a fix is released, the advisory is published with credit to the reporter unless they prefer otherwise.

## Scope

In scope, for the code in this repository:

- handling of catalog credentials (usernames, passwords, API keys, custom headers);
- TLS use, redirects and where credentials and custom headers are sent;
- the in-app updater: release lookup, download integrity, archive path safety and the install swap;
- where downloaded books and covers are written (path traversal through titles, file names or URLs);
- injection through catalog data or custom HTTP headers (see #94).

Out of scope: KOReader itself, the e-reader's operating system, and OPDS servers (Calibre-Web, Kavita,
Komga and others). Please report those to their own projects.

## What you should know

### Credentials are stored in plain text

Catalog passwords, API keys and custom headers are saved in `settings/opdsplus.lua` inside KOReader's data
folder, unencrypted, like the rest of KOReader's settings. Anyone with access to the device's storage can
read them. Use a dedicated account or a read-only API key for your e-reader where your server allows it.

With an `http://` catalog, Basic authentication sends the username and password in cleartext over the
network. Use `https://` for any catalog that needs a password.

### TLS for catalogs

Catalog requests use KOReader's network stack with its defaults, which encrypt `https://` connections but
do **not** verify the server's certificate. This keeps self-hosted servers with self-signed certificates
working, but it means an attacker on the same network could impersonate a catalog server. OPDS Plus does:

- refuse to follow a redirect from `https://` to `http://`;
- send Basic credentials and the `Authorization`, `Cookie` and `Proxy-Authorization` headers only to the
  origin (scheme, host and port) they were configured for, including the first request to a linked resource,
  never across a redirect to another origin;
- send a catalog's custom headers only to that catalog's origin.

### Authentication discovery and streaming sync (1.6.0 and later)

Linked authentication documents are fetched anonymously over same-origin HTTPS, with certificate-chain
and hostname verification using KOReader's CA bundle. Catalog credentials, custom headers and redirects
are disabled for that request. Inline documents received with an ordinary catalog request still use the
catalog connection's existing TLS behavior. Treat provider text as untrusted information, not permission
to send credentials to advertised links. OAuth login, token persistence and refresh are not implemented.

Streaming progress writes require the catalog's explicit **Sync streaming progress** opt-in. The default
is local-only reading, including use of Kavita's read-only image endpoint. Synchronization checks the
provider/stream identity and asks on conflicting positions; its server APIs cannot make the read/check/write
sequence atomic. Closing or suspending cancels pending requests, but an already-sent write may have reached
the server. See the [streaming guide](docs/wiki/Kavita.md#two-way-streaming-progress).

### The in-app updater (1.4.0 and later)

The updater only ever contacts `api.github.com`, `github.com` and `*.githubusercontent.com`, over HTTPS,
and follows at most four redirects, all of which must stay on those hosts. For every connection it:

- verifies the certificate chain against KOReader's bundled CA list (`data/ca-bundle.crt`), so expired,
  self-signed and untrusted certificates are refused (a wrong device clock also causes this);
- checks that the certificate's subjectAltName DNS names cover the host it connected to.

It installs a release only when the asset `opds_plus.koplugin.zip` matches the SHA-256 digest GitHub
publishes for it (or the `.sha256` file attached to the release). The digest comes from GitHub over the
same verified connection: it protects against corrupted or tampered downloads, but it is not a signature,
so the updater trusts whoever can publish releases on this repository and GitHub itself.

Before anything reaches the plugins folder, every archive entry is checked: one top-level
`opds_plus.koplugin/` folder, no absolute paths, `..`, backslashes, control characters, links or device
files, and limits on entry count and size. The release is extracted next to the installed plugin
(`opds_plus.koplugin.new`), checked (required files, every `.lua` file loads, version matches the release,
KOReader new enough), then swapped in with two renames. The previous version is kept as
`opds_plus.koplugin.bak` and can be restored from the menu.

The updater refuses to touch a development install (a symlinked plugin folder or one containing `.git`)
unless you turn on the developer override.

If the device loses power between the two renames, the plugin folder may be missing. Rename
`opds_plus.koplugin.bak` back to `opds_plus.koplugin` in KOReader's `plugins` folder to recover.

### Data collection

OPDS Plus collects no analytics and sends nothing to its author. Requests go only to the catalogs you add
and, for the update check, to GitHub, which sees your IP address and the user agent
`OPDSPlus/<version>`. The weekly automatic check runs only when the device is already online and can be
turned off under **Settings → Updates**.
