#!/usr/bin/env python3
"""Loopback stand-in for the two GitHub hosts the updater talks to, for the OTA e2e run.

  /api/repos/<repo>/releases/latest           the "latest release" API answer, with an ETag
  /gh/<repo>/releases/download/<tag>/<name>   302 to /cdn/<name>, like github.com does
  /cdn/<name>                                 the release asset
  /__mode?m=<mode>                            what the next answers say (see MODES)
  /__quit                                     stops the server

The driver rewrites https://api.github.com/... to /api/... and https://github.com/... to /gh/...
"""
import argparse
import hashlib
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

REPO = "greywolf1499/opds_plus.koplugin"
ASSET = "opds_plus.koplugin.zip"

# same: the latest release is the installed version; good: a newer one; bad_digest: a newer one whose
# API digest does not match the asset
MODES = ("same", "good", "bad_digest")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--asset", required=True, help="zip served as the newer release")
    parser.add_argument("--new-version", required=True)
    parser.add_argument("--old-version", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()

    with open(args.asset, "rb") as handle:
        asset = handle.read()
    digest = hashlib.sha256(asset).hexdigest()
    state = {"mode": "same"}
    log = open(args.log, "a", encoding="utf-8")

    def release_json():
        mode = state["mode"]
        version = args.old_version if mode == "same" else args.new_version
        tag = "v" + version
        shown_digest = ("0" * 64) if mode == "bad_digest" else digest
        base = f"https://github.com/{REPO}/releases/download/{tag}/"
        return {
            "tag_name": tag,
            "name": tag,
            "body": f"e2e release {version} ({mode})",
            "html_url": f"https://github.com/{REPO}/releases/tag/{tag}",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": ASSET,
                    "size": len(asset),
                    "digest": "sha256:" + shown_digest,
                    "browser_download_url": base + ASSET,
                },
            ],
        }

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def send(self, code, body=b"", headers=None):
            self.send_response(code)
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_GET(self):
            url = urlparse(self.path)
            log.write(json.dumps({
                "path": url.path,
                "mode": state["mode"],
                "if_none_match": self.headers.get("If-None-Match"),
                "user_agent": self.headers.get("User-Agent"),
            }) + "\n")
            log.flush()
            if url.path == "/__mode":
                mode = parse_qs(url.query).get("m", [""])[0]
                if mode not in MODES:
                    return self.send(400, b"unknown mode")
                state["mode"] = mode
                return self.send(200, b"ok")
            if url.path == "/__quit":
                self.send(200, b"bye")
                threading.Thread(target=server.shutdown, daemon=True).start()
                return None
            if url.path == f"/api/repos/{REPO}/releases/latest":
                body = json.dumps(release_json()).encode()
                etag = '"' + hashlib.sha1(body).hexdigest() + '"'
                if self.headers.get("If-None-Match") == etag:
                    return self.send(304, b"", {"ETag": etag})
                return self.send(200, body, {"Content-Type": "application/json", "ETag": etag})
            if url.path.startswith(f"/gh/{REPO}/releases/download/") and url.path.endswith("/" + ASSET):
                host = self.headers.get("Host")
                return self.send(302, b"", {"Location": f"http://{host}/cdn/{ASSET}"})
            if url.path == "/cdn/" + ASSET:
                return self.send(200, asset, {"Content-Type": "application/zip"})
            return self.send(404, b"not found")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"mock github on 127.0.0.1:{args.port}, asset sha256 {digest}", flush=True)
    server.serve_forever()
    log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
