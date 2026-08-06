#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
子砚自动化研发终端状态监控系统
————————————————————————————
终端实时滚动刷新：研发状态 / 学习 / 代码变化 / 模块 / 真机 / 问题 / 计划
数据来自 collect.py + 多机 SSH，禁止编造。
停止：tmp_shots/STOP_ITERATE 或 停止迭代
"""
from __future__ import annotations

import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TMP = ROOT / "tmp_shots"
sys.path.insert(0, str(HERE))

from collect import (  # noqa: E402
    OUT_JSON,
    collect,
    ping_host,
    run,
    ssh as ssh_one,
)

STOP1 = TMP / "STOP_ITERATE"
STOP2 = TMP / "停止迭代"
SCROLL_LOG = TMP / "rd_terminal_monitor.log"
INTERVAL = float(os.environ.get("ZIYAN_RD_TERM_INTERVAL", "8"))

DEVICES = [
    {"tag": "53", "host": "192.168.31.53", "user": "mobile", "role": "子砚真机"},
    {"tag": "166", "host": "192.168.31.166", "user": "root", "role": "子砚真机"},
    {"tag": "171", "host": "192.168.31.171", "user": "root", "role": "TS参考"},
    {"tag": "149", "host": "192.168.31.149", "user": "root", "role": "TS参考"},
]


def stopped() -> bool:
    return STOP1.exists() or STOP2.exists()


def ssh_to(user: str, host: str, remote: str, timeout: int = 6) -> tuple[int, str]:
    cmd = [
        "sshpass", "-p", os.environ.get("ZIYAN_RD_PASS", "alpine"),
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no",
        "-o", f"ConnectTimeout={timeout}",
        f"{user}@{host}",
        remote,
    ]
    return run(cmd, timeout=timeout + 4)


def probe_devices() -> List[Dict[str, Any]]:
    rows = []
    for d in DEVICES:
        row: Dict[str, Any] = {
            "tag": d["tag"], "host": d["host"], "role": d["role"],
            "ping": ping_host(d["host"]), "ssh": False, "detail": "",
        }
        if not row["ping"]:
            row["detail"] = "ping fail"
            rows.append(row)
            continue
        if d["role"].startswith("TS"):
            code, out = ssh_to(
                d["user"], d["host"],
                "ps -A -o command 2>/dev/null | grep TSDaemon | grep -v grep | head -1; "
                "cat /var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null; "
                "cat /var/mobile/Media/TouchSprite/config/screen.cfg 2>/dev/null",
            )
            row["ssh"] = code == 0
            row["detail"] = (out or "").replace("\n", " | ")[:180]
        else:
            code, out = ssh_to(
                d["user"], d["host"],
                "VAR=/var/jb/usr/lib/ziyan/var; test -d $VAR || VAR=/usr/lib/ziyan/var; "
                "echo PKG=$(dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n '/com.ziyan.ziyan/p'); "
                "echo SB=$(cat $VAR/.ziyan_sb_alive 2>/dev/null); "
                "echo PASS=$(cat $VAR/.ziyan_selftest_pass 2>/dev/null); "
                "echo ACTIVE=$(cat $VAR/.ziyan_project_active 2>/dev/null || echo none); "
                "echo SCREEN=$(cat $VAR/.ziyan_screen_info 2>/dev/null | tr '\\n' ' '); "
                "echo LOGIN=$(cat $VAR/.ziyan_login_once.txt 2>/dev/null | tr '\\n' ' ')",
            )
            row["ssh"] = code == 0 and "PKG=" in (out or "")
            row["detail"] = (out or "").replace("\n", " | ")[:220]
        rows.append(row)
    return rows


def line(s: str = "") -> None:
    print(s, flush=True)


def sep(title: str) -> None:
    line("")
    line("=" * 72)
    line(f"  {title}")
    line("=" * 72)


def section(title: str) -> None:
    line("")
    line(f"── {title} ──")


def render(data: Dict[str, Any], devices: List[Dict[str, Any]], round_n: int) -> str:
    """Build text block; print + return for log append."""
    buf: List[str] = []

    def p(s: str = "") -> None:
        buf.append(s)
        print(s, flush=True)

    p("")
    p("#" * 72)
    p(f"# 子砚自动化研发终端状态监控  round={round_n}  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    p("#" * 72)

    phase = data.get("phase") or {}
    proj = data.get("project") or {}
    comp = proj.get("completion") or phase.get("completion") or {}
    p(f"当前焦点 → {phase.get('current_focus', '?')}    引擎 {data.get('engine_version', '?')}")
    p(f"完成比例 → {comp.get('ratio_note', '?')}（仅统计有证据阶段，禁止虚构%）")
    cycle = phase.get("cycle") or []
    focus = phase.get("current_focus") or ""
    if cycle:
        bits = []
        for n in cycle:
            bits.append(f"[{n}]" if n == focus else n)
        p("循环: " + " → ".join(bits))

    section("研发阶段（有证据才 done / blocked）")
    for s in phase.get("stages") or []:
        p(f"  [{s.get('status')}] {s.get('name')}  |  {s.get('evidence')}")

    section("正在执行 / 已完成 / 阻塞")
    p(str(data.get("running_task") or "").rstrip())
    for x in data.get("completed_tasks") or []:
        p(f"  ✓ {x}")
    for b in (proj.get("blocked") or []):
        p(f"  ✗ BLOCKED {b.get('name')} | {b.get('evidence')}")

    section("架构模块（文件存在=present，不宣称能力 PASS）")
    arch = data.get("architecture") or {}
    p(f"  管道: {arch.get('pipeline', '')}")
    for m in arch.get("modules") or []:
        flag = "OK" if m.get("present") else "MISS"
        p(f"  [{flag}] {m.get('name'):12} {m.get('file')}  {m.get('size')}B  {m.get('mtime')}")

    section("代码变化（48h 真实 mtime）")
    ch = data.get("code_changes") or []
    if not ch:
        p("  （无）")
    for c in ch[:12]:
        p(f"  {c.get('mtime')}  {c.get('path')}")

    section("新增模块 / 函数优化")
    nm = data.get("new_modules") or []
    p(f"  模块高亮: {', '.join(nm) if nm else '（相对基线无新增名）'}  引擎文件数={len(data.get('modules') or [])}")
    for h in (data.get("function_optimizations") or [])[:8]:
        p(f"  · {h}")

    section("TouchSprite 学习（只习惯，不抄 API）")
    ts = data.get("ts_learning") or {}
    p(f"  {ts.get('rule')}")
    p(f"  learning.lua 存在={ts.get('learning_module')}  path={ts.get('learning_path')}")
    for doc in (ts.get("docs") or [])[:4]:
        p(f"  · {doc.get('file')} ({doc.get('bytes')}B)")

    section("设备库 DEVICE_DB + 四机在线")
    ddb = data.get("device_db") or {}
    if ddb.get("exists"):
        p(f"  DB={ddb.get('path')} updated={ddb.get('updated')}")
        for d in (ddb.get("devices") or [])[:4]:
            p(f"  · {d.get('ip')} role={d.get('role')} logic={d.get('logic') or d.get('screen_cfg')} "
              f"dpi={d.get('dpi','?')} pkg={d.get('pkg') or d.get('run') or ''}")
    else:
        p("  DEVICE_DB 缺失或不可读")
    for d in devices:
        flag = "OK" if d.get("ssh") else ("PING" if d.get("ping") else "DOWN")
        p(f"  .{d['tag']} [{d['role']}] {flag}  {d.get('detail', '')[:160]}")

    section("屏幕同步 / 游戏状态机 / 进角")
    ss = data.get("screen_sync") or {}
    p(f"  screen_sync ok={ss.get('ok')}  {ss.get('raw') or ss.get('note')}")
    gt = data.get("game_test") or {}
    sm = gt.get("state_machine") or {}
    if sm:
        p(f"  状态机到达: {sm.get('reached')}  verdict={sm.get('verdict')}  | {sm.get('note')}")
        p(f"  链: {' → '.join(sm.get('chain') or [])}")
    fs = (gt.get("forever_status") or "").strip().replace("\n", " | ")
    p(f"  forever: {fs or '（无 forever_status / 已停）'}")
    role = data.get("role_enter") or {}
    p(f"  进角/登录: verdict={role.get('verdict')}  {role.get('role_enter')}  file={role.get('login_once_file')}")

    section("知识库 / 错误库 / 实验")
    kb = data.get("knowledge") or {}
    p(f"  GAME_KNOWLEDGE={kb.get('game_knowledge_lines')}  ERROR_DB={kb.get('error_db_lines')}  "
      f"experiments={kb.get('experiment_lines')}  notes={kb.get('learning_notes')}")

    section("自动化脚本生成")
    cg = data.get("codegen") or {}
    p(f"  {cg.get('status')}")
    for s in (cg.get("scripts") or [])[:5]:
        p(f"  · {s.get('path')} @ {s.get('mtime')}")

    section("文件 / 体积")
    fs2 = (proj.get("file_stats") or {})
    p(f"  root={fs2.get('root_kb')}KB lua={fs2.get('lua_kb')}KB tmp_shots={fs2.get('tmp_shots_kb')}KB "
      f"engine_lua={fs2.get('engine_lua_count')} PHASE3目录={fs2.get('phase3_probe_dirs')} "
      f"_*.lua探针={fs2.get('tmp_underscore_lua')}")

    section("问题 / 错误 / 修复进度")
    probs = (data.get("errors") or {}).get("problems") or []
    if not probs:
        p("  （本轮采集无带证据问题项）")
    for pr in probs:
        p(f"  ! [{pr.get('level')}] {pr.get('item')}  src={pr.get('src')}")
    for fx in data.get("fix_progress") or []:
        p(f"  fix: {fx.get('item')} → {fx.get('status')}")

    section("下一步计划")
    for n in data.get("next_plans") or []:
        p(f"  → {n}")

    p("")
    p(f"（integrity fabricated={ (data.get('integrity') or {}).get('fabricated')}  json={OUT_JSON}）")
    p("按【停止迭代】或写入 tmp_shots/STOP_ITERATE 结束监控循环")
    return "\n".join(buf) + "\n"


def main() -> None:
    TMP.mkdir(parents=True, exist_ok=True)
    round_n = 0
    line(f"[ZiYan] 终端状态监控启动 interval={INTERVAL}s root={ROOT}")
    while True:
        if stopped():
            line("[ZiYan] 检测到 STOP → 退出终端监控")
            break
        round_n += 1
        try:
            data = collect()
        except Exception as e:
            data = {
                "phase": {"current_focus": "采集异常", "stages": [], "cycle": []},
                "running_task": str(e),
                "completed_tasks": [],
                "code_changes": [],
                "new_modules": [],
                "modules": [],
                "function_optimizations": [],
                "ts_learning": {},
                "screen_sync": {},
                "game_test": {},
                "role_enter": {},
                "codegen": {},
                "errors": {"problems": [{"level": "error", "item": str(e), "src": "terminal_monitor"}]},
                "fix_progress": [],
                "next_plans": ["修复采集器"],
                "integrity": {"fabricated": False},
                "engine_version": "?",
            }
        try:
            devices = probe_devices()
        except Exception as e:
            devices = [{"tag": "?", "role": "err", "ping": False, "ssh": False, "detail": str(e)}]
        # attach multi-device into json for web console consumers
        try:
            data["devices_quad"] = devices
            OUT_JSON.write_text(
                __import__("json").dumps(data, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            pass
        block = render(data, devices, round_n)
        try:
            with SCROLL_LOG.open("a", encoding="utf-8") as f:
                f.write(block)
                f.write("\n")
        except Exception:
            pass
        # sleep in slices to react to STOP quickly
        left = INTERVAL
        while left > 0:
            if stopped():
                line("[ZiYan] 检测到 STOP → 退出终端监控")
                return
            step = min(1.0, left)
            time.sleep(step)
            left -= step


if __name__ == "__main__":
    main()
