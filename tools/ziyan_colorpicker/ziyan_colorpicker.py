#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
兼容入口（已废弃独立 UI）。

唯一主程序：ZiYanColorPicker.py（v1.3.4）
色串唯一源：formats.py
自测只对照 Desktop ios7/ios8p（子砚抓色器产出），禁止触动色参样例。
"""
from __future__ import annotations

import os
import runpy
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_MAIN = os.path.join(_HERE, "ZiYanColorPicker.py")


def main() -> None:
    if not os.path.isfile(_MAIN):
        print("missing ZiYanColorPicker.py", file=sys.stderr)
        sys.exit(2)
    sys.argv[0] = _MAIN
    runpy.run_path(_MAIN, run_name="__main__")


if __name__ == "__main__":
    main()
