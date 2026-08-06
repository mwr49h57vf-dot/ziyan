#!/usr/bin/env python3
"""
TSColorPicker 兼容取色（macOS 无法直接跑 TSColorPicker.exe 时用）。

用法:
  python3 tools/ts_color_pick.py <截图> --logic 1136x640 --init 1 \\
      --point 1019,247 --offsets 1,0;2,0;3,0 --fuzzy 90 --pad 12

  python3 tools/ts_color_pick.py <截图> --logic 1136x640 --init 1 --auto skill

输出触动/TS 格式:
  findMultiColorInRegionFuzzy(0x主色, "dx|dy|0x..,...", fuzzy, x1,y1,x2,y2)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("需要 Pillow: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)


def parse_wh(s: str) -> tuple[int, int]:
    a, b = s.lower().split("x")
    return int(a), int(b)


def logic_to_img(lx: int, ly: int, lw: int, lh: int, iw: int, ih: int) -> tuple[int, int]:
    """逻辑坐标 → 截图像素（按比例，不先拉伸再取点，避免色偏）。"""
    x = int(round(lx / max(lw - 1, 1) * (iw - 1)))
    y = int(round(ly / max(lh - 1, 1) * (ih - 1)))
    return max(0, min(iw - 1, x)), max(0, min(ih - 1, y))


def rgb_at(im: Image.Image, lx: int, ly: int, lw: int, lh: int) -> int:
    x, y = logic_to_img(lx, ly, lw, lh, im.width, im.height)
    r, g, b = im.getpixel((x, y))[:3]
    return (r << 16) | (g << 8) | b


def emit(
    main: int,
    offs: list[tuple[int, int, int]],
    fuzzy: int,
    ax: int,
    ay: int,
    pad: int,
    lw: int,
    lh: int,
) -> str:
    parts = [f"{dx}|{dy}|0x{c:06x}" for dx, dy, c in offs]
    x1 = max(0, ax - pad)
    y1 = max(0, ay - pad)
    x2 = min(lw - 1, ax + pad)
    y2 = min(lh - 1, ay + pad)
    return (
        f'findMultiColorInRegionFuzzy(0x{main:06x}, "{",".join(parts)}", '
        f"{fuzzy}, {x1}, {y1}, {x2}, {y2})"
    )


def auto_pick(im: Image.Image, lw: int, lh: int, kind: str) -> tuple[int, int, list[tuple[int, int]]]:
    """在常见 UI 区选锚点 + 默认偏移。"""
    regions = {
        "skill": (920, 480, 1120, 630),
        "hp": (30, 480, 220, 630),
        "minimap": (980, 20, 1120, 150),
        "xp": (300, 600, 850, 635),
        "user": (1000, 230, 1040, 270),
    }
    x1, y1, x2, y2 = regions.get(kind, regions["skill"])

    def score(lx: int, ly: int) -> float:
        c = rgb_at(im, lx, ly, lw, lh)
        r, g, b = (c >> 16) & 255, (c >> 8) & 255, c & 255
        # 与邻域色差
        diffs = []
        for dx, dy in ((6, 0), (-6, 0), (0, 6), (0, -6), (10, 8), (-8, 10)):
            c2 = rgb_at(im, lx + dx, ly + dy, lw, lh)
            r2, g2, b2 = (c2 >> 16) & 255, (c2 >> 8) & 255, c2 & 255
            diffs.append(abs(r - r2) + abs(g - g2) + abs(b - b2))
        return sum(diffs) / len(diffs)

    best = None
    for ly in range(y1, y2, 2):
        for lx in range(x1, x2, 2):
            s = score(lx, ly)
            if best is None or s > best[0]:
                best = (s, lx, ly)
    assert best
    ax, ay = best[1], best[2]
    # 选色差较大的偏移（比全同色水平串稳）
    cands: list[tuple[int, int, int, int]] = []
    base = rgb_at(im, ax, ay, lw, lh)
    br, bg, bb = (base >> 16) & 255, (base >> 8) & 255, base & 255
    for dy in range(-24, 25):
        for dx in range(-24, 25):
            if dx == 0 and dy == 0:
                continue
            c = rgb_at(im, ax + dx, ay + dy, lw, lh)
            r, g, b = (c >> 16) & 255, (c >> 8) & 255, c & 255
            d = abs(r - br) + abs(g - bg) + abs(b - bb)
            if d < 40:
                continue
            cands.append((d, dx, dy, c))
    cands.sort(reverse=True)
    offs: list[tuple[int, int]] = []
    for d, dx, dy, c in cands:
        if any(abs(dx - ox) + abs(dy - oy) < 5 for ox, oy in offs):
            continue
        offs.append((dx, dy))
        if len(offs) >= 4:
            break
    if len(offs) < 3:
        offs = [(1, 0), (2, 0), (3, 0), (0, 1)]
    return ax, ay, offs


def main() -> int:
    ap = argparse.ArgumentParser(description="TSColorPicker-compatible multi-color emitter")
    ap.add_argument("image", type=Path)
    ap.add_argument("--logic", default="1136x640", help="init 后逻辑分辨率，如 1136x640")
    ap.add_argument("--init", type=int, default=1, choices=(0, 1, 2))
    ap.add_argument("--point", help="锚点 logicX,logicY")
    ap.add_argument(
        "--offsets",
        default="1,0;2,0;3,0",
        help="dx,dy;dx,dy;... 相对锚点",
    )
    ap.add_argument("--fuzzy", type=int, default=90)
    ap.add_argument("--pad", type=int, default=12, help="搜索框半宽")
    ap.add_argument("--auto", choices=("skill", "hp", "minimap", "xp", "user"))
    args = ap.parse_args()

    lw, lh = parse_wh(args.logic)
    if args.init == 0 and lw > lh:
        print("警告: init(0) 通常逻辑为竖屏(短x长)，当前 logic 像横屏", file=sys.stderr)

    im = Image.open(args.image).convert("RGB")
    print(f"-- image={im.size} logic={lw}x{lh} init={args.init}")

    if args.auto:
        ax, ay, off_xy = auto_pick(im, lw, lh, args.auto)
        print(f"-- auto={args.auto} anchor=({ax},{ay})")
    else:
        if not args.point:
            print("需要 --point 或 --auto", file=sys.stderr)
            return 2
        ax, ay = map(int, args.point.split(","))
        off_xy = []
        for part in args.offsets.split(";"):
            if not part.strip():
                continue
            dx, dy = map(int, part.split(","))
            off_xy.append((dx, dy))

    main_c = rgb_at(im, ax, ay, lw, lh)
    print(f"-- getColor({ax},{ay})=0x{main_c:06X}")
    offs = [(dx, dy, rgb_at(im, ax + dx, ay + dy, lw, lh)) for dx, dy in off_xy]
    for dx, dy, c in offs:
        print(f"-- offset ({dx},{dy})=0x{c:06X}")

    cmd = emit(main_c, offs, args.fuzzy, ax, ay, args.pad, lw, lh)
    print()
    print(f"init({args.init})")
    print(cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
