import numpy as np, colorsys, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2048
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-%s.otf"
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)

def screen(a, b): return 255 - (255 - a) * (255 - b) / 255

def waves_layer(base, alpha):
    """Aether's three tapered waves, as a soft additive layer."""
    img = base
    x0, x1 = S * 0.04, S * 0.96
    u = np.clip((xx - x0) / (x1 - x0), 0, 1)
    window = np.clip(np.sin(np.pi * u), 0, 1)
    fade = window ** 1.1
    for yc, amp, ph, hue in [(0.69, 0.040, 0.0, 0.52), (0.755, 0.050, 1.2, 0.60), (0.82, 0.040, 2.4, 0.74)]:
        A = amp * S * window ** 1.4
        f = yc * S + A * np.sin(2 * np.pi * 2.0 * u + ph)
        dfdx = np.gradient(f[0])[None, :]
        d = np.abs(yy - f) / np.sqrt(1 + dfdx ** 2)
        core = np.clip(1 - (d - S * 0.004) / (S * 0.0015), 0, 1)
        glow = np.exp(-(d / (S * 0.025)) ** 2) * 0.5
        rgb = np.array(colorsys.hsv_to_rgb(hue, 0.55, 1.0), np.float32) * 255
        img = screen(img, rgb[None, None, :] * ((glow + core * 0.8) * fade * alpha)[..., None])
    return img

def aether_bg():
    cx, cy = S * 0.5, S * 0.42
    r = np.clip(np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (S * 0.8), 0, 1)[..., None]
    img = np.array([24, 32, 72], np.float32) * (1 - r) + np.array([4, 5, 14], np.float32) * r
    return waves_layer(img, 0.55)

def bell_bg():
    v = (yy / S)[..., None]
    top = np.array([16, 20, 54], np.float32); mid = np.array([78, 56, 112], np.float32); low = np.array([226, 140, 92], np.float32)
    horizon = 0.80
    t1 = np.clip(v / 0.66, 0, 1)
    sky = top * (1 - t1) + mid * t1
    t2 = np.clip((v - 0.52) / (horizon - 0.52), 0, 1)
    sky = sky * (1 - t2) + low * t2
    hy = horizon * S
    cx, R = S * 0.5, S * 0.105
    d = np.sqrt((xx - cx) ** 2 + (yy - hy) ** 2)
    above = (yy < hy)[..., None]
    glow = np.exp(-((d - R).clip(0) / (0.08 * S)) ** 2)[..., None] * above
    sky = sky + (np.array([255, 190, 120], np.float32) - sky) * glow * 0.5
    disc = np.clip((R - d) / 3, 0, 1)[..., None] * above
    sky = sky * (1 - disc) + np.array([255, 226, 172], np.float32) * disc
    # faint bell rings around the sun
    for rr, a in [(0.20, 0.30), (0.27, 0.20), (0.34, 0.12)]:
        ring = np.exp(-((d - rr * S) / (0.005 * S)) ** 2)[..., None] * above
        sky = sky + (np.array([255, 236, 205], np.float32) - sky) * ring * a
    wt = np.clip((yy - hy) / (S - hy), 0, 1)[..., None]
    water = np.array([38, 32, 66], np.float32) * (1 - wt) + np.array([10, 10, 26], np.float32) * wt
    streak = np.exp(-((xx - cx) / (0.05 * S + 0.12 * (yy - hy))) ** 2) * np.exp(-(yy - hy) / (0.12 * S))
    shimmer = 0.6 + 0.4 * np.sin((yy - hy) / (0.009 * S)) ** 2
    water = water + (np.array([250, 180, 110], np.float32) - water) * (streak * shimmer)[..., None] * 0.6
    below = (yy >= hy)[..., None]
    return sky * (1 - below) + water * below

def tile(bg, symbol, number, name, glow_rgb, out):
    img = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    # Element-tile hairline frame
    frame = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    m = int(S * 0.085)
    fd.rounded_rectangle([m, m, S - m, S - m], radius=int(S * 0.11), outline=(255, 255, 255, 70), width=int(S * 0.0045))
    img = Image.alpha_composite(img, frame)

    # Symbol with a tinted glow
    sym_font = ImageFont.truetype(FONT % "Light", int(S * 0.43))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    cx, cy = S * 0.5, S * 0.43
    ld.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=(250, 251, 255, 255))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=glow_rgb + (230,))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.03))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, layer)

    # Atomic number (top-left) and name (bottom), in the tile's quiet voice
    small = ImageFont.truetype(FONT % "Regular", int(S * 0.075))
    tiny = ImageFont.truetype(FONT % "Regular", int(S * 0.058))
    td = ImageDraw.Draw(img)
    td.text((m + S * 0.06, m + S * 0.045), number, font=small, fill=(255, 255, 255, 200))

    img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(out)

tile(aether_bg(), "Ae", "1", "Aether", (120, 210, 255), sys.argv[1])
tile(bell_bg(), "Bw", "2", "Bell Weather", (255, 190, 120), sys.argv[2])
print("ok")
