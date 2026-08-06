#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""子砚研发状态采集 — 只读真实工程/日志/真机，禁止编造。"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT / "tmp_shots"
OUT_JSON = TMP / "rd_console_status.json"
BASELINE = TMP / "rd_console_baseline.json"
ENGINE = ROOT / "lua" / "ziyan_engine"
OBJC = ROOT / "objc"
MEDIA = ROOT / "media_seed"

DEVICE_HOST = os.environ.get("ZIYAN_RD_HOST", "192.168.31.53")
DEVICE_USER = os.environ.get("ZIYAN_RD_USER", "mobile")
DEVICE_PASS = os.environ.get("ZIYAN_RD_PASS", "alpine")
SSH_TIMEOUT = int(os.environ.get("ZIYAN_RD_SSH_TIMEOUT", "8"))

CYCLE = [
    "项目扫描",
    "架构分析",
    "模块开发",
    "代码测试",
    "真机运行",
    "游戏测试",
    "数据分析",
    "错误修复",
    "函数优化",
    "文档更新",
    "清理文件",
    "下一轮迭代",
]

# 架构门面 → 源文件（存在即 present；不宣称能力 PASS）
ARCH_MODULES = [
    ("Device", "device.lua"),
    ("Screen", "screen.lua"),
    ("Coordinate", "coordinate.lua"),
    ("ScreenSync", "screen_sync.lua"),
    ("Vision", "vision.lua"),
    ("Image", "cv.lua"),
    ("OCR", "py_cv.lua"),
    ("Touch", "touch.lua"),
    ("Verify", "verify.lua"),
    ("StateMachine", "state_machine.lua"),
    ("File", "io_fs.lua"),
    ("Network", "res_interop.lua"),
    ("Game", "game.lua"),
    ("Learning", "learning.lua"),
    ("ModulesAPI", "modules/init.lua"),
]


KNOWN_CORE_MODULES = {
    "app", "codec", "color", "control", "coordinate", "cv", "device", "game",
    "init", "io_fs", "learning", "orient", "py_cv", "res_interop", "screen",
    "toast", "touch", "ts_alias", "vision",
}


def now_iso() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def run(cmd: List[str], timeout: int = 20) -> Tuple[int, str]:
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, cwd=str(ROOT)
        )
        out = (p.stdout or "") + (("\n" + p.stderr) if p.stderr else "")
        return p.returncode, out.strip()
    except Exception as e:
        return 99, str(e)


def ssh(remote: str, timeout: int = SSH_TIMEOUT) -> Tuple[int, str]:
    cmd = [
        "sshpass", "-p", DEVICE_PASS,
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no",
        "-o", f"ConnectTimeout={timeout}",
        f"{DEVICE_USER}@{DEVICE_HOST}",
        remote,
    ]
    return run(cmd, timeout=timeout + 5)


def ping_host(host: str) -> bool:
    code, _ = run(["ping", "-c", "1", "-W", "2000", host], timeout=5)
    return code == 0


def read_text(path: Path, max_bytes: int = 200_000) -> str:
    try:
        data = path.read_bytes()[:max_bytes]
        return data.decode("utf-8", errors="replace")
    except Exception:
        return ""


def count_jsonl(path: Path) -> int:
    if not path.exists():
        return 0
    try:
        n = 0
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.strip():
                    n += 1
        return n
    except Exception:
        return 0


def arch_module_status() -> List[Dict[str, Any]]:
    """真实文件存在性；不宣称识别/点击成功率。"""
    rows = []
    for label, fname in ARCH_MODULES:
        p = ENGINE / fname
        row: Dict[str, Any] = {
            "name": label,
            "file": f"lua/ziyan_engine/{fname}",
            "present": p.exists(),
            "size": p.stat().st_size if p.exists() else 0,
            "mtime": datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
            if p.exists() else "",
            "status": "present" if p.exists() else "missing",
        }
        rows.append(row)
    return rows


