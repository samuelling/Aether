"""App Store screenshots for Ambit: each raw iPhone screenshot (any size) captioned and framed
on a 1320 × 2868 canvas (Apple's 6.9" iPhone size), in the icon's space-above, land-below palette.

    python3 AppStore/make_ambit_screenshots.py RAW_DIR OUT_DIR

RAW_DIR holds the phone screenshots named 1.png, 2.png, … (or .jpg, .jpeg, .heic converted first);
captions come from SHOTS below, in the same order.
"""
import os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1320, 2868
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-%s.otf"

# (caption, subcaption) for 1.png, 2.png, …
SHOTS = [
    ("Hear the invisible\naround you", "Four instruments, one key, one tempo"),
    ("The satellites\noverhead", "Orbitakt plays them as dub percussion"),
    ("The weather,\nas a deep drone", "Bellweathered: pressure, wind and light"),
    ("The radio waves\nin the room", "Aether gives every device a voice"),
    ("Your phone's own\ntraffic, on piano", "Leitmotif hears the rhythm, never the content"),
    ("Everything stays\non your iPhone", "No accounts, ads or tracking"),
]


def background():
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    v = (yy / H)[..., None]
    horizon = 0.62
    t = np.clip(v / horizon, 0, 1)
    sky = np.array([6, 8, 26], np.float32) * (1 - t) + np.array([52, 32, 62], np.float32) * t ** 2.4
    rng = np.random.default_rng(124)
    for _ in range(160):
        x, y = rng.uniform(0, W), rng.uniform(0, H * horizon * 0.95)
        a, s = rng.uniform(0.15, 0.55) * (1 - y / (H * horizon)), rng.uniform(1.2, 2.6)
        d2 = (xx - x) ** 2 + (yy - y) ** 2
        sky = 255 - (255 - sky) * (255 - np.array([220, 230, 255], np.float32) * (np.exp(-d2 / (2 * s * s)) * a)[..., None]) / 255
    t2 = np.clip((v - horizon) / (1 - horizon), 0, 1)
    land = np.array([58, 36, 28], np.float32) * (1 - t2) ** 1.4 + np.array([8, 8, 6], np.float32) * (1 - (1 - t2) ** 1.4)
    img = np.where(v < horizon, sky, land)
    line = np.exp(-((yy - H * horizon) / 2.5) ** 2)[..., None] * 0.35
    img = 255 - (255 - img) * (255 - np.array([255, 190, 130], np.float32) * line) / 255
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")


def rounded(im, r):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.size[0] - 1, im.size[1] - 1], radius=r, fill=255)
    out = Image.new("RGBA", im.size)
    out.paste(im, (0, 0), mask)
    return out


def compose(raw, caption, sub, out):
    bg = background().convert("RGBA")
    d = ImageDraw.Draw(bg)
    big = ImageFont.truetype(FONT % "Light", 104)
    small = ImageFont.truetype(FONT % "Regular", 46)
    y = 190
    for line in caption.split("\n"):
        d.text((W / 2, y), line, font=big, anchor="ma", fill=(246, 247, 252))
        y += 124
    d.text((W / 2, y + 26), sub, font=small, anchor="ma", fill=(196, 190, 235))
    top = y + 140

    shot = Image.open(raw).convert("RGB")
    sh = H - top + 120                     # let the phone run off the bottom edge a little
    sw = int(shot.width * sh / shot.height)
    if sw > W - 180:                       # keep side margins
        sw = W - 180
        sh = int(shot.height * sw / shot.width)
    shot = rounded(shot.resize((sw, sh), Image.LANCZOS), 64)
    x = (W - sw) // 2
    glow = Image.new("RGBA", bg.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle([x - 6, top - 6, x + sw + 6, top + sh + 6], radius=70, fill=(150, 140, 255, 90))
    bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(30)))
    frame = Image.new("RGBA", bg.size, (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle([x - 4, top - 4, x + sw + 4, top + sh + 4], radius=68, outline=(255, 255, 255, 60), width=3)
    bg.alpha_composite(shot, (x, top))
    bg = Image.alpha_composite(bg, frame)
    bg.convert("RGB").save(out)        # RGB, no alpha: App Store Connect rejects transparency


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    for i, (cap, sub) in enumerate(SHOTS, 1):
        raw = next((os.path.join(src, f"{i}.{e}") for e in ("png", "jpg", "jpeg") if os.path.exists(os.path.join(src, f"{i}.{e}"))), None)
        if raw:
            compose(raw, cap, sub, os.path.join(dst, f"ambit-{i}.png"))
            print("made", f"ambit-{i}.png")
