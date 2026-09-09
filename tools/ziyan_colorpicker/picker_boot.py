# -*- coding: utf-8 -*-
"""发行 exe 入口：解密内存中的抓色器再执行。"""
from __future__ import annotations

import marshal
import os
import sys
import types

import _collect_imports  # noqa: F401
from protect_build import decrypt_bytes

if getattr(sys, "frozen", False):
    _BASE = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(sys.executable)))
else:
    _BASE = os.path.dirname(os.path.abspath(__file__))


def _load():
    path = os.path.join(_BASE, "_zy_payload.bin")
    raw = decrypt_bytes(open(path, "rb").read())
    codes = marshal.loads(raw)
    fmt = types.ModuleType("formats")
    fmt.__file__ = os.path.join(_BASE, "formats.py")
    sys.modules["formats"] = fmt
    exec(codes["formats.py"], fmt.__dict__)
    g = {
        "__name__": "__main__",
        "__file__": os.path.join(_BASE, "ZiYanColorPicker.py"),
    }
    exec(codes["ZiYanColorPicker.py"], g)


if __name__ == "__main__":
    _load()
