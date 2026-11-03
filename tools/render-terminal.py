#!/usr/bin/env python3
"""Render captured terminal output as a terminal-style PNG.

Used to produce the demo images in docs/. Reads a UTF-8 text file that holds
the captured output and renders it with a dark terminal theme, monospace
font, optional title bar and per-line colouring rules.

Usage:
    python tools/render-terminal.py <input.txt> <output.png> [--title "..."]
"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Dark terminal palette
BG = (24, 26, 31)
BAR = (36, 39, 46)
FG = (208, 212, 220)
DIM = (118, 124, 138)
RED = (240, 113, 120)
GREEN = (126, 208, 130)
YELLOW = (229, 192, 123)
BLUE = (110, 168, 254)
CYAN = (86, 182, 194)
BOLD = (245, 247, 250)

PAD = 26
LINE_H = 22
BAR_H = 34


def pick_font(size):
    """Latin monospace font. CJK is handled separately by pick_cjk_font."""
    candidates = [
        r"C:\Windows\Fonts\consola.ttf",
        r"C:\Windows\Fonts\DejaVuSansMono_0.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
    ]
    for c in candidates:
        p = Path(c)
        if p.exists():
            try:
                return ImageFont.truetype(str(p), size)
            except Exception:
                continue
    return ImageFont.load_default()


def pick_cjk_font(size):
    """Font with CJK glyphs. Consolas has none, so CJK text must use this."""
    candidates = [
        r"C:\Windows\Fonts\NotoSansSC-VF.ttf",
        r"C:\Windows\Fonts\msyh.ttc",
        r"C:\Windows\Fonts\simhei.ttf",
        r"C:\Windows\Fonts\Deng.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/System/Library/Fonts/PingFang.ttc",
    ]
    for c in candidates:
        p = Path(c)
        if p.exists():
            try:
                return ImageFont.truetype(str(p), size)
            except Exception:
                continue
    return None


def is_cjk(ch):
    o = ord(ch)
    return (
        0x4E00 <= o <= 0x9FFF      # CJK unified ideographs
        or 0x3400 <= o <= 0x4DBF   # extension A
        or 0x3000 <= o <= 0x303F   # CJK punctuation
        or 0xFF00 <= o <= 0xFFEF   # fullwidth forms
        or 0x2E80 <= o <= 0x2EFF   # radicals
    )


def colorize(line):
    """Return (text, color) for a captured output line."""
    s = line.rstrip("\n")
    if not s.strip():
        return s, FG
    low = s.lower()
    if "[fail]" in low or "error" in low or "blocked" in low or "violation" in low:
        return s, RED
    if "[ok]" in low or "[pass]" in low or "passed" in low:
        return s, GREEN
    if "[skip]" in low or "[manual]" in low or "warn" in low:
        return s, YELLOW
    if s.strip().startswith("===") or s.strip().startswith("---"):
        return s, BLUE
    if s.startswith("$ ") or s.startswith("> "):
        return s, CYAN
    if s.startswith("harness gate blocked"):
        return s, RED
    return s, FG


def draw_mixed(dr, xy, text, latin_font, cjk_font, fill):
    """Draw a line, switching to the CJK font for CJK codepoints."""
    x, y = xy
    if cjk_font is None:
        dr.text((x, y), text, font=latin_font, fill=fill)
        return
    # split into runs of same script
    buf = []
    pending = []
    cur_cjk = None
    for ch in text:
        c = is_cjk(ch)
        if cur_cjk is None:
            cur_cjk = c
        elif c != cur_cjk:
            buf.append(("".join(pending), cur_cjk))
            pending = []
            cur_cjk = c
        pending.append(ch)
    if pending:
        buf.append(("".join(pending), cur_cjk))

    for run, is_c in buf:
        if not run:
            continue
        f = cjk_font if is_c else latin_font
        dr.text((x, y), run, font=f, fill=fill)
        x += dr.textlength(run, font=f)


def measure(dr, text, latin_font, cjk_font):
    if cjk_font is None:
        return dr.textlength(text, font=latin_font)
    total = 0.0
    run = ""
    cur = None
    for ch in text:
        c = is_cjk(ch)
        if cur is None:
            cur = c
        elif c != cur:
            total += dr.textlength(run, font=cjk_font if cur else latin_font)
            run = ""
            cur = c
        run += ch
    if run:
        total += dr.textlength(run, font=cjk_font if cur else latin_font)
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--title", default=None)
    ap.add_argument("--size", type=int, default=15)
    args = ap.parse_args()

    text = Path(args.input).read_text(encoding="utf-8")
    lines = text.splitlines()

    font = pick_font(args.size)
    cjk = pick_cjk_font(args.size)

    probe = Image.new("RGB", (10, 10))
    d = ImageDraw.Draw(probe)
    max_w = max((measure(d, ln, font, cjk) for ln in lines), default=0)
    title_w = measure(d, args.title, font, cjk) if args.title else 0

    width = int(max(max_w, title_w) + PAD * 2)
    height = BAR_H + PAD * 2 + len(lines) * LINE_H

    img = Image.new("RGB", (width, height), BG)
    dr = ImageDraw.Draw(img)

    if args.title:
        dr.rectangle([0, 0, width, BAR_H], fill=BAR)
        for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
            dr.ellipse([14 + i * 18, 12, 24 + i * 18, 22], fill=c)
        tw = measure(dr, args.title, font, cjk)
        draw_mixed(dr, ((width - tw) / 2, 9), args.title, font, cjk, DIM)

    y = BAR_H + PAD
    for ln in lines:
        s, c = colorize(ln)
        draw_mixed(dr, (PAD, y), s, font, cjk, c)
        y += LINE_H

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    img.save(args.output)
    print(f"wrote {args.output} ({width}x{height})")


if __name__ == "__main__":
    main()
