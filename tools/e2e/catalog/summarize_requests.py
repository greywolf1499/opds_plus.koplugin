#!/usr/bin/env python3
"""Summarise the mock server's requests.jsonl per segment (segments are split at /__mark/<name> requests).

Prints one line per segment: feed GET/HEAD counts, cover/thumb GETs (with distinct URLs), downloads, other.
"""
import json
import sys


def classify(rec):
    path = rec["path"].split("?")[0]
    if path.startswith("/__mark/") or path == "/__quit":
        return None
    if path.startswith("/cf/"):
        path = path[3:]
    if path.startswith(("/cover/", "/thumb/")):
        return "cover_get" if rec["method"] == "GET" else "cover_other"
    if path.startswith("/dl/"):
        return "download"
    if path.startswith(("/opds", "/cf/feed")) or rec["path"].startswith("/cf/feed"):
        return "feed_" + rec["method"].lower()
    return "other"


def main(path):
    segments = [("start", [])]
    try:
        lines = open(path).read().splitlines()
    except OSError:
        print("(no requests.jsonl)")
        return
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec["path"].startswith("/__mark/"):
            segments.append((rec["path"].split("/__mark/", 1)[1], []))
            continue
        segments[-1][1].append(rec)
    for name, recs in segments:
        counts = {}
        cover_urls = set()
        for rec in recs:
            kind = classify(rec)
            if kind is None:
                continue
            counts[kind] = counts.get(kind, 0) + 1
            if kind == "cover_get":
                cover_urls.add(rec["path"])
        summary = " ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "(none)"
        print(f"segment[{name}]: {summary} distinct_cover_urls={len(cover_urls)}")


if __name__ == "__main__":
    main(sys.argv[1])