def project_file_stats() -> Dict[str, Any]:
    """项目体积与临时探针目录计数（真实 du/find）。"""
    def du_kb(path: Path) -> int:
        code, out = run(["du", "-sk", str(path)], timeout=30)
        if code != 0:
            return -1
        try:
            return int(out.split()[0])
        except Exception:
            return -1

    probe_dirs = list(TMP.glob("PHASE3_*")) if TMP.exists() else []
    probe_luas = list(TMP.rglob("_*.lua")) if TMP.exists() else []
    reports = list(TMP.glob("REPORT_*.md")) if TMP.exists() else []
    return {
        "root_kb": du_kb(ROOT),
        "lua_kb": du_kb(ROOT / "lua"),
        "tmp_shots_kb": du_kb(TMP),
        "engine_lua_count": len(list(ENGINE.glob("*.lua"))) if ENGINE.exists() else 0,
        "phase3_probe_dirs": len([p for p in probe_dirs if p.is_dir()]),
        "tmp_underscore_lua": len([p for p in probe_luas if p.is_file()]),
        "report_count": len(reports),
        "knowledge_lines": count_jsonl(TMP / "GAME_KNOWLEDGE.jsonl"),
        "error_db_lines": count_jsonl(TMP / "ERROR_DB.jsonl"),
        "experiment_lines": count_jsonl(TMP / "experiments" / "experiment_log.jsonl"),
    }


def load_device_db() -> Dict[str, Any]:
    p = TMP / "DEVICE_DB.json"
    if not p.exists():
        return {"exists": False, "devices": []}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        data["exists"] = True
        data["path"] = str(p.relative_to(ROOT))
        return data
    except Exception as e:
        return {"exists": False, "error": str(e), "devices": []}


def game_state_machine_note(login: Dict[str, Any]) -> Dict[str, Any]:
    """游戏状态机进度：仅根据登录结论推断，禁止虚构进角。"""
    chain = [
        "启动", "登录识别", "服务器识别", "角色选择", "进入角色", "游戏主界面", "任务执行",
    ]
    verdict = login.get("verdict")
    if verdict == "PASS":
        reached = "进入角色"  # 仍需截图证据；此处仅表示文件宣称 PASS
        note = "PHASE3 文件含 PASS；进角仍须截图复核"
    elif verdict == "FAIL":
        reached = "登录识别"
        note = "卡在登录；服务器/选角/进角未验证"
    else:
        reached = "启动"
        note = "无有效 PHASE3 结论"
    return {
        "chain": chain,
        "reached": reached,
        "verdict": verdict,
        "note": note,
    }


def list_engine_modules() -> List[Dict[str, Any]]:
    mods = []
    if not ENGINE.is_dir():
        return mods
    for p in sorted(ENGINE.glob("*.lua")):
        st = p.stat()
        mods.append({
            "name": p.stem,
            "path": str(p.relative_to(ROOT)),
            "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
            "size": st.st_size,
            "is_new_vs_core": p.stem not in KNOWN_CORE_MODULES,
        })
    return mods


def recent_code_changes(hours: float = 48.0) -> List[Dict[str, Any]]:
    cutoff = time.time() - hours * 3600
    changes = []
    roots = [ENGINE, OBJC, MEDIA, ROOT / "tools"]
    exts = {".lua", ".m", ".h", ".sh", ".py", ".md"}
    for base in roots:
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if not p.is_file() or p.suffix.lower() not in exts:
                continue
            try:
                st = p.stat()
            except OSError:
                continue
            if st.st_mtime < cutoff:
                continue
            rel = str(p.relative_to(ROOT))
            if "/.theos/" in rel or "/vendor/" in rel:
                continue
            changes.append({
                "path": rel,
                "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                "size": st.st_size,
            })
    changes.sort(key=lambda x: x["mtime"], reverse=True)
    return changes[:80]


def load_or_init_baseline(mods: List[Dict[str, Any]]) -> Dict[str, Any]:
    if BASELINE.exists():
        try:
            return json.loads(BASELINE.read_text(encoding="utf-8"))
        except Exception:
            pass
    base = {
        "created": now_iso(),
        "modules": sorted(m["name"] for m in mods),
        "files": {m["path"]: m["mtime"] for m in mods},
    }
    TMP.mkdir(parents=True, exist_ok=True)
    BASELINE.write_text(json.dumps(base, ensure_ascii=False, indent=2), encoding="utf-8")
    return base


