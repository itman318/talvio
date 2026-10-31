"""Cuts the Talvio duck sticker sheet (10 stickers on white) into transparent stickers and gives each
a looping motion (sway, hop, nod, breathe…) plus a glossy shine sweep → animated WebP for the app.
Usage: python3 duck_animate.py sheet.png out_dir [preview.png]"""
import math
import sys

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

SRC, OUT = sys.argv[1], sys.argv[2]
PREVIEW = sys.argv[3] if len(sys.argv) > 3 else None
NAMES = ['hide', 'wave', 'nocontacts', 'search', 'cool', 'sleep', 'delete', 'contacts', 'settings', 'secure']
FRAMES, SIZE, FPS = 30, 320, 12
TAU = math.tau

im = Image.open(SRC).convert('RGBA')
a = np.array(im).astype(int)
white = (a[:, :, 0] > 238) & (a[:, :, 1] > 238) & (a[:, :, 2] > 238)
lab, _ = ndimage.label(white)
border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
fg = ~np.isin(lab, list(border))
fl, m = ndimage.label(ndimage.binary_opening(fg, iterations=2))
sizes = ndimage.sum(fg, fl, range(1, m + 1))
objs = ndimage.find_objects(fl)
parts = sorted([(i, objs[i]) for i in range(m) if sizes[i] > 20000], key=lambda x: (x[1][0].start // 300, x[1][1].start))
assert len(parts) == 10, len(parts)
# little extras around a sticker (zzz, hearts, motion lines) belong to the nearest sticker
extras = {i: [] for i, _ in parts}
centres = {i: ((sl[0].start + sl[0].stop) / 2, (sl[1].start + sl[1].stop) / 2) for i, sl in parts}
for j in range(m):
    if sizes[j] > 20000 or sizes[j] < 120:
        continue
    cy, cx = ndimage.center_of_mass(fl == j + 1)
    k = min(centres, key=lambda i: (centres[i][0] - cy) ** 2 + (centres[i][1] - cx) ** 2)
    extras[k].append(j)


def cut(i, sl):
    ys, xs = sl
    for j in extras[i]:
        o = objs[j]
        ys = slice(min(ys.start, o[0].start), max(ys.stop, o[0].stop))
        xs = slice(min(xs.start, o[1].start), max(xs.stop, o[1].stop))
    pad = 6
    y0, y1 = max(0, ys.start - pad), min(a.shape[0], ys.stop + pad)
    x0, x1 = max(0, xs.start - pad), min(a.shape[1], xs.stop + pad)
    sub = fl[y0:y1, x0:x1]
    mask = ndimage.binary_fill_holes(np.isin(sub, [i + 1] + [j + 1 for j in extras[i]]))
    mask = ndimage.binary_dilation(mask, iterations=1)
    alpha = Image.fromarray((mask * 255).astype('uint8')).filter(ImageFilter.GaussianBlur(0.8))
    tile = im.crop((x0, y0, x1, y1))
    tile.putalpha(alpha)
    # fit into the square with room to move
    s = (SIZE * 0.84) / max(tile.size)
    return tile.resize((round(tile.width * s), round(tile.height * s)), Image.LANCZOS)


def motion(name, t):
    """→ (dx, dy, rotation°, scale x, scale y) around the bottom centre."""
    s = math.sin
    hop = abs(s(t * TAU * 2))
    if name == 'hide':  # shy wiggle
        return 0, 0, 3.5 * s(t * TAU * 2), 1 + 0.015 * s(t * TAU * 4), 1 - 0.015 * s(t * TAU * 4)
    if name == 'wave':  # friendly sway with a bob
        return 0, -4 * hop, 5 * s(t * TAU * 2), 1, 1 + 0.01 * hop
    if name in ('nocontacts', 'search'):  # looking around
        return 10 * s(t * TAU), -3 * hop, 4 * s(t * TAU), 1, 1
    if name == 'cool':  # nodding to the beat
        land = max(0.0, -s(t * TAU * 2))
        return 0, -10 * max(0.0, s(t * TAU * 2)), 2 * s(t * TAU), 1 + 0.04 * land, 1 - 0.04 * land
    if name == 'sleep':  # breathing
        b = s(t * TAU)
        return 0, 0, -2 + 1.5 * b, 1 - 0.02 * b, 1 + 0.035 * b
    if name == 'delete':  # tossing: quick shake, then rest
        shake = 3.5 * s(t * TAU * 6) if t < 0.4 else 0
        return 0, -6 * max(0.0, s(t * TAU)) if t < 0.5 else 0, shake, 1, 1
    if name == 'contacts':  # happy hops
        land = 0.05 if hop < 0.15 else 0
        return 0, -16 * hop, 0, 1 + land, 1 - land
    if name == 'settings':  # tinkering tilt
        return 0, -3 * hop, 4 * s(t * TAU), 1, 1
    if name == 'secure':  # proud pulse
        p = 1 + 0.035 * s(t * TAU * 2)
        return 0, 0, 1.5 * s(t * TAU), p, p
    return 0, 0, 0, 1, 1


def shine(frame, t):
    """A glossy diagonal light sweeping across once per loop."""
    if not 0.55 < t < 0.85:
        return frame
    p = (t - 0.55) / 0.3
    w, h = frame.size
    band = Image.new('L', (w, h), 0)
    arr = np.zeros((h, w), dtype=np.float32)
    yy, xx = np.mgrid[0:h, 0:w]
    centre = -0.4 * w + p * 1.8 * w
    d = np.abs((xx + yy * 0.6) - centre)
    arr = np.clip(1 - d / 38, 0, 1) * 0.38
    band = Image.fromarray((arr * 255).astype('uint8'))
    alpha = frame.getchannel('A')
    band = Image.fromarray(np.minimum(np.array(band), np.array(alpha)).astype('uint8'))
    white = Image.new('RGBA', (w, h), (255, 255, 255, 0))
    white.putalpha(band)
    return Image.alpha_composite(frame, white)


def render(name, sticker, t):
    dx, dy, rot, sx, sy = motion(name, t)
    big = SIZE * 2
    canvas = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    st = sticker.resize((round(sticker.width * 2 * sx), round(sticker.height * 2 * sy)), Image.BICUBIC)
    # bottom-centre pivot
    base_y = round(big * 0.95)
    x = round(big / 2 - st.width / 2 + dx * 2)
    y = round(base_y - st.height + dy * 2)
    layer = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    layer.paste(st, (x, y), st)
    layer = layer.rotate(rot, resample=Image.BICUBIC, center=(big / 2 + dx * 2, base_y + dy * 2))
    canvas = Image.alpha_composite(canvas, layer)
    return shine(canvas.resize((SIZE, SIZE), Image.LANCZOS), t)


stickers = [cut(i, sl) for i, sl in parts]
sheet = []
for name, st in zip(NAMES, stickers):
    frames = [render(name, st, k / FRAMES) for k in range(FRAMES)]
    frames[0].save(f'{OUT}/{name}.webp', save_all=True, append_images=frames[1:], duration=round(1000 / FPS), loop=0, quality=70, method=6, alpha_quality=80)
    sheet.append(frames)
    print('✓', name)
if PREVIEW:
    picks = [0, 9, 18, 27]
    pv = Image.new('RGBA', (SIZE * len(picks), SIZE * len(NAMES)), (243, 244, 249, 255))
    for r, frames in enumerate(sheet):
        for c, k in enumerate(picks):
            pv.alpha_composite(frames[k], (c * SIZE, r * SIZE))
    pv.convert('RGB').resize((SIZE * len(picks) // 2, SIZE * len(NAMES) // 2)).save(PREVIEW)
