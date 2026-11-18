#!/usr/bin/env python3
# -*- coding: ascii -*-
"""
red-line-scan.py -- cross-platform twin of red-line-scan.ps1

WHY BOTH
    PowerShell 5.1 is preinstalled on Windows and is the fastest path there.
    macOS / Linux agents usually have python3 and no PowerShell, so the same
    rules must be enforceable there too. This file mirrors the .ps1 CLI and
    exit codes; keep the two in sync when you change matching behaviour.

USAGE
    python3 scripts/red-line-scan.py --root .
    python3 scripts/red-line-scan.py --root . --rules R1,R4
    python3 scripts/red-line-scan.py --root . --files a.java b.kt
    git diff --cached --name-only --diff-filter=ACM | python3 scripts/red-line-scan.py --files-from-stdin

EXIT CODE
    0 = clean, 1 = violations found (usable as a gate)

ASCII only: console encodings differ per OS; rule text comes from the JSON.
"""

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass

DEFAULT_INCLUDE = ["*.java", "*.kt", "*.ts", "*.tsx", "*.js", "*.vue", "*.xml", "*.sql"]
DEFAULT_EXCLUDE_DIR = [".git", "node_modules", "target", "dist", "build", "out",
                       "coverage", ".harness", ".trae", ".idea"]


def norm(path):
    return path.replace("/", os.sep).replace("\\", os.sep)


def rel_path(root, full):
    full = os.path.abspath(full)
    root = os.path.abspath(root)
    if full.lower().startswith(root.lower()):
        return full[len(root):].lstrip("/\\")
    return full


def match_any(name, patterns):
    low = name.lower()
    return any(fnmatch.fnmatch(low, p.lower()) for p in patterns)


def excluded(rel, exclude_dirs):
    parts = re.split(r"[\\/]", rel)
    return any(p in exclude_dirs for p in parts)


def collect(root, include, exclude_dirs, files):
    if files:
        picked = []
        for f in files:
            p = f if os.path.isabs(f) else os.path.join(root, f)
            if not os.path.exists(p) or os.path.isdir(p):
                continue
            rel = rel_path(root, p)
            if not match_any(os.path.basename(p), include):
                continue
            if excluded(rel, exclude_dirs):
                continue
            picked.append((p, rel))
        return picked

    picked = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in exclude_dirs]
        for n in names:
            p = os.path.join(base, n)
            rel = rel_path(root, p)
            if not match_any(n, include):
                continue
            if excluded(rel, exclude_dirs):
                continue
            picked.append((p, rel))
    return picked