def new_modules_since_baseline(mods: List[Dict[str, Any]], baseline: Dict[str, Any]) -> List[str]:
    old = set(baseline.get("modules") or [])
    cur = {m["name"] for m in mods}
    # Also treat historically "new" architecture modules as highlighted if present
    highlight = sorted((cur - old) | ({"coordinate", "vision", "learning"} & cur))
    return highlight


def function_optimizations(changes: List[Dict[str, Any]]) -> List[str]:
    """基于真实近期改动文件推断优化点（不虚构函数名）。"""
    hints = []
    mapping = [
        ("ZiYanScreenBridge.m", "ScreenBridge：解锁门控 / pollUnlock 显式请求"),
        ("Tweak.m", "SpringBoard Home：homeHardwareButton singlePressUp"),
        ("device.lua", "device.unlock / project_active 协同"),
        ("ZiYanScriptRunner.m", "ScriptRunner：project_active 生命周期"),
        ("game.lua", "Game 状态机 / 登录路径"),
        ("coordinate.lua", "Coordinate 缩放与游戏区"),
        ("vision.lua", "Vision 门面"),
        ("learning.lua", "Learning 知识库"),
        ("touch.lua", "Touch / tap 时序"),
        ("screen.lua", "Screen 冻帧同步"),
    ]
    changed_paths = {c["path"] for c in changes}
    for key, desc in mapping:
        for p in changed_paths:
            if p.endswith(key) or key in p:
                hints.append(f"{desc} ← {p}")
                break
    if not hints and changes:
        for c in changes[:8]:
            hints.append(f"近期改动：{c['path']} @ {c['mtime']}")
    return hints


def detect_phase(device_ok: bool, problems: List[str], forever: str) -> Dict[str, Any]:
    """根据真实产物推断当前阶段（有证据才标完成）。"""
    stages = []

    def add(name: str, status: str, evidence: str):
        stages.append({"name": name, "status": status, "evidence": evidence})

    p0 = TMP / "PHASE0_TS_ARCHITECTURE.md"
    p1 = TMP / "PHASE1_ARCHITECTURE_REFRESH.md"
    p2 = TMP / "PHASE2_DSC_SMOKE.txt"
    p3 = TMP / "PHASE3_LOGIN_ONCE.txt"
    r4 = list(TMP.glob("REPORT_00*.md"))

    add("阶段0 TS架构分析", "done" if p0.exists() else "pending",
        str(p0.relative_to(ROOT)) if p0.exists() else "缺 PHASE0 文档")
    add("阶段1 架构刷新", "done" if p1.exists() else "pending",
        str(p1.relative_to(ROOT)) if p1.exists() else "缺 PHASE1 文档")
    add("阶段2 DSC/Vision", "done" if p2.exists() else "pending",
        str(p2.relative_to(ROOT)) if p2.exists() else "缺 DSC 冒烟记录")

    login_txt = read_text(p3) if p3.exists() else ""
    if p3.exists() and "FAIL" in login_txt:
        add("阶段3 登录进角", "blocked", "PHASE3_LOGIN_ONCE.txt → FAIL")
    elif p3.exists() and "PASS" in login_txt:
        add("阶段3 登录进角", "done", "PHASE3_LOGIN_ONCE.txt → PASS")
    else:
        add("阶段3 登录进角", "pending", "无有效登录结论")

    kb = TMP / "GAME_KNOWLEDGE.jsonl"
    errdb = TMP / "ERROR_DB.jsonl"
    explog = TMP / "experiments" / "experiment_log.jsonl"
    add("阶段4 游戏知识库", "done" if kb.exists() and kb.stat().st_size > 20 else "pending",
        f"GAME_KNOWLEDGE.jsonl lines≈{count_jsonl(kb)}" if kb.exists() else "缺知识库")
    add("阶段5 实验记录", "done" if explog.exists() else "pending",
        f"experiment_log.jsonl lines≈{count_jsonl(explog)}; ERROR_DB≈{count_jsonl(errdb)}")
    r7 = TMP / "REPORT_007_20260722_1525.md"
    add("阶段6 TS对照/长期优化", "active" if r7.exists() else "pending",
        "REPORT_007 + TS 观察设备；进角未 PASS 不宣称完成")
    mon = ROOT / "tools" / "ziyan_rd_console" / "terminal_monitor.py"
    add("阶段7 终端状态监控", "done" if mon.exists() else "pending",
        str(mon.relative_to(ROOT)) if mon.exists() else "缺 terminal_monitor")
    maint = ROOT / "tools" / "ziyan_rd_console" / "maintain.py"
    add("阶段8 自动维护", "done" if maint.exists() else "pending",
        str(maint.relative_to(ROOT)) if maint.exists() else "缺 maintain.py")
    learn = ROOT / "tools" / "ziyan_rd_console" / "learn_optimize.py"
    add("阶段9 自主优化学习", "done" if learn.exists() else "pending",
        str(learn.relative_to(ROOT)) if learn.exists() else "缺 learn_optimize.py")

    add("进度报告机制", "done" if r4 else "pending",
        f"REPORT 数={len(r4)}" if r4 else "无 REPORT_*")

    # current focus — 有证据才指向错误修复/游戏测试
    current = "项目扫描"
    if not device_ok:
        current = "真机运行"
    elif any("登录" in p or "login" in p.lower() or "FAIL" in p for p in problems):
        current = "错误修复"
    elif "lan_play=ERR" in forever or "usb_play=ERR" in forever:
        current = "游戏测试"
    elif p3.exists() and "FAIL" in login_txt:
        current = "错误修复"
    else:
        current = "下一轮迭代"

    done_n = sum(1 for s in stages if s["status"] == "done")
    blocked_n = sum(1 for s in stages if s["status"] == "blocked")
    return {
        "stages": stages,
        "current_focus": current,
        "cycle": CYCLE,
        "completion": {
            "done": done_n,
            "blocked": blocked_n,
            "total": len(stages),
            "ratio_note": f"{done_n}/{len(stages)} done（blocked={blocked_n}；非虚构百分比）",
        },
    }


