"""Ambit's icons: element tiles like the four instruments', over space above and land below,
with the four instruments around the mix pad (Orbitakt top, Leitmotif right, Bellweathered
bottom, Aether left) and the puck in the middle.

    python3 AppStore/make_ambit_icons.py Ambit/AppIcon/.../AppIcon.png Ambit/AppIconName/.../AppIcon.png

Reuses tile() and the helpers from make_icons.py (everything above its final tile() calls).
"""
import os, sys
import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "make_icons.py")).read()
exec(src[: src.index("# 119 and 120 are the next")])   # defines S, xx, yy, screen(), tile()


def ambit_bg(puck_hue):
    v = (yy / S)[..., None]
    horizon = 0.5
    # Space above: deep blue-black fading to a dusk glow at the horizon, with stars.
    t = np.clip(v / horizon, 0, 1)
    sky = np.array([6, 8, 26], np.float32) * (1 - t) + np.array([58, 34, 66], np.float32) * t ** 2.2
    rng = np.random.default_rng(124)
    for _ in range(110):
        x, y = rng.uniform(0, S), rng.uniform(0, S * horizon * 0.92)
        a, s = rng.uniform(0.15, 0.6) * (1 - y / (S * horizon)), rng.uniform(1.5, 3.2)
        d2 = (xx - x) ** 2 + (yy - y) ** 2
        sky = screen(sky, np.array([220, 230, 255], np.float32)[None, None, :] * (np.exp(-d2 / (2 * s * s)) * a)[..., None])
    # Land below: warm at the horizon, earth toward the bottom.
    t2 = np.clip((v - horizon) / (1 - horizon), 0, 1)
    land = np.array([62, 38, 30], np.float32) * (1 - t2) ** 1.5 + np.array([8, 9, 6], np.float32) * (1 - (1 - t2) ** 1.5)
    img = np.where(v < horizon, sky, land)
    line = np.exp(-((yy - S * horizon) / (S * 0.002)) ** 2)[..., None] * 0.35
    img = screen(img, np.array([255, 190, 130], np.float32)[None, None, :] * line)

    # The pad: a ring, and the four instruments' glows around it.
    cx, cy = S * 0.5, S * 0.40
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    ring = np.exp(-((d - S * 0.30) / (S * 0.003)) ** 2) * 0.35
    img = screen(img, np.array([235, 235, 255], np.float32)[None, None, :] * ring[..., None])
    for (dx, dy), col in [((0, -1), (140, 170, 255)), ((1, 0), (255, 110, 170)),
                          ((0, 1), (255, 190, 120)), ((-1, 0), (120, 210, 255))]:
        px, py = cx + dx * S * 0.30, cy + dy * S * 0.30
        dd = np.sqrt((xx - px) ** 2 + (yy - py) ** 2)
        glow = np.exp(-(dd / (S * 0.05)) ** 2) * 0.7 + np.clip((S * 0.016 - dd) / 3, 0, 1)
        img = screen(img, np.array(col, np.float32)[None, None, :] * glow[..., None])
    return img


# 124 and 125 follow the instruments' tiles; the mass is the number of voices (and, for the
# personal edition, the DNS port it listens on, like Leitmotif Name).
tile(ambit_bg(0), "Ab", "124", "[4]", "Ambit", (200, 190, 255), sys.argv[1])
if len(sys.argv) > 2:
    tile(ambit_bg(0), "An", "125", "[53]", "Ambit Name", (255, 184, 92), sys.argv[2])
print("ok")
