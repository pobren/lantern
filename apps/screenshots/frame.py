# Puts each raw screenshot on a coloured background with a caption above, at the exact sizes App Store Connect
# accepts: iPhone 6.9 inch 1320 x 2868, iPad 13 inch 2064 x 2752, Mac 2880 x 1800 (or 1440 x 900 from a 1x screen).
# Usage: python3 frame.py raw_dir out_dir
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

RAW, OUT = sys.argv[1], sys.argv[2]
SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752), "mac": (2880, 1800)}
CAPTIONS = {
    "inbox": "Fast, native mail for Fastmail",
    "email": "A calm, clear place to read",
    "compose": "Write and reply with ease",
    "folders": "All your folders and labels",
    "dark": "Looks lovely in dark mode",
    "settings": "Your addresses and signatures",
}
TOP, BOTTOM = (47, 91, 211), (28, 52, 130)
FONTS = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
         "/System/Library/Fonts/Helvetica.ttc", "/Library/Fonts/Arial.ttf"]


def font(size):
    for f in FONTS:
        if os.path.exists(f):
            try:
                ft = ImageFont.truetype(f, size)
                try:
                    ft.set_variation_by_name("Bold")
                except Exception:
                    pass
                return ft
            except Exception:
                continue
    try:
        return ImageFont.load_default(size)
    except TypeError:
        return ImageFont.load_default()


def background(w, h):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return img


def rounded(shot, radius):
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.size[0] - 1, shot.size[1] - 1], radius, fill=255)
    out = shot.convert("RGBA")
    out.putalpha(mask)
    return out


def frame(path, device, name):
    W, H = SIZES[device]
    shot = Image.open(path).convert("RGB")
    if device == "mac" and shot.width < 2000:
        W, H = 1440, 900   # also accepted; a 1x capture stays sharp instead of being blown up
    img = background(W, H)
    caption = CAPTIONS.get(name, "")
    size = int(W * (0.062 if device == "iphone" else 0.045 if device == "ipad" else 0.034))
    f = font(size)
    d = ImageDraw.Draw(img)
    cap_h = int(H * (0.13 if device == "iphone" else 0.11 if device == "ipad" else 0.15))
    tw = d.textlength(caption, font=f)
    d.text(((W - tw) / 2, cap_h * 0.42), caption, font=f, fill="white")
    room_w, room_h = int(W * 0.86), H - cap_h - int(H * 0.04)
    scale = min(room_w / shot.width, room_h / shot.height)
    shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    radius = int(shot.width * (0.07 if device == "iphone" else 0.03 if device == "ipad" else 0.012))
    shot = rounded(shot, radius)
    x, y = (W - shot.width) // 2, cap_h + (room_h - shot.height) // 2 + int(H * 0.01)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 18, x + shot.width, y + shot.height + 18], radius, fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    img = Image.alpha_composite(img.convert("RGBA"), shadow)
    img.alpha_composite(shot, (x, y))
    return img.convert("RGB")


os.makedirs(OUT, exist_ok=True)
for device in SIZES:
    folder = os.path.join(RAW, device)
    if not os.path.isdir(folder):
        continue
    for i, file in enumerate(sorted(os.listdir(folder)), 1):
        if not file.endswith(".png"):
            continue
        name = file.split("-", 1)[1][:-4] if "-" in file else file[:-4]
        out = frame(os.path.join(folder, file), device, name)
        out.save(os.path.join(OUT, f"{device}-{file}"))
        print(device, file, out.size)
