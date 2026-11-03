#!/usr/bin/env python3
"""sql-review-gate.py -- refuse commits that touch SQL without a sql_review note.

Mirrors scripts/sql-review-gate.ps1 for macOS / Linux hosts.

BINDING (the note does NOT have to travel with the commit)
  1) a summary.md inside this commit           <- most accurate
  2) HARNESS_TASK=<feature>                    <- explicit override
  3) newest summary.md under .harness/changes  <- fallback; the path is printed
Missing field -> a TODO placeholder is appended automatically, but the commit is
still refused until the placeholder is replaced with a real result.

SCOPE: only source extensions that carry SQL are inspected; the gate script
itself and all .md files are skipped.
"""
import argparse
import os
import re
import sys

SQL_PATTERNS = [
    re.compile(r'\bselect\b.+?\bfrom\b', re.I),
    re.compile(r'\binsert\b.+?\binto\b', re.I),
    re.compile(r'\b(update|delete)\b.+?\b(where|set|from)\b', re.I),
]
HOT_PATTERNS = [
    (re.compile(r'\bselect\s+\*', re.I), 'select *'),
    (re.compile(r'\bnot\s+in\s*\(', re.I), 'not in'),
    (re.compile(r"like\s*'?\s*%", re.I), "like '%..."),
]
SQL_EXT = {'.java', '.sql', '.xml', '.kt', '.py', '.js', '.ts', '.vue', '.cs'}
PLACEHOLDER = '- sql_review: TODO(evaluate tables / estimated rows / access path)'


def read_staged_diff(path):
    files, added = [], []
    if not path or not os.path.isfile(path):
        return files, added
    cur = ''
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n').rstrip('\r')
            if line.startswith('+++ '):
                cur = line[4:].strip()
                if cur == '/dev/null':
                    cur = ''
                else:
                    cur = re.sub(r'^[ab]/', '', cur)
                    if cur not in files:
                        files.append(cur)
                continue
            if cur and line.startswith('+') and not line.startswith('+++'):
                added.append((cur, line[1:]))
    return files, added


def get_note(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(r'^[^\r\n]*sql_review\b[^\r\n]*', text, re.M)
    if not m:
        return None
    v = m.group(0)
    i = v.find('sql_review')
    if i >= 0:
        v = v[i + len('sql_review'):]
    return v.lstrip(':- \uFF1A').strip()


def add_placeholder(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        return False
    if 'sql_review' in text:
        return False
    sep = '' if text.endswith('\n') else '\n'
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text + sep + PLACEHOLDER + '\n')
    return True


def all_summaries(root):
    base = os.path.join(root, '.harness', 'changes')
    out = []
    if not os.path.isdir(base):
        return out
    for dirpath, _, files in os.walk(base):
        if os.path.basename(dirpath) == '_template':
            continue
        if 'summary.md' not in files:
            continue
        p = os.path.join(dirpath, 'summary.md')
        try:
            m = os.path.getmtime(p)
        except OSError:
            continue
        out.append((m, p))
    out.sort(reverse=True)
    return [p for _, p in out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=os.getcwd())
    ap.add_argument('--diff-file', default='')
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    files, added = read_staged_diff(args.diff_file)
    if not added:
        print('[SKIP] no added lines to inspect')
        return 0

    sql, hot = [], []
    for path, line in added:
        if os.path.splitext(path)[1].lower() not in SQL_EXT:
            continue
        if re.search(r'scripts/sql-review-gate\.', path, re.I):
            continue
        if not any(p.search(line) for p in SQL_PATTERNS):
            continue
        sql.append((path, line))
        for p, name in HOT_PATTERNS:
            if p.search(line) and name not in hot:
                hot.append(name)

    if not sql:
        print('[SKIP] no SQL detected in the staged source lines')
        return 0

    candidates, in_commit = [], set()
    for f in files:
        m = re.match(r'^\.harness/changes/([^/]+)/summary\.md$', f, re.I)
        if not m or m.group(1) == '_template':
            continue
        p = os.path.join(root, f.replace('/', os.sep))
        if p not in candidates:
            candidates.append(p)
            in_commit.add(p)
    task = os.environ.get('HARNESS_TASK')
    if task:
        p = os.path.join(root, '.harness', 'changes', task, 'summary.md')
        if os.path.isfile(p) and p not in candidates:
            candidates.append(p)
    if not candidates:
        for p in all_summaries(root):
            candidates.append(p)

    note, note_from = '', ''
    for c in candidates:
        v = get_note(c)
        if v is None:
            continue
        if len(v) < 4 or re.match(r'(?i)^todo', v):
            continue
        # prefer the most detailed note when several summaries are candidates
        if len(v) > len(note):
            note, note_from = v, c

    print('[INFO] SQL lines in staged source: %d' % len(sql))
    for h in hot:
        print('[WARN] hot SQL pattern: %s (see .harness/rules/SQL review rules)' % h)
        print('       load the 14-sql-review skill and evaluate: tables / estimated rows / access path')

    if note:
        label = os.path.basename(os.path.dirname(note_from))
        where = 'in this commit' if note_from in in_commit else 'on disk, not in this commit'
        print('[PASS] sql_review (%s, %s): %s' % (label, where, note))
        return 0

    if not candidates:
        print('[FAIL] SQL changed but no summary.md exists under .harness/changes/.')
        print('       create .harness/changes/<feature>/summary.md from the template, then fill:')
        print('       sql_review: <tables, estimated rows, access path / explain result>')
        return 1

    target = candidates[0]
    if add_placeholder(target):
        print('[INFO] appended a placeholder to %s' % target)
    print('[FAIL] sql_review is missing or still a TODO.')
    print('       edit %s:' % target)
    print('       sql_review: <tables, estimated rows, access path / explain result>')
    print('       load the 14-sql-review skill, evaluate with MCP (count / index / explain), then commit again.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