def collect_ts_learning() -> Dict[str, Any]:
    docs = []
    for name in [
        "PHASE0_TS_ARCHITECTURE.md",
        "PHASE1_TS_HABITS_REDESIGN.md",
        "PHASE0_TS_RAW.txt",
    ]:
        p = TMP / name
        if p.exists():
            body = read_text(p, 8000)
            docs.append({
                "file": str(p.relative_to(ROOT)),
                "bytes": p.stat().st_size,
                "preview": body[:400].replace("\n", " ").strip(),
            })
    learning = ENGINE / "learning.lua"
    return {
        "docs": docs,
        "learning_module": learning.exists(),
        "learning_path": str(learning.relative_to(ROOT)) if learning.exists() else "",
        "rule": "只学 TS 习惯；禁止调用/复制 TS API（工程约定）",
        "note": "无 .171/.149 在线抓取结果则不声称已学完",
    }


def collect_device() -> Dict[str, Any]:
    reachable = ping_host(DEVICE_HOST)
    info: Dict[str, Any] = {
        "host": DEVICE_HOST,
        "ping": reachable,
        "ssh_ok": False,
        "pkg": "",
        "sb_alive": "",
        "project_active": "none",
        "selftest_pass": "",
        "screen_info": "",
        "lua_procs": [],
        "minimize_tail": [],
        "play_log_tail": [],
        "selftest_tail": [],
        "error": "",
    }
    if not reachable:
        info["error"] = "ping 失败：设备不可达"
        return info

    remote = r"""
VAR=/var/jb/usr/lib/ziyan/var
Z=/var/jb/usr/lib/ziyan
echo __PKG__
dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n '/com.ziyan.ziyan/p'
echo __SB__
cat "$VAR/.ziyan_sb_alive" 2>/dev/null || echo missing
echo __ACTIVE__
cat "$VAR/.ziyan_project_active" 2>/dev/null || echo none
echo __PASS__
cat "$VAR/.ziyan_selftest_pass" 2>/dev/null || echo 0
echo __SCREEN__
cat "$VAR/.ziyan_screen_info" 2>/dev/null | tr '\n' ' '
echo
echo __PROCS__
ps aux 2>/dev/null | grep -E 'ziyan_run|lua5.3' | grep -v grep | head -8
echo __MIN__
tail -8 "$VAR/.ziyan_minimize_log" 2>/dev/null
echo __PLAY__
tail -12 "$VAR/.ziyan_game_play_log.txt" 2>/dev/null
echo __STEST__
tail -8 "$VAR/.ziyan_selftest_report.txt" 2>/dev/null
echo __END__
"""
    code, out = ssh(remote)
    if code != 0 or "__PKG__" not in out:
        info["error"] = f"ssh 失败 rc={code}: {out[:300]}"
        return info
    info["ssh_ok"] = True

    def section(key: str, nxt: str) -> str:
        a = out.find(key)
        b = out.find(nxt)
        if a < 0:
            return ""
        a += len(key)
        if b < 0:
            b = len(out)
        return out[a:b].strip()

    info["pkg"] = section("__PKG__", "__SB__")
    info["sb_alive"] = section("__SB__", "__ACTIVE__")
    info["project_active"] = section("__ACTIVE__", "__PASS__")
    info["selftest_pass"] = section("__PASS__", "__SCREEN__")
    info["screen_info"] = section("__SCREEN__", "__PROCS__")
    procs = section("__PROCS__", "__MIN__")
    info["lua_procs"] = [ln for ln in procs.splitlines() if ln.strip()][:8]
    info["minimize_tail"] = section("__MIN__", "__PLAY__").splitlines()[-8:]
    info["play_log_tail"] = section("__PLAY__", "__STEST__").splitlines()[-12:]
    info["selftest_tail"] = section("__STEST__", "__END__").splitlines()[-8:]
    return info


