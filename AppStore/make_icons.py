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
    for yc, amp, ph, hue in [(0.72, 0.036, 0.0, 0.52), (0.785, 0.046, 1.2, 0.60), (0.85, 0.036, 2.4, 0.74)]:
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

def tile(bg, symbol, number, mass, name, glow_rgb, out):
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
    cx, cy = S * 0.5, S * 0.40
    ld.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=(250, 251, 255, 255))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=glow_rgb + (230,))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.03))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, layer)

    # Periodic-table furniture: atomic number (top-left), atomic mass (top-right),
    # name under the symbol.
    small = ImageFont.truetype(FONT % "Regular", int(S * 0.078))
    tiny = ImageFont.truetype(FONT % "Medium", int(S * 0.050))
    td = ImageDraw.Draw(img)
    inset_x, inset_y = m + S * 0.055, m + S * 0.04
    td.text((inset_x, inset_y), number, font=small, fill=(255, 255, 255, 215))
    td.text((S - inset_x, inset_y), mass, font=small, anchor="ra", fill=(255, 255, 255, 150))
    # Name, letter-spaced, centred under the symbol
    label, track = name.upper(), S * 0.012
    widths = [td.textlength(ch, font=tiny) for ch in label]
    x = S * 0.5 - (sum(widths) + track * (len(label) - 1)) / 2
    for ch, w in zip(label, widths):
        td.text((x, S * 0.632), ch, font=tiny, anchor="lm", fill=(255, 255, 255, 175))
        x += w + track

    img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(out)

# 119 and 120 are the next undiscovered elements; the masses are each app's medium:
# 2402 MHz (Bluetooth advertising channel 37) and 1013 hPa (one standard atmosphere).
tile(aether_bg(), "Ae", "119", "[2402]", "Aether", (120, 210, 255), sys.argv[1])
tile(bell_bg(), "Bw", "120", "[1013]", "Bell Weather", (255, 190, 120), sys.argv[2])
print("ok")
