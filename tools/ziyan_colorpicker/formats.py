# -*- coding: utf-8 -*-
"""
子砚取色器 · 脚本生成（formats = 色串唯一源）

产出目标：Desktop ios7.lua / ios8p.lua（ZiYanColorPicker v1.3.4）
禁止写入/自测触动精灵色参；不搬 TS 源码。

语义：
  make_fmc(points):
    第1点 → 主色 0xRRGGBB
    其后点 → 相对第1点 dx|dy|0xRRGGBB，逗号连接
  make_find_multi_color_in_region_fuzzy(...):
    x,y = findMultiColorInRegionFuzzy( <FMC>, degree, ax, ay, sx, sy )
    ROI = RegA → RegS；若 A/S 全 0 且给了图像尺寸则 S=(w-1,h-1)
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple


Point = Dict[str, int]  # x,y,c  (c = 0xRRGGBB)


def rgb_to_c(r: int, g: int, b: int) -> int:
    return ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)


def c_to_rgb(c: int) -> Tuple[int, int, int]:
    return ((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)


def make_fmc(points: Sequence[Point]) -> str:
    """对齐 ColorPicker make_FMC：主色 + 相对偏点串（含引号外的逗号分隔）。"""
    if not points:
        return '0x000000, ""'
    first = points[0]
    parts = ['0x%06x, "' % (first["c"] & 0xFFFFFF)]
    offs = []
    fx, fy = first["x"], first["y"]
    for p in points[1:]:
        offs.append(
            "%d|%d|0x%06x"
            % (p["x"] - fx, p["y"] - fy, p["c"] & 0xFFFFFF)
        )
    parts.append(",".join(offs))
    parts.append('"')
    return "".join(parts)


def make_find_multi_color_in_region_fuzzy(
    points: Sequence[Point],
    ax: int,
    ay: int,
    sx: int,
    sy: int,
    degree: int = 90,
    img_w: int = 0,
    img_h: int = 0,
    assign: str = "x,y",
) -> str:
    """
    对齐 ColorPicker make_findMultiColorInRegionFuzzy。
    A/S 全 0 且提供了图像尺寸时，S 落到 (w-1, h-1)。
    """
    if ax == 0 and ay == 0 and sx == 0 and sy == 0 and img_w > 0 and img_h > 0:
        sx, sy = img_w - 1, img_h - 1
    fmc = make_fmc(points)
    return "%s = findMultiColorInRegionFuzzy( %s, %d, %d, %d, %d, %d)" % (
        assign,
        fmc,
        int(degree),
        int(ax),
        int(ay),
        int(sx),
        int(sy),
    )


def make_local_line(points: Sequence[Point], ax: int, ay: int, sx: int, sy: int, degree: int = 90) -> str:
    """业务脚本常用：local x,y = findMultiColorInRegionFuzzy(...)"""
    body = make_find_multi_color_in_region_fuzzy(
        points, ax, ay, sx, sy, degree=degree, assign="x,y"
    )
    return "local " + body


def ordered_registers(regs: Dict[int, Optional[Point]]) -> List[Point]:
    """对齐 ColorPicker getPosList：先 1..9，再 0。"""
    out: List[Point] = []
    for i in range(1, 10):
        p = regs.get(i)
        if p:
            out.append(p)
    p0 = regs.get(0)
    if p0:
        out.append(p0)
    return out