def collect_game_login() -> Dict[str, Any]:
    p3 = TMP / "PHASE3_LOGIN_ONCE.txt"
    probe = TMP / "PHASE3_PHASE_PROBE.txt"
    body = read_text(p3) if p3.exists() else ""
    verdict = "unknown"
    if "FAIL" in body:
        verdict = "FAIL"
    elif body and "PASS" in body:
        verdict = "PASS"
    elif not p3.exists():
        verdict = "no_record"
    return {
        "login_once_file": str(p3.relative_to(ROOT)) if p3.exists() else "",
        "verdict": verdict,
        "tail": body[-1200:] if body else "",
        "phase_probe_exists": probe.exists(),
        "role_enter": "未进入角色" if verdict == "FAIL" else (
            "有 PASS 记录" if verdict == "PASS" else "无结论"
        ),
    }


def collect_codegen() -> Dict[str, Any]:
    candidates = []
    for pat in ["**/_zy_auto_gen*.lua", "**/_zy_game_play*.lua", "**/*codegen*"]:
        for p in ROOT.glob(pat):
            if p.is_file() and ".theos" not in str(p):
                candidates.append({
                    "path": str(p.relative_to(ROOT)),
                    "mtime": datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                    "size": p.stat().st_size,
                })
    # media_seed forever play
    forever = MEDIA / "_zy_game_play_forever.lua"
    return {
        "scripts": sorted(candidates, key=lambda x: x["mtime"], reverse=True)[:20],
        "forever_play_seed": forever.exists(),
        "status": "有生成/种子脚本" if candidates or forever.exists() else "未见自动生成脚本文件",
    }