def read_text(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith(b"\xff\xfe"):
        return raw[2:].decode("utf-16-le", errors="replace")
    if raw.startswith(b"\xfe\xff"):
        return raw[2:].decode("utf-16-be", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def parse_added_lines(diff_text):
    added = {}
    cur = None
    for line in diff_text.split("\n"):
        if line.startswith("diff --git "):
            cur = None
            continue
        m = re.match(r'^\+\+\+ "b/(.+)"', line) or re.match(r"^\+\+\+ b/(.+)", line)
        if m:
            cur = m.group(1).strip()
            added.setdefault(cur, set())
            continue
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if m:
            if not cur:
                continue
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) else 1
            added[cur].update(range(start, start + count))
    return added


def read_scan_text(root, rel, path, use_index):
    if use_index:
        try:
            out = subprocess.run(["git", "-C", root, "show", ":" + rel.replace(os.sep, "/")],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if out.returncode == 0:
                return out.stdout.decode("utf-8", "replace")
        except Exception:
            pass
    return read_text(path)


def scan_file(path, rel, rules, added=None, text=None):
    hits = []
    if text is None:
        text = read_text(path)
    for rule in rules:
        pattern = rule.get("pattern")
        if not pattern:
            continue
        if rule.get("multiline"):
            # PowerShell [regex]::Matches is case-sensitive: mirror that here.
            for m in re.finditer(pattern, text):
                if rule.get("requireAlso") and not re.search(rule["requireAlso"], m.group(0)):
                    continue
                start = text.count("\n", 0, m.start()) + 1
                if added is not None:
                    span = m.group(0).count("\n") + 1
                    if not any((start + k) in added for k in range(span)):
                        continue
                snippet = re.sub(r"\s+", " ", m.group(0)).strip()
                hits.append((rule, rel, start, snippet))
        else:
            # PowerShell -match is case-insensitive: mirror that here.
            flags = re.IGNORECASE
            for i, line in enumerate(text.split("\n"), 1):
                line = line.rstrip("\r")
                if added is not None and i not in added:
                    continue
                if not re.search(pattern, line, flags):
                    continue
                if rule.get("requireAlso") and not re.search(rule["requireAlso"], line, re.IGNORECASE):
                    continue
                hits.append((rule, rel, i, line.strip()))
    return hits


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("--rules-file", default=None)
    ap.add_argument("--rules", default=None, help="comma separated ids, e.g. R1,R4")
    ap.add_argument("--files", nargs="*", default=None)
    ap.add_argument("--files-from-stdin", action="store_true")
    ap.add_argument("--diff-from-stdin", action="store_true")
    ap.add_argument("--diff-file", default=None)
    ap.add_argument("--include", nargs="*", default=DEFAULT_INCLUDE)
    ap.add_argument("--exclude-dir", nargs="*", default=DEFAULT_EXCLUDE_DIR)
    ap.add_argument("--list-rules", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.stderr.write("Root not found: %s\n" % root)
        return 2
    rules_file = args.rules_file or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                 "red-line-rules.json")
    if not os.path.exists(rules_file):
        sys.stderr.write("Rule file not found: %s\n" % rules_file)
        return 2

    with open(rules_file, "r", encoding="utf-8-sig") as fh:
        cfg = json.load(fh)
    rules = list(cfg.get("rules") or [])
    if not rules:
        sys.stderr.write("No rules defined in %s\n" % rules_file)
        return 2

    if args.list_rules:
        for r in rules:
            print("%-4s %-28s %s" % (r.get("id", ""), r.get("name", ""), ",".join(r.get("include") or [])))
        return 0

    if args.rules:
        ids = [x.strip() for x in args.rules.split(",") if x.strip()]
        rules = [r for r in rules if r.get("id") in ids]
        if not rules:
            sys.stderr.write("No rule matched: %s\n" % args.rules)
            return 2

    files = args.files
    added = None
    use_index = False
    if args.diff_from_stdin or args.diff_file:
        if args.diff_file:
            with open(args.diff_file, "rb") as fh:
                diff_text = fh.read().decode("utf-8", "replace")
        else:
            diff_text = sys.stdin.buffer.read().decode("utf-8", "replace")
        added = parse_added_lines(diff_text)
        use_index = True
        if not added:
            if not args.quiet:
                print("[OK] red-line scan passed: no added line in diff")
            return 0
        files = list(added.keys())
    elif args.files_from_stdin:
        files = [x.strip() for x in sys.stdin.buffer.read().decode("utf-8", "replace").splitlines() if x.strip()]

    picked = collect(root, args.include, args.exclude_dir, files)

    hits = []
    for path, rel in picked:
        rel_slash = rel.replace(os.sep, "/")
        file_added = None
        if added is not None:
            file_added = added.get(rel_slash)
            if file_added is None:
                continue
        applicable = []
        for rule in rules:
            inc = rule.get("include") or []
            if inc and not match_any(os.path.basename(path), inc):
                continue
            inc_path = rule.get("includePath") or []
            if inc_path and not match_any(rel_slash, inc_path):
                continue
            applicable.append(rule)
        if applicable:
            text = read_scan_text(root, rel, path, use_index)
            hits.extend(scan_file(path, rel, applicable, file_added, text))

    if not hits:
        if not args.quiet:
            print("[OK] red-line scan passed: 0 violation (%d files scanned)" % len(picked))
        return 0

    print("[FAIL] red-line scan found %d violation(s):" % len(hits))
    print("")
    groups = {}
    for rule, rel, line_no, snippet in hits:
        groups.setdefault(rule.get("id"), []).append((rule, rel, line_no, snippet))
    for rid, items in groups.items():
        first = items[0][0]
        print("[%s] %s  -- %d hit(s)" % (rid, first.get("name", ""), len(items)))
        print("     hint: %s" % first.get("hint", ""))
        for _, rel, line_no, snippet in items:
            print("     %s:%d" % (rel, line_no))
            if not args.quiet:
                print("         %s" % snippet)
        print("")
    print("Red lines are zero-tolerance: STOP -> FIX -> re-verify from the affected stage.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
