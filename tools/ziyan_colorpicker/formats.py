# -*- coding: utf-8 -*-
"""
子砚取色器 · 脚本生成（formats = 色串唯一源）

对齐触动 TSColorPicker 1.7.10 的 make_FMC / make_findMultiColorInRegionFuzzy
以及内置自定义格式（X,Y,Color / 表 / pos.new / 桃桃 RGB·Hex / 点阵 / 旧版）。

产出目标：Desktop ios7.lua / ios8p.lua（ZiYanColorPicker）
禁止写入/自测触动精灵色参；不搬 TS 源码，只复现可观察的格式语义。
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Sequence, Tuple

import math


Point = Dict[str, int]  # x,y,c 及可选 r,g,b
PosList = List[Point]


def rgb_to_c(r: int, g: int, b: int) -> int:
    return ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)


def c_to_rgb(c: int) -> Tuple[int, int, int]:
    return ((c >> 16) & 0xFF, (c >> 8) & 0xFF, (c & 0xFF))


def enrich(p: Point) -> Point:
    """保证点含 r/g/b。"""
    q = dict(p)
    if "r" not in q or "g" not in q or "b" not in q:
        q["r"], q["g"], q["b"] = c_to_rgb(int(q.get("c", 0)))
    q["c"] = int(q.get("c", 0)) & 0xFFFFFF
    q["x"] = int(q.get("x", 0))
    q["y"] = int(q.get("y", 0))
    return q


def make_fmc(points: Sequence[Point]) -> str:
    """对齐 ColorPicker make_FMC：主色 + 相对偏点串（含引号外的逗号分隔）。"""
    if not points:
        return '0x000000, ""'
    first = enrich(points[0])
    parts = ['0x%06x, "' % (first["c"] & 0xFFFFFF)]
    offs = []
    fx, fy = first["x"], first["y"]
    for p in points[1:]:
        p = enrich(p)
        offs.append(
            "%d|%d|0x%06x" % (p["x"] - fx, p["y"] - fy, p["c"] & 0xFFFFFF)
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
            out.append(enrich(p))
    p0 = regs.get(0)
    if p0:
        out.append(enrich(p0))
    return out


def toboolean(setv: Any) -> bool:
    if isinstance(setv, bool):
        return setv
    try:
        return abs(int(setv)) > 0
    except (TypeError, ValueError):
        return bool(setv)


def _maybe_strip_space(text: str, setv: Dict[str, str]) -> str:
    if not toboolean(setv.get("空格补齐", "1")):
        return text.replace(" ", "")
    return text


def _maybe_strip_nl(text: str, setv: Dict[str, str]) -> str:
    if not toboolean(setv.get("换行格式", "1")):
        return text.replace("\n", "").replace("\t", "")
    return text


def _old_common(fmt: str, a: Point, s: Point) -> str:
    ret = fmt
    ret = ret.replace("#SX#", "%4d" % a["x"]).replace("#SY#", "%4d" % a["y"])
    ret = ret.replace("#EX#", "%4d" % s["x"]).replace("#EY#", "%4d" % s["y"])
    ret = ret.replace("#0SX#", "%d" % a["x"]).replace("#0SY#", "%d" % a["y"])
    ret = ret.replace("#0EX#", "%d" % s["x"]).replace("#0EY#", "%d" % s["y"])
    ret = ret.replace("#CR#", "\r").replace("#LF#", "\n")
    ret = ret.replace("#SP#", " ").replace("#T#", "\t")
    return ret


def _old_pos(fmt: str, p: Point) -> str:
    p = enrich(p)
    ret = fmt
    ret = ret.replace("#X#", "%4d" % p["x"]).replace("#Y#", "%4d" % p["y"])
    ret = ret.replace("#R#", "%3d" % p["r"]).replace("#G#", "%3d" % p["g"]).replace("#B#", "%3d" % p["b"])
    ret = ret.replace("#0X#", "%d" % p["x"]).replace("#0Y#", "%d" % p["y"])
    ret = ret.replace("#0R#", "%d" % p["r"]).replace("#0G#", "%d" % p["g"]).replace("#0B#", "%d" % p["b"])
    ret = ret.replace("#HR#", "%02x" % p["r"]).replace("#HG#", "%02x" % p["g"]).replace("#HB#", "%02x" % p["b"])
    ret = ret.replace("#C#", "0x%06x" % p["c"])
    return ret


def make_old_script(pre: str, mid: str, sep: str, fix: str, poslist: Sequence[Point], a: Point, s: Point) -> str:
    fmc = make_fmc(poslist)
    ret = _old_common(pre, a, s).replace("#FMC#", fmc)
    sep_s = _old_common(sep, a, s).replace("#FMC#", fmc)
    fix_s = _old_common(fix, a, s).replace("#FMC#", fmc)
    parts = []
    for p in poslist:
        parts.append(_old_pos(_old_common(mid, a, s), p))
    return ret + sep_s.join(parts) + fix_s


def z_cmp_color(c1: int, c2: int) -> int:
    """对齐 TS z_cmpColor：三通道乘积相似度 0~100。"""
    r1, g1, b1 = c_to_rgb(c1)
    r2, g2, b2 = c_to_rgb(c2)
    rd = (0xFF - abs(r1 - r2)) / 0xFF
    gd = (0xFF - abs(g1 - g2)) / 0xFF
    bd = (0xFF - abs(b1 - b2)) / 0xFF
    return int(math.ceil(rd * gd * bd * 100))


def cap_matrix(
    pix,
    w: int,
    h: int,
    ax: int,
    ay: int,
    sx: int,
    sy: int,
    color: int,
    csim: int = 90,
    xstep: int = 1,
    ystep: int = 1,
    dot0: str = "0",
    dot1: str = "1",
) -> str:
    """对齐 TS capMatrix：A→S 矩形内与参考色比相似度，输出 01 点阵。"""
    xstep = xstep if xstep > 0 else 1
    ystep = ystep if ystep > 0 else 1
    x0, x1 = (ax, sx) if ax <= sx else (sx, ax)
    y0, y1 = (ay, sy) if ay <= sy else (sy, ay)
    rows = []
    y = y0
    while y <= y1:
        cols = []
        x = x0
        while x <= x1:
            if 0 <= x < w and 0 <= y < h:
                r, g, b = pix[x, y]
                cc = rgb_to_c(r, g, b)
            else:
                cc = 0
            cols.append(dot1 if z_cmp_color(cc, color) > csim else dot0)
            x += xstep
        rows.append("".join(cols))
        y += ystep
    return "\n".join(rows) + ("\n" if rows else "")


# 触动内置格式标题（下拉顺序与 cf_enabled + customformats.lua 一致）
FMT_XY_COLOR = "X, Y, Color"
FMT_BRACE = "{X, Y, Color},"
FMT_POSNEW = "pos.new(X, Y, Color),"
FMT_TAOTAO_RGB = "精简去空格版RGB - By 桃桃"
FMT_TAOTAO_HEX = "精简去空格版Hex - By 桃桃"
FMT_MATRIX = "简易点阵(快捷键 ~ )"
FMT_OLD = "旧版兼容格式"

FORMAT_NAMES = [
    FMT_XY_COLOR,
    FMT_BRACE,
    FMT_POSNEW,
    FMT_TAOTAO_RGB,
    FMT_TAOTAO_HEX,
    FMT_MATRIX,
    FMT_OLD,
]

DEFAULT_SETTINGS = {
    FMT_XY_COLOR: {
        "格式2相似度": "85",
        "格式2函数名": "isColor",
        "空格补齐": "1",
        "换行格式": "1",
    },
    FMT_BRACE: {
        "格式2相似度": "85",
        "格式2函数名": "isColor",
        "空格补齐": "1",
        "换行格式": "1",
    },
    FMT_POSNEW: {
        "相似度": "90",
        "格式2延迟": "100",
        "格式2点按深度": "100",
        "格式2默认标签": "",
    },
    FMT_TAOTAO_RGB: {
        "相似度(1-100 空为100%)": "85",
    },
    FMT_TAOTAO_HEX: {
        "相似度(1-100 空为100%)": "85",
    },
    FMT_MATRIX: {
        "格式1前缀": "{#LF#",
        "格式1中缀": "#T#{ #X#, #Y#, #C#},#LF#",
        "格式1分隔符": "",
        "格式1后缀": "}",
    },
    FMT_OLD: {
        "格式1前缀": "{#LF#",
        "格式1中缀": "#T#{ #X#, #Y#, #C#},#LF#",
        "格式1分隔符": "",
        "格式1后缀": "}",
        "格式2前缀": "if (",
        "格式2中缀": "isColor( #X#, #Y#, #C#, 85)",
        "格式2分隔符": "#SP#and#SP#",
        "格式2后缀": ") then",
    },
}


def default_settings(name: str) -> Dict[str, str]:
    return dict(DEFAULT_SETTINGS.get(name, {}))


def slot_text(name: str, p: Point, setv: Optional[Dict[str, str]] = None) -> str:
    """多点寄存行（对齐 multiPosFormatRule）。"""
    setv = setv or default_settings(name)
    p = enrich(p)
    if name == FMT_BRACE:
        fmt = "{ %4d, %4d, 0x%06x },\n" % (p["x"], p["y"], p["c"])
        fmt = _maybe_strip_nl(fmt, setv)
        return _maybe_strip_space(fmt, setv)
    if name == FMT_POSNEW:
        return "pos.new( %4d, %4d, 0x%06x ),\n" % (p["x"], p["y"], p["c"])
    if name == FMT_TAOTAO_RGB:
        return "%d,%d,%d,%d,%d\n" % (p["x"], p["y"], p["r"], p["g"], p["b"])
    if name == FMT_TAOTAO_HEX:
        return "%d,%d,0x%06x\n" % (p["x"], p["y"], p["c"])
    if name == FMT_OLD:
        return _old_pos("{ #X#, #Y#, #C#},\n", p)
    fmt = " %4d, %4d, 0x%06x \n" % (p["x"], p["y"], p["c"])
    fmt = _maybe_strip_nl(fmt, setv)
    return _maybe_strip_space(fmt, setv)


def single_text(name: str, p: Point, setv: Optional[Dict[str, str]] = None) -> str:
    """单点预览 / ` 键剪贴板（对齐 singlePosFormatRule）。"""
    setv = setv or default_settings(name)
    p = enrich(p)
    if name == FMT_BRACE:
        fmt = "{ %4d, %4d, 0x%06x }" % (p["x"], p["y"], p["c"])
        return _maybe_strip_space(fmt, setv)
    if name == FMT_POSNEW:
        return "pos.new( %4d, %4d, 0x%06x)" % (p["x"], p["y"], p["c"])
    if name == FMT_TAOTAO_RGB:
        return "%d,%d,%d,%d,%d" % (p["x"], p["y"], p["r"], p["g"], p["b"])
    if name == FMT_TAOTAO_HEX:
        return "%d,%d,0x%06x" % (p["x"], p["y"], p["c"])
    if name == FMT_OLD:
        return _old_pos("{ #X#, #Y#, #C#}", p)
    fmt = " %4d, %4d, 0x%06x " % (p["x"], p["y"], p["c"])
    return _maybe_strip_space(fmt, setv)


def preview_info(name: str, p: Point) -> str:
    """右侧「取色格式预览」一行。"""
    p = enrich(p)
    if name in (FMT_TAOTAO_RGB, FMT_TAOTAO_HEX):
        return "X:%d Y:%d  R:%d G:%d B:%d  C:0x%06x" % (
            p["x"], p["y"], p["r"], p["g"], p["b"], p["c"]
        )
    return single_text(name, p).strip()


def _table_xy_color(points: Sequence[Point], setv: Dict[str, str]) -> str:
    ret = "{\n"
    for p in points:
        p = enrich(p)
        ret += "\t{ %4d, %4d, 0x%06x},\n" % (p["x"], p["y"], p["c"])
    ret += "}"
    ret = _maybe_strip_nl(ret, setv)
    return _maybe_strip_space(ret, setv)


def _iscolor_chain(points: Sequence[Point], setv: Dict[str, str], rgb: bool = False) -> str:
    fn = setv.get("格式2函数名", "isColor") or "isColor"
    sim = setv.get("格式2相似度", "85")
    parts = []
    for p in points:
        p = enrich(p)
        if rgb:
            sim2 = setv.get("相似度(1-100 空为100%)", "85")
            extra = ("," + sim2) if sim2 != "" else ""
            parts.append("isColor(%d,%d,%d,%d,%d%s)" % (p["x"], p["y"], p["r"], p["g"], p["b"], extra))
        else:
            if "相似度(1-100 空为100%)" in setv:
                sim2 = setv.get("相似度(1-100 空为100%)", "85")
                extra = ("," + sim2) if sim2 != "" else ""
                parts.append("isColor(%d,%d,0x%06x%s)" % (p["x"], p["y"], p["c"], extra))
            else:
                parts.append("%s(%4d, %4d, 0x%06x, %s)" % (fn, p["x"], p["y"], p["c"], sim))
    joiner = " and \n" if toboolean(setv.get("换行格式", "1")) and "格式2函数名" in setv else " and "
    if "格式2函数名" in setv:
        ret = "if (" + joiner.join(parts) + ") then"
        ret = _maybe_strip_nl(ret, setv)
        return _maybe_strip_space(ret, setv)
    return "if " + " and ".join(parts) + " then"


def make_scripts(
    name: str,
    points: Sequence[Point],
    ax: int,
    ay: int,
    sx: int,
    sy: int,
    degree: int = 90,
    setv: Optional[Dict[str, str]] = None,
    img_w: int = 0,
    img_h: int = 0,
    local_prefix: bool = False,
    pix=None,
    xc: Tuple[int, int] = (0, 0),
    cc: Tuple[int, int] = (0, 0),
) -> Tuple[str, str, str]:
    """生成触动三路脚本框：表 / 比色 if / findMultiColorInRegionFuzzy。"""
    setv = setv or default_settings(name)
    pts = [enrich(p) for p in points]
    a = {"x": int(ax), "y": int(ay), "c": 0}
    s = {"x": int(sx), "y": int(sy), "c": 0}
    if ax == 0 and ay == 0 and sx == 0 and sy == 0 and img_w > 0 and img_h > 0:
        sx, sy = img_w - 1, img_h - 1
        s = {"x": sx, "y": sy, "c": 0}
    fmc_line = make_find_multi_color_in_region_fuzzy(
        pts, ax, ay, sx, sy, degree=degree, img_w=img_w, img_h=img_h
    )
    if local_prefix and not fmc_line.startswith("local "):
        fmc_line = "local " + fmc_line

    empty = ("", "", fmc_line if pts else "")
    if not pts:
        return empty

    if name == FMT_POSNEW:
        t1 = "{\n\tcsim = %s,\n" % setv.get("相似度", "90")
        t1 += "\ttl = pos.new(%d, %d),\n" % (ax, ay)
        t1 += "\tbr = pos.new(%d, %d),\n" % (sx, sy)
        for p in pts:
            t1 += "\tpos.new( %4d, %4d, 0x%06x),\n" % (p["x"], p["y"], p["c"])
        t1 += "}"
        t2 = "{\n\tcsim = %s,\n\tdelay = %s,\n\tclkdeep = %s,\n\tlabel = \"%s\",\n" % (
            setv.get("相似度", "90"),
            setv.get("格式2延迟", "100"),
            setv.get("格式2点按深度", "100"),
            setv.get("格式2默认标签", ""),
        )
        for p in pts:
            t2 += "\tpos.new( %4d, %4d, 0x%06x),\n" % (p["x"], p["y"], p["c"])
        t2 += "}"
        return t1, t2, fmc_line

    if name == FMT_TAOTAO_RGB:
        t1 = "--取色列表\r\n{\r\n"
        for p in pts:
            t1 += "\t{%d,%d,%d,%d,%d},\r\n" % (p["x"], p["y"], p["r"], p["g"], p["b"])
        t1 += "}"
        t2 = _iscolor_chain(pts, setv, rgb=True)
        return t1, t2, fmc_line

    if name == FMT_TAOTAO_HEX:
        t1 = "--取色列表\r\n{\r\n"
        for p in pts:
            t1 += "\t{%d,%d,0x%06x},\r\n" % (p["x"], p["y"], p["c"])
        t1 += "}"
        t2 = _iscolor_chain(pts, setv, rgb=False)
        return t1, t2, fmc_line

    if name == FMT_MATRIX:
        t1 = make_old_script(
            setv.get("格式1前缀", "{#LF#"),
            setv.get("格式1中缀", "#T#{ #X#, #Y#, #C#},#LF#"),
            setv.get("格式1分隔符", ""),
            setv.get("格式1后缀", "}"),
            pts, a, s,
        )
        csim = xc[0] if xc[0] else 90
        xstep = cc[0] if cc[0] else 1
        ystep = cc[1] if cc[1] else 1
        if pix is not None and img_w > 0 and img_h > 0:
            t2 = cap_matrix(pix, img_w, img_h, ax, ay, sx, sy, pts[0]["c"], csim, xstep, ystep)
        else:
            t2 = ""
        return t1, t2, fmc_line

    if name == FMT_OLD:
        t1 = make_old_script(
            setv.get("格式1前缀", "{#LF#"),
            setv.get("格式1中缀", "#T#{ #X#, #Y#, #C#},#LF#"),
            setv.get("格式1分隔符", ""),
            setv.get("格式1后缀", "}"),
            pts, a, s,
        )
        t2 = make_old_script(
            setv.get("格式2前缀", "if ("),
            setv.get("格式2中缀", "isColor( #X#, #Y#, #C#, 85)"),
            setv.get("格式2分隔符", "#SP#and#SP#"),
            setv.get("格式2后缀", ") then"),
            pts, a, s,
        )
        return t1, t2, fmc_line

    # X, Y, Color 与 {X, Y, Color},
    t1 = _table_xy_color(pts, setv)
    t2 = _iscolor_chain(pts, setv, rgb=False)
    if name == FMT_XY_COLOR or name == FMT_BRACE:
        fmc_out = fmc_line
        if not toboolean(setv.get("空格补齐", "1")):
            fmc_out = fmc_out.replace(" ", "")
        return t1, t2, fmc_out
    return t1, t2, fmc_line
