# -*- coding: utf-8 -*-
"""把抓色器打成只含 exe 的发行 zip。源码目录留给自己改，不进压缩包。"""
from __future__ import annotations

import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RESOURCES = os.path.join(ROOT, "Resources")
RELEASE_DIR_NAME = "ZiYan"
RELEASE_EXE_NAME = "ZiYan.exe"
RELEASE_ZIP_NAME = "ZiYan.zip"
FORBIDDEN_SUFFIXES = (
    ".py",
    ".pyc",
    ".pyo",
    ".spec",
    ".bat",
    ".ps1",
    ".txt",
    ".md",
    ".json",
    ".lua",
)


def forbidden_release_members(names):
    """返回不应出现在发行 zip 里的条目。只允许那一个 exe。"""
    bad = []
    for name in names:
        rel = name.replace("\\", "/").rstrip("/")
        if not rel or rel.endswith("/"):
            continue
        base = rel.split("/")[-1]
        low = base.lower()
        if any(low.endswith(suf) for suf in FORBIDDEN_SUFFIXES):
            bad.append(name)
            continue
        if low != RELEASE_EXE_NAME.lower():
            bad.append(name)
    return bad


def write_release_zip(exe_path, zip_path=None):
    if not os.path.isfile(exe_path):
        raise FileNotFoundError(exe_path)
    if zip_path is None:
        zip_path = os.path.join(HERE, RELEASE_ZIP_NAME)
    inner = "%s/%s" % (RELEASE_DIR_NAME, RELEASE_EXE_NAME)
    tmp = zip_path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(exe_path, inner)
    os.replace(tmp, zip_path)
    with zipfile.ZipFile(zip_path) as zf:
        names = [i.filename for i in zf.infolist() if not i.filename.endswith("/")]
    bad = forbidden_release_members(names)
    if bad:
        raise RuntimeError("release zip leaked files: %s" % bad)
    return zip_path


def _bmp_icon_image(im):
    """32 位 ICO DIB（XOR + AND）。Win7 资源管理器只认这个，不认 PNG-in-ICO。"""
    import struct

    im = im.convert("RGBA")
    w, h = im.size
    pixels = list(im.getdata())
    xor = bytearray()
    for y in range(h - 1, -1, -1):
        for r, g, b, a in pixels[y * w : (y + 1) * w]:
            # 预乘透明，圆角抗锯齿才不会露出白点
            if a < 255:
                r = r * a // 255
                g = g * a // 255
                b = b * a // 255
            xor += struct.pack("BBBB", b, g, r, a)
    row_bytes = ((w + 31) // 32) * 4
    and_mask = bytearray()
    for y in range(h - 1, -1, -1):
        bits = 0
        count = 0
        out = bytearray()
        for _r, _g, _b, a in pixels[y * w : (y + 1) * w]:
            bits = (bits << 1) | (1 if a < 128 else 0)
            count += 1
            if count == 8:
                out.append(bits)
                bits = 0
                count = 0
        if count:
            bits <<= 8 - count
            out.append(bits)
        out.extend(b"\x00" * (row_bytes - len(out)))
        and_mask += out
    header = struct.pack(
        "<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(xor), 0, 0, 0, 0
    )
    return header + xor + and_mask


def make_ico(png_path, ico_path):
    import struct

    from PIL import Image

    src = Image.open(png_path).convert("RGBA")
    sizes = (16, 32, 48)
    resample = getattr(Image, "LANCZOS", Image.BICUBIC)
    images = [_bmp_icon_image(src.resize((s, s), resample)) for s in sizes]
    offset = 6 + 16 * len(images)
    buf = [struct.pack("<HHH", 0, 1, len(images))]
    blobs = []
    for s, blob in zip(sizes, images):
        buf.append(struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(blob), offset))
        blobs.append(blob)
        offset += len(blob)
    with open(ico_path, "wb") as f:
        f.write(b"".join(buf) + b"".join(blobs))
    return ico_path


