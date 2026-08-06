#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""子砚自动化研发状态控制台 — 实时窗口（真实采集，禁止虚构）。"""
from __future__ import annotations

import json
import sys
import threading
import traceback
from pathlib import Path
from typing import Any, Dict, Optional

import tkinter as tk
from tkinter import ttk

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from collect import OUT_JSON, collect  # noqa: E402

REFRESH_MS = 6000
TITLE = "子砚自动化研发状态控制台"

# 工业控制台配色（非紫、非奶油）
BG = "#0e1114"
PANEL = "#161b20"
FG = "#d7dde3"
MUTED = "#8b949e"
ACCENT = "#3d8bfd"
OK = "#3fb950"
WARN = "#d29922"
ERR = "#f85149"
LINE = "#2a323a"


class ConsoleApp:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title(TITLE)
        self.root.geometry("1180x820")
        self.root.configure(bg=BG)
        self.root.minsize(960, 640)

        self._busy = False
        self._data: Optional[Dict[str, Any]] = None
        self._err: str = ""

        self._build()
        self.root.after(200, self._tick)

    def _build(self) -> None:
        top = tk.Frame(self.root, bg=BG)
        top.pack(fill="x", padx=14, pady=(12, 6))

        tk.Label(
            top, text=TITLE, bg=BG, fg=FG,
            font=("PingFang SC", 18, "bold"),
        ).pack(side="left")

        self.lbl_clock = tk.Label(top, text="", bg=BG, fg=MUTED, font=("Menlo", 11))
        self.lbl_clock.pack(side="right")

        self.lbl_focus = tk.Label(
            self.root, text="采集中…", bg=BG, fg=ACCENT,
            font=("PingFang SC", 13), anchor="w",
        )
        self.lbl_focus.pack(fill="x", padx=14, pady=(0, 8))

        # cycle strip
        self.cycle_frame = tk.Frame(self.root, bg=BG)
        self.cycle_frame.pack(fill="x", padx=14, pady=(0, 8))
        self.cycle_labels = []

        body = tk.Frame(self.root, bg=BG)
        body.pack(fill="both", expand=True, padx=10, pady=(0, 10))

        # left / right panes via paned
        paned = tk.PanedWindow(body, orient="horizontal", bg=BG, sashwidth=4, bd=0)
        paned.pack(fill="both", expand=True)

        left = tk.Frame(paned, bg=BG)
        right = tk.Frame(paned, bg=BG)
        paned.add(left, minsize=520)
        paned.add(right, minsize=400)

        self.txt_left = self._make_text(left)
        self.txt_right = self._make_text(right)

        foot = tk.Frame(self.root, bg=BG)
        foot.pack(fill="x", padx=14, pady=(0, 10))
        self.lbl_foot = tk.Label(
            foot,
            text="数据源：工程文件 mtime · tmp_shots · 真机 SSH | 禁止虚构完成状态",
            bg=BG, fg=MUTED, font=("PingFang SC", 10), anchor="w",
        )
        self.lbl_foot.pack(fill="x")

        btn = tk.Button(
            foot, text="立即刷新", command=self._force_refresh,
            bg=PANEL, fg=FG, activebackground=LINE, activeforeground=FG,
            relief="flat", padx=12, pady=4, font=("PingFang SC", 11),
        )
        btn.pack(side="right")

    def _make_text(self, parent: tk.Widget) -> tk.Text:
        wrap = tk.Frame(parent, bg=PANEL, highlightthickness=1, highlightbackground=LINE)
        wrap.pack(fill="both", expand=True, padx=4, pady=4)
        txt = tk.Text(
            wrap, bg=PANEL, fg=FG, insertbackground=FG,
            relief="flat", wrap="word",
            font=("Menlo", 11), padx=10, pady=10,
            highlightthickness=0,
        )
        scr = ttk.Scrollbar(wrap, command=txt.yview)
        txt.configure(yscrollcommand=scr.set)
        scr.pack(side="right", fill="y")
        txt.pack(side="left", fill="both", expand=True)
        txt.tag_configure("h", foreground=ACCENT, font=("PingFang SC", 12, "bold"))
        txt.tag_configure("ok", foreground=OK)
        txt.tag_configure("warn", foreground=WARN)
        txt.tag_configure("err", foreground=ERR)
        txt.tag_configure("muted", foreground=MUTED)
        txt.configure(state="disabled")
        return txt

    def _set_text(self, widget: tk.Text, blocks: list) -> None:
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        for item in blocks:
            if isinstance(item, tuple):
                text, tag = item
                widget.insert("end", text, tag)
            else:
                widget.insert("end", item)
        widget.configure(state="disabled")

    def _force_refresh(self) -> None:
        if not self._busy:
            self._start_collect()

    def _tick(self) -> None:
        if not self._busy:
            self._start_collect()
        self.root.after(REFRESH_MS, self._tick)

    def _start_collect(self) -> None:
        self._busy = True
        self.lbl_clock.configure(text="刷新中…")

        def worker():
            err = ""
            data = None
            try:
                data = collect()
            except Exception:
                err = traceback.format_exc()
            self.root.after(0, lambda: self._on_data(data, err))

        threading.Thread(target=worker, daemon=True).start()

    def _on_data(self, data: Optional[Dict[str, Any]], err: str) -> None:
        self._busy = False
        self._err = err
        if data:
            self._data = data
            try:
                OUT_JSON.write_text(
                    json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
                )
            except Exception:
                pass
        self._render()

    def _render_cycle(self, focus: str) -> None:
        for w in self.cycle_frame.winfo_children():
            w.destroy()
        cycle = (self._data or {}).get("phase", {}).get("cycle") or []
        for i, name in enumerate(cycle):
            active = name == focus
            fg = ACCENT if active else MUTED
            bg = PANEL if active else BG
            tk.Label(
                self.cycle_frame, text=name, bg=bg, fg=fg,
                font=("PingFang SC", 10, "bold" if active else "normal"),
                padx=8, pady=4,
            ).pack(side="left", padx=2)
            if i < len(cycle) - 1:
                tk.Label(self.cycle_frame, text="→", bg=BG, fg=LINE).pack(side="left")

    def _render(self) -> None:
        if self._err and not self._data:
            self.lbl_focus.configure(text="采集失败", fg=ERR)
            self._set_text(self.txt_left, [("采集异常\n\n", "h"), (self._err, "err")])
            self._set_text(self.txt_right, [])
            self.lbl_clock.configure(text="")
            return

        d = self._data or {}
        gen = d.get("generated_at", "")
        focus = d.get("phase", {}).get("current_focus", "")
        self.lbl_clock.configure(text=f"更新 {gen} · 每 {REFRESH_MS // 1000}s")
        self.lbl_focus.configure(
            text=f"当前研发焦点 → {focus}    引擎 {d.get('engine_version', '?')}    设备 {d.get('device_host', '')}",
            fg=ACCENT,
        )
        self._render_cycle(focus)

        device = d.get("device") or {}
        left = []
        left.append(("【当前研发阶段】\n", "h"))
        for s in (d.get("phase") or {}).get("stages") or []:
            st = s.get("status")
            tag = "ok" if st == "done" else ("err" if st == "blocked" else "warn")
            left.append((f"  [{st}] {s.get('name')}\n", tag))
            left.append((f"         证据: {s.get('evidence')}\n", "muted"))
        left.append("\n")

        left.append(("【正在执行任务】\n", "h"))
        left.append((d.get("running_task", "") + "\n\n", "muted"))

        left.append(("【已完成任务】\n", "h"))
        done = d.get("completed_tasks") or []
        if done:
            for x in done:
                left.append((f"  · {x}\n", "ok"))
        else:
            left.append(("  （尚无带证据的完成项）\n", "muted"))
        left.append("\n")

        left.append(("【代码变化】（48h mtime，真实文件）\n", "h"))
        ch = d.get("code_changes") or []
        if not ch:
            left.append(("  无近 48h 改动文件\n", "muted"))
        for c in ch[:18]:
            left.append((f"  {c['mtime']}  {c['path']}\n", "muted"))
        left.append("\n")

        left.append(("【新增模块】\n", "h"))
        nm = d.get("new_modules") or []
        left.append((("  " + ", ".join(nm) + "\n") if nm else "  （相对基线无新增）\n", "ok" if nm else "muted"))
        left.append((f"  引擎模块总数: {len(d.get('modules') or [])}\n\n", "muted"))

        left.append(("【函数优化】（由真实改动文件映射）\n", "h"))
        for h in d.get("function_optimizations") or []:
            left.append((f"  · {h}\n", "muted"))
        left.append("\n")

        left.append(("【TouchSprite 学习结果】\n", "h"))
        ts = d.get("ts_learning") or {}
        left.append((f"  规则: {ts.get('rule')}\n", "muted"))
        left.append((f"  learning 模块: {ts.get('learning_module')} ({ts.get('learning_path')})\n", "muted"))
        left.append((f"  说明: {ts.get('note')}\n", "warn"))
        for doc in ts.get("docs") or []:
            left.append((f"  · {doc['file']} ({doc['bytes']}B)\n", "muted"))

        right = []
        right.append(("【真机运行状态】\n", "h"))
        if device.get("ssh_ok"):
            right.append(("  SSH: OK\n", "ok"))
        else:
            right.append(("  SSH: FAIL\n", "err"))
            if device.get("error"):
                right.append((f"  {device.get('error')}\n", "err"))
        right.append((f"  ping: {device.get('ping')}  host: {device.get('host')}\n", "muted"))
        right.append((f"  project_active: {device.get('project_active')}\n", "muted"))
        right.append((f"  sb_alive: {device.get('sb_alive')}\n", "muted"))
        right.append((f"  selftest_pass: {device.get('selftest_pass')}\n",
                      "ok" if str(device.get("selftest_pass")) == "1" else "warn"))
        right.append("\n")

        right.append(("【设备信息】\n", "h"))
        right.append((f"  {device.get('pkg') or '（无 dpkg 输出）'}\n", "muted"))
        right.append("\n")

        right.append(("【屏幕同步状态】\n", "h"))
        ss = d.get("screen_sync") or {}
        right.append((f"  ok={ss.get('ok')}\n", "ok" if ss.get("ok") else "warn"))
        right.append((f"  {ss.get('raw') or ss.get('note')}\n\n", "muted"))

        right.append(("【游戏测试状态】\n", "h"))
        gt = d.get("game_test") or {}
        right.append((f"  forever:\n{gt.get('forever_status') or '（无 forever_status）'}\n", "muted"))
        for ln in (gt.get("play_log_tail") or [])[-6:]:
            tag = "err" if "FAIL" in ln else "muted"
            right.append((f"  {ln}\n", tag))
        right.append("\n")

        right.append(("【进入角色状态】\n", "h"))
        role = d.get("role_enter") or {}
        tag = "err" if role.get("verdict") == "FAIL" else ("ok" if role.get("verdict") == "PASS" else "warn")
        right.append((f"  verdict={role.get('verdict')}  {role.get('role_enter')}\n", tag))
        if role.get("login_once_file"):
            right.append((f"  文件: {role.get('login_once_file')}\n", "muted"))
        right.append("\n")

        right.append(("【自动化脚本生成状态】\n", "h"))
        cg = d.get("codegen") or {}
        right.append((f"  {cg.get('status')}\n", "muted"))
        for s in (cg.get("scripts") or [])[:8]:
            right.append((f"  · {s['path']} @ {s['mtime']}\n", "muted"))
        right.append("\n")

        right.append(("【错误分析 / 问题列表】\n", "h"))
        probs = (d.get("errors") or {}).get("problems") or []
        if not probs:
            right.append(("  当前采集未发现带证据的问题项\n", "ok"))
        for p in probs:
            tag = "err" if p.get("level") == "error" else "warn"
            right.append((f"  [{p.get('level')}] {p.get('item')}\n", tag))
            right.append((f"         src: {p.get('src')}\n", "muted"))
        right.append("\n")

        right.append(("【修复进度】\n", "h"))
        fixes = d.get("fix_progress") or []
        if not fixes:
            right.append(("  （无带证据的修复项）\n", "muted"))
        for f in fixes:
            right.append((f"  · {f.get('item')}: {f.get('status')}\n", "ok"))
            right.append((f"    证据: {f.get('evidence')}\n", "muted"))
        right.append("\n")

        right.append(("【下一步计划】\n", "h"))
        for p in d.get("next_plans") or []:
            right.append((f"  → {p}\n", "warn"))

        if self._err:
            right.append(("\n【采集器异常】\n", "h"))
            right.append((self._err[:800] + "\n", "err"))

        self._set_text(self.txt_left, left)
        self._set_text(self.txt_right, right)

    def run(self) -> None:
        self.root.mainloop()


def main() -> None:
    ConsoleApp().run()


if __name__ == "__main__":
    main()
