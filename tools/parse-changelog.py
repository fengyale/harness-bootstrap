#!/usr/bin/env python3
"""Parse VERSION changelog into per-release notes.

The VERSION file holds a changelog with sections like:

    1.22.0  (自举门禁 + 门禁真实性 + 三态可判定)
    - line
    - line

    1.21.0  (SKILL 瘦身 + 验收可判定 + 晋升有留痕)
    ...

This script splits it into {version: {title, body}} so the release notes
can be generated from the same source that the package already trusts.
"""
import re
import sys
import json
from pathlib import Path

VER_RE = re.compile(r'^\s*(\d+\.\d+\.\d+)\s{2,}(.*)$')


def parse(text: str):
    releases = []
    cur = None
    for line in text.splitlines():
        m = VER_RE.match(line)
        if m:
            if cur:
                releases.append(cur)
            cur = {"version": m.group(1), "title": m.group(2).strip(), "body": []}
        elif cur is not None:
            cur["body"].append(line.rstrip())
    if cur:
        releases.append(cur)

    # trim trailing blanks of each body
    for r in releases:
        while r["body"] and not r["body"][-1].strip():
            r["body"].pop()
        r["body"] = [l for l in r["body"] if l.strip()]
    return releases


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "VERSION")
    out = Path(sys.argv[2] if len(sys.argv) > 2 else "releases.json")
    text = src.read_text(encoding="utf-8")
    rel = parse(text)
    out.write_text(
        json.dumps(rel, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"parsed {len(rel)} releases -> {out}")
    for r in rel:
        n = len(r["body"])
        print(f"  {r['version']:<10} {n:>3} lines   {r['title']}")


if __name__ == "__main__":
    main()