def extract_problems(device: Dict[str, Any], forever: str, login: Dict[str, Any]) -> List[Dict[str, str]]:
    probs = []
    # ping 失败但 SSH 成功时常见（ICMP 被拦）→ 不报 error
    if not device.get("ssh_ok"):
        if not device.get("ping"):
            probs.append({"level": "error", "item": "设备 ping+ssh 均失败", "src": DEVICE_HOST})
        else:
            probs.append({"level": "error", "item": "SSH 失败", "src": device.get("error", "")[:200]})
    if "usb_play=ERR" in forever:
        probs.append({"level": "warn", "item": "forever usb_play=ERR", "src": "tmp_shots/forever_status.txt"})
    if "lan_play=ERR" in forever:
        probs.append({"level": "warn", "item": "forever lan_play=ERR", "src": "tmp_shots/forever_status.txt"})
    if login.get("verdict") == "FAIL":
        probs.append({"level": "error", "item": "登录进角 FAIL（仍 login）", "src": "PHASE3_LOGIN_ONCE.txt"})
    for ln in device.get("play_log_tail") or []:
        if "FAIL" in ln or "error" in ln.lower():
            probs.append({"level": "warn", "item": ln[:160], "src": "device:.ziyan_game_play_log.txt"})
    # dedupe
    seen = set()
    out = []
    for p in probs:
        k = p["item"]
        if k in seen:
            continue
        seen.add(k)
        out.append(p)
    return out[:30]


