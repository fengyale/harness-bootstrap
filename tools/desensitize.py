#!/usr/bin/env python3
"""Desensitise a captured harness installation so it can be published.

Replaces real infrastructure identifiers with neutral placeholders:

  * private IPv4 addresses   -> 10.0.0.x / 192.168.1.x
  * host:port pairs          -> neutral host:port
  * passwords and tokens     -> <redacted>
  * absolute Windows paths    -> neutral paths
  * product / company names  -> neutral descriptions
  * internal URLs            -> neutral URLs

Run:
    python tools/desensitize.py <src-dir> <dst-dir> [--report report.md]

The source tree is never modified.
"""
import argparse
import json
import re
import shutil
from pathlib import Path

# ---------------------------------------------------------------- rules

# Real host:port pairs seen in the capture. Keyed by the exact text so a
# generic pattern cannot accidentally rewrite unrelated numbers.
HOST_MAP = {
    "171.16.101.10": "10.0.0.10",
    "171.16.101.13": "10.0.0.13",
}

# Any remaining private IPv4 (RFC1918) -> deterministic 10.0.0.x
PRIVATE_IP = re.compile(
    r"\b(?:10|172|192)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"
)

# Absolute Windows paths
WIN_PATH = re.compile(r"[A-Za-z]:\\[^\s`\"'|)>,;]+")

# Internal hostnames / URLs
URL = re.compile(r"https?://[^\s`\"'|<>]+")

# Credentials: any key whose value looks like a secret
SECRET_ASSIGN = re.compile(
    r"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|"
    r"signKey|sign_key)\b\s*[:=]\s*(\S+)"
)

# Chinese-style credential annotation, e.g. "（密码 test123）" or "(密码: abc)"
SECRET_CN = re.compile(r"(密码|口令|密钥)\s*[:：]?\s*([^\s)）】，。;；]+)")

# Product / company identifiers
TEXT_MAP = [
    # company / product names
    (r"新星医保质控系统", "医保质控系统"),
    (r"新星 HIS", "HIS 平台"),
    (r"新星HIS", "HIS 平台"),
    (r"新星", "某厂商"),
    # repo / project identifiers
    (r"medical-insurance-web", "insurance-web"),
    (r"medical-insurance", "insurance-backend"),
    (r"medical-rpa-work", "rpa-work"),
    (r"medical_log", "log_db"),
    (r"medical_zs", "main_db"),
    (r"zhfw_group", "group"),
    # package / org names
    (r"com\.kyb", "com.example"),
    (r"\bkyb\b", "example"),
    # specific third-party HIS vendors (identifies the deployment)
    (r"益康云", "平台A"),
    (r"万达", "平台B"),
    (r"创业慧康", "平台C"),
    (r"郑州九院", "平台D"),
    (r"周口一院", "平台E"),
    (r"省医东华", "平台F"),
    # generic org-ish words in paths
    (r"工作空间", "workspace"),
]

# Lines that should be dropped entirely rather than rewritten.
# Only lines that actually carry a credential or a credential *location*.
# References to a config file name are fine and are kept -- they are part of
# the evidence trail and carry no secret.
DROP_LINE = re.compile(
    r"(?i)(gitlab\.env|gitlab-mcp\.env|\bgitlab-mcp\b|"
    r"凭据.*勿外传|token 在|token 在|密码见|密码为)"
)

SKIP_DIRS = {".git", "node_modules", "__pycache__"}
TEXT_EXT = {".md", ".json", ".jsonl", ".txt", ".yml", ".yaml", ".ps1", ".py", ".cfg", ".ini"}


def desensitize_text(text: str) -> str:
    # 1. known hosts first (longest / most specific)
    for real, fake in HOST_MAP.items():
        text = text.replace(real, fake)

    # 2. any other private IPv4 -> deterministic 10.0.0.x
    def ip_sub(m):
        octets = m.group(0).split(".")
        return f"10.0.0.{octets[3]}"

    text = PRIVATE_IP.sub(ip_sub, text)

    # 3. credentials
    text = SECRET_ASSIGN.sub(lambda m: f"{m.group(1)}=<redacted>", text)
    text = SECRET_CN.sub(lambda m: f"{m.group(1)} <redacted>", text)

    # 4. absolute Windows paths
    def path_sub(m):
        p = m.group(0)
        # keep the trailing file name, drop the drive and directories
        parts = [x for x in p.replace("/", "\\").split("\\") if x]
        if not parts:
            return p
        return f"<path>/{'/'.join(parts[-2:])}".replace("/", "\\")

    text = WIN_PATH.sub(path_sub, text)

    # 5. URLs -> neutral
    def url_sub(m):
        u = m.group(0)
        if "github.com" in u or "example.com" in u:
            return u
        return "<internal-url>"

    text = URL.sub(url_sub, text)

    # 5b. user-profile / roaming paths
    text = re.sub(r"(?i)%APPDATA%\\[^\s`\"'|<>]+", "<user-profile>", text)
    text = re.sub(r"(?i)~\.(?:trae-cn|dsh|agents)[\\/][^\s`\"'|<>]+", "<skills-dir>", text)

    # 6. product / company names
    for pat, rep in TEXT_MAP:
        text = re.sub(pat, rep, text)

    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    src = Path(args.src).resolve()
    dst = Path(args.dst).resolve()

    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)

    changed = []
    dropped = []

    for path in sorted(src.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        rel = path.relative_to(src)
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)

        if path.suffix.lower() in TEXT_EXT:
            try:
                original = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                shutil.copy2(path, target)
                continue

            kept_lines = []
            for line in original.splitlines():
                if DROP_LINE.search(line):
                    dropped.append((str(rel), line.strip()[:110]))
                    continue
                kept_lines.append(line)

            new = desensitize_text("\n".join(kept_lines))
            target.write_text(new, encoding="utf-8")
            if new != original:
                changed.append(str(rel))
        else:
            shutil.copy2(path, target)

    print(f"files rewritten : {len(changed)}")
    print(f"lines dropped   : {len(dropped)}")
    if dropped:
        print("\ndropped lines:")
        for f, line in dropped:
            print(f"  {f}: {line}")

    if args.report:
        rep = Path(args.report)
        rep.write_text(
            "# Desensitisation report\n\n"
            f"- files rewritten: {len(changed)}\n"
            f"- lines dropped: {len(dropped)}\n\n"
            "## Rewritten files\n\n"
            + "\n".join(f"- {f}" for f in changed)
            + "\n\n## Dropped lines\n\n"
            + "\n".join(f"- `{f}`: {line}" for f, line in dropped)
            + "\n",
            encoding="utf-8",
        )
        print(f"\nreport -> {rep}")


if __name__ == "__main__":
    main()
