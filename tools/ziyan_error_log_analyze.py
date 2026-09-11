#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""错误日志 → 代码定位 分析器（功能五：AI 自动分析真实设备错误）

职责（只做“定位 + 分组 + 修复建议”，不盲改代码）：
  1. 读取桌面 ziyan错误日志/<stamp>/*.json（或任意目录）
  2. 按 failure_pattern 分组（同一根因只算一次），避免同一错误反复修
  3. 用事件里的 script.path / message 栈帧定位到项目内源文件与行号
  4. 产出结构化报告：原因 / 项目 / 文件 / 模块 / 函数 / 代码位置 / 修复建议 / 尝试历史
  5. 记录尝试次数：同一 pattern 连续 3 次未修复 → 标 FAIL/BLOCKED（由调用方维护 attempts 文件）

用法：
  python3 tools/ziyan_error_log_analyze.py --logs ~/Desktop/ziyan错误日志/20260911_234150
  python3 tools/ziyan_error_log_analyze.py --logs <dir> --repo /Users/mac/Desktop/ZiYan_副本 --out report.json
"""
import argparse
import datetime
import json
import os
import re
import sys

STACK_RE = re.compile(r"([/\w\.\-]+\.lua):(\d+)")
MSG_LOC_RE = re.compile(r"([/\w\.\-]+\.lua):(\d+):\s*(.*)", re.S)
DEVICE_SCRIPT_RE = re.compile(r"/Media/ZiYan/(.+)$")


def load_events(logs_dir):
    events = []
    for root, _dirs, files in os.walk(logs_dir):
        for name in files:
            if not name.endswith(".json") or name.endswith(".tmp"):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception as exc:  # noqa: BLE001
                print("SKIP %s: %s" % (path, exc), file=sys.stderr)
                continue
            if isinstance(data, dict) and data.get("event_id"):
                data["_file"] = path
                events.append(data)
    return sorted(events, key=lambda e: e.get("time_unix", 0))


def pattern_key(ev):
    """failure_pattern：同类型 + 同脚本名 + 归一化后的错误文本（去数字/地址/路径前缀）"""
    msg = str(ev.get("message") or "")
    head = msg.split("\n")[0]
    norm = re.sub(r"\d+", "N", head)
    norm = re.sub(r"(/[^\s:]+)+", "<path>", norm)
    norm = norm[:160]
    script = (ev.get("script") or {}).get("name") or "?"
    return "%s|%s|%s" % (ev.get("type") or "?", script, norm)


def locate(ev, repo):
    """把设备上的脚本路径映射回仓库内路径，并提取行号"""
    script = (ev.get("script") or {}).get("path") or ""
    line = None
    text = str(ev.get("message") or "")
    m = MSG_LOC_RE.search(text)
    if m:
        line = int(m.group(2))
    candidates = []
    rel = None
    dm = DEVICE_SCRIPT_RE.search(script)
    if dm:
        rel = dm.group(1)
        candidates.append(os.path.join(repo, rel))
        candidates.append(os.path.join(repo, "media_seed", rel.replace("ZYCV/res/", "ZYCV/res/")))
    for c in candidates:
        if os.path.exists(c):
            return c, line, rel
    return (candidates[0] if candidates else script), line, rel


def module_of(path):
    parts = str(path).split(os.sep)
    for key in ("lua", "objc", "tools", "layout"):
        if key in parts:
            i = parts.index(key)
            tail = parts[i:]
            if key == "lua" and len(tail) > 2:
                return "/".join(tail[:3])
            return "/".join(tail[:2])
    return os.path.basename(str(path))


def suggest(ev, path, line, exc_from_file):
    """按错误类型给修复方向（不自动改代码；供 AI 修复环节使用）"""
    etype = ev.get("type")
    msg = str(ev.get("message") or "")
    tips = []
    if etype == "script_error":
        if "attempt to index a nil value" in msg:
            tips.append("业务脚本在第 %s 行访问了 nil 字段：先判空或检查前置状态初始化" % line)
        elif "attempt to call a nil value" in msg:
            tips.append("调用了未定义函数：核对函数名/模块加载顺序（package.path 是否包含该脚本目录）")
        elif "not enough memory" in msg:
            tips.append("内存不足：检查是否有大表/截图对象未释放")
        else:
            tips.append("按栈帧查看该行上下文；确认输入/状态是否满足前置条件")
    elif etype == "timeout":
        tips.append("脚本 30s 未 yield：检查死循环/阻塞调用；必要时给长循环加 mSleep 或分段")
    elif etype == "hang":
        tips.append("画面 300 轮无变化：确认游戏状态/前台应用是否正确；必要时重新进入目标页面")
    elif etype == "stop":
        tips.append("人为停止（音量键/控制面）：如非预期停止，检查是否误触或控制命令残留")
    elif etype == "abnormal_exit":
        tips.append("上次进程非正常结束：查看 crash 日志与系统 jetsam；确认是否被系统回收")
    elif etype == "sb_restart":
        tips.append("SpringBoard 重启：核对是否由注入/插件引起（安装日志、崩溃报告）")
    elif etype == "cold_start":
        tips.append("冷启动记录：正常生命周期事件，无需修复")
    if exc_from_file:
        tips.append("仓库定位: %s:%s" % (exc_from_file, line))
    return tips


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs", required=True, help="日志目录（桌面导出的 ziyan错误日志/<stamp>）")
    ap.add_argument("--repo", default="/Users/mac/Desktop/ZiYan_副本")
    ap.add_argument("--out", default=None)
    ap.add_argument("--max-attempts", type=int, default=3)
    args = ap.parse_args()

    events = load_events(os.path.expanduser(args.logs))
    if not events:
        print("NO_EVENTS in %s" % args.logs)
        return 2

    groups = {}
    for ev in events:
        key = pattern_key(ev)
        groups.setdefault(key, []).append(ev)

    report = {
        "generated_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "logs_dir": os.path.abspath(os.path.expanduser(args.logs)),
        "repo": args.repo,
        "total_events": len(events),
        "pattern_count": len(groups),
        "patterns": [],
    }

    for key, evs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        ev = evs[-1]  # 用最新一条做定位
        path, line, rel = locate(ev, args.repo)
        first_seen = min(e.get("time") or "" for e in evs)
        last_seen = max(e.get("time") or "" for e in evs)
        entry = {
            "pattern": key,
            "count": len(evs),
            "type": ev.get("type"),
            "first_seen": first_seen,
            "last_seen": last_seen,
            "devices": sorted({(e.get("device") or {}).get("model", "?") for e in evs}),
            "os": sorted({(e.get("device") or {}).get("os", "?") for e in evs}),
            "ziyan": sorted({(e.get("version") or {}).get("ziyan", "?") for e in evs}),
            "script": (ev.get("script") or {}).get("path"),
            "module": module_of(path),
            "file": path,
            "line": line,
            "message": str(ev.get("message") or "")[:400],
            "stack": str(ev.get("stack") or "")[:600],
            "sample_event": ev.get("event_id"),
            "fix_hints": suggest(ev, path, line, rel),
            "attempts": 0,
            "status": "OPEN",
        }
        if entry["attempts"] >= args.max_attempts:
            entry["status"] = "FAIL_BLOCKED"
        report["patterns"].append(entry)

    out_path = args.out or os.path.join(os.path.expanduser(args.logs), "ai_analysis.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)

    print("ANALYZED events=%d patterns=%d" % (report["total_events"], report["pattern_count"]))
    for p in report["patterns"]:
        print("PATTERN [%s] x%d type=%s file=%s:%s" % (p["type"], p["count"], p["type"], p["file"], p["line"]))
        for h in p["fix_hints"]:
            print("   → %s" % h)
    print("REPORT %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
