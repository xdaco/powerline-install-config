#!/usr/bin/env python3
"""Render powerline's real ANSI output as an SVG.

Usage:
    powerline shell left --last-exit-code=0 --jobnum=0 \\
        | python3 tools/screenshot.py > prompt.svg
    rsvg-convert -z 2 -o powerline-prompt.png prompt.svg

Run it from inside a git repository so the gitstatus segment appears.

Reads the escape sequences powerline actually emits, so the segments, glyphs and
colours are whatever the live config produces -- nothing here describes the
prompt, it only draws it.
"""
import re, sys, html

FONT = "MesloLGS Nerd Font Mono"
FS = 34.0                      # font size
CELL = 0.60205 * FS            # Meslo advance width, read from the TTF's hmtx
LINEH = FS * 1.45
PAD_X, PAD_Y = 26.0, 22.0
TERM_BG = "#16181a"

# Classic xterm palette for 0-15; 16-231 are the 6x6x6 cube; 232-255 grayscale.
BASE16 = ["#000000","#cd0000","#00cd00","#cdcd00","#0000ee","#cd00cd","#00cdcd","#e5e5e5",
          "#7f7f7f","#ff0000","#00ff00","#ffff00","#5c5cff","#ff00ff","#00ffff","#ffffff"]
LEVELS = [0, 95, 135, 175, 215, 255]

def xterm(n):
    n = int(n)
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        r, g, b = LEVELS[n // 36], LEVELS[(n % 36) // 6], LEVELS[n % 6]
        return f"#{r:02x}{g:02x}{b:02x}"
    v = 8 + 10 * (n - 232)
    return f"#{v:02x}{v:02x}{v:02x}"

def parse(s):
    """ANSI -> [(text, fg, bg, bold)]. Only the attributes powerline emits."""
    fg, bg, bold = "#e5e5e5", None, False
    # re.split with a capturing group alternates: even indices are text, odd
    # indices are the SGR parameters that preceded it.
    out = []
    chunks = re.split(r'\x1b\[([0-9;]*)m', s)
    for idx, chunk in enumerate(chunks):
        if idx % 2 == 1:                      # SGR parameters
            codes = [c for c in chunk.split(';') if c != '']
            j = 0
            while j < len(codes):
                c = codes[j]
                if c == '0':
                    fg, bg, bold = "#e5e5e5", None, False
                elif c == '1':
                    bold = True
                elif c == '22':
                    bold = False
                elif c == '39':
                    fg = "#e5e5e5"
                elif c == '49':
                    bg = None
                elif c == '38' and codes[j+1:j+2] == ['5']:
                    fg = xterm(codes[j+2]); j += 2
                elif c == '48' and codes[j+1:j+2] == ['5']:
                    bg = xterm(codes[j+2]); j += 2
                j += 1
        elif chunk:
            out.append((chunk, fg, bg, bold))
    return out

def svg(runs, extra_lines):
    cols = sum(len(t) for t, _, _, _ in runs) + 2
    for ln in extra_lines:
        cols = max(cols, len(ln[0]) + 2)
    rows = 1 + len(extra_lines)
    w = PAD_X * 2 + cols * CELL
    h = PAD_Y * 2 + rows * LINEH

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
         f'viewBox="0 0 {w:.0f} {h:.0f}">',
         f'<rect width="{w:.0f}" height="{h:.0f}" rx="10" fill="{TERM_BG}"/>',
         f'<g font-family="{FONT}" font-size="{FS}" xml:space="preserve">']

    base = PAD_Y + LINEH * 0.72
    x = PAD_X
    # Backgrounds first, as one rect per run: a half-cell overlap on each side
    # keeps the divider glyphs seamless, which is the whole point of the
    # triangles -- a 1px gap between two rects is instantly visible.
    for text, fg, bg, bold in runs:
        run_w = len(text) * CELL
        if bg:
            o.append(f'<rect x="{x-0.5:.2f}" y="{PAD_Y:.2f}" width="{run_w+1:.2f}" '
                     f'height="{LINEH:.2f}" fill="{bg}"/>')
        x += run_w
    x = PAD_X
    for text, fg, bg, bold in runs:
        run_w = len(text) * CELL
        weight = ' font-weight="bold"' if bold else ''
        o.append(f'<text x="{x:.2f}" y="{base:.2f}" fill="{fg}" textLength="{run_w:.2f}" '
                 f'lengthAdjust="spacing"{weight}>{html.escape(text)}</text>')
        x += run_w
    for n, (text, colour) in enumerate(extra_lines, start=1):
        o.append(f'<text x="{PAD_X:.2f}" y="{base + n*LINEH:.2f}" fill="{colour}" '
                 f'textLength="{len(text)*CELL:.2f}" lengthAdjust="spacing">{html.escape(text)}</text>')
    o.append('</g></svg>')
    return '\n'.join(o)

if __name__ == '__main__':
    raw = sys.stdin.buffer.read().decode('utf-8', 'replace').rstrip('\n')
    runs = parse(raw)
    # A block cursor after the prompt, so it reads as a live prompt rather than
    # a stray line of coloured text.
    runs.append(("█", "#9aa0a6", None, False))
    sys.stdout.write(svg(runs, []))