# iOS AppIcon 文件名 → 像素边长（系统再加圆角，源图铺满正方形）
APP_ICON_PX = {
    "AppIcon29x29.png": 29,
    "AppIcon29x29@2x.png": 58,
    "AppIcon29x29@3x.png": 87,
    "AppIcon40x40.png": 40,
    "AppIcon40x40@2x.png": 80,
    "AppIcon40x40@3x.png": 120,
    "AppIcon50x50.png": 50,
    "AppIcon50x50@2x.png": 100,
    "AppIcon57x57.png": 57,
    "AppIcon57x57@2x.png": 114,
    "AppIcon57x57@3x.png": 171,
    "AppIcon60x60.png": 60,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon72x72.png": 72,
    "AppIcon72x72@2x.png": 144,
    "AppIcon76x76.png": 76,
    "AppIcon76x76@2x.png": 152,
}


def apply_round_alpha(src, radius_ratio=0.22):
    """JPEG 圆角外是白底；裁成透明圆角，Win7 才不会四个白点。"""
    from PIL import Image, ImageDraw

    im = src.convert("RGBA")
    w, h = im.size
    rad = max(2, int(min(w, h) * radius_ratio))
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    if hasattr(d, "rounded_rectangle"):
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=rad, fill=255)
    else:
        d.rectangle([rad, 0, w - rad, h], fill=255)
        d.rectangle([0, rad, w, h - rad], fill=255)
        d.pieslice([0, 0, rad * 2, rad * 2], 180, 270, fill=255)
        d.pieslice([w - rad * 2, 0, w, rad * 2], 270, 360, fill=255)
        d.pieslice([0, h - rad * 2, rad * 2, h], 90, 180, fill=255)
        d.pieslice([w - rad * 2, h - rad * 2, w, h], 0, 90, fill=255)
    im.putalpha(mask)
    return im


def flatten_square_icon(src):
    """圆角预览铺满正方形：透明/白边用中线渐变蓝补上，避免桌面露白角。"""
    im = src.convert("RGBA")
    w, h = im.size
    mid = w // 2
    col = [im.getpixel((mid, y)) for y in range(h)]

    def fallback(y):
        r, g, b, a = col[y]
        if a >= 16 and not (r > 240 and g > 240 and b > 240):
            return (r, g, b)
        for dy in range(1, h):
            for yy in (y + dy, y - dy):
                if 0 <= yy < h:
                    rr, gg, bb, aa = col[yy]
                    if aa >= 16 and not (rr > 240 and gg > 240 and bb > 240):
                        return (rr, gg, bb)
        return (30, 90, 180)

    out = src.convert("RGB")
    pix = out.load()
    srcp = im.load()
    for y in range(h):
        fill = fallback(y)
        for x in range(w):
            r, g, b, a = srcp[x, y]
            if a < 200 or (r > 240 and g > 240 and b > 240):
                pix[x, y] = fill
    return out


def apply_app_icons(preview_path, resources_dir=None):
    from PIL import Image

    if resources_dir is None:
        resources_dir = RESOURCES
    src = flatten_square_icon(Image.open(preview_path))
    resample = getattr(Image, "LANCZOS", Image.BICUBIC)
    written = []
    for name, px in APP_ICON_PX.items():
        path = os.path.join(resources_dir, name)
        src.resize((px, px), resample).save(path, format="PNG")
        written.append(path)
    return written


if __name__ == "__main__":
    import sys

    preview = os.path.join(HERE, "ziyan_app_icon_preview.png")
    png = os.path.join(HERE, "ziyan_picker_icon.png")
    ico = os.path.join(HERE, "ziyan.ico")
    if os.path.isfile(preview):
        from PIL import Image

        rounded = apply_round_alpha(Image.open(preview))
        rounded.save(png)
        rounded.save(preview)
        apply_app_icons(preview)
        print("APP_ICONS_OK", RESOURCES)
    if os.path.isfile(png):
        make_ico(png, ico)
        print("ICO_OK", ico)
    exe = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, RELEASE_EXE_NAME)
    if os.path.isfile(exe):
        out = write_release_zip(exe)
        print("ZIP_OK", out)
    else:
        print("NO_EXE_YET", exe)
