# spec/vendor

Third-party code the specs need but CI can't get from a KOReader install.

| File | Source | Notes |
|---|---|---|
| `luxl.lua` | `frontend/luxl.lua` of [koreader/koreader](https://github.com/koreader/koreader) v2026.07.1 (AGPL-3.0, like this plugin) | Copied unmodified. `core/parser.lua` requires `luxl`, which KOReader provides at runtime. |
| `socket/url.lua` | `common/socket/url.lua` of the same KOReader release (LuaSocket 3.x by Diego Nehab, MIT, with a patch by KOReader) | Copied unmodified. KOReader ends the authority of a URL at `/`, `?` or `#`, where stock LuaSocket ends it at `/` only, so `http://host?x=1` has the host `host` on a device. Specs that parse URLs need the same behaviour. |

The `contract` specs (`scripts/test.sh --contract`) compare these copies with the ones of a real
KOReader install, so a stale copy is noticed. Nothing in this directory is shipped in the release zip.
