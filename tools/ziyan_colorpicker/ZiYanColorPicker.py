#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
子砚取点抓色器 v1.7.5
抄触动 TSColorPicker 1.7.10（.48 实操对照）：
  主窗 MDI 只放图页，标签/关闭可点
  取色面板 = 进程内独立对话框（触动 class #32770），关闭不盖图、不强制再弹出
  方向键 = moveMouseToXY：系统鼠标在图上走 1px，坐标/颜色值/RGB/网格立刻更新
  读图：打开/新建/粘贴/截屏，棋盘格衬底（不用 WndProc 拖放，以免标题栏拉不动）
设备截屏仍走子砚 framecap HTTP（:50005/:50015），不链接触动运行时。
"""

from __future__ import annotations

import ctypes
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
    FORMAT_NAMES,
    FMT_XY_COLOR,
    c_to_rgb,
    default_settings,
    make_fmc,
    make_find_multi_color_in_region_fuzzy,
    make_scripts,
    ordered_registers,
    preview_info,
    resolve_find_roi,
    rgb_to_c,
    single_text,
    slot_text,
)

SNAP_PORTS = (50005, 50015)
MARKS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
SLOT_ORDER = list(range(1, 10)) + [0]
# 触动取色面板右侧数字钮：①…⑨⓪（0 号在最后）
CIRCLED = ["⓪", "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
APP_VER = "1.7.5"

# 触动 default_keymap.lua：VK UP/DOWN/LEFT/RIGHT → moveMouseToXY(getCurrentXY()±1)
# Shift ×10、Ctrl/Alt ×100。
# Windows Tk 认 <KeyPress-Left>；只绑这一组，避免一次走两格。
ARROW_BINDS = (
    ("<KeyPress-Up>", 0, -1),
    ("<KeyPress-Down>", 0, 1),
    ("<KeyPress-Left>", -1, 0),
    ("<KeyPress-Right>", 1, 0),
    ("<Shift-KeyPress-Up>", 0, -10),
    ("<Shift-KeyPress-Down>", 0, 10),
    ("<Shift-KeyPress-Left>", -10, 0),
    ("<Shift-KeyPress-Right>", 10, 0),
    ("<Control-KeyPress-Up>", 0, -100),
    ("<Control-KeyPress-Down>", 0, 100),
    ("<Control-KeyPress-Left>", -100, 0),
    ("<Control-KeyPress-Right>", 100, 0),
    ("<Alt-KeyPress-Up>", 0, -100),
    ("<Alt-KeyPress-Down>", 0, 100),
    ("<Alt-KeyPress-Left>", -100, 0),
    ("<Alt-KeyPress-Right>", 100, 0),
)
MAIN_TITLE = "子砚取点抓色器(ZiYanColorPicker)"
IMG_PAD = 24  # 触动图页四周棋盘格边
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


def _bundle_dir() -> str:
    """源码目录，或 PyInstaller 解包目录。"""
    if getattr(sys, "frozen", False):
        return getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(sys.executable)))
    return _HERE


def apply_window_icon(win: tk.Misc) -> None:
    """任务栏/窗口用子砚 ZY 图标；发行 exe 与源码共用 ziyan.ico。"""
    ico = os.path.join(_bundle_dir(), "ziyan.ico")
    png = os.path.join(_bundle_dir(), "ziyan_picker_icon.png")
    try:
        if os.path.isfile(ico):
            win.iconbitmap(default=ico)
    except Exception:
        try:
            if os.path.isfile(ico):
                win.iconbitmap(ico)
        except Exception:
            pass
    try:
        src = ico if os.path.isfile(ico) else png
        if not os.path.isfile(src):
            return
        im = Image.open(src).convert("RGBA")
        resample = getattr(Image, "LANCZOS", Image.BICUBIC)
        im = im.resize((32, 32), resample)
        photo = ImageTk.PhotoImage(im)
        win.iconphoto(True, photo)
        setattr(win, "_ziyan_icon_ref", photo)
    except Exception:
        pass


def apply_snapshot_orient(im: Image.Image, orient: int) -> Image.Image:
    """把 HTTP 原图转到 init 坐标系。方向1=横屏 HOME 在右。
    手机 /snapshot 只写 .ziyan_orient，PNG 仍是竖图，必须在抓色器转。
    PIL ROTATE_90 把竖图底边转到右边（与 init(1) 一致）。"""
    if im is None:
        return im
    o = int(orient)
    w, h = im.size
    portrait = h >= w
    if o == 0:
        return im if portrait else im.transpose(Image.ROTATE_270)
    if o == 1:
        return im.transpose(Image.ROTATE_90) if portrait else im
    if o == 2:
        return im.transpose(Image.ROTATE_270) if portrait else im.transpose(Image.ROTATE_180)
    return im


def _checkerboard(w: int, h: int, cell: int = 8) -> Image.Image:
    """触动图页衬底：灰白棋盘格（只做读图模块背景，不是找色像素）。"""
    im = Image.new("RGB", (max(1, w), max(1, h)), (192, 192, 192))
    draw = ImageDraw.Draw(im)
    light = (224, 224, 224)
    for y in range(0, h, cell * 2):
        for x in range(0, w, cell * 2):
            draw.rectangle([x, y, x + cell - 1, y + cell - 1], fill=light)
            draw.rectangle(
                [x + cell, y + cell, x + 2 * cell - 1, y + 2 * cell - 1], fill=light
            )
    return im


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


def arrow_stick_after_nudge(warp_ok: bool = False) -> bool:
    """方向键改的是取样点；无论系统鼠标有没有跟上，都锁到下一次单击。"""
    return True


def make_find_line(
    points: List[dict], ax: int, ay: int, sx: int, sy: int, degree: int, local: bool
) -> str:
    body = make_find_multi_color_in_region_fuzzy(
        points, ax, ay, sx, sy, degree=int(degree), assign="x,y"
    )
    return ("local " + body) if local else body


def ordered_regs(regs: Dict[int, Optional[dict]]) -> List[dict]:
    return ordered_registers(regs)


def get_system_mouse() -> Optional[Tuple[int, int]]:
    try:
        if sys.platform == "win32":
            import ctypes
            from ctypes import wintypes

            pt = wintypes.POINT()
            if ctypes.windll.user32.GetCursorPos(ctypes.byref(pt)):
                return int(pt.x), int(pt.y)
    except Exception:
        return None
    return None


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
                    im = Image.open(io.BytesIO(body)).convert("RGB")
                    return apply_snapshot_orient(im, int(orient))
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


class ColorPanel(tk.Toplevel):
    """抄触动：取色面板是同进程独立对话框，不是盖在图页上的 Frame。"""

    def __init__(self, app: "App") -> None:
        super().__init__(app)
        self.app = app
        self._host = app
        self._visible = False
        self.tk_mag: Optional[ImageTk.PhotoImage] = None
        self.slot_vars: Dict[int, tk.StringVar] = {}
        self.slot_entries: Dict[int, tk.Entry] = {}
        self.slot_swatches: Dict[int, tk.Canvas] = {}
        self.withdraw()
        self.title("取色面板")
        self.configure(bg="#d4d0c8")
        self.resizable(False, False)
        try:
            # 跟主窗一组：不单独占任务栏。不在每次 show 里重设位置，否则一拖就弹回。
            self.transient(app)
        except tk.TclError:
            pass
        self.protocol("WM_DELETE_WINDOW", self.hide_panel)
        self._placed = False
        self._build()

    def hide_panel(self) -> None:
        self._visible = False
        self.withdraw()

    def show_panel(self) -> None:
        """打开面板。用户拖过之后记住位置，不再强行弹回。"""
        self._visible = True
        try:
            self.deiconify()
            if not self._placed:
                self.app.update_idletasks()
                ax = int(self.app.winfo_rootx())
                ay = int(self.app.winfo_rooty())
                self.geometry("589x499+%d+%d" % (ax + 40, ay + 80))
                self._placed = True
            self.lift()
        except tk.TclError:
            pass

    def _build(self) -> None:
        # 整体左右分栏（对齐触动：左脚本区 + 右网格；测试钮必须横向可见）
        body = tk.Frame(self, bg="#d4d0c8")
        body.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

        # 必须先 pack 右栏：否则 left expand 会把网格 / <-测试 挤没（触动面板是左右分栏）
        right = tk.Frame(body, bg="#d4d0c8", width=228)
        right.pack(side=tk.RIGHT, fill=tk.Y, padx=(8, 0))
        right.pack_propagate(False)
        left = tk.Frame(body, bg="#d4d0c8")
        left.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        # --- 左：格式 + 色点行（对齐触动 customformats 下拉） ---
        head = tk.Frame(left, bg="#d4d0c8")
        head.pack(fill=tk.X)
        self.fmt_var = tk.StringVar(value=FMT_XY_COLOR)
        self.fmt_combo = ttk.Combobox(
            head,
            textvariable=self.fmt_var,
            values=list(FORMAT_NAMES),
            width=28,
            state="readonly",
            takefocus=0,
        )
        self.fmt_combo.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.fmt_combo.bind("<<ComboboxSelected>>", lambda e: self.app.on_format_changed())
        tk.Button(head, text="设置", width=6, takefocus=0, command=self.app.open_format_settings).pack(
            side=tk.LEFT, padx=6
        )

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
            # 要放下 坐标+十六进制+十进制色值+RGB，勿再压成 22 列
            ent = tk.Entry(row, textvariable=var, width=48, font=("Consolas", 9))
            ent.pack(side=tk.LEFT, padx=3, fill=tk.X, expand=True)
            ent.configure(state="readonly")
            ent.bind("<Double-Button-1>", lambda e, n=i: (self._copy_slot(n), "break")[-1])
            ent.bind("<Control-c>", lambda e, n=i: (self._copy_slot(n), "break")[-1])
            self.slot_entries[i] = ent
            sw = tk.Canvas(row, width=16, height=14, bg="#808080", highlightthickness=1)
            sw.pack(side=tk.LEFT, padx=2)
            self.slot_swatches[i] = sw
            tk.Button(
                row,
                text=CIRCLED[i],
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

        # 三行输出：触动每框只有「<-测试」（生成(F)已把第1框写入剪贴板）
        self.out_lines: List[tk.Text] = []
        for _ in range(3):
            row = tk.Frame(left, bg="#d4d0c8")
            row.pack(fill=tk.BOTH, expand=True, pady=2)
            tk.Button(
                row,
                text="<-测试",
                width=8,
                takefocus=0,
                command=partial(self.app.test_on_device, _ + 1),
            ).pack(side=tk.RIGHT, padx=(4, 0), anchor="n")
            t = tk.Text(
                row,
                height=3,
                font=("Consolas", 9),
                bg="#fff",
                fg="#000",
                wrap=tk.NONE,
                cursor="xterm",
                exportselection=True,
                undo=False,
            )
            t.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
            self.out_lines.append(t)
            self._wire_copyable_text(t)

        # 触动：X/C 在面板左下，A/S 在右栏
        xcf = tk.Frame(left, bg="#d4d0c8")
        xcf.pack(fill=tk.X, pady=(4, 0))
        tk.Button(xcf, text="X", width=2, takefocus=0, command=lambda: self.app.asxc_button("X")).pack(
            side=tk.LEFT
        )
        self.ent_xx = tk.Entry(xcf, width=5)
        self.ent_xx.pack(side=tk.LEFT, padx=1)
        self.ent_xy = tk.Entry(xcf, width=5)
        self.ent_xy.pack(side=tk.LEFT, padx=1)
        tk.Button(xcf, text="C", width=2, takefocus=0, command=lambda: self.app.asxc_button("C")).pack(
            side=tk.LEFT, padx=(8, 0)
        )
        self.ent_cx = tk.Entry(xcf, width=5)
        self.ent_cx.pack(side=tk.LEFT, padx=1)
        self.ent_cy = tk.Entry(xcf, width=5)
        self.ent_cy.pack(side=tk.LEFT, padx=1)

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
        self.lbl_ang = tk.Label(right, text="坐标间角度: 0.000000", bg="#d4d0c8", anchor="w")
        self.lbl_ang.pack(fill=tk.X)

        # A/S 在右栏（触动取色面板右侧）
        asf = tk.Frame(right, bg="#d4d0c8")
        asf.pack(fill=tk.X, pady=4)
        tk.Button(asf, text="A", width=2, takefocus=0, command=lambda: self.app.asxc_button("A")).pack(
            side=tk.LEFT
        )
        self.ent_ax = tk.Entry(asf, width=5)
        self.ent_ax.pack(side=tk.LEFT, padx=1)
        self.ent_ay = tk.Entry(asf, width=5)
        self.ent_ay.pack(side=tk.LEFT, padx=1)
        tk.Button(asf, text="S", width=2, takefocus=0, command=lambda: self.app.asxc_button("S")).pack(
            side=tk.LEFT, padx=(6, 0)
        )
        self.ent_sx = tk.Entry(asf, width=5)
        self.ent_sx.pack(side=tk.LEFT, padx=1)
        self.ent_sy = tk.Entry(asf, width=5)
        self.ent_sy.pack(side=tk.LEFT, padx=1)
        for e in (
            self.ent_ax,
            self.ent_ay,
            self.ent_sx,
            self.ent_sy,
            self.ent_xx,
            self.ent_xy,
            self.ent_cx,
            self.ent_cy,
        ):
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

    def _copy_slot(self, idx: int) -> None:
        text = (self.slot_vars.get(idx).get() if idx in self.slot_vars else "") or ""
        text = text.strip()
        if not text:
            self.app.status_set("该行没有可复制的色点")
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
                    i,
                    slot_text(self.app.fmt_name(), p, self.app.fmt_settings()).rstrip("\n"),
                    "#%06x" % (p["c"] & 0xFFFFFF),
                )
            else:
                self.set_slot_text(i, "", None)

    def write_as_entries(self) -> None:
        for ent, val in (
            (self.ent_ax, self.app.reg_a[0]),
            (self.ent_ay, self.app.reg_a[1]),
            (self.ent_sx, self.app.reg_s[0]),
            (self.ent_sy, self.app.reg_s[1]),
            (self.ent_xx, self.app.reg_x[0]),
            (self.ent_xy, self.app.reg_x[1]),
            (self.ent_cx, self.app.reg_c[0]),
            (self.ent_cy, self.app.reg_c[1]),
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
        self.lbl_fmt.configure(
            text="取色格式预览: "
            + preview_info(self.app.fmt_name(), {"x": x, "y": y, "c": c, "r": r, "g": g, "b": b})
        )
        self.swatch.configure(bg="#%06x" % c)

        pts = ordered_regs(regs)
        if pts:
            f = pts[0]
            dx, dy = x - f["x"], y - f["y"]
            dist = math.sqrt(dx * dx + dy * dy)
            ang = math.degrees(math.atan2(dy, dx)) if dx or dy else 0.0
            self.lbl_dx.configure(text="X坐标间距: %d" % dx)
            self.lbl_dy.configure(text="Y坐标间距: %d" % dy)
            self.lbl_dist.configure(text="坐标间距: %.6f" % dist)
            self.lbl_ang.configure(text="坐标间角度: %.6f" % ang)
        else:
            self.lbl_dx.configure(text="X坐标间距: 0")
            self.lbl_dy.configure(text="Y坐标间距: 0")
            self.lbl_dist.configure(text="坐标间距: 0.000000")
            self.lbl_ang.configure(text="坐标间角度: 0.000000")

        # 右侧网格：缩小格子，给 A/S 留出触动同款底栏（19×12 会把 A/S 挤出 499 高）
        half, cell = 7, 8
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


class ImageWindow(tk.Frame):
    """主窗 MDI 页：图在子砚主窗口里，缩放/旋转走主窗工具栏（抄触动，不是独立黑窗）。"""

    def __init__(self, app: "App", im: Image.Image, title: str) -> None:
        super().__init__(app.nb, bg="#808080")
        self.app = app
        self.doc_title = title
        self.img = im.convert("RGB")
        self.pix = self.img.load()
        self.zoom = 1.0
        if max(self.img.width, self.img.height) < 400:
            self.zoom = 2.0
        self.cursor = (self.img.width // 2, self.img.height // 2)
        self.page_pad = IMG_PAD
        self.base_im: Optional[Image.Image] = None
        self.tk_img: Optional[ImageTk.PhotoImage] = None
        self.tk_check: Optional[ImageTk.PhotoImage] = None
        self.paint_job = None
        self._pan = None
        self.configure(bg="#808080")

        stage = tk.Frame(self, bg="#808080")
        stage.pack(fill=tk.BOTH, expand=True)
        self.canvas = tk.Canvas(stage, bg="#c0c0c0", highlightthickness=0, cursor="crosshair", takefocus=1)
        self.hbar = ttk.Scrollbar(stage, orient=tk.HORIZONTAL, command=self.canvas.xview)
        self.vbar = ttk.Scrollbar(stage, orient=tk.VERTICAL, command=self.canvas.yview)
        self.canvas.configure(xscrollcommand=self.hbar.set, yscrollcommand=self.vbar.set)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        self.vbar.grid(row=0, column=1, sticky="ns")
        self.hbar.grid(row=1, column=0, sticky="ew")
        stage.rowconfigure(0, weight=1)
        stage.columnconfigure(0, weight=1)
        tk.Button(
            stage,
            text="×",
            width=2,
            takefocus=0,
            command=self._on_close,
            bg="#c0c0c0",
        ).place(relx=1.0, x=-24, y=2, width=20, height=18)

        self.canvas.bind("<Motion>", self.on_motion)
        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        self.canvas.bind("<Control-ButtonPress-1>", self.on_ctrl_press)
        self.canvas.bind("<Control-Button-1>", self.on_ctrl_press)
        self.canvas.bind("<Shift-ButtonPress-1>", self.on_shift_press)
        self.canvas.bind("<Enter>", lambda e: self.activate())
        self.canvas.bind("<MouseWheel>", self.on_wheel)
        self.canvas.bind("<Button-4>", self.on_wheel)
        self.canvas.bind("<Button-5>", self.on_wheel)
        self._drag_a = None
        self._shift_down = False

        try:
            app.nb.add(self, text=self._tab_name())
            app.nb.select(self)
        except tk.TclError:
            pass
        self.rebuild_base()
        self.paint()
        self.activate()

    def _tab_name(self) -> str:
        t = self.doc_title or ""
        if "[" in t and t.endswith("]"):
            return t[t.rfind("[") + 1 : -1]
        return os.path.basename(t) or t

    def title(self, s: Optional[str] = None) -> str:
        if s is None:
            return self.doc_title
        self.doc_title = s
        try:
            self.app.nb.tab(self, text=self._tab_name())
        except tk.TclError:
            pass
        self.app._sync_main_title()
        return self.doc_title

    def lift(self, aboveThis: Optional[tk.Misc] = None) -> None:  # noqa: N803
        try:
            self.app.nb.select(self)
        except tk.TclError:
            pass

    def _on_close(self) -> None:
        try:
            self.app.nb.forget(self)
        except tk.TclError:
            pass
        self.app.unregister_window(self)
        self.destroy()

    def replace_image(self, im: Image.Image, title: Optional[str] = None) -> None:
        """原地换图（实时刷新用，不开新窗）。"""
        old = self.cursor
        self.img = im.convert("RGB")
        self.pix = self.img.load()
        x = min(old[0], self.img.width - 1)
        y = min(old[1], self.img.height - 1)
        self.cursor = (max(0, x), max(0, y))
        if title:
            self.title(title)
        self.rebuild_base()
        self.paint()
        self.app.push_panel_from_active()

    def activate(self) -> None:
        self.app.active_win = self
        try:
            if str(self.app.nb.select()) != str(self):
                self.app.nb.select(self)
            self.canvas.focus_set()
        except tk.TclError:
            pass
        self.app._sync_main_title()
        self.app.push_panel_from_active()

    def set_zoom(self, z: float) -> None:
        self.zoom = max(0.5, min(16.0, float(z)))
        self.rebuild_base()
        self.paint()

    def rotate_left(self) -> None:
        self.img = self.img.transpose(Image.ROTATE_90)
        self.pix = self.img.load()
        self.cursor = (min(self.cursor[0], self.img.width - 1), min(self.cursor[1], self.img.height - 1))
        self.rebuild_base()
        self.paint()
        self.app.push_panel_from_active()

    def rotate_right(self) -> None:
        self.img = self.img.transpose(Image.ROTATE_270)
        self.pix = self.img.load()
        self.cursor = (min(self.cursor[0], self.img.width - 1), min(self.cursor[1], self.img.height - 1))
        self.rebuild_base()
        self.paint()
        self.app.push_panel_from_active()

    def flip_h(self) -> None:
        self.img = self.img.transpose(Image.FLIP_LEFT_RIGHT)
        self.pix = self.img.load()
        self.rebuild_base()
        self.paint()
        self.app.push_panel_from_active()

    def flip_v(self) -> None:
        self.img = self.img.transpose(Image.FLIP_TOP_BOTTOM)
        self.pix = self.img.load()
        self.rebuild_base()
        self.paint()
        self.app.push_panel_from_active()

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
        pad = int(getattr(self, "page_pad", IMG_PAD))
        page = _checkerboard(frame.width + pad * 2, frame.height + pad * 2)
        page.paste(frame, (pad, pad))
        self.tk_img = ImageTk.PhotoImage(page)
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.tk_img)
        self.canvas.configure(scrollregion=(0, 0, page.width, page.height))

    def on_wheel(self, e) -> str:
        delta = getattr(e, "delta", 0) or 0
        if not delta:
            delta = 120 if getattr(e, "num", 0) == 4 else -120
        if delta > 0:
            self.set_zoom(self.zoom * 1.25)
        else:
            self.set_zoom(self.zoom / 1.25)
        return "break"

    def schedule_paint(self) -> None:
        if self.paint_job:
            self.after_cancel(self.paint_job)
        self.paint_job = self.after(1, self.paint)

    def canvas_xy(self, e) -> Tuple[int, int]:
        z = self.zoom if self.zoom else 1.0
        pad = int(getattr(self, "page_pad", IMG_PAD))
        x = int((self.canvas.canvasx(e.x) - pad) / z)
        y = int((self.canvas.canvasy(e.y) - pad) / z)
        x = max(0, min(self.img.width - 1, x))
        y = max(0, min(self.img.height - 1, y))
        return x, y

    def logical_to_screen(self, ix: int, iy: int) -> Tuple[int, int]:
        self.update_idletasks()
        z = self.zoom if self.zoom else 1.0
        pad = int(getattr(self, "page_pad", IMG_PAD))
        cx = pad + ix * z + z * 0.5
        cy = pad + iy * z + z * 0.5
        sx = int(self.canvas.winfo_rootx() + cx - self.canvas.canvasx(0))
        sy = int(self.canvas.winfo_rooty() + cy - self.canvas.canvasy(0))
        return sx, sy

    def warp_os_mouse(self) -> None:
        """抄触动 moveMouseToXY：把系统鼠标移到当前图像素中心。"""
        try:
            self.ensure_visible()
            self.update_idletasks()
            sx, sy = self.logical_to_screen(self.cursor[0], self.cursor[1])
            set_system_mouse(sx, sy)
        except Exception as e:
            self.app.status_set("鼠标同步失败: %s" % e)

    def ensure_visible(self) -> None:
        z = self.zoom
        x, y = self.cursor
        pad = int(getattr(self, "page_pad", IMG_PAD))
        item = self.canvas.create_rectangle(
            pad + x * z, pad + y * z, pad + x * z + 1, pad + y * z + 1, outline=""
        )
        self.canvas.see(item)
        self.canvas.delete(item)

    def on_motion(self, e) -> None:
        if getattr(self.app, "_pick_lock", 0):
            return
        # 方向键刚挪过取样点：在鼠标真正点一下之前，不要用旧指针坐标把 HUD 打回去
        if getattr(self.app, "_arrow_stick", False):
            return
        self.app.active_win = self
        self.cursor = self.canvas_xy(e)
        self.schedule_paint()
        self.app.push_panel_from_active()

    def on_press(self, e) -> None:
        # Windows 上 Ctrl+左键常常只报到 ButtonPress-1（state 带 Control）
        if int(getattr(e, "state", 0) or 0) & 0x4:
            return self.on_ctrl_press(e)
        # 触动：单击只移动光标；Ctrl+左键 / 回车 / 数字键才入寄存
        self.app._arrow_stick = False
        self.activate()
        if getattr(self.app, "tool_mode", "pick") == "hand":
            self.canvas.scan_mark(e.x, e.y)
            self._pan = True
            return
        self.cursor = self.canvas_xy(e)
        self.app.push_panel_from_active()
        self.paint()

    def on_ctrl_press(self, e) -> Optional[str]:
        """触动 Ctrl+左键 = colorToNextColorRegister(getCurrentXY())。
        方向键改的是取样点；系统鼠标往往还在原地，不能用点击坐标覆盖。"""
        if getattr(self.app, "_ctrl_pick_guard", False):
            return "break"
        self.app._ctrl_pick_guard = True
        self.app.after(80, lambda: setattr(self.app, "_ctrl_pick_guard", False))
        self.activate()
        self.app.pick_next()
        return "break"

    def on_shift_press(self, e) -> Optional[str]:
        self.activate()
        self.cursor = self.canvas_xy(e)
        self._drag_a = self.cursor
        self.app.auto_roi = False
        self.app.reg_a = self.cursor
        self.app.panel.write_as_entries()
        return "break"

    def on_drag(self, e) -> None:
        if self._pan:
            self.canvas.scan_dragto(e.x, e.y, gain=1)
            return
        self.cursor = self.canvas_xy(e)
        if self._drag_a is not None:
            self.app.reg_s = self.cursor
            self.app.panel.write_as_entries()
            self.rebuild_base()
        self.schedule_paint()
        self.app.push_panel_from_active()

    def on_release(self, e) -> None:
        if self._pan:
            self._pan = None
            return
        # Ctrl+点击：松开时不要按鼠标位置把方向键取样点打回去
        if int(getattr(e, "state", 0) or 0) & 0x4:
            return
        self.cursor = self.canvas_xy(e)
        if self._drag_a is not None:
            self.app.reg_s = self.cursor
            self.app.panel.write_as_entries()
            self.rebuild_base()
            self.paint()
        self._drag_a = None


class App(tk.Tk):
    def __init__(self) -> None:
        _win_dpi_aware()
        super().__init__()
        self.title(MAIN_TITLE)
        apply_window_icon(self)
        # 不要盖在触动抓色器默认左上角；.48 上触动常在 +1+4
        self.geometry("960x700+470+8")
        self.minsize(640, 480)
        self.configure(bg="#c0c0c0")

        self.regs: Dict[int, Optional[dict]] = {i: None for i in range(10)}
        self.next_reg = 1
        self.reg_a = (0, 0)
        self.reg_s = (0, 0)
        self.reg_x = (0, 0)
        self.reg_c = (0, 0)
        self.auto_roi = True
        self.degree = tk.IntVar(value=90)
        self.local_prefix = tk.BooleanVar(value=False)
        self.device_ip = tk.StringVar(value="192.168.31.101")
        self.device_orient = tk.IntVar(value=1)
        self.live_var = tk.BooleanVar(value=False)
        self._fmt_settings: Dict[str, Dict[str, str]] = {
            n: default_settings(n) for n in FORMAT_NAMES
        }
        self.cached_scripts = ["", "", ""]
        self.dev = DeviceClient()
        self.image_windows: List[ImageWindow] = []
        self.active_win: Optional[ImageWindow] = None
        self.live_win: Optional[ImageWindow] = None
        self.snap_seq = 0
        self._live_job = None
        self._snap_busy = False
        self.tool_mode = "pick"
        self._icons: List[ImageTk.PhotoImage] = []
        self._last_dir = os.path.expanduser("~")
        self._pick_lock = 0
        self._arrow_stick = False
        self._ctrl_pick_guard = False

        self._build()
        self._bind_keys()
        self.device_ip.trace_add("write", self._on_ip_changed)
        self.status_set("v%s | 主窗抄触动取点抓色器；取色面板为浮窗；截屏在「文件/工具栏」" % APP_VER)

    def _on_ip_changed(self, *_args) -> None:
        self.dev.set_ip(self.device_ip.get())

    def _icon16(self, kind: str) -> ImageTk.PhotoImage:
        """主窗图标工具栏（抄触动分组，不用中文大钮当面板主铬）。"""
        im = Image.new("RGB", (16, 16), (192, 192, 192))
        d = ImageDraw.Draw(im)
        k = kind
        if k == "new":
            d.rectangle([3, 1, 12, 14], outline=(0, 0, 0), fill=(255, 255, 255))
        elif k == "open":
            d.polygon([(1, 6), (5, 6), (6, 3), (14, 3), (14, 13), (1, 13)], outline=(0, 0, 0), fill=(255, 200, 80))
        elif k == "save":
            d.rectangle([2, 2, 13, 13], outline=(0, 0, 80), fill=(40, 80, 180))
            d.rectangle([5, 8, 10, 13], fill=(220, 220, 220))
        elif k == "zoom1":
            d.rectangle([2, 2, 13, 13], outline=(0, 0, 0), fill=(255, 255, 255))
            d.line([(4, 8), (12, 8)], fill=(0, 0, 0))
            d.line([(8, 4), (8, 12)], fill=(0, 0, 0))
        elif k == "zoomin":
            d.ellipse([2, 2, 11, 11], outline=(0, 0, 0))
            d.line([(6, 5), (6, 8)], fill=(0, 0, 0))
            d.line([(5, 6), (8, 6)], fill=(0, 0, 0))
            d.line([(10, 10), (14, 14)], fill=(0, 0, 0), width=2)
        elif k == "zoomout":
            d.ellipse([2, 2, 11, 11], outline=(0, 0, 0))
            d.line([(5, 6), (8, 6)], fill=(0, 0, 0))
            d.line([(10, 10), (14, 14)], fill=(0, 0, 0), width=2)
        elif k == "fliph":
            d.polygon([(2, 8), (7, 3), (7, 13)], fill=(0, 0, 0))
            d.polygon([(14, 8), (9, 3), (9, 13)], fill=(0, 0, 0))
        elif k == "flipv":
            d.polygon([(8, 2), (3, 7), (13, 7)], fill=(0, 0, 0))
            d.polygon([(8, 14), (3, 9), (13, 9)], fill=(0, 0, 0))
        elif k == "rotl":
            d.arc([2, 2, 13, 13], 40, 320, fill=(0, 0, 0))
            d.polygon([(3, 3), (7, 3), (3, 7)], fill=(0, 0, 0))
        elif k == "rotr":
            d.arc([2, 2, 13, 13], 220, 140, fill=(0, 0, 0))
            d.polygon([(13, 3), (9, 3), (13, 7)], fill=(0, 0, 0))
        elif k == "hand":
            d.polygon([(5, 14), (5, 7), (7, 4), (8, 7), (10, 3), (11, 8), (13, 14)], outline=(0, 0, 0), fill=(255, 220, 180))
        elif k == "pick":
            d.line([(3, 13), (10, 6)], fill=(0, 0, 0), width=2)
            d.rectangle([9, 3, 13, 7], outline=(0, 0, 0), fill=(200, 40, 40))
        elif k == "play":
            d.polygon([(4, 3), (13, 8), (4, 13)], fill=(0, 120, 0))
        elif k == "stop":
            d.rectangle([4, 4, 12, 12], fill=(140, 0, 0))
        elif k == "panel":
            d.rectangle([2, 3, 14, 13], outline=(0, 0, 0), fill=(212, 208, 200))
            d.rectangle([4, 5, 12, 7], fill=(80, 80, 80))
        elif k == "gear":
            d.ellipse([3, 3, 12, 12], outline=(0, 0, 0))
            d.ellipse([6, 6, 9, 9], fill=(80, 80, 80))
        elif k == "cam":
            d.rectangle([2, 5, 14, 13], outline=(0, 0, 0), fill=(40, 40, 40))
            d.ellipse([5, 6, 11, 12], outline=(200, 200, 200))
        else:
            d.rectangle([3, 3, 12, 12], outline=(0, 0, 0))
        ph = ImageTk.PhotoImage(im, master=self)
        self._icons.append(ph)
        return ph

    def _tb_sep(self, bar: tk.Frame) -> None:
        f = tk.Frame(bar, width=2, bg="#808080", relief=tk.SUNKEN, bd=1)
        f.pack(side=tk.LEFT, fill=tk.Y, padx=3, pady=3)

    def _tb_btn(self, bar: tk.Frame, kind: str, cmd, tip: str) -> tk.Button:
        b = tk.Button(
            bar,
            image=self._icon16(kind),
            command=cmd,
            takefocus=0,
            relief=tk.RAISED,
            bd=1,
            bg="#c0c0c0",
            activebackground="#d0d0d0",
            padx=2,
            pady=1,
        )
        b.pack(side=tk.LEFT, padx=1, pady=2)
        b.bind("<Enter>", lambda e: self.status_set(tip))
        return b

    def _build_toolbar(self) -> None:
        bar = tk.Frame(self, bg="#c0c0c0", relief=tk.RAISED, bd=1)
        bar.pack(fill=tk.X)
        self._tb_btn(bar, "new", self.new_image, "新建")
        self._tb_btn(bar, "open", self.open_image, "打开图片")
        self._tb_btn(bar, "save", self.save_image, "保存图片")
        self._tb_sep(bar)
        self._tb_btn(bar, "zoom1", lambda: self._zoom_abs(1.0), "1:1")
        self._tb_btn(bar, "zoomout", lambda: self._zoom_active(1 / 1.25), "缩小")
        self._tb_btn(bar, "zoomin", lambda: self._zoom_active(1.25), "放大")
        self._tb_btn(bar, "fliph", self._flip_h, "水平翻转")
        self._tb_btn(bar, "flipv", self._flip_v, "垂直翻转")
        self._tb_btn(bar, "rotl", lambda: self._rotate_active(True), "左旋")
        self._tb_btn(bar, "rotr", lambda: self._rotate_active(False), "右旋")
        self._tb_sep(bar)
        self._tb_btn(bar, "hand", lambda: self._set_tool("hand"), "抓手")
        self._tb_btn(bar, "pick", lambda: self._set_tool("pick"), "取色")
        self._tb_sep(bar)
        self._tb_btn(bar, "play", lambda: self._set_live(True), "实时画面")
        self._tb_btn(bar, "stop", lambda: self._set_live(False), "停止实时")
        self._tb_sep(bar)
        self._tb_btn(bar, "panel", self.lift_panel, "取色面板")
        self._tb_btn(bar, "gear", self.open_device_dialog, "连接设备")
        self._tb_btn(bar, "cam", lambda: self.snap_device(new_window=True), "截屏")

    def _set_tool(self, mode: str) -> None:
        self.tool_mode = mode
        cur = "fleur" if mode == "hand" else "crosshair"
        for win in self.image_windows:
            try:
                win.canvas.configure(cursor=cur)
            except tk.TclError:
                pass
        self.status_set("工具: " + ("抓手" if mode == "hand" else "取色"))

    def _set_live(self, on: bool) -> None:
        self.live_var.set(bool(on))
        self._toggle_live()

    def _zoom_abs(self, z: float) -> None:
        win = self.active_win
        if win:
            win.set_zoom(z)

    def _flip_h(self) -> None:
        if self.active_win:
            self.active_win.flip_h()

    def _flip_v(self) -> None:
        if self.active_win:
            self.active_win.flip_v()

    def _on_tab_changed(self, _e=None) -> None:
        try:
            w = self.nametowidget(self.nb.select())
        except Exception:
            return
        if isinstance(w, ImageWindow):
            self.active_win = w
            self._sync_main_title()
            self.push_panel_from_active()

    def _sync_main_title(self) -> None:
        win = self.active_win
        if win:
            name = win.title()
            if name.startswith(MAIN_TITLE):
                self.title(name)
            else:
                self.title("%s - [%s]" % (MAIN_TITLE, win._tab_name()))
        else:
            self.title(MAIN_TITLE)

    def save_image(self) -> None:
        self.save_image_as()

    def save_image_as(self) -> None:
        win = self.active_win
        if not win:
            self.status_set("没有可保存的图片")
            return
        path = filedialog.asksaveasfilename(
            initialdir=self._last_dir,
            defaultextension=".png",
            filetypes=[
                ("PNG", "*.png"),
                ("JPEG", "*.jpg;*.jpeg"),
                ("BMP", "*.bmp"),
                ("All", "*.*"),
            ],
        )
        if path:
            self._last_dir = os.path.dirname(path)
            win.img.save(path)
            win.title("%s - [%s]" % (MAIN_TITLE, os.path.basename(path)))
            self.status_set("已保存 " + path)

    def new_image(self) -> None:
        """触动「新建」：空白图页进 MDI，取色面板仍留在主窗内。"""
        im = _checkerboard(640, 480)
        self.snap_seq += 1
        self.open_image_window(im, "未命名_%d" % self.snap_seq)

    def _install_win_drop(self) -> None:
        """故意空实现。曾经用 SetWindowLongPtr 钩 WM_DROPFILES，64 位 Tk 上会把标题栏拖动/关闭弄死。"""
        return

    def _open_dropped(self, paths) -> None:
        n = 0
        for path in paths:
            ext = os.path.splitext(path)[1].lower()
            if ext not in (".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp"):
                continue
            try:
                self._last_dir = os.path.dirname(path)
                self.open_image_window(Image.open(path).convert("RGB"), os.path.basename(path))
                n += 1
            except Exception as e:
                self.status_set("打开失败 %s: %s" % (path, e))
        if n:
            self.status_set("已拖入 %d 张图" % n)

    def open_device_dialog(self) -> None:
        """设备 IP 在主窗「连接设备」对话框，不进取色面板（抄触动窗口分工）。"""
        win = tk.Toplevel(self)
        win.title("连接设备")
        win.configure(bg="#d4d0c8")
        win.geometry("380x200+80+80")
        try:
            win.attributes("-toolwindow", True)
        except tk.TclError:
            pass
        row = tk.Frame(win, bg="#d4d0c8")
        row.pack(fill=tk.X, padx=10, pady=8)
        tk.Label(row, text="手机IP", bg="#d4d0c8").pack(side=tk.LEFT)
        tk.Entry(row, textvariable=self.device_ip, width=18).pack(side=tk.LEFT, padx=6)
        tk.Label(row, text="方向", bg="#d4d0c8").pack(side=tk.LEFT)
        tk.Spinbox(row, from_=0, to=2, width=3, textvariable=self.device_orient).pack(side=tk.LEFT)
        row2 = tk.Frame(win, bg="#d4d0c8")
        row2.pack(fill=tk.X, padx=10, pady=4)
        tk.Label(row2, text="相似度", bg="#d4d0c8").pack(side=tk.LEFT)
        tk.Spinbox(row2, from_=1, to=100, width=4, textvariable=self.degree).pack(side=tk.LEFT)
        tk.Checkbutton(row2, text="local前缀", variable=self.local_prefix, bg="#d4d0c8").pack(
            side=tk.LEFT, padx=8
        )
        tk.Checkbutton(
            row2,
            text="实时画面",
            variable=self.live_var,
            bg="#d4d0c8",
            command=self._toggle_live,
        ).pack(side=tk.LEFT)
        bf = tk.Frame(win, bg="#d4d0c8")
        bf.pack(fill=tk.X, padx=10, pady=12)
        tk.Button(bf, text="探测", width=8, command=self.connect_device).pack(side=tk.LEFT, padx=4)
        tk.Button(bf, text="截屏", width=8, command=lambda: self.snap_device(new_window=True)).pack(
            side=tk.LEFT, padx=4
        )
        tk.Button(bf, text="关闭", width=8, command=win.destroy).pack(side=tk.LEFT, padx=4)

    def _build(self) -> None:
        menubar = tk.Menu(self)
        m_file = tk.Menu(menubar, tearoff=0)
        m_file.add_command(label="新建", command=self.new_image)
        m_file.add_command(label="打开图片", command=self.open_image, accelerator="Ctrl+O")
        m_file.add_command(label="粘贴图片", command=self.paste_image, accelerator="Ctrl+V")
        m_file.add_command(label="保存图片", command=self.save_image, accelerator="Ctrl+S")
        m_file.add_command(label="另存为...", command=self.save_image_as)
        m_file.add_separator()
        m_file.add_command(label="连接设备...", command=self.open_device_dialog)
        m_file.add_command(label="截屏", command=lambda: self.snap_device(new_window=True))
        m_file.add_command(label="刷新画面", command=lambda: self.snap_device(new_window=False))
        m_file.add_separator()
        m_file.add_command(label="退出", command=self.destroy)
        menubar.add_cascade(label="文件(F)", menu=m_file)
        m_edit = tk.Menu(menubar, tearoff=0)
        m_edit.add_command(label="生成脚本(F)", command=self.generate)
        m_edit.add_command(label="清除所有(Z)", command=self.clear_regs)
        m_edit.add_command(label="复制当前点(`)", command=self.copy_current_point)
        m_edit.add_command(label="重取已选颜色(R)", command=self.repick_colors)
        menubar.add_cascade(label="编辑(E)", menu=m_edit)
        m_win = tk.Menu(menubar, tearoff=0)
        m_win.add_command(label="打开取色面板(R)", command=self.lift_panel, accelerator="Ctrl+R")
        m_win.add_command(label="关闭当前图片", command=self.close_active_image)
        m_win.add_command(label="刷新窗口列表", command=self.refresh_window_menu)
        menubar.add_cascade(label="窗口(W)", menu=m_win)
        self._m_win = m_win
        m_help = tk.Menu(menubar, tearoff=0)
        m_help.add_command(label="快捷键", command=self.show_hotkeys)
        m_help.add_command(label="关于", command=self.show_about)
        menubar.add_cascade(label="帮助(H)", menu=m_help)
        self.config(menu=menubar)
        self.bind_all("<Control-n>", lambda e: self.new_image())
        self.bind_all("<Control-N>", lambda e: self.new_image())
        self.bind_all("<Control-o>", lambda e: self.open_image())
        self.bind_all("<Control-O>", lambda e: self.open_image())
        self.bind_all("<Control-v>", lambda e: None if self._focus_is_entry() else self.paste_image())
        self.bind_all("<Control-s>", lambda e: self.save_image())
        self.bind_all("<Control-r>", lambda e: self.lift_panel())
        self.bind_all("<Control-R>", lambda e: self.lift_panel())
        self.bind_all("<Control-w>", lambda e: self.close_active_image())
        self.bind_all("<Control-W>", lambda e: self.close_active_image())

        self._build_toolbar()

        self.mdi = tk.Frame(self, bg="#808080")
        self.mdi.pack(fill=tk.BOTH, expand=True)
        self.nb = ttk.Notebook(self.mdi)
        self.nb.pack(fill=tk.BOTH, expand=True)
        self.nb.bind("<<NotebookTabChanged>>", self._on_tab_changed)

        st = tk.Frame(self, bg="#c0c0c0")
        st.pack(fill=tk.X, side=tk.BOTTOM)
        self.status = tk.Label(st, text="", bg="#808080", fg="#fff", anchor="w")
        self.status.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.lbl_dev = tk.Label(st, text="设备: 未连接", bg="#808080", fg="#fcc", width=22, anchor="e")
        self.lbl_dev.pack(side=tk.RIGHT)

        self.panel = ColorPanel(self)
        self.after(80, self.lift_panel)

    def _focus_is_entry(self) -> bool:
        """A/S/X/C 坐标格才拦截快捷键；脚本框/只读槽不挡住方向键取色。"""
        try:
            f = self.focus_get()
        except tk.TclError:
            return False
        if f is None:
            return False
        panel = getattr(self, "panel", None)
        if panel is None:
            return isinstance(f, (tk.Entry, tk.Spinbox))
        asxc = (
            panel.ent_ax,
            panel.ent_ay,
            panel.ent_sx,
            panel.ent_sy,
            panel.ent_xx,
            panel.ent_xy,
            panel.ent_cx,
            panel.ent_cy,
        )
        return f in asxc or isinstance(f, tk.Spinbox)

    def _panel_holds_focus(self) -> bool:
        try:
            f = self.focus_get()
            return f is not None and str(f).startswith(str(self.panel))
        except Exception:
            return False

    def keep_panel_inside(self) -> None:
        """不再把面板钉死在主窗某个坐标，否则用户一拖就被弹回。"""
        return

    def _on_arrow_event(self, dx: int, dy: int, e=None) -> Optional[str]:
        """触动方向键永远 moveMouseToXY。同一按键若绑了多次，15ms 内只走一格。"""
        now = time.monotonic()
        last = float(getattr(self, "_last_arrow_mono", 0) or 0)
        if now - last < 0.015:
            return "break"
        self._last_arrow_mono = now
        return self.nudge_active(dx, dy)

    def _steal_arrow_class(self, cls: str) -> None:
        extra = (("<Left>", -1, 0), ("<Right>", 1, 0), ("<Up>", 0, -1), ("<Down>", 0, 1))
        for seq, dx, dy in ARROW_BINDS + extra:
            try:
                self.bind_class(cls, seq, lambda e, x=dx, y=dy: self._on_arrow_event(x, y, e))
            except tk.TclError:
                pass

    def _bind_keys(self) -> None:
        # 只 bind_all + 抢会吃方向键的类。控件上再 bind 一次会在这台机连走 3 格。
        for seq, dx, dy in ARROW_BINDS:
            self.bind_all(seq, lambda e, x=dx, y=dy: self._on_arrow_event(x, y, e))
        # Windows 部分机只认 <Left> 不认 <KeyPress-Left>
        for seq, dx, dy in (
            ("<Left>", -1, 0),
            ("<Right>", 1, 0),
            ("<Up>", 0, -1),
            ("<Down>", 0, 1),
        ):
            self.bind_all(seq, lambda e, x=dx, y=dy: self._on_arrow_event(x, y, e))
        for cls in ("Text", "TCombobox", "TNotebook", "Combobox", "Listbox", "Entry"):
            self._steal_arrow_class(cls)
        self.bind_all("f", lambda e: None if self._focus_is_entry() else self.generate())
        self.bind_all("F", lambda e: None if self._focus_is_entry() else self.generate())
        self.bind_all("z", lambda e: None if self._focus_is_entry() else self.clear_regs())
        self.bind_all("Z", lambda e: None if self._focus_is_entry() else self.clear_regs())
        self.bind_all("a", lambda e: self._key_asxc("A", e))
        self.bind_all("s", lambda e: self._key_asxc("S", e))
        self.bind_all("x", lambda e: self._key_asxc("X", e))
        self.bind_all("c", lambda e: self._key_asxc("C", e))
        self.bind_all("e", lambda e: self._key_e(e))
        self.bind_all("d", lambda e: self._key_d(e))
        self.bind_all("w", lambda e: None if self._focus_is_entry() else self.reload_pasteboard())
        self.bind_all("W", lambda e: None if self._focus_is_entry() else self.reload_pasteboard())
        self.bind_all("r", lambda e: None if self._focus_is_entry() else self.repick_colors())
        self.bind_all("j", lambda e: None if self._focus_is_entry() else self._rotate_active(True))
        self.bind_all("J", lambda e: None if self._focus_is_entry() else self._rotate_active(True))
        self.bind_all("k", lambda e: None if self._focus_is_entry() else self._rotate_active(False))
        self.bind_all("K", lambda e: None if self._focus_is_entry() else self._rotate_active(False))
        self.bind_all("=", lambda e: None if self._focus_is_entry() else self._zoom_active(1.25))
        self.bind_all("+", lambda e: None if self._focus_is_entry() else self._zoom_active(1.25))
        self.bind_all("-", lambda e: None if self._focus_is_entry() else self._zoom_active(1 / 1.25))
        self.bind_all("`", lambda e: None if self._focus_is_entry() else self.copy_current_point())
        self.bind_all("<Return>", lambda e: None if self._focus_is_entry() else self.pick_next())
        # 触动 Ctrl+左键：点在图上或面板上，都写入当前取样点（方向键走过的那个）
        self.bind_all("<Control-ButtonPress-1>", self._global_ctrl_pick)
        self.bind_all("<Control-Button-1>", self._global_ctrl_pick)
        for i in range(10):
            self.bind_all(str(i), lambda e, n=i: None if self._focus_is_entry() else self.pick_to(n))
            self.bind_all(
                "<Shift-Key-%d>" % i,
                lambda e, n=i: None if self._focus_is_entry() else self.clear_one(n),
            )

    def status_set(self, s: str) -> None:
        self.status.configure(text=s)

    def copy_clipboard(self, text: str) -> None:
        """写入系统剪贴板一份。禁止 append 两次，否则 705, 450 会黏成 705, 450705, 450。"""
        text = "" if text is None else str(text)
        try:
            self.clipboard_clear()
            self.update_idletasks()
            self.clipboard_append(text)
            self.update()
            try:
                got = self.clipboard_get()
            except tk.TclError:
                got = ""
            if got != text:
                self.clipboard_clear()
                self.update_idletasks()
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
        self.refresh_window_menu()
        self._sync_main_title()

    def open_image_window(self, im: Image.Image, title: str) -> ImageWindow:
        disp = title if title.startswith(MAIN_TITLE) else "%s - [%s]" % (MAIN_TITLE, title)
        win = ImageWindow(self, im, disp)
        self.image_windows.append(win)
        self.active_win = win
        self.status_set("已打开 %s（%d张）" % (title, len(self.image_windows)))
        self.refresh_window_menu()
        return win

    def open_image(self) -> None:
        path = filedialog.askopenfilename(
            initialdir=self._last_dir,
            filetypes=[("Images", "*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp"), ("All", "*.*")],
        )
        if path:
            self._last_dir = os.path.dirname(path)
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
            self.open_device_dialog()
            return
        self.status_set("并行探测 %s …" % ip)

        def work() -> None:
            port, msg = self.dev.probe(ip)

            def done() -> None:
                if port:
                    self.lbl_dev.configure(text="设备: :%d 已缓存" % port, fg="#9f9")
                    self.status_set(msg + " | 截屏将直连此端口")
                else:
                    self.lbl_dev.configure(text="设备: 未连接", fg="#fcc")
                    messagebox.showerror("连接失败", msg)

            self.after(0, done)

        threading.Thread(target=work, daemon=True).start()

    def snap_device(self, new_window: bool = True) -> None:
        if self._snap_busy:
            return
        ip = self.device_ip.get().strip()
        if not ip:
            self.open_device_dialog()
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
                        text="设备: :%s %dms" % (self.dev.port or "?", ms), fg="#9f9"
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
                    self.lbl_dev.configure(text="设备: 断开", fg="#fcc")
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

    def sample_active_pixel(self) -> None:
        """从当前图位图取出光标像素，写入 坐标/颜色值/RGB/网格（抄触动悬停取样）。"""
        win = self.active_win
        if not win or not self.panel:
            return
        try:
            if not win.winfo_exists():
                return
            x, y = win.cursor
            if not (0 <= x < win.img.width and 0 <= y < win.img.height):
                return
            self.panel.refresh_cursor_info(win.img, win.pix, win.cursor, self.regs)
            r, g, b = win.pix[x, y]
            c = rgb_to_c(r, g, b)
            self.status_set("取色 (%d,%d) 0x%06x RGB(%d,%d,%d)" % (x, y, c, r, g, b))
            log = os.environ.get("ZY_CP_ARROW_LOG")
            if log:
                with open(log, "a", encoding="utf-8") as f:
                    f.write(
                        "xy=%d,%d color=0x%06x rgb=%d,%d,%d hud=%s\n"
                        % (x, y, c, r, g, b, self.panel.lbl_col.cget("text"))
                    )
        except Exception as e:
            self.status_set("取色失败: %s" % e)

    def push_panel_from_active(self) -> None:
        win = self.active_win
        if not win or not self.panel:
            return
        try:
            if not win.winfo_exists():
                return
            self.panel.refresh_cursor_info(win.img, win.pix, win.cursor, self.regs)
        except Exception as e:
            self.status_set("取色失败: %s" % e)

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

    def _global_ctrl_pick(self, e) -> Optional[str]:
        """面板/图上都可 Ctrl+点：不要点到「清除/①」钮时再写一次。"""
        w = getattr(e, "widget", None)
        try:
            if isinstance(w, tk.Button):
                return None
        except Exception:
            pass
        win = self.active_win
        if not win:
            return "break"
        return win.on_ctrl_press(e)

    def pick_to(self, idx: int) -> None:
        if not self.active_win:
            messagebox.showwarning("取色", "请先打开图片或截屏")
            return
        idx = int(idx)
        self.regs[idx] = self.point_now()
        # 触动：数字键/① 只写入色点，不改 A/S；A/S 全 0 时 F 用整图
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

    def fmt_name(self) -> str:
        try:
            name = self.panel.fmt_var.get()
        except Exception:
            name = FMT_XY_COLOR
        return name if name in FORMAT_NAMES else FMT_XY_COLOR

    def fmt_settings(self) -> Dict[str, str]:
        name = self.fmt_name()
        if name not in self._fmt_settings:
            self._fmt_settings[name] = default_settings(name)
        return self._fmt_settings[name]

    def on_format_changed(self) -> None:
        self.panel.refresh_slots()
        self.push_panel_from_active()
        self.status_set("格式: " + self.fmt_name())

    def open_format_settings(self) -> None:
        name = self.fmt_name()
        setv = dict(self.fmt_settings())
        win = tk.Toplevel(self)
        win.title("自定义格式 [%s] 的参数设置" % name)
        win.configure(bg="#d4d0c8")
        win.geometry("520x280+80+80")
        tk.Label(win, text="参数名", bg="#d4d0c8").grid(row=0, column=0, sticky="w", padx=8, pady=4)
        tk.Label(win, text="参数值", bg="#d4d0c8").grid(row=0, column=1, sticky="w", padx=8, pady=4)
        ents = {}
        for i, key in enumerate(setv.keys()):
            tk.Label(win, text=key, bg="#d4d0c8").grid(row=i + 1, column=0, sticky="w", padx=8)
            e = tk.Entry(win, width=48)
            e.insert(0, setv[key])
            e.grid(row=i + 1, column=1, sticky="ew", padx=8, pady=2)
            ents[key] = e
        win.columnconfigure(1, weight=1)

        def save() -> None:
            for k, e in ents.items():
                setv[k] = e.get()
            self._fmt_settings[name] = setv
            self.panel.refresh_slots()
            win.destroy()
            self.status_set("已保存格式设置: " + name)

        tk.Button(win, text="确定", command=save, width=10).grid(
            row=len(setv) + 2, column=1, sticky="e", padx=8, pady=10
        )

    def _shift_down(self, e) -> bool:
        try:
            return bool(e.state & 0x0001)
        except Exception:
            return False

    def _key_asxc(self, which: str, e) -> Optional[str]:
        if self._focus_is_entry():
            return None
        if self._shift_down(e):
            self.jump_to_asxc(which)
        else:
            self.set_asxc(which)
        return "break"

    def _key_e(self, e) -> Optional[str]:
        if self._focus_is_entry():
            return None
        if self._shift_down(e):
            self.reset_as()
        else:
            self.swap_asxc()
        return "break"

    def _key_d(self, e) -> Optional[str]:
        if self._focus_is_entry():
            return None
        if self._shift_down(e):
            self.clear_rect_text()
        else:
            self.copy_rect()
        return "break"

    def set_asxc(self, which: str) -> None:
        if not self.active_win:
            return
        xy = self.active_win.cursor
        self.auto_roi = False
        if which == "A":
            self.reg_a = xy
        elif which == "S":
            self.reg_s = xy
        elif which == "X":
            self.reg_x = xy
        else:
            self.reg_c = xy
        self.panel.write_as_entries()
        self.copy_clipboard("%d, %d" % xy)
        if self.active_win:
            self.active_win.rebuild_base()
            self.active_win.paint()

    def asxc_button(self, which: str) -> None:
        """触动：点 A/S/X/C 按钮 = 复制该缓冲坐标。"""
        mp = {"A": self.reg_a, "S": self.reg_s, "X": self.reg_x, "C": self.reg_c}
        xy = mp.get(which, (0, 0))
        self.copy_clipboard("%d, %d" % xy)

    def jump_to_asxc(self, which: str) -> None:
        mp = {"A": self.reg_a, "S": self.reg_s, "X": self.reg_x, "C": self.reg_c}
        xy = mp.get(which, (0, 0))
        win = self.active_win
        if not win:
            return
        x = max(0, min(win.img.width - 1, xy[0]))
        y = max(0, min(win.img.height - 1, xy[1]))
        win.cursor = (x, y)
        win.paint()
        self.push_panel_from_active()
        win.after(1, win.warp_os_mouse)

    def swap_asxc(self) -> None:
        ax = self.reg_a
        self.reg_a = self.reg_x
        self.reg_x = ax
        ss = self.reg_s
        self.reg_s = self.reg_c
        self.reg_c = ss
        self.panel.write_as_entries()
        if self.active_win:
            self.active_win.rebuild_base()
            self.active_win.paint()

    def reset_as(self) -> None:
        self.reg_a = (0, 0)
        self.reg_s = (0, 0)
        self.panel.write_as_entries()
        if self.active_win:
            self.active_win.rebuild_base()
            self.active_win.paint()

    def copy_rect(self) -> None:
        text = "%d, %d, %d, %d" % (self.reg_a[0], self.reg_a[1], self.reg_s[0], self.reg_s[1])
        self.panel.lbl_roi.configure(text=text)
        self.copy_clipboard("%d, %d" % (self.reg_a[0], self.reg_a[1]) + ", %d, %d" % (self.reg_s[0], self.reg_s[1]))

    def clear_rect_text(self) -> None:
        self.panel.lbl_roi.configure(text="")

    def copy_current_point(self) -> None:
        if not self.active_win:
            return
        p = self.point_now()
        text = single_text(self.fmt_name(), p, self.fmt_settings())
        self.copy_clipboard(text)

    def reload_pasteboard(self) -> None:
        parts = []
        for i in SLOT_ORDER:
            p = self.regs.get(i)
            if p:
                parts.append(slot_text(self.fmt_name(), p, self.fmt_settings()))
        self.copy_clipboard("".join(parts))

    def repick_colors(self) -> None:
        win = self.active_win
        if not win:
            return
        for i, p in list(self.regs.items()):
            if not p:
                continue
            x, y = p["x"], p["y"]
            if 0 <= x < win.img.width and 0 <= y < win.img.height:
                r, g, b = win.pix[x, y]
                p["c"] = rgb_to_c(r, g, b)
                p["r"], p["g"], p["b"] = r, g, b
                self.regs[i] = p
        self.panel.refresh_slots()
        self.status_set("已按原坐标重取颜色(R)")

    def _rotate_active(self, left: bool) -> None:
        win = self.active_win
        if not win:
            return
        if left:
            win.rotate_left()
        else:
            win.rotate_right()

    def _zoom_active(self, factor: float) -> None:
        win = self.active_win
        if not win:
            return
        win.set_zoom(win.zoom * factor)

    def lift_panel(self) -> None:
        self.panel.show_panel()

    def close_active_image(self) -> None:
        win = self.active_win
        if win:
            win._on_close()

    def refresh_window_menu(self) -> None:
        m = getattr(self, "_m_win", None)
        if m is None:
            return
        m.delete(0, tk.END)
        m.add_command(label="打开取色面板(R)", command=self.lift_panel)
        m.add_command(label="关闭当前图片", command=self.close_active_image)
        for i, win in enumerate(list(self.image_windows)):
            try:
                title = win.title()
            except tk.TclError:
                continue
            m.add_command(label=title, command=lambda w=win: w.activate())

    def show_hotkeys(self) -> None:
        messagebox.showinfo(
            "快捷键",
            "数字 0-9 取色入寄存  Shift+数字 清除该寄存\n"
            "回车 / Ctrl+左键 取下一空寄存\n"
            "方向键 逐像素取色（坐标/颜色值/RGB/网格，抄触动 moveMouseToXY）  Shift 10px\n"
            "A/S/X/C 当前点写入缓冲  Shift+A/S/X/C 鼠标跳到该点\n"
            "F 生成脚本  Z 清除所有  R 重取颜色  E 交换 A↔X、S↔C\n"
            "D 复制 A,S 矩形  W 点列入剪贴板  ` 当前点格式入剪贴板\n"
            "+/- 或滚轮 缩放  J/K 旋转  拖入图片到主窗打开",
        )

    def show_about(self) -> None:
        messagebox.showinfo(
            "关于",
            "子砚取点抓色器 v%s\n抄触动精灵取点抓色器(TSColorPicker) 1.7.10：\n"
            "主窗 MDI 只放图；取色面板是独立对话框；方向键逐像素取色。\n"
            "设备截屏：子砚 framecap HTTP :50005/:50015" % APP_VER,
        )

    def set_a(self) -> None:
        self.set_asxc("A")

    def set_s(self) -> None:
        self.set_asxc("S")

    def sync_as_from_entries(self) -> None:
        try:
            self.reg_a = (int(self.panel.ent_ax.get()), int(self.panel.ent_ay.get()))
            self.reg_s = (int(self.panel.ent_sx.get()), int(self.panel.ent_sy.get()))
            self.reg_x = (int(self.panel.ent_xx.get()), int(self.panel.ent_xy.get()))
            self.reg_c = (int(self.panel.ent_cx.get()), int(self.panel.ent_cy.get()))
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
        """抄触动 moveMouseUp/Down/Left/Right：光标 ±N，鼠标跟上，立刻从位图取该像素。"""
        win = self.active_win
        if not win:
            self.status_set("请先打开图片再按方向键取色")
            return "break"
        try:
            if not win.winfo_exists():
                return "break"
        except tk.TclError:
            return "break"
        x = max(0, min(win.img.width - 1, win.cursor[0] + dx))
        y = max(0, min(win.img.height - 1, win.cursor[1] + dy))
        win.cursor = (x, y)
        self._arrow_stick = True
        # 锁 Motion：SetCursorPos 前旧鼠标位置会把光标打回，表现为「动了却没取到色」
        self._pick_lock = int(getattr(self, "_pick_lock", 0)) + 1
        lock_n = self._pick_lock
        win.ensure_visible()
        win.paint()
        try:
            win.canvas.focus_set()
        except tk.TclError:
            pass
        self.sample_active_pixel()
        win.warp_os_mouse()
        self.sample_active_pixel()
        self._arrow_stick = arrow_stick_after_nudge(True)

        def unlock(n=lock_n) -> None:
            if getattr(self, "_arrow_stick", False):
                return
            if getattr(self, "_pick_lock", 0) == n:
                self._pick_lock = 0

        self.after(200, unlock)
        return "break"

    def _current_find_params(self):
        pts = ordered_regs(self.regs)
        if not pts:
            return None
        try:
            self.sync_as_from_entries()
        except Exception:
            pass
        img_w = self.active_win.img.width if self.active_win else 0
        img_h = self.active_win.img.height if self.active_win else 0
        ax, ay, sx, sy = resolve_find_roi(
            self.reg_a[0], self.reg_a[1], self.reg_s[0], self.reg_s[1], pts, img_w, img_h
        )
        self.reg_a = (ax, ay)
        self.reg_s = (sx, sy)
        try:
            deg = int(self.degree.get())
        except Exception:
            deg = 90
        return pts, deg, ax, ay, sx, sy

    def test_on_device(self, idx: int = 3) -> None:
        """抄触动「<-测试」：把脚本打到手机跑，PC 面板不弹结果窗。"""
        ip = self.device_ip.get().strip()
        if not ip:
            self.status_set("连接或传输失败：未设置设备 IP（文件 → 连接设备）")
            return
        params = self._current_find_params()
        if not params:
            self.status_set("连接或传输失败：请先取色点再测试")
            return
        pts, deg, ax, ay, sx, sy = params
        main, offs = make_fmc_offs(pts)
        orient = int(self.device_orient.get())
        s1, s2, s3 = self._make_three_scripts(pts, deg, ax, ay, sx, sy)
        self.panel.set_outputs(s1, s2, s3)
        self.panel.write_as_entries()
        self.status_set("正在设备上测试找色（输出框 %d）…" % int(idx))

        def work() -> None:
            try:
                rep = self.dev.findtest(ip, orient, main, offs, deg, ax, ay, sx, sy)
                x = int(rep.get("x", -1))
                y = int(rep.get("y", -1))
                ok = bool(rep.get("ok")) and x >= 0 and y >= 0

                def done() -> None:
                    msg = "命中 x:%d, y:%d" % (x, y) if ok else "未找到 x:%d, y:%d" % (x, y)
                    self.status_set("测试结果: %s" % msg)

                self.after(0, done)
            except Exception as e:
                err = str(e)

                def fail() -> None:
                    self.status_set("连接或传输失败: " + err)

                self.after(0, fail)

        threading.Thread(target=work, daemon=True).start()

    def _make_three_scripts(self, pts, deg, ax, ay, sx, sy):
        img_w = self.active_win.img.width if self.active_win else 0
        img_h = self.active_win.img.height if self.active_win else 0
        pix = self.active_win.pix if self.active_win else None
        return make_scripts(
            self.fmt_name(),
            pts,
            ax,
            ay,
            sx,
            sy,
            degree=deg,
            setv=self.fmt_settings(),
            img_w=img_w,
            img_h=img_h,
            local_prefix=bool(self.local_prefix.get()),
            pix=pix,
            xc=self.reg_x,
            cc=self.reg_c,
        )

    def generate(self) -> None:
        try:
            params = self._current_find_params()
            if not params:
                messagebox.showwarning("生成", "请先取色")
                return
            pts, deg, ax, ay, sx, sy = params
            s1, s2, s3 = self._make_three_scripts(pts, deg, ax, ay, sx, sy)
            self.cached_scripts = [s1, s2, s3]
            self.panel.write_as_entries()
            self.panel.set_outputs(s1, s2, s3)
            self.panel.refresh_slots()
            self.copy_clipboard(s3)
            try:
                t2 = self.panel.out_lines[2]
                t2.focus_set()
                self.panel._select_all_text(t2)
            except Exception:
                pass
            self.status_set("已生成并复制 find 行 · ROI %d,%d,%d,%d" % (ax, ay, sx, sy))
        except Exception as e:
            messagebox.showerror("生成失败", str(e))


def _selftest_desktop() -> None:
    """自测只认 Desktop ios7/ios8p（ZiYanColorPicker 产出），禁止触动色参样例。"""
    import re

    assert APP_VER == "1.7.5"
    src = open(__file__, "r", encoding="utf-8").read()
    assert "sample_active_pixel" in src
    assert "moveMouseToXY" in src
    assert "class ColorPanel(tk.Toplevel)" in src
    assert "class ImageWindow(tk.Frame)" in src
    assert MAIN_TITLE in src
    assert "keep_panel_inside" in src
    assert "_checkerboard" in src
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


def _smoke_formats() -> None:
    """不依赖 Desktop lua：三路脚本与 FMC 合同。"""
    pts = [
        {"x": 10, "y": 20, "c": 0x112233},
        {"x": 15, "y": 28, "c": 0xAABBCC},
        {"x": 40, "y": 50, "c": 0x00FF00},
    ]
    fmc = make_fmc(pts)
    if '0x112233, "5|8|0xaabbcc,30|30|0x00ff00"' != fmc.lower():
        raise SystemExit("smoke FAIL fmc %s" % fmc)
    for name in FORMAT_NAMES:
        s1, s2, s3 = make_scripts(name, pts, 1, 2, 100, 200, degree=90)
        if "findMultiColorInRegionFuzzy" not in s3:
            raise SystemExit("smoke FAIL no fmc in box3 format=%s" % name)
        print("PASS format", name, "box1=%d box2=%d box3=%d" % (len(s1), len(s2), len(s3)))
    print("smoke ok", APP_VER)


def _arrow_key_selftest() -> None:
    """方向键必须改 坐标/颜色值（脚本框有焦点也要取到像素）。"""
    app = App()
    im = Image.new("RGB", (80, 60))
    px = im.load()
    for y in range(60):
        for x in range(80):
            px[x, y] = ((x * 3) % 256, (y * 4) % 256, (x + y) % 256)
    app.open_image_window(im, "arrow.png")
    app.update()
    win = app.active_win
    win.cursor = (10, 10)
    app.sample_active_pixel()
    app.update()
    x0, y0 = win.cursor
    xy0 = app.panel.lbl_xy.cget("text")
    col0 = app.panel.lbl_col.cget("text")
    app.panel.out_lines[0].focus_set()
    app.update()
    app.panel.out_lines[0].event_generate("<Right>")
    app.update()
    if win.cursor != (x0 + 1, y0):
        raise SystemExit("arrow FAIL cursor %s != (%d,%d)" % (win.cursor, x0 + 1, y0))
    xy1 = app.panel.lbl_xy.cget("text")
    col1 = app.panel.lbl_col.cget("text")
    if xy1 == xy0:
        raise SystemExit("arrow FAIL HUD xy not sampled: %s" % xy1)
    if col1 == col0:
        raise SystemExit("arrow FAIL HUD color not sampled: %s" % col1)
    app.panel.focus_set()
    app.update()
    app.panel.event_generate("<Down>")
    app.update()
    if win.cursor != (x0 + 1, y0 + 1):
        raise SystemExit("arrow FAIL panel-focus cursor %s" % (win.cursor,))
    print("arrow key sample ok", xy1, col1)
    app.destroy()


def _auto_test(img_path: str, outdir: str) -> None:
    os.makedirs(outdir, exist_ok=True)
    app = App()
    im = Image.open(img_path).convert("RGB")
    app.open_image_window(im, os.path.basename(img_path))
    w, h = im.size

    def go() -> None:
        pts_xy = ((w // 4, h // 4), (w // 2, h // 2), (3 * w // 4, 3 * h // 4))
        for i, xy in enumerate(pts_xy, 1):
            app.active_win.cursor = xy
            app.pick_to(i)
        app.generate()
        gen_path = os.path.join(outdir, "gen.txt")
        with open(gen_path, "w", encoding="utf-8") as f:
            f.write("FMT=%s\n" % app.fmt_name())
            f.write("TITLE_MAIN=%s\n" % app.title())
            f.write("TITLE_PANEL=%s\n" % app.panel.title())
            try:
                f.write("TITLE_IMG=%s\n" % app.active_win.title())
            except Exception:
                pass
            assert app.panel.title() == "取色面板"
            assert MAIN_TITLE in app.title()
            for i, s in enumerate(app.cached_scripts, 1):
                f.write("--- box%d ---\n%s\n" % (i, s))
        try:
            ImageGrab.grab(all_screens=True).save(os.path.join(outdir, "gui.png"))
        except Exception as e:
            with open(os.path.join(outdir, "grab_err.txt"), "w", encoding="utf-8") as f:
                f.write(str(e))
        print("AUTO_TEST_OK", gen_path)
        app.after(300, app.destroy)

    app.after(800, go)
    app.mainloop()


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] in ("--test", "-t"):
        _selftest_desktop()
        return
    if len(sys.argv) > 1 and sys.argv[1] in ("--smoke",):
        _smoke_formats()
        return
    if len(sys.argv) > 1 and sys.argv[1] in ("--arrow-test",):
        _arrow_key_selftest()
        return
    if len(sys.argv) > 2 and sys.argv[1] in ("--auto-test",):
        _auto_test(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else os.getcwd())
        return
    app = App()
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        app.open_image_window(Image.open(sys.argv[1]).convert("RGB"), os.path.basename(sys.argv[1]))
    app.mainloop()


if __name__ == "__main__":
    main()
