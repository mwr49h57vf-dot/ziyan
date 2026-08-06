#!/usr/bin/python3
"""
TSColorPicker 兼容取色 GUI（macOS 替代 TSColorPicker.exe）

工作流（与触动取色工具一致）:
  1. 手机 init(1) 横屏画面
  2. tools/pull_ts_shot.sh 拉逻辑横屏截图 ts_shot.png
  3. 本工具打开截图，依次点击：主色点 + 若干偏移点
  4. 复制生成的 findMultiColorInRegionFuzzy 到脚本

操作:
  左键  — 加点（第 1 个=主色，其后=相对偏移）
  右键 / U — 撤销一点
  C     — 清空
  生成  — 输出/复制 Lua
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

try:
    from PIL import Image, ImageTk
except ImportError:
    print("需要: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)


class TSColorPickerApp:
    def __init__(self, root: tk.Tk, image_path: Path, logic: tuple[int, int], fuzzy: int, pad: int):
        self.root = root
        self.logic_w, self.logic_h = logic
        self.fuzzy = fuzzy
        self.pad = pad
        self.points: list[tuple[int, int, int]] = []  # logic x,y,color
        self.im = Image.open(image_path).convert("RGB")
        self.image_path = image_path

        root.title(f"TSColorPicker (ZiYan) — {image_path.name}  init逻辑 {self.logic_w}x{self.logic_h}")
        root.geometry("1100x720")

        top = ttk.Frame(root)
        top.pack(fill=tk.X, padx=8, pady=6)
        ttk.Label(top, text=f"相似度").pack(side=tk.LEFT)
        self.fuzzy_var = tk.IntVar(value=fuzzy)
        ttk.Spinbox(top, from_=50, to=100, width=5, textvariable=self.fuzzy_var).pack(side=tk.LEFT, padx=4)
        ttk.Label(top, text="搜索半宽").pack(side=tk.LEFT)
        self.pad_var = tk.IntVar(value=pad)
        ttk.Spinbox(top, from_=4, to=80, width=5, textvariable=self.pad_var).pack(side=tk.LEFT, padx=4)
        ttk.Button(top, text="打开图片…", command=self.open_image).pack(side=tk.LEFT, padx=6)
        ttk.Button(top, text="撤销", command=self.undo).pack(side=tk.LEFT)
        ttk.Button(top, text="清空", command=self.clear).pack(side=tk.LEFT, padx=4)
        ttk.Button(top, text="生成并复制", command=self.generate).pack(side=tk.LEFT, padx=8)

        self.status = tk.StringVar(value="左键加点：第1点=主色，后续=偏移点（相对主色）")
        ttk.Label(root, textvariable=self.status).pack(fill=tk.X, padx=8)

        self.canvas = tk.Canvas(root, bg="#222", cursor="crosshair")
        self.canvas.pack(fill=tk.BOTH, expand=True, padx=8, pady=4)
        self.canvas.bind("<Button-1>", self.on_left)
        self.canvas.bind("<Button-2>", lambda e: self.undo())
        self.canvas.bind("<Button-3>", lambda e: self.undo())
        root.bind("u", lambda e: self.undo())
        root.bind("U", lambda e: self.undo())
        root.bind("c", lambda e: self.clear())
        root.bind("<Configure>", self._on_resize)

        self.out = tk.Text(root, height=5, wrap=tk.WORD, font=("Menlo", 12))
        self.out.pack(fill=tk.X, padx=8, pady=6)

        self.tk_img = None
        self.scale = 1.0
        self.ox = self.oy = 0
        self._draw_image()

    def open_image(self) -> None:
        p = filedialog.askopenfilename(
            filetypes=[("Images", "*.png *.jpg *.jpeg *.bmp"), ("All", "*.*")]
        )
        if not p:
            return
        self.image_path = Path(p)
        self.im = Image.open(self.image_path).convert("RGB")
        self.clear()
        self._draw_image()
        self.root.title(f"TSColorPicker (ZiYan) — {self.image_path.name}")

    def _on_resize(self, _evt=None) -> None:
        self.root.after(80, self._draw_image)

    def _draw_image(self) -> None:
        cw = max(self.canvas.winfo_width(), 100)
        ch = max(self.canvas.winfo_height(), 100)
        iw, ih = self.im.size
        self.scale = min(cw / iw, ch / ih)
        dw, dh = int(iw * self.scale), int(ih * self.scale)
        self.ox = (cw - dw) // 2
        self.oy = (ch - dh) // 2
        shown = self.im.resize((dw, dh), Image.Resampling.BILINEAR)
        self.tk_img = ImageTk.PhotoImage(shown)
        self.canvas.delete("all")
        self.canvas.create_image(self.ox, self.oy, anchor=tk.NW, image=self.tk_img)
        for i, (lx, ly, col) in enumerate(self.points):
            ix = int(lx / max(self.logic_w - 1, 1) * (iw - 1))
            iy = int(ly / max(self.logic_h - 1, 1) * (ih - 1))
            cx = self.ox + int(ix * self.scale)
            cy = self.oy + int(iy * self.scale)
            r = 6 if i == 0 else 4
            color = "#00ff66" if i == 0 else "#ff3344"
            self.canvas.create_oval(cx - r, cy - r, cx + r, cy + r, outline=color, width=2)
            self.canvas.create_text(cx + 10, cy - 8, text=str(i), fill=color, anchor=tk.W)

    def _canvas_to_logic(self, cx: int, cy: int) -> tuple[int, int] | None:
        ix = (cx - self.ox) / self.scale
        iy = (cy - self.oy) / self.scale
        iw, ih = self.im.size
        if ix < 0 or iy < 0 or ix >= iw or iy >= ih:
            return None
        lx = int(round(ix / max(iw - 1, 1) * (self.logic_w - 1)))
        ly = int(round(iy / max(ih - 1, 1) * (self.logic_h - 1)))
        return max(0, min(self.logic_w - 1, lx)), max(0, min(self.logic_h - 1, ly))

    def _color_at_logic(self, lx: int, ly: int) -> int:
        iw, ih = self.im.size
        x = int(round(lx / max(self.logic_w - 1, 1) * (iw - 1)))
        y = int(round(ly / max(self.logic_h - 1, 1) * (ih - 1)))
        x = max(0, min(iw - 1, x))
        y = max(0, min(ih - 1, y))
        r, g, b = self.im.getpixel((x, y))[:3]
        return (r << 16) | (g << 8) | b

    def on_left(self, evt) -> None:
        pos = self._canvas_to_logic(evt.x, evt.y)
        if not pos:
            return
        lx, ly = pos
        col = self._color_at_logic(lx, ly)
        self.points.append((lx, ly, col))
        n = len(self.points)
        if n == 1:
            self.status.set(f"主色 ({lx},{ly}) 0x{col:06X} — 继续点偏移点")
        else:
            ax, ay, _ = self.points[0]
            self.status.set(
                f"偏移#{n-1} dx={lx-ax} dy={ly-ay} 0x{col:06X} — 点「生成并复制」"
            )
        self._draw_image()
        self.generate(copy=False)

    def undo(self) -> None:
        if self.points:
            self.points.pop()
        self._draw_image()
        self.generate(copy=False)

    def clear(self) -> None:
        self.points.clear()
        self.out.delete("1.0", tk.END)
        self.status.set("已清空。左键加点。")
        self._draw_image()

    def build_lua(self) -> str:
        if not self.points:
            return "-- 请先点击主色点和偏移点"
        ax, ay, main = self.points[0]
        parts = []
        for lx, ly, col in self.points[1:]:
            parts.append(f"{lx - ax}|{ly - ay}|0x{col:06x}")
        if not parts:
            # 触动允许只有主色：用 0|0|同色 占位，或单点区域找色
            parts.append(f"0|0|0x{main:06x}")
        fuzzy = int(self.fuzzy_var.get())
        pad = int(self.pad_var.get())
        x1, y1 = max(0, ax - pad), max(0, ay - pad)
        x2 = min(self.logic_w - 1, ax + pad)
        y2 = min(self.logic_h - 1, ay + pad)
        off = ",".join(parts)
        return (
            f"init(1)\n"
            f"x, y = findMultiColorInRegionFuzzy(0x{main:06x}, \"{off}\", "
            f"{fuzzy}, {x1}, {y1}, {x2}, {y2})"
        )

    def generate(self, copy: bool = True) -> None:
        code = self.build_lua()
        self.out.delete("1.0", tk.END)
        self.out.insert(tk.END, code)
        if copy and self.points:
            self.root.clipboard_clear()
            self.root.clipboard_append(code)
            self.status.set("已生成并复制到剪贴板（TSColorPicker 格式）")


def main() -> int:
    ap = argparse.ArgumentParser(description="TSColorPicker-compatible GUI")
    ap.add_argument("image", nargs="?", help="截图路径（逻辑横屏或任意比例）")
    ap.add_argument("--logic", default="1136x640")
    ap.add_argument("--fuzzy", type=int, default=90)
    ap.add_argument("--pad", type=int, default=15)
    args = ap.parse_args()
    lw, lh = map(int, args.logic.lower().split("x"))

    img = args.image
    if not img:
        root = tk.Tk()
        root.withdraw()
        img = filedialog.askopenfilename(
            title="选择截图（建议先 pull_ts_shot.sh）",
            filetypes=[("PNG", "*.png"), ("All", "*.*")],
        )
        root.destroy()
        if not img:
            return 1

    path = Path(img)
    if not path.exists():
        print("文件不存在:", path, file=sys.stderr)
        return 1

    root = tk.Tk()
    TSColorPickerApp(root, path, (lw, lh), args.fuzzy, args.pad)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
