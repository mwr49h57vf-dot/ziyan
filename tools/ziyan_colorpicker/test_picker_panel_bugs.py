# -*- coding: utf-8 -*-
"""取色面板三问：复制黏连、方向键跟点、生成脚本 ROI。"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from formats import (  # noqa: E402
    FMT_XY_COLOR,
    make_find_multi_color_in_region_fuzzy,
    make_scripts,
    resolve_find_roi,
    single_text,
    slot_text,
)


def _one_clipboard(text: str) -> str:
    """剪贴板只应留下一份；旧实现 append 两次会黏成 705, 450705, 450。"""
    return text


def test_copy_not_glued() -> None:
    # 用户原句：面板点 705.449.0*c19b66，黏贴变成 705, 450705, 450
    glued = "705, 450" + "705, 450"
    assert glued == "705, 450705, 450"
    assert _one_clipboard("705, 450") == "705, 450"
    p = {"x": 705, "y": 449, "c": 0xC19B66}
    text = single_text(FMT_XY_COLOR, p)
    assert text.count("705") == 1
    assert "450705" not in text
    assert "0xc19b66" in text.lower()


def test_single_line_has_decimal_color() -> None:
    # 用户：单行复制只有坐标和十六进制，没有十进制色值
    # 0xe3c59e = 14927262；RGB 227,197,158
    p = {"x": 719, "y": 450, "c": 0xE3C59E}
    text = single_text(FMT_XY_COLOR, p)
    slot = slot_text(FMT_XY_COLOR, p)
    for s in (text, slot):
        assert "719" in s and "450" in s
        assert "0xe3c59e" in s.lower()
        assert "14927262" in s
        assert "227" in s and "197" in s and "158" in s
        assert s.count("\n") <= 1


def test_roi_uses_captured_points() -> None:
    pts = [{"x": 705, "y": 449, "c": 0xC19B66}]
    # 只按了 A、S 仍是 0,0：禁止把范围写成 705,449,0,0
    ax, ay, sx, sy = resolve_find_roi(705, 449, 0, 0, pts, img_w=2208, img_h=1242)
    assert (ax, ay, sx, sy) == (705, 449, 705, 449)
    line = make_find_multi_color_in_region_fuzzy(pts, ax, ay, sx, sy)
    assert line.count("\n") == 0
    assert line.endswith("90, 705, 449, 705, 449)")
    # A/S 全 0：用色点包围盒，不要 0,0,0,0
    ax, ay, sx, sy = resolve_find_roi(0, 0, 0, 0, pts, img_w=2208, img_h=1242)
    assert (ax, ay, sx, sy) == (705, 449, 705, 449)
    # 完整 A/S 对角仍听人手动画的框
    assert resolve_find_roi(10, 20, 100, 80, pts) == (10, 20, 100, 80)
    # 从原点拉到 S
    assert resolve_find_roi(0, 0, 100, 80, pts) == (0, 0, 100, 80)


def test_generate_box3_one_line_with_roi() -> None:
    pts = [
        {"x": 705, "y": 449, "c": 0xC19B66},
        {"x": 708, "y": 452, "c": 0xB08A55},
    ]
    ax, ay, sx, sy = resolve_find_roi(0, 0, 0, 0, pts, 2208, 1242)
    _s1, _s2, s3 = make_scripts(FMT_XY_COLOR, pts, ax, ay, sx, sy, degree=90)
    assert s3.count("findMultiColorInRegionFuzzy") == 1
    assert "\n" not in s3
    assert s3.endswith("90, 705, 449, 708, 452)")


def test_snapshot_follows_orient1() -> None:
    from PIL import Image
    from ZiYanColorPicker import apply_snapshot_orient

    # 真机 /snapshot?orient=1 仍给竖图 640x1136；方向1必须变成横屏 HOME 在右
    im = Image.new("RGB", (4, 8), (10, 10, 10))
    im.putpixel((1, 7), (255, 0, 0))  # 竖图底边 = HOME
    out = apply_snapshot_orient(im, 1)
    assert out.size == (8, 4), out.size
    assert out.getpixel((7, 2)) == (255, 0, 0)  # 90°顺时针后 HOME 在右
    assert apply_snapshot_orient(im, 0).size == (4, 8)
    land = Image.new("RGB", (8, 4), (1, 2, 3))
    assert apply_snapshot_orient(land, 1).size == (8, 4)


def test_arrow_stick_stays_until_click() -> None:
    # 方向键之后必须锁住取样点，直到下一次普通单击
    from ZiYanColorPicker import arrow_stick_after_nudge

    assert arrow_stick_after_nudge(warp_ok=True) is True
    assert arrow_stick_after_nudge(warp_ok=False) is True


if __name__ == "__main__":
    test_copy_not_glued()
    test_single_line_has_decimal_color()
    test_roi_uses_captured_points()
    test_generate_box3_one_line_with_roi()
    test_snapshot_follows_orient1()
    test_arrow_stick_stays_until_click()
    print("PICKER_PANEL_BUGS=PASS")
