#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
子砚取点抓色器 v1.3
- 取色面板布局对齐触动抓色器
- 方向键移动取色光标并同步系统鼠标（DPI 修正）
- 设备端口缓存 + HTTP 长连接，截屏/实时刷新加速
"""

from __future__ import annotations

import http.client
import io
import json
import os
import sys
import threading
import time
import tkinter as tk
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from functools import partial
from tkinter import filedialog, messagebox, ttk
from typing import Dict, List, Optional, Tuple

try:
    from PIL import Image, ImageDraw, ImageGrab, ImageTk
except ImportError:
    print("need pillow: pip install pillow", file=sys.stderr)
    sys.exit(1)

# 色串生成唯一源：formats.py（禁第二套 make_fmc，禁触动色参自测）
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from formats import (  # noqa: E402
    c_to_rgb,
    make_fmc,
    make_find_multi_color_in_region_fuzzy,
    ordered_registers,
    rgb_to_c,
)

SNAP_PORTS = (50005, 50015)
MARKS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
SLOT_ORDER = list(range(1, 10)) + [0]
APP_VER = "1.3.4"
LIVE_MS = 700  # 实时刷新间隔，不宜过密以免手机截屏压力过大
DESKTOP_IOS7 = "/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P = "/Users/mac/Desktop/ios8p.lua"


def _win_dpi_aware() -> None:
    if sys.platform != "win32":
        return
    try:
        import ctypes

        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)  # system DPI aware
        except Exception:
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass


def make_fmc_offs(points: List[dict]) -> Tuple[int, str]:
    """主色 + 偏点串（无引号），供 /findtest；与 formats.make_fmc 同源。"""
    if not points:
        return 0, ""
    fmc = make_fmc(points)
    # '0xRRGGBB, "offs"' → main int + offs
    main_s, _, rest = fmc.partition(",")
    main = int(main_s.strip(), 16)
    offs = rest.strip()
    if offs.startswith('"') and offs.endswith('"'):
        offs = offs[1:-1]
    return main, offs


def roi_bbox(points: List[dict]) -> Tuple[int, int, int, int]:
    xs = [p["x"] for p in points]
    ys = [p["y"] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def make_find_line(
    points: List[dict], ax: int, ay: int, sx: int, sy: int, degree: int, local: bool
) -> str:
    body = make_find_multi_color_in_region_fuzzy(
        points, ax, ay, sx, sy, degree=int(degree), assign="x,y"
    )
    return ("local " + body) if local else body


def ordered_regs(regs: Dict[int, Optional[dict]]) -> List[dict]:
    return ordered_registers(regs)


def set_system_mouse(sx: int, sy: int) -> bool:
    """同步系统鼠标到屏幕坐标。"""
    try:
        if sys.platform == "win32":
            import ctypes

            ok = bool(ctypes.windll.user32.SetCursorPos(int(sx), int(sy)))
            if not ok:
                # 备用：绝对移动 (0..65535)
                sw = ctypes.windll.user32.GetSystemMetrics(0) or 1
                sh = ctypes.windll.user32.GetSystemMetrics(1) or 1
                abs_x = int(sx * 65535 / max(1, sw - 1))
                abs_y = int(sy * 65535 / max(1, sh - 1))
                MOUSEEVENTF_MOVE = 0x0001
                MOUSEEVENTF_ABSOLUTE = 0x8000
                ctypes.windll.user32.mouse_event(
                    MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, abs_x, abs_y, 0, 0
                )
                ok = True
            return ok
        if sys.platform == "darwin":
            try:
                import Quartz

                Quartz.CGWarpMouseCursorPosition((float(sx), float(sy)))
                Quartz.CGAssociateMouseAndMouseCursorPosition(True)
                return True
            except Exception:
                return False
    except Exception:
        return False
    return False


class DeviceClient:
    """缓存 IP/端口 + HTTP 复用，加速反复截屏。"""

    def __init__(self) -> None:
        self.ip: Optional[str] = None
        self.port: Optional[int] = None
        self._lock = threading.Lock()
        self.last_ms = 0

    def invalidate(self) -> None:
        with self._lock:
            self.port = None

    def set_ip(self, ip: str) -> None:
        ip = ip.strip()
        with self._lock:
            if ip != self.ip:
                self.ip = ip
                self.port = None

    def _probe_one(self, ip: str, port: int, timeout: float) -> Optional[int]:
        try:
            conn = http.client.HTTPConnection(ip, port, timeout=timeout)
            conn.request("GET", "/status", headers={"Connection": "close"})
            resp = conn.getresponse()
            body = resp.read(256)
            conn.close()
            if resp.status == 200 and body:
                return port
        except Exception:
            return None
        return None

    def probe(self, ip: str) -> Tuple[Optional[int], str]:
        self.set_ip(ip)
        # 双端口并行探测，单路超时短
        found: Optional[int] = None
        with ThreadPoolExecutor(max_workers=2) as ex:
            futs = {ex.submit(self._probe_one, ip, p, 0.8): p for p in SNAP_PORTS}
            for fut in as_completed(futs):
                port = fut.result()
                if port:
                    found = port
                    break
        if found:
            with self._lock:
                self.port = found
            return found, "已连接 http://%s:%d/" % (ip, found)
        return None, "未检测到 :50005/:50015"

    def snapshot(self, ip: str, orient: int, port: Optional[int] = None) -> Image.Image:
        """已知端口直拉；失败才重探。"""
        self.set_ip(ip)
        ports: List[int] = []
        with self._lock:
            if port:
                ports.append(int(port))
            elif self.port:
                ports.append(int(self.port))
        for p in SNAP_PORTS:
            if p not in ports:
                ports.append(p)

        last = "无响应"
        t0 = time.time()
        for p in ports:
            try:
                conn = http.client.HTTPConnection(ip, p, timeout=3.5)
                conn.request(
                    "GET",
                    "/snapshot?orient=%d" % int(orient),
                    headers={"Connection": "close", "User-Agent": "ZiYanCP/" + APP_VER},
                )
                resp = conn.getresponse()
                body = resp.read()
                conn.close()
                if resp.status == 200 and len(body) > 500:
                    with self._lock:
                        self.port = p
                    self.last_ms = int((time.time() - t0) * 1000)
                    return Image.open(io.BytesIO(body)).convert("RGB")
                last = "HTTP %s len=%d" % (resp.status, len(body))
            except Exception as e:
                last = str(e)
                continue
        # 全失败清缓存
        with self._lock:
            self.port = None
        raise RuntimeError(last)

    def findtest(
        self,
        ip: str,
        orient: int,
        main: int,
        offs: str,
        degree: int,
        x1: int,
        y1: int,
        x2: int,
        y2: int,
    ) -> dict:
        """POST /findtest → 手机 toast(x:,y:) 并返回 JSON。"""
        self.set_ip(ip)
        ports: List[int] = []
        with self._lock:
            if self.port:
                ports.append(int(self.port))
        for p in SNAP_PORTS:
            if p not in ports:
                ports.append(p)
        body = urllib.parse.urlencode(
            {
                "main": "0x%06x" % (main & 0xFFFFFF),
                "offs": offs,
                "degree": int(degree),
                "x1": int(x1),
                "y1": int(y1),
                "x2": int(x2),
                "y2": int(y2),
                "orient": int(orient),
                "toast": 1,
            }
        )
        last = "no port"
        for p in ports:
            try:
                conn = http.client.HTTPConnection(ip, p, timeout=6.0)
                conn.request(
                    "POST",
                    "/findtest",
                    body=body.encode("utf-8"),
                    headers={
                        "Content-Type": "application/x-www-form-urlencoded",
                        "Connection": "close",
                        "User-Agent": "ZiYanCP/" + APP_VER,
                    },
                )
                resp = conn.getresponse()
                raw = resp.read()
                conn.close()
                if resp.status == 200 and raw:
                    with self._lock:
                        self.port = p
                    try:
                        return json.loads(raw.decode("utf-8", "replace"))
                    except Exception:
                        return {"ok": False, "x": -1, "y": -1, "err": raw[:200]}
                last = "HTTP %s" % resp.status
            except Exception as e:
                last = str(e)
                continue
        raise RuntimeError(last)


class ColorPanel(tk.Frame):
    """取色面板：布局对齐触动抓色器。"""

    def __init__(self, master: tk.Misc, app: "App") -> None:
        super().__init__(master, bg="#d4d0c8")
        self.app = app
        self.tk_mag: Optional[ImageTk.PhotoImage] = None
        self.slot_vars: Dict[int, tk.StringVar] = {}
        self.slot_entries: Dict[int, tk.Entry] = {}
        self.slot_swatches: Dict[int, tk.Canvas] = {}
        self._build()

    def _build(self) -> None:
        # 整体左右分栏（对齐触动：左脚本区 + 右网格；测试钮必须横向可见）
        body = tk.Frame(self, bg="#d4d0c8")
        body.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

        left = tk.Frame(body, bg="#d4d0c8")
        left.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        right = tk.Frame(body, bg="#d4d0c8", width=228)
        right.pack(side=tk.RIGHT, fill=tk.Y, padx=(8, 0))
        right.pack_propagate(False)

        # --- 左：格式 + 色点行 ---
        head = tk.Frame(left, bg="#d4d0c8")
        head.pack(fill=tk.X)
        self.fmt_var = tk.StringVar(value="X, Y, Color")
        ttk.Combobox(
            head, textvariable=self.fmt_var, values=["X, Y, Color"], width=14, state="readonly"
        ).pack(side=tk.LEFT)
        tk.Button(head, text="设置", width=6, takefocus=0).pack(side=tk.LEFT, padx=6)

        for i in SLOT_ORDER:
            row = tk.Frame(left, bg="#d4d0c8")
            row.pack(fill=tk.X, pady=1)
            tk.Button(
                row,
                text="清除%d" % i,
                width=6,
                takefocus=0,
                command=partial(self.app.clear_one, i),
            ).pack(side=tk.LEFT)
            var = tk.StringVar(value="")
            self.slot_vars[i] = var
            # 色点文本区适中宽度（对齐触动左栏，勿再压成竖条）
            ent = tk.Entry(row, textvariable=var, width=22, font=("Consolas", 9))
            ent.pack(side=tk.LEFT, padx=3, fill=tk.X, expand=True)
            ent.configure(state="readonly")
            self.slot_entries[i] = ent
            sw = tk.Canvas(row, width=16, height=14, bg="#808080", highlightthickness=1)
            sw.pack(side=tk.LEFT, padx=2)
            self.slot_swatches[i] = sw
            tk.Button(
                row,
                text=str(i),
                width=3,
                takefocus=0,
                command=partial(self.app.pick_to, i),
            ).pack(side=tk.LEFT)

        bf = tk.Frame(left, bg="#d4d0c8")
        bf.pack(fill=tk.X, pady=6)
        tk.Button(bf, text="清除所有(Z)", width=12, takefocus=0, command=self.app.clear_regs).pack(
            side=tk.LEFT, padx=2, ipady=3
        )
        tk.Button(
            bf,
            text="生成脚本(F)",
            width=12,
            takefocus=0,
            command=self.app.generate,
            bg="#c0c0c0",
        ).pack(side=tk.LEFT, padx=2, ipady=3)

        # 三行输出 + 复制 / <-测试（可鼠标拖选、右键复制、Ctrl+C）
        self.out_lines: List[tk.Text] = []
        for _ in range(3):
            row = tk.Frame(left, bg="#d4d0c8")
            row.pack(fill=tk.BOTH, expand=True, pady=2)
            t = tk.Text(
                row,
                height=3,
                font=("Consolas", 9),
                bg="#fff",
                fg="#000",
                wrap=tk.CHAR,
                cursor="xterm",
                exportselection=True,
                undo=False,
            )
            t.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
            self.out_lines.append(t)
            self._wire_copyable_text(t)
            side = tk.Frame(row, bg="#d4d0c8")
            side.pack(side=tk.RIGHT, padx=(4, 0), anchor="n")
            tk.Button(
                side,
                text="复制",
                width=7,
                takefocus=0,
                command=partial(self._copy_text, t),
            ).pack(pady=(0, 2))
            tk.Button(
                side,
                text="<-测试",
                width=7,
                takefocus=0,
                command=self.app.test_on_device,
            ).pack()

        # --- 右：坐标/颜色/网格/间距/A S ---
        self.lbl_xy = tk.Label(
            right, text="坐标: (  0,   0)", bg="#d4d0c8", fg="#000", font=("Consolas", 11), anchor="w"
        )
        self.lbl_xy.pack(fill=tk.X, pady=(4, 2))
        self.lbl_col = tk.Label(
            right, text="颜色值: 0x000000", bg="#d4d0c8", fg="#000", font=("Consolas", 11), anchor="w"
        )
        self.lbl_col.pack(fill=tk.X, pady=2)
        self.lbl_rgb = tk.Label(
            right,
            text="RGB值: (  0,   0,   0)",
            bg="#d4d0c8",
            fg="#000",
            font=("Consolas", 11),
            anchor="w",
        )
        self.lbl_rgb.pack(fill=tk.X, pady=2)
        self.lbl_fmt = tk.Label(
            right, text="取色格式预览: -", bg="#d4d0c8", fg="#333", font=("Consolas", 9), anchor="w"
        )
        self.lbl_fmt.pack(fill=tk.X, pady=2)
        self.swatch = tk.Canvas(right, width=200, height=26, bg="#000", highlightthickness=1)
        self.swatch.pack(anchor="w", pady=4)

        tk.Label(right, text="网格", bg="#d4d0c8", fg="#000", font=("", 10)).pack(anchor="w")
        self.mag = tk.Label(right, bg="#000", bd=1, relief=tk.SUNKEN)
        self.mag.pack(pady=4, anchor="w")

        self.lbl_dx = tk.Label(right, text="X坐标间距: 0", bg="#d4d0c8", anchor="w")
        self.lbl_dx.pack(fill=tk.X)
        self.lbl_dy = tk.Label(right, text="Y坐标间距: 0", bg="#d4d0c8", anchor="w")
        self.lbl_dy.pack(fill=tk.X)
        self.lbl_dist = tk.Label(right, text="坐标间距: 0", bg="#d4d0c8", anchor="w")
        self.lbl_dist.pack(fill=tk.X)
        self.lbl_ang = tk.Label(right, text="坐标间距角度: 0", bg="#d4d0c8", anchor="w")
        self.lbl_ang.pack(fill=tk.X)

        asf = tk.Frame(right, bg="#d4d0c8")
        asf.pack(fill=tk.X, pady=8)
        tk.Label(asf, text="A", bg="#d4d0c8").pack(side=tk.LEFT)
        self.ent_ax = tk.Entry(asf, width=5)
        self.ent_ax.pack(side=tk.LEFT, padx=1)
        self.ent_ay = tk.Entry(asf, width=5)
        self.ent_ay.pack(side=tk.LEFT, padx=1)
        tk.Label(asf, text="S", bg="#d4d0c8").pack(side=tk.LEFT, padx=(6, 0))
        self.ent_sx = tk.Entry(asf, width=5)
        self.ent_sx.pack(side=tk.LEFT, padx=1)
        self.ent_sy = tk.Entry(asf, width=5)
        self.ent_sy.pack(side=tk.LEFT, padx=1)
        for e in (self.ent_ax, self.ent_ay, self.ent_sx, self.ent_sy):
            e.insert(0, "0")
            e.bind("<FocusOut>", lambda ev: self.app.sync_as_from_entries())

        self.lbl_roi = tk.Label(right, text="0, 0, 0, 0", bg="#d4d0c8", fg="#333", anchor="w")
        self.lbl_roi.pack(fill=tk.X)

    def _wire_copyable_text(self, t: tk.Text) -> None:
        """脚本输出框：拖选 / 右键菜单 / Ctrl+A·C 均可复制（Windows 剪贴板需 update）。"""
        menu = tk.Menu(t, tearoff=0)
        menu.add_command(label="全选", command=lambda: self._select_all_text(t))
        menu.add_command(label="复制", command=lambda: self._copy_selection_or_all(t))

        def popup(e: tk.Event) -> str:
            try:
                t.focus_set()
                menu.tk_popup(e.x_root, e.y_root)
            finally:
                menu.grab_release()
            return "break"

        t.bind("<Button-3>", popup)
        if sys.platform == "darwin":
            t.bind("<Button-2>", popup)
            t.bind("<Control-Button-1>", popup)
        t.bind("<Control-a>", lambda e: (self._select_all_text(t), "break")[-1])
        t.bind("<Control-c>", lambda e: (self._copy_selection_or_all(t), "break")[-1])
        t.bind("<Command-a>", lambda e: (self._select_all_text(t), "break")[-1])
        t.bind("<Command-c>", lambda e: (self._copy_selection_or_all(t), "break")[-1])
        # 双击：全选并复制，方便一键拿走脚本
        t.bind("<Double-Button-1>", lambda e: (self._select_all_text(t), self._copy_selection_or_all(t), "break")[-1])

    @staticmethod
    def _select_all_text(t: tk.Text) -> None:
        t.tag_add("sel", "1.0", "end-1c")
        t.mark_set("insert", "1.0")
        t.see("insert")

    def _copy_selection_or_all(self, t: tk.Text) -> None:
        try:
            text = t.get("sel.first", "sel.last")
        except tk.TclError:
            text = t.get("1.0", "end-1c")
        text = (text or "").strip()
        if not text:
            self.app.status_set("输出框为空，无可复制内容")
            return
        self.app.copy_clipboard(text)

    def _copy_text(self, t: tk.Text) -> None:
        text = t.get("1.0", "end-1c").strip()
        if not text:
            self.app.status_set("输出框为空，无可复制内容")
            return
        self.app.copy_clipboard(text)

    def set_slot_text(self, idx: int, text: str, color_hex: Optional[str] = None) -> None:
        ent = self.slot_entries[idx]
        ent.configure(state="normal")
        self.slot_vars[idx].set(text)
        ent.delete(0, tk.END)
        if text:
            ent.insert(0, text)
        ent.configure(state="readonly")
        self.slot_swatches[idx].configure(bg=color_hex if color_hex else "#808080")

    def refresh_slots(self) -> None:
        for i in SLOT_ORDER:
            p = self.app.regs.get(i)
            if p:
                self.set_slot_text(
                    i, "%d, %d, 0x%06x" % (p["x"], p["y"], p["c"]), "#%06x" % p["c"]
                )
            else:
                self.set_slot_text(i, "", None)

    def write_as_entries(self) -> None:
        for ent, val in (
            (self.ent_ax, self.app.reg_a[0]),
            (self.ent_ay, self.app.reg_a[1]),
            (self.ent_sx, self.app.reg_s[0]),
            (self.ent_sy, self.app.reg_s[1]),
        ):
            ent.delete(0, tk.END)
            ent.insert(0, str(val))
        self.lbl_roi.configure(
            text="%d, %d, %d, %d"
            % (self.app.reg_a[0], self.app.reg_a[1], self.app.reg_s[0], self.app.reg_s[1])
        )

    def set_outputs(self, line: str, fmc: str, roi: str) -> None:
        for t, text in zip(self.out_lines, (line, fmc, roi)):
            t.delete("1.0", tk.END)
            t.insert(tk.END, text)

    def refresh_cursor_info(self, img: Image.Image, pix, cursor: Tuple[int, int], regs) -> None:
        import math

        x, y = cursor
        if not (0 <= x < img.width and 0 <= y < img.height):
            return
        r, g, b = pix[x, y]
        c = rgb_to_c(r, g, b)
        self.lbl_xy.configure(text="坐标: (%4d, %4d)" % (x, y))
        self.lbl_col.configure(text="颜色值: 0x%06x" % c)
        self.lbl_rgb.configure(text="RGB值: (%3d, %3d, %3d)" % (r, g, b))
        self.lbl_fmt.configure(text="取色格式预览: %d, %d, 0x%06x" % (x, y, c))
        self.swatch.configure(bg="#%06x" % c)

        pts = ordered_regs(regs)
        if pts:
            f = pts[0]
            dx, dy = x - f["x"], y - f["y"]
            dist = math.sqrt(dx * dx + dy * dy)
            ang = math.degrees(math.atan2(dy, dx)) if dx or dy else 0.0
            self.lbl_dx.configure(text="X坐标间距: %d" % dx)
            self.lbl_dy.configure(text="Y坐标间距: %d" % dy)
            self.lbl_dist.configure(text="坐标间距: %.2f" % dist)
            self.lbl_ang.configure(text="坐标间距角度: %.2f" % ang)
        else:
            self.lbl_dx.configure(text="X坐标间距: 0")
            self.lbl_dy.configure(text="Y坐标间距: 0")
            self.lbl_dist.configure(text="坐标间距: 0")
            self.lbl_ang.configure(text="坐标间距角度: 0")

        # 右侧网格：19×19 格 × 12px（适配右栏宽度，避免挤掉左栏测试钮）
        half, cell = 9, 12
        size = cell * (half * 2 + 1)
        mag = Image.new("RGB", (size, size), (0, 0, 0))
        mp = mag.load()
        for dy in range(-half, half + 1):
            for dx in range(-half, half + 1):
                xx, yy = x + dx, y + dy
                col = pix[xx, yy] if 0 <= xx < img.width and 0 <= yy < img.height else (0, 0, 0)
                ox, oy = (dx + half) * cell, (dy + half) * cell
                for yy2 in range(cell):
                    for xx2 in range(cell):
                        mp[ox + xx2, oy + yy2] = col
        draw = ImageDraw.Draw(mag)
        for i in range(half * 2 + 2):
            draw.line([(i * cell, 0), (i * cell, size)], fill=(60, 60, 60))
            draw.line([(0, i * cell), (size, i * cell)], fill=(60, 60, 60))
        draw.rectangle(
            [half * cell, half * cell, (half + 1) * cell - 1, (half + 1) * cell - 1],
            outline="#ffffff",
            width=2,
        )
        self.tk_mag = ImageTk.PhotoImage(mag)
        self.mag.configure(image=self.tk_mag)


class ImageWindow(tk.Toplevel):
    """截图窗口（可多开；支持原地刷新画面）。"""

    def __init__(self, app: "App", im: Image.Image, title: str) -> None:
        super().__init__(app)
        self.app = app
        self.img = im.convert("RGB")
        self.pix = self.img.load()
        self.zoom = 1.0 if max(self.img.width, self.img.height) > 1400 else 2.0
        self.cursor = (self.img.width // 2, self.img.height // 2)
        self.base_im: Optional[Image.Image] = None
        self.tk_img: Optional[ImageTk.PhotoImage] = None
        self.paint_job = None
        self.title(title)
        self.geometry("960x620+160+%d" % (50 + 28 * (len(app.image_windows) % 8)))
        self.configure(bg="#1a1a1a")
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        bar = tk.Frame(self, bg="#323232")
        bar.pack(fill=tk.X)
        self.lbl_size = tk.Label(
            bar, text="%dx%d" % (self.img.width, self.img.height), bg="#323232", fg="#9cf"
        )
        self.lbl_size.pack(side=tk.LEFT, padx=8)
        for text, cmd in (
            ("缩小", lambda: self.set_zoom(self.zoom / 1.25)),
            ("放大", lambda: self.set_zoom(self.zoom * 1.25)),
            ("1:1", lambda: self.set_zoom(1.0)),
            ("设为当前", self.activate),
        ):
            tk.Button(bar, text=text, command=cmd, takefocus=0, bg="#4a4a4a", fg="#fff").pack(
                side=tk.LEFT, padx=2, pady=3
            )

        stage = tk.Frame(self, bg="#1a1a1a")
        stage.pack(fill=tk.BOTH, expand=True)
        self.canvas = tk.Canvas(stage, bg="#1a1a1a", highlightthickness=0, cursor="crosshair")
        self.hbar = ttk.Scrollbar(stage, orient=tk.HORIZONTAL, command=self.canvas.xview)
        self.vbar = ttk.Scrollbar(stage, orient=tk.VERTICAL, command=self.canvas.yview)
        self.canvas.configure(xscrollcommand=self.hbar.set, yscrollcommand=self.vbar.set)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        self.vbar.grid(row=0, column=1, sticky="ns")
        self.hbar.grid(row=1, column=0, sticky="ew")
        stage.rowconfigure(0, weight=1)
        stage.columnconfigure(0, weight=1)

        self.canvas.bind("<Motion>", self.on_motion)
        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<Enter>", lambda e: self.activate())
        self.bind("<FocusIn>", lambda e: self.activate())
        for key, d in (
            ("<Up>", (0, -1)),
            ("<Down>", (0, 1)),
            ("<Left>", (-1, 0)),
            ("<Right>", (1, 0)),
            ("<Shift-Up>", (0, -10)),
            ("<Shift-Down>", (0, 10)),
            ("<Shift-Left>", (-10, 0)),
            ("<Shift-Right>", (10, 0)),
        ):
            self.bind(key, lambda e, dd=d: self.app.nudge_active(dd[0], dd[1]))

        self.rebuild_base()
        self.paint()
        self.activate()

    def replace_image(self, im: Image.Image, title: Optional[str] = None) -> None:
        """原地换图（实时刷新用，不开新窗）。"""
        old = self.cursor
        self.img = im.convert("RGB")
        self.pix = self.img.load()
        x = min(old[0], self.img.width - 1)
        y = min(old[1], self.img.height - 1)
        self.cursor = (max(0, x), max(0, y))
        self.lbl_size.configure(text="%dx%d" % (self.img.width, self.img.height))
        if title:
            self.title(title)
        self.rebuild_base()
        self.paint()
        self.app.push_panel_from_active()

    def _on_close(self) -> None:
        self.app.unregister_window(self)
        self.destroy()

    def activate(self) -> None:
        self.app.active_win = self
        try:
            self.lift()
            self.canvas.focus_set()
        except tk.TclError:
            pass
        self.app.push_panel_from_active()

    def set_zoom(self, z: float) -> None:
        self.zoom = max(0.5, min(16.0, float(z)))
        self.rebuild_base()
        self.paint()

    def rebuild_base(self) -> None:
        z = self.zoom
        w = max(1, int(self.img.width * z))
        h = max(1, int(self.img.height * z))
        disp = self.img.resize((w, h), Image.NEAREST)
        draw = ImageDraw.Draw(disp)
        ax, ay = self.app.reg_a
        sx, sy = self.app.reg_s
        if (ax, ay) != (0, 0) or (sx, sy) != (0, 0):
            x0, x1 = sorted((ax, sx))
            y0, y1 = sorted((ay, sy))
            draw.rectangle(
                [x0 * z, y0 * z, (x1 + 1) * z - 1, (y1 + 1) * z - 1],
                outline="#00ff88",
                width=max(1, int(z)),
            )
        for i in range(1, 10):
            p = self.app.regs.get(i)
            if p:
                self._mark(draw, p, MARKS[i - 1], z)
        if self.app.regs.get(0):
            self._mark(draw, self.app.regs[0], MARKS[9], z)
        self.base_im = disp

    def _mark(self, draw: ImageDraw.ImageDraw, p: dict, label: str, z: float) -> None:
        x, y = p["x"] * z, p["y"] * z
        r = max(3, int(3 * z))
        draw.ellipse([x - r, y - r, x + r, y + r], outline="#ffe566", width=max(1, int(z)))
        try:
            draw.text((x + r + 2, y - r), str(label), fill="#ffe566")
        except Exception:
            pass

    def paint(self) -> None:
        if not self.base_im:
            return
        z = self.zoom
        frame = self.base_im.copy()
        draw = ImageDraw.Draw(frame)
        cx, cy = self.cursor
        draw.rectangle(
            [cx * z, cy * z, (cx + 1) * z - 1, (cy + 1) * z - 1],
            outline="#ff3333",
            width=max(1, 2 if z >= 3 else 1),
        )
        draw.line([(cx * z + z / 2, 0), (cx * z + z / 2, frame.height)], fill="#ff6666")
        draw.line([(0, cy * z + z / 2), (frame.width, cy * z + z / 2)], fill="#ff6666")
        self.tk_img = ImageTk.PhotoImage(frame)
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.tk_img)
        self.canvas.configure(scrollregion=(0, 0, frame.width, frame.height))

    def schedule_paint(self) -> None:
        if self.paint_job:
            self.after_cancel(self.paint_job)
        self.paint_job = self.after(1, self.paint)

    def canvas_xy(self, e) -> Tuple[int, int]:
        z = self.zoom if self.zoom else 1.0
        x = int(self.canvas.canvasx(e.x) / z)
        y = int(self.canvas.canvasy(e.y) / z)
        x = max(0, min(self.img.width - 1, x))
        y = max(0, min(self.img.height - 1, y))
        return x, y

    def logical_to_screen(self, ix: int, iy: int) -> Tuple[int, int]:
        self.update_idletasks()
        z = self.zoom if self.zoom else 1.0
        # 像素中心在 canvas 内容坐标
        cx = ix * z + z * 0.5
        cy = iy * z + z * 0.5
        # 转到画布控件客户区，再加屏幕原点
        sx = int(self.canvas.winfo_rootx() + cx - self.canvas.canvasx(0))
        sy = int(self.canvas.winfo_rooty() + cy - self.canvas.canvasy(0))
        return sx, sy

    def warp_os_mouse(self) -> None:
        try:
            self.ensure_visible()
            self.update_idletasks()
            sx, sy = self.logical_to_screen(self.cursor[0], self.cursor[1])
            set_system_mouse(sx, sy)
            self.app.status_set(
                "光标(%d,%d) 鼠标->(%d,%d)" % (self.cursor[0], self.cursor[1], sx, sy)
            )
        except Exception as e:
            self.app.status_set("鼠标同步失败: %s" % e)

    def ensure_visible(self) -> None:
        z = self.zoom
        x, y = self.cursor
        item = self.canvas.create_rectangle(x * z, y * z, x * z + 1, y * z + 1, outline="")
        self.canvas.see(item)
        self.canvas.delete(item)

    def on_motion(self, e) -> None:
        self.app.active_win = self
        self.cursor = self.canvas_xy(e)
        self.schedule_paint()
        self.app.push_panel_from_active()

    def on_press(self, e) -> None:
        self.activate()
        self.cursor = self.canvas_xy(e)
        self.app.push_panel_from_active()
        self.app.pick_next()


class App(tk.Tk):
    def __init__(self) -> None:
        _win_dpi_aware()
        super().__init__()
        self.title("子砚取点抓色器 v%s" % APP_VER)
        # 对齐触动抓色面板（约 520×600，保证「<-测试」横向可见）
        self.geometry("520x600+40+40")
        self.minsize(500, 560)
        self.configure(bg="#d4d0c8")

        self.regs: Dict[int, Optional[dict]] = {i: None for i in range(10)}
        self.next_reg = 1
        self.reg_a = (0, 0)
        self.reg_s = (0, 0)
        self.auto_roi = True
        self.degree = tk.IntVar(value=90)
        self.local_prefix = tk.BooleanVar(value=True)
        self.device_ip = tk.StringVar(value="192.168.31.101")
        self.device_orient = tk.IntVar(value=1)
        self.live_var = tk.BooleanVar(value=False)
        self.dev = DeviceClient()
        self.image_windows: List[ImageWindow] = []
        self.active_win: Optional[ImageWindow] = None
        self.live_win: Optional[ImageWindow] = None
        self.snap_seq = 0
        self._live_job = None
        self._snap_busy = False

        self._build()
        self._bind_keys()
        self.device_ip.trace_add("write", self._on_ip_changed)
        self.status_set("v%s | 连接后截屏；勾选「实时画面」可跟手机刷新" % APP_VER)

    def _on_ip_changed(self, *_args) -> None:
        self.dev.set_ip(self.device_ip.get())

    def _build(self) -> None:
        menubar = tk.Menu(self)
        m_file = tk.Menu(menubar, tearoff=0)
        m_file.add_command(label="打开图片(新窗口)", command=self.open_image)
        m_file.add_command(label="粘贴图片(新窗口)", command=self.paste_image)
        m_file.add_separator()
        m_file.add_command(label="退出", command=self.destroy)
        menubar.add_cascade(label="文件", menu=m_file)
        m_dev = tk.Menu(menubar, tearoff=0)
        m_dev.add_command(label="连接设备", command=self.connect_device)
        m_dev.add_command(label="截屏(新窗口)", command=lambda: self.snap_device(new_window=True))
        m_dev.add_command(label="刷新当前窗口", command=lambda: self.snap_device(new_window=False))
        menubar.add_cascade(label="设备", menu=m_dev)
        self.config(menu=menubar)

        bar = tk.Frame(self, bg="#c0c0c0")
        bar.pack(fill=tk.X)
        for text, cmd in (
            ("打开", self.open_image),
            ("粘贴", self.paste_image),
            ("连接", self.connect_device),
            ("截屏", lambda: self.snap_device(new_window=True)),
            ("刷新", lambda: self.snap_device(new_window=False)),
            ("生成(F)", self.generate),
        ):
            tk.Button(bar, text=text, command=cmd, takefocus=0).pack(side=tk.LEFT, padx=3, pady=3)

        dev = tk.Frame(self, bg="#d4d0c8")
        dev.pack(fill=tk.X, padx=4, pady=2)
        tk.Label(dev, text="手机IP", bg="#d4d0c8").pack(side=tk.LEFT)
        tk.Entry(dev, textvariable=self.device_ip, width=14).pack(side=tk.LEFT, padx=3)
        tk.Label(dev, text="方向", bg="#d4d0c8").pack(side=tk.LEFT)
        tk.Spinbox(dev, from_=0, to=2, width=3, textvariable=self.device_orient).pack(side=tk.LEFT)
        self.lbl_dev = tk.Label(dev, text="设备: 未连接", bg="#d4d0c8", fg="#a00")
        self.lbl_dev.pack(side=tk.LEFT, padx=6)
        tk.Label(dev, text="相似度", bg="#d4d0c8").pack(side=tk.LEFT)
        tk.Spinbox(dev, from_=1, to=100, width=4, textvariable=self.degree).pack(side=tk.LEFT)
        tk.Checkbutton(dev, text="local前缀", variable=self.local_prefix, bg="#d4d0c8").pack(
            side=tk.LEFT, padx=4
        )
        tk.Checkbutton(
            dev,
            text="实时画面",
            variable=self.live_var,
            bg="#d4d0c8",
            command=self._toggle_live,
        ).pack(side=tk.LEFT, padx=4)

        tip = tk.Label(
            self,
            text="方向键移动取色点并带动鼠标；「截屏」新窗口，「刷新/实时」跟手机画面（连接后端口会缓存）。",
            bg="#d4d0c8",
            fg="#333",
            anchor="w",
        )
        tip.pack(fill=tk.X, padx=4)

        self.panel = ColorPanel(self, self)
        self.panel.pack(fill=tk.BOTH, expand=True, padx=2, pady=2)

        self.status = tk.Label(self, text="", bg="#808080", fg="#fff", anchor="w")
        self.status.pack(fill=tk.X, side=tk.BOTTOM)

    def _focus_is_entry(self) -> bool:
        try:
            f = self.focus_get()
            return isinstance(f, (tk.Entry, tk.Text, tk.Spinbox))
        except tk.TclError:
            return False

    def _bind_keys(self) -> None:
        def nudge(dx, dy, e=None):
            if self._focus_is_entry():
                return ""
            return self.nudge_active(dx, dy)

        for seq, d in (
            ("<Up>", (0, -1)),
            ("<Down>", (0, 1)),
            ("<Left>", (-1, 0)),
            ("<Right>", (1, 0)),
            ("<Shift-Up>", (0, -10)),
            ("<Shift-Down>", (0, 10)),
            ("<Shift-Left>", (-10, 0)),
            ("<Shift-Right>", (10, 0)),
        ):
            self.bind_all(seq, lambda e, dd=d: nudge(dd[0], dd[1], e))
        self.bind_all("f", lambda e: None if self._focus_is_entry() else self.generate())
        self.bind_all("F", lambda e: None if self._focus_is_entry() else self.generate())
        self.bind_all("z", lambda e: None if self._focus_is_entry() else self.clear_regs())
        self.bind_all("Z", lambda e: None if self._focus_is_entry() else self.clear_regs())
        for i in range(10):
            self.bind_all(str(i), lambda e, n=i: None if self._focus_is_entry() else self.pick_to(n))

    def status_set(self, s: str) -> None:
        self.status.configure(text=s)

    def copy_clipboard(self, text: str) -> None:
        """写入系统剪贴板；Windows 下须 update 后内容才可粘到外部编辑器。"""
        try:
            self.clipboard_clear()
            self.clipboard_append(text)
            self.update_idletasks()
            # 再触一次，避免部分 Win 环境丢失剪贴板
            self.clipboard_append(text)
            self.update()
            self.status_set("已复制到剪贴板（%d 字）" % len(text))
        except tk.TclError as e:
            self.status_set("复制失败: %s" % e)

    def unregister_window(self, win: ImageWindow) -> None:
        if win in self.image_windows:
            self.image_windows.remove(win)
        if self.live_win is win:
            self.live_win = None
            self.live_var.set(False)
            self._stop_live()
        if self.active_win is win:
            self.active_win = self.image_windows[-1] if self.image_windows else None

    def open_image_window(self, im: Image.Image, title: str) -> ImageWindow:
        win = ImageWindow(self, im, title)
        self.image_windows.append(win)
        self.active_win = win
        self.status_set("已打开 %s（%d窗）" % (title, len(self.image_windows)))
        return win

    def open_image(self) -> None:
        path = filedialog.askopenfilename(
            filetypes=[("Images", "*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp"), ("All", "*.*")]
        )
        if path:
            self.open_image_window(Image.open(path).convert("RGB"), os.path.basename(path))

    def paste_image(self) -> None:
        grab = ImageGrab.grabclipboard()
        if isinstance(grab, Image.Image):
            self.snap_seq += 1
            self.open_image_window(grab.convert("RGB"), "粘贴_%d" % self.snap_seq)
        else:
            messagebox.showwarning("粘贴", "剪贴板没有图片")

    def connect_device(self) -> None:
        ip = self.device_ip.get().strip()
        if not ip:
            messagebox.showwarning("设备", "请填写手机 IP")
            return
        self.status_set("并行探测 %s …" % ip)

        def work() -> None:
            port, msg = self.dev.probe(ip)

            def done() -> None:
                if port:
                    self.lbl_dev.configure(text="设备: :%d 已缓存" % port, fg="#060")
                    self.status_set(msg + " | 截屏将直连此端口")
                else:
                    self.lbl_dev.configure(text="设备: 未连接", fg="#a00")
                    messagebox.showerror("连接失败", msg)

            self.after(0, done)

        threading.Thread(target=work, daemon=True).start()

    def snap_device(self, new_window: bool = True) -> None:
        if self._snap_busy:
            return
        ip = self.device_ip.get().strip()
        if not ip:
            messagebox.showwarning("截屏", "请先填 IP")
            return
        orient = int(self.device_orient.get())
        self._snap_busy = True
        self.status_set("截屏中…")

        def work() -> None:
            try:
                im = self.dev.snapshot(ip, orient, self.dev.port)
                ms = self.dev.last_ms

                def done() -> None:
                    self._snap_busy = False
                    self.lbl_dev.configure(
                        text="设备: :%s %dms" % (self.dev.port or "?", ms), fg="#060"
                    )
                    if new_window or not self.active_win or not self.active_win.winfo_exists():
                        self.snap_seq += 1
                        title = "截图%d_%s" % (self.snap_seq, time.strftime("%H%M%S"))
                        win = self.open_image_window(im, title)
                        if self.live_var.get():
                            self.live_win = win
                    else:
                        self.active_win.replace_image(
                            im, "刷新_%s" % time.strftime("%H%M%S")
                        )
                        self.status_set("已刷新当前窗 %dms" % ms)

                self.after(0, done)
            except Exception as e:
                err = str(e)

                def fail() -> None:
                    self._snap_busy = False
                    self.lbl_dev.configure(text="设备: 断开", fg="#a00")
                    if not self.live_var.get():
                        messagebox.showerror("截屏失败", err)
                    self.status_set("截屏失败: " + err)

                self.after(0, fail)

        threading.Thread(target=work, daemon=True).start()

    def _toggle_live(self) -> None:
        if self.live_var.get():
            self.status_set("实时画面已开（约 %dms/帧，刷新当前窗）" % LIVE_MS)
            if not self.active_win:
                self.snap_device(new_window=True)
            self._schedule_live()
        else:
            self._stop_live()
            self.status_set("实时画面已关")

    def _stop_live(self) -> None:
        if self._live_job:
            try:
                self.after_cancel(self._live_job)
            except Exception:
                pass
            self._live_job = None

    def _schedule_live(self) -> None:
        self._stop_live()
        if not self.live_var.get():
            return
        self._live_job = self.after(LIVE_MS, self._live_tick)

    def _live_tick(self) -> None:
        if not self.live_var.get():
            return
        # 复用刷新当前窗，避免狂开窗口；忙则跳过本帧
        if not self._snap_busy:
            self.snap_device(new_window=False)
        self._schedule_live()

    def push_panel_from_active(self) -> None:
        win = self.active_win
        if not win or not self.panel:
            return
        try:
            if not win.winfo_exists():
                return
            self.panel.refresh_cursor_info(win.img, win.pix, win.cursor, self.regs)
        except Exception:
            pass

    def color_at_active(self) -> int:
        win = self.active_win
        if not win:
            return 0
        r, g, b = win.pix[win.cursor[0], win.cursor[1]]
        return rgb_to_c(r, g, b)

    def point_now(self) -> dict:
        win = self.active_win
        assert win is not None
        x, y = win.cursor
        c = self.color_at_active()
        r, g, b = c_to_rgb(c)
        return {"x": x, "y": y, "c": c, "r": r, "g": g, "b": b}

    def alloc_next(self) -> int:
        for i in SLOT_ORDER:
            if self.regs[i] is None:
                return i
        return self.next_reg

    def pick_next(self) -> None:
        idx = self.alloc_next()
        self.pick_to(idx)
        self.next_reg = SLOT_ORDER[(SLOT_ORDER.index(idx) + 1) % 10]

    def pick_to(self, idx: int) -> None:
        if not self.active_win:
            messagebox.showwarning("取色", "请先打开图片或截屏")
            return
        idx = int(idx)
        self.regs[idx] = self.point_now()
        if self.auto_roi:
            self.as_from_bbox(silent=True)
        self.panel.refresh_slots()
        self.panel.write_as_entries()
        self.push_panel_from_active()
        try:
            self.active_win.rebuild_base()
            self.active_win.paint()
        except Exception:
            pass
        p = self.regs[idx]
        self.status_set("取色#%d (%d,%d) 0x%06x" % (idx, p["x"], p["y"], p["c"]))

    def clear_one(self, idx: int) -> None:
        self.regs[int(idx)] = None
        if self.auto_roi:
            pts = ordered_regs(self.regs)
            if pts:
                self.as_from_bbox(silent=True)
            else:
                self.reg_a = (0, 0)
                self.reg_s = (0, 0)
        self.panel.refresh_slots()
        self.panel.write_as_entries()
        if self.active_win:
            try:
                self.active_win.rebuild_base()
                self.active_win.paint()
            except Exception:
                pass

    def clear_regs(self) -> None:
        for i in range(10):
            self.regs[i] = None
        self.next_reg = 1
        self.reg_a = (0, 0)
        self.reg_s = (0, 0)
        self.panel.refresh_slots()
        self.panel.write_as_entries()
        if self.active_win:
            try:
                self.active_win.rebuild_base()
                self.active_win.paint()
            except Exception:
                pass

    def set_a(self) -> None:
        if not self.active_win:
            return
        self.auto_roi = False
        self.reg_a = self.active_win.cursor
        self.panel.write_as_entries()

    def set_s(self) -> None:
        if not self.active_win:
            return
        self.auto_roi = False
        self.reg_s = self.active_win.cursor
        self.panel.write_as_entries()

    def sync_as_from_entries(self) -> None:
        try:
            self.reg_a = (int(self.panel.ent_ax.get()), int(self.panel.ent_ay.get()))
            self.reg_s = (int(self.panel.ent_sx.get()), int(self.panel.ent_sy.get()))
            self.auto_roi = False
            self.panel.write_as_entries()
        except ValueError:
            return
        if self.active_win:
            self.active_win.rebuild_base()
            self.active_win.paint()

    def as_from_bbox(self, silent: bool = False) -> None:
        pts = ordered_regs(self.regs)
        if not pts:
            if not silent:
                messagebox.showwarning("A/S", "请先取色点")
            return
        ax, ay, sx, sy = roi_bbox(pts)
        self.reg_a = (ax, ay)
        self.reg_s = (sx, sy)
        self.auto_roi = True
        if not silent:
            self.panel.write_as_entries()

    def nudge_active(self, dx: int, dy: int) -> str:
        win = self.active_win
        if not win:
            self.status_set("请先点开截图窗口再按方向键")
            return "break"
        try:
            if not win.winfo_exists():
                return "break"
        except tk.TclError:
            return "break"
        x = max(0, min(win.img.width - 1, win.cursor[0] + dx))
        y = max(0, min(win.img.height - 1, win.cursor[1] + dy))
        win.cursor = (x, y)
        win.paint()
        self.push_panel_from_active()
        # 先刷画面再同步鼠标（含 scroll + DPI）
        win.after(1, win.warp_os_mouse)
        return "break"

    def _current_find_params(self):
        pts = ordered_regs(self.regs)
        if not pts:
            return None
        if self.auto_roi or (self.reg_a == (0, 0) and self.reg_s == (0, 0)):
            ax, ay, sx, sy = roi_bbox(pts)
            self.reg_a, self.reg_s = (ax, ay), (sx, sy)
        else:
            self.sync_as_from_entries()
        ax, ay = self.reg_a
        sx, sy = self.reg_s
        if ax == ay == sx == sy == 0 and self.active_win:
            sx, sy = self.active_win.img.width - 1, self.active_win.img.height - 1
            self.reg_s = (sx, sy)
        try:
            deg = int(self.degree.get())
        except Exception:
            deg = 90
        return pts, deg, ax, ay, sx, sy

    def test_on_device(self) -> None:
        """对齐触动「<-测试」：在对应 IP 手机上 findMulti + toast(x:,y:)。"""
        ip = self.device_ip.get().strip()
        if not ip:
            messagebox.showwarning("测试", "请先填写手机 IP 并连接")
            return
        params = self._current_find_params()
        if not params:
            messagebox.showwarning("测试", "请先取色点再测试")
            return
        pts, deg, ax, ay, sx, sy = params
        main, offs = make_fmc_offs(pts)
        orient = int(self.device_orient.get())
        # 同步填输出框，便于对照
        line = make_find_line(pts, ax, ay, sx, sy, deg, bool(self.local_prefix.get()))
        self.panel.set_outputs(line, make_fmc(pts), "%d, %d, %d, %d" % (ax, ay, sx, sy))
        self.panel.write_as_entries()
        self.status_set("正在设备上测试找色…")

        def work() -> None:
            try:
                rep = self.dev.findtest(ip, orient, main, offs, deg, ax, ay, sx, sy)
                x = int(rep.get("x", -1))
                y = int(rep.get("y", -1))
                ok = bool(rep.get("ok")) and x >= 0 and y >= 0

                def done() -> None:
                    msg = "命中 x:%d, y:%d" % (x, y) if ok else "未找到 x:%d, y:%d" % (x, y)
                    self.status_set("测试结果: %s（手机已 toast）" % msg)
                    if ok:
                        messagebox.showinfo("测试", msg + "\n手机已弹出 toast(x:,y:)")
                    else:
                        messagebox.showwarning(
                            "测试",
                            msg + "\n手机已 toast；请检查色点/ROI/方向是否与当前画面一致",
                        )

                self.after(0, done)
            except Exception as e:
                err = str(e)

                def fail() -> None:
                    self.status_set("测试失败: " + err)
                    messagebox.showerror(
                        "测试失败",
                        err + "\n需手机已装子砚 94+（/findtest）。可先点「连接」再测。",
                    )

                self.after(0, fail)

        threading.Thread(target=work, daemon=True).start()

    def generate(self) -> None:
        try:
            params = self._current_find_params()
            if not params:
                messagebox.showwarning("生成", "请先取色")
                return
            pts, deg, ax, ay, sx, sy = params
            line = make_find_line(pts, ax, ay, sx, sy, deg, bool(self.local_prefix.get()))
            fmc = make_fmc(pts)
            roi = "%d, %d, %d, %d" % (ax, ay, sx, sy)
            self.panel.write_as_entries()
            self.panel.set_outputs(line, fmc, roi)
            self.panel.refresh_slots()
            # 生成后自动入剪贴板，并选中第一行便于鼠标再拷
            self.copy_clipboard(line)
            try:
                t0 = self.panel.out_lines[0]
                t0.focus_set()
                self.panel._select_all_text(t0)
            except Exception:
                pass
            self.status_set("已生成并复制 · ROI %s" % roi)
        except Exception as e:
            messagebox.showerror("生成失败", str(e))


def _selftest_desktop() -> None:
    """自测只认 Desktop ios7/ios8p（ZiYanColorPicker 产出），禁止触动色参样例。"""
    import re

    assert APP_VER == "1.3.4"
    src = open(__file__, "r", encoding="utf-8").read()
    assert "\u2460" not in src
    fail = 0
    for path, tag in ((DESKTOP_IOS7, "ios7"), (DESKTOP_IOS8P, "ios8p")):
        if not os.path.isfile(path):
            print("FAIL missing", path)
            fail += 1
            continue
        for i, line in enumerate(open(path, encoding="utf-8"), 1):
            if "findMultiColorInRegionFuzzy" not in line:
                continue
            mm = re.search(
                r'findMultiColorInRegionFuzzy\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
                line,
            )
            if not mm:
                print("FAIL parse", tag, i)
                fail += 1
                continue
            main, offs = mm.group(1).lower(), mm.group(2)
            deg, ax, ay, sx, sy = map(int, mm.groups()[2:])
            # 偏点串本就是相对首点；用相对坐标系点列做 roundtrip
            rel_pts = [{"x": 0, "y": 0, "c": int(main, 16)}]
            if offs:
                for part in offs.split(","):
                    dx, dy, col = part.split("|")
                    rel_pts.append(
                        {"x": int(dx), "y": int(dy), "c": int(col, 16)}
                    )
            fmc = make_fmc(rel_pts).lower()
            expect = ('%s, "%s"' % (main, offs)).lower()
            if fmc != expect:
                print("FAIL fmc", tag, i, fmc, "!=", expect)
                fail += 1
            else:
                print("PASS fmc", tag, "L%d" % i)
            line_gen = make_find_line(rel_pts, ax, ay, sx, sy, deg, False)
            need = "%d, %d, %d, %d, %d)" % (deg, ax, ay, sx, sy)
            if need not in line_gen:
                print("FAIL roi", tag, i)
                fail += 1
            else:
                print("PASS roi", tag, "L%d" % i)
            main_i, offs_i = make_fmc_offs(rel_pts)
            if main_i != int(main, 16) or offs_i.lower() != offs.lower():
                print("FAIL findtest-offs", tag, i)
                fail += 1
            else:
                print("PASS findtest-offs", tag, "L%d" % i)
    if fail:
        raise SystemExit("selftest FAIL count=%d" % fail)
    print("selftest ok", APP_VER, "desktop≡formats")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] in ("--test", "-t"):
        _selftest_desktop()
        return
    app = App()
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        app.open_image_window(Image.open(sys.argv[1]).convert("RGB"), os.path.basename(sys.argv[1]))
    app.mainloop()


if __name__ == "__main__":
    main()
