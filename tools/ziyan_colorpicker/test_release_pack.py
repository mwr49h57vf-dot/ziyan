# -*- coding: utf-8 -*-
"""发行包合同：别人拿到的 zip 只能跑功能，不能读到源码/脚本。"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from pack_release import (  # noqa: E402
    RELEASE_DIR_NAME,
    RELEASE_EXE_NAME,
    RELEASE_ZIP_NAME,
    forbidden_release_members,
)


def test_source_and_scripts_are_forbidden() -> None:
    # 用户：发给别人的包不能读到抓色器各类文件
    leaked = [
        RELEASE_DIR_NAME + "/ZiYanColorPicker.py",
        RELEASE_DIR_NAME + "/formats.py",
        RELEASE_DIR_NAME + "/build_exe.bat",
        RELEASE_DIR_NAME + "/USAGE.txt",
        RELEASE_DIR_NAME + "/start.bat",
    ]
    bad = forbidden_release_members(leaked)
    assert RELEASE_DIR_NAME + "/ZiYanColorPicker.py" in bad
    assert RELEASE_DIR_NAME + "/formats.py" in bad
    assert RELEASE_DIR_NAME + "/build_exe.bat" in bad


def test_only_named_exe_is_allowed() -> None:
    ok = [RELEASE_DIR_NAME + "/" + RELEASE_EXE_NAME]
    assert forbidden_release_members(ok) == []
    assert forbidden_release_members([RELEASE_DIR_NAME + "/other.exe"]) != []


def test_encrypt_hides_source() -> None:
    from protect_build import decrypt_bytes, encrypt_bytes

    raw = b"def secret_picker():\n    return 175\n"
    blob = encrypt_bytes(raw)
    assert b"secret_picker" not in blob
    assert decrypt_bytes(blob) == raw


def _ico_entry_kinds(path: str):
    data = open(path, "rb").read()
    assert data[:4] == b"\x00\x00\x01\x00"
    n = int.from_bytes(data[4:6], "little")
    kinds = []
    off = 6
    for _ in range(n):
        w, h = data[off], data[off + 1]
        size = int.from_bytes(data[off + 8 : off + 12], "little")
        ofs = int.from_bytes(data[off + 12 : off + 16], "little")
        payload = data[ofs : ofs + 8]
        kind = "PNG" if payload[:8] == b"\x89PNG\r\n\x1a\n" else "BMP"
        kinds.append((w, h, kind, size))
        off += 16
    return kinds


def test_icon_file_is_windows_ico() -> None:
    path = os.path.join(HERE, "ziyan.ico")
    assert os.path.isfile(path), path
    from PIL import Image

    im = Image.open(path)
    assert im.format == "ICO"
    assert im.size[0] >= 16 and im.size[1] >= 16
    # Win7 资源管理器不显示 PNG-in-ICO，16/32/48 必须是 BMP
    kinds = _ico_entry_kinds(path)
    bmp = [k for k in kinds if k[2] == "BMP"]
    assert any(k[0] in (16, 32) and k[2] == "BMP" for k in kinds), kinds
    assert bmp, kinds


def test_ico_corners_are_transparent() -> None:
    # 用户：四个角白点，不是圆润。圆角外必须透明，不能是白像素。
    path = os.path.join(HERE, "ziyan.ico")
    from PIL import Image

    im = Image.open(path)
    frame = im.ico.getimage((48, 48)).convert("RGBA")
    w, h = frame.size
    for xy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        px = frame.getpixel(xy)
        assert px[3] < 32, (xy, px)


def test_app_icon_not_green_placeholder() -> None:
    from pack_release import RESOURCES

    path = os.path.join(RESOURCES, "AppIcon60x60@3x.png")
    assert os.path.isfile(path), path
    from PIL import Image

    im = Image.open(path)
    assert im.size == (180, 180)
    assert os.path.getsize(path) > 2000
    colors = im.convert("RGB").getcolors(maxcolors=64)
    assert colors is None or len(colors) > 8


def test_current_zip_if_present() -> None:
    path = os.path.join(HERE, RELEASE_ZIP_NAME)
    if not os.path.isfile(path):
        return
    import zipfile

    with zipfile.ZipFile(path) as zf:
        names = [i.filename for i in zf.infolist() if not i.filename.endswith("/")]
    assert forbidden_release_members(names) == [], names


if __name__ == "__main__":
    test_source_and_scripts_are_forbidden()
    test_only_named_exe_is_allowed()
    test_encrypt_hides_source()
    test_icon_file_is_windows_ico()
    test_ico_corners_are_transparent()
    test_app_icon_not_green_placeholder()
    test_current_zip_if_present()
    print("RELEASE_PACK=PASS")
