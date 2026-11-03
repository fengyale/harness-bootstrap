#!/usr/bin/env python3
"""Publish each entry in releases.json as a GitHub Release.

releases.json is generated from VERSION by tools/parse-changelog.py, so VERSION
remains the single source of truth. This script creates one GitHub Release per
version, with a tag named v<version>. Existing releases are skipped, so the
script is safe to re-run.

Usage:
    python tools/parse-changelog.py
    GITHUB_TOKEN=... python tools/publish-releases.py
    GITHUB_TOKEN=... python tools/publish-releases.py --dry-run
    GITHUB_TOKEN=... python tools/publish-releases.py --from 1.8.0
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"


def request(method, path, token, payload=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "harness-bootstrap-release-tool")
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw.strip() else {}


def build_body(rel):
    title = rel["title"].strip()
    title = title.strip("()（）").strip()
    lines = [f"**{rel['version']}** — {title}" if title else f"**{rel['version']}**", ""]
    lines += rel["body"]
    return "\n".join(lines).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="fengyale/harness-bootstrap")
    ap.add_argument("--from", dest="since", default=None,
                    help="only publish this version and older (e.g. 1.8.0)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        sys.exit("GITHUB_TOKEN is not set")

    here = Path(__file__).resolve().parent.parent
    releases = json.loads((here / "releases.json").read_text(encoding="utf-8"))

    if args.since:
        def key(v):
            return [int(x) for x in v.split(".")]
        threshold = key(args.since)
        releases = [r for r in releases if key(r["version"]) <= threshold]

    existing = set()
    page = 1
    while True:
        batch = request(
            "GET", f"/repos/{args.repo}/releases?per_page=100&page={page}", token)
        if not batch:
            break
        for r in batch:
            existing.add(r["tag_name"])
        page += 1
        if len(batch) < 100:
            break

    created, skipped = [], []
    for rel in sorted(releases, key=lambda r: [int(x) for x in r["version"].split(".")]):
        tag = f"v{rel['version']}"
        if tag in existing:
            skipped.append(tag)
            continue
        body = build_body(rel)
        if args.dry_run:
            print(f"[dry] would create {tag}: {body.splitlines()[0]}")
            created.append(tag)
            continue
        payload = {
            "tag_name": tag,
            "name": f"{rel['version']} — {rel['title'].strip('()（）').strip()}",
            "body": body,
            "draft": False,
            "prerelease": False,
        }
        try:
            request("POST", f"/repos/{args.repo}/releases", token, payload)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            print(f"  FAIL {tag}: {e.code} {detail[:200]}", file=sys.stderr)
            continue
        created.append(tag)
        print(f"  created {tag}")

    print(f"\ncreated: {len(created)}   skipped (already exist): {len(skipped)}")
    if skipped:
        print("skipped: " + ", ".join(skipped))


if __name__ == "__main__":
    main()
