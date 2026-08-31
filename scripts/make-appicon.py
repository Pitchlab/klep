#!/usr/bin/env python3
# Genereert de tijdelijke app-icoonbron scripts/appicon/icon-1024.png: een afgeronde
# vierkant met verloop en een witte waveform. Simpele bron, geen ontwerpwerk (PL-730).
# build-app.sh leidt hier met sips + iconutil de .iconset en AppIcon.icns uit af; die
# stappen draaien op Command Line Tools zonder Python. Deze generator is alleen nodig
# om de bron opnieuw te maken. Draai: python3 scripts/make-appicon.py
from PIL import Image, ImageDraw
import os

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Verticaal verloop van indigo naar violet.
top = (37, 42, 92)
bot = (91, 55, 148)
for y in range(S):
    t = y / (S - 1)
    r = int(top[0] + (bot[0] - top[0]) * t)
    g = int(top[1] + (bot[1] - top[1]) * t)
    b = int(top[2] + (bot[2] - top[2]) * t)
    d.line([(0, y), (S, y)], fill=(r, g, b, 255))

# Afgerond vierkant als masker (macOS-icoon-hoekradius ~ 22%).
radius = int(S * 0.2237)
mask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)
img.putalpha(mask)

# Witte waveform: zeven afgeronde staven, symmetrisch oplopend/aflopend.
d = ImageDraw.Draw(img)
heights = [0.30, 0.52, 0.74, 0.92, 0.74, 0.52, 0.30]
n = len(heights)
bar_w = int(S * 0.072)
gap = int(S * 0.052)
total_w = n * bar_w + (n - 1) * gap
x0 = (S - total_w) // 2
cy = S // 2
for i, h in enumerate(heights):
    bh = int(S * 0.5 * h)
    x = x0 + i * (bar_w + gap)
    d.rounded_rectangle([x, cy - bh // 2, x + bar_w, cy + bh // 2],
                        radius=bar_w // 2, fill=(255, 255, 255, 255))

out = os.path.join(os.path.dirname(__file__), "appicon", "icon-1024.png")
img.save(out)
print("wrote", out)