def fix_progress(device: Dict[str, Any], changes: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    """仅列出有真实证据的修复项。"""
    items = []
    paths = " ".join(c["path"] for c in changes)
    if "Tweak.m" in paths:
        items.append({
            "item": "Home 键 singlePressUp",
            "evidence": "objc/.../Tweak.m 今日改动；历史 minimize 日志含 singlePressUp",
            "status": "已合入源码" + (
                "；真机日志可见" if any("singlePressUp" in x for x in (device.get("minimize_tail") or []))
                else "；本轮日志未再触发则不宣称验收"
            ),
        })
    if "ZiYanScreenBridge.m" in paths or "device.lua" in paths:
        st = device.get("selftest_tail") or []
        passed = device.get("selftest_pass") == "1" or any("PASS" in x for x in st)
        items.append({
            "item": "显式 unlock_req 不再被 project_active 丢弃",
            "evidence": "ZiYanScreenBridge.m / device.lua 改动",
            "status": "自测 PASS=1" if passed else "源码已改；等待本轮自测证据",
        })
    if device.get("selftest_pass") == "1":
        items.append({
            "item": "iOS16 三项自测",
            "evidence": "设备 .ziyan_selftest_pass=1 + report",
            "status": "PASS",
        })
    return items


def next_plans(problems: List[Dict[str, str]], login: Dict[str, Any]) -> List[str]:
    plans = []
    if login.get("verdict") == "FAIL":
        plans.append("阻塞：登录进角 FAIL — 拔刀缺密/免密无响应；仙侠金钮压暗仍 login（见 REPORT_007）")
        plans.append("优先复核 Device/Screen/Coordinate/OCR/Image；再迭代登录凭证或免密路径")
    if any("lan_play=ERR" in p["item"] or "usb_play=ERR" in p["item"] for p in problems):
        plans.append("排查 forever_iterate play ERR（进程/脚本/设备路径）")
    if not plans:
        plans.append("保持控制台采集；有真实改动再推进下一阶段")
    plans.append("维护：maintain.py 清理探针脚本；保留知识库/ERROR_DB/REPORT")
    plans.append("遵守：未启动项目不对系统空闲解锁；显式 unlock_req 可用；禁止虚构 PASS")
    return plans


def infer_running_task(device: Dict[str, Any], forever: str) -> str:
    procs = device.get("lua_procs") or []
    if procs:
        return "真机脚本进程：\n" + "\n".join(procs[:4])
    if forever.strip():
        return f"forever_status：{forever.strip().splitlines()[0]}"
    if device.get("ssh_ok"):
        return "无 ziyan_run 进程；设备在线空闲（未宣称正在自测）"
    return "采集器运行中 / 设备未连接"


def completed_tasks(phase: Dict[str, Any], device: Dict[str, Any]) -> List[str]:
    done = []
    for s in phase.get("stages") or []:
        if s.get("status") == "done":
            done.append(f"{s['name']}（{s['evidence']}）")
    if device.get("selftest_pass") == "1":
        done.append("设备自测标记 .ziyan_selftest_pass=1")
    # package
    if device.get("pkg"):
        done.append(f"真机包：{device['pkg'][:80]}")
    return done


def collect() -> Dict[str, Any]:
    TMP.mkdir(parents=True, exist_ok=True)
    mods = list_engine_modules()
    baseline = load_or_init_baseline(mods)
    changes = recent_code_changes(48)
    forever = read_text(TMP / "forever_status.txt")
    device = collect_device()
    login = collect_game_login()
    problems = extract_problems(device, forever, login)
    phase = detect_phase(device.get("ssh_ok", False), [p["item"] for p in problems], forever)
    ts = collect_ts_learning()
    codegen = collect_codegen()
    fixes = fix_progress(device, changes)
    plans = next_plans(problems, login)
    opts = function_optimizations(changes)
    new_mods = new_modules_since_baseline(mods, baseline)

    # screen sync status from real screen_info
    screen = device.get("screen_info") or ""
    screen_sync = {
        "raw": screen,
        "ok": bool(screen) and ("logic=" in screen or "logicBuf=" in screen),
        "note": "来自设备 .ziyan_screen_info；空则未同步/无记录",
    }

    engine_ver = ""
    init_body = read_text(ENGINE / "init.lua", 5000)
    m = re.search(r'version\s*=\s*"([^"]+)"', init_body)
    if m:
        engine_ver = m.group(1)

    payload = {
        "generated_at": now_iso(),
        "root": str(ROOT),
        "device_host": DEVICE_HOST,
        "engine_version": engine_ver,
        "phase": phase,
        "project": {
            "completion": phase.get("completion") or {},
            "blocked": [s for s in (phase.get("stages") or []) if s.get("status") == "blocked"],
            "file_stats": project_file_stats(),
        },
        "architecture": {
            "pipeline": "Device→Screen→Coordinate→Vision→Image→OCR→Touch→File→Network→Game→Learning",
            "modules": arch_module_status(),
        },
        "running_task": infer_running_task(device, forever),
        "completed_tasks": completed_tasks(phase, device),
        "code_changes": changes,
        "new_modules": new_mods,
        "modules": mods,
        "function_optimizations": opts,
        "ts_learning": ts,
        "device_db": load_device_db(),
        "device": device,
        "screen_sync": screen_sync,
        "game_test": {
            "forever_status": forever.strip(),
            "play_log_tail": device.get("play_log_tail") or [],
            "state_machine": game_state_machine_note(login),
        },
        "role_enter": login,
        "codegen": codegen,
        "knowledge": {
            "game_knowledge_lines": count_jsonl(TMP / "GAME_KNOWLEDGE.jsonl"),
            "error_db_lines": count_jsonl(TMP / "ERROR_DB.jsonl"),
            "experiment_lines": count_jsonl(TMP / "experiments" / "experiment_log.jsonl"),
            "learning_notes": str((TMP / "LEARNING_LOGIN_NOTES.md").relative_to(ROOT))
            if (TMP / "LEARNING_LOGIN_NOTES.md").exists() else "",
        },
        "errors": {
            "problems": problems,
            "device_error": device.get("error") or "",
            "selftest_tail": device.get("selftest_tail") or [],
            "minimize_tail": device.get("minimize_tail") or [],
        },
        "fix_progress": fixes,
        "next_plans": plans,
        "integrity": {
            "fabricated": False,
            "sources": [
                "lua/ziyan_engine/* mtime",
                "objc/* mtime",
                "tmp_shots/PHASE*/REPORT*/forever_status/DEVICE_DB/GAME_KNOWLEDGE/ERROR_DB",
                f"ssh {DEVICE_USER}@{DEVICE_HOST}",
            ],
        },
    }
    OUT_JSON.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


if __name__ == "__main__":
    data = collect()
    print(json.dumps({
        "generated_at": data["generated_at"],
        "focus": data["phase"]["current_focus"],
        "ssh_ok": data["device"]["ssh_ok"],
        "problems": len(data["errors"]["problems"]),
        "changes": len(data["code_changes"]),
        "out": str(OUT_JSON),
    }, ensure_ascii=False, indent=2))
