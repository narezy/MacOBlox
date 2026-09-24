#!/usr/bin/env python3
"""QR code to the GitHub project: rounded modules, logo gradient colours and
the Mac O' Blox logo in the middle (error correction H keeps it readable).
Needs qrencode and Pillow. Writes qr_github.png."""

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
URL = "https://github.com/narezy/MacOBlox"
TOP, BOTTOM = (0x8b, 0x5c, 0xf6), (0x25, 0x63, 0xeb)   # logo gradient
SCALE, QUIET = 40, 4                                    # px per module, border modules

text = subprocess.run(["qrencode", "-l", "H", "-m", "0", "-t", "ASCII", URL],
                      capture_output=True, text=True, check=True).stdout
rows = [line[::2] for line in text.splitlines() if line.strip()]
n = len(rows)
dark = [[c == "#" for c in row] for row in rows]
size = (n + 2 * QUIET) * SCALE

def colour(y):
    t = y / size
    return tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))

# draw at 4x and downscale for smooth curves
k = 4
img = Image.new("RGB", (size * k, size * k), "white")
draw = ImageDraw.Draw(img)
s = SCALE * k

def in_finder(r, c):
    return any(r0 <= r < r0 + 7 and c0 <= c < c0 + 7 for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)))

logo_modules = int(n * 0.24) | 1                      # odd width, centred
lo = (n - logo_modules) // 2
def in_logo(r, c):
    return lo - 1 <= r <= lo + logo_modules and lo - 1 <= c <= lo + logo_modules

for r in range(n):
    for c in range(n):
        if not dark[r][c] or in_finder(r, c) or in_logo(r, c):
            continue
        x, y = (c + QUIET) * s, (r + QUIET) * s
        pad = s * 0.06
        draw.rounded_rectangle([x + pad, y + pad, x + s - pad, y + s - pad], radius=s * 0.38,
                               fill=colour((r + QUIET + 0.5) * SCALE))

for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)):
    x, y = (c0 + QUIET) * s, (r0 + QUIET) * s
    fill = colour((r0 + QUIET + 3.5) * SCALE)
    draw.rounded_rectangle([x, y, x + 7 * s, y + 7 * s], radius=s * 2.0, fill=fill)
    draw.rounded_rectangle([x + s, y + s, x + 6 * s, y + 6 * s], radius=s * 1.4, fill="white")
    draw.rounded_rectangle([x + 2 * s, y + 2 * s, x + 5 * s, y + 5 * s], radius=s * 0.9, fill=fill)

# logo on a white rounded plate
box = (lo + QUIET) * s, (lo + QUIET) * s, (lo + logo_modules + QUIET) * s, (lo + logo_modules + QUIET) * s
draw.rounded_rectangle(box, radius=s * 1.2, fill="white")
logo = Image.open(HERE / "logo_1024.png").convert("RGBA")
inner = int((box[2] - box[0]) * 0.86)
logo = logo.resize((inner, inner), Image.LANCZOS)
offset = (box[0] + (box[2] - box[0] - inner) // 2, box[1] + (box[3] - box[1] - inner) // 2)
img.paste(logo, offset, logo)

img.resize((size, size), Image.LANCZOS).save(HERE / "qr_github.png")
print(f"{n}x{n} modules, {size}px")
