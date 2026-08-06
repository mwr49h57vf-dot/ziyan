#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
阶段8：自动维护 — 安全清理临时探针，保留核心源码/知识库/报告。
默认 dry-run；加 --apply 才删除。禁止动 lua/ziyan_engine、objc、media_seed 核心。
"""
from __future__ import annotations

import argparse
import json
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT / "tmp_shots"
LOG = TMP / "maintain_log.jsonl"

# 仅清理 tmp_shots 下一次性探针脚本名（保留 png/log/REPORT/知识库）
SAFE_PROBE_NAMES = {
    "_probe166.lua", "_probe53.lua", "_probe_ui.lua", "_ocr166.lua", "_ocr53.lua",
    "_shot.lua", "_toast166.lua", "_toast53.lua", "_try.lua", "_calib.lua",
    "_tapgrid.lua", "_touchcheck.lua", "_mianmi_snap.lua", "_auth166.lua",
    "_close.lua", "_drop.lua", "_exact.lua", "_reopen_mianmi.lua", "_verify_enter.lua",
    "_vo.lua", "_now.lua", "_after.lua", "_onetap.lua", "_paste.lua",
}

KEEP_ALWAYS = {
    "GAME_KNOWLEDGE.jsonl", "ERROR_DB.jsonl", "DEVICE_DB.json",
    "LEARNING_LOGIN_NOTES.md", "PHASE3_LOGIN_ONCE.txt",
    "rd_console_status.json", "rd_console_baseline.json",
    "forever_status.txt",
}


def candidates() -> list[Path]:
    found = []
    if not TMP.exists():
        return found
    for p in TMP.rglob("*"):
        if not p.is_file():
            continue
        if p.name in KEEP_ALWAYS:
            continue
        if p.name in SAFE_PROBE_NAMES:
            found.append(p)
            continue
        # 超大滚动日志：截断而非删除（在 apply 里处理）
    return sorted(found)


def trunc_scroll_log(apply: bool) -> dict:
    scroll = TMP / "rd_terminal_monitor.log"
    info = {"path": str(scroll.relative_to(ROOT)) if scroll.exists() else "", "action": "skip"}
    if not scroll.exists():
        return info
    size = scroll.stat().st_size
    info["size"] = size
    if size < 2_000_000:
        info["action"] = "keep_small"
        return info
    if apply:
        data = scroll.read_bytes()[-500_000:]
        scroll.write_bytes(data)
        info["action"] = "truncated_to_500KB"
    else:
        info["action"] = "would_truncate"
    return info


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="真正删除；默认只列出")
    args = ap.parse_args()
    TMP.mkdir(parents=True, exist_ok=True)

    cands = candidates()
    scroll = trunc_scroll_log(args.apply)
    deleted = []
    if args.apply:
        for p in cands:
            try:
                rel = str(p.relative_to(ROOT))
                p.unlink()
                deleted.append(rel)
            except OSError as e:
                deleted.append(f"FAIL {p}: {e}")

    row = {
        "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "epoch": int(time.time()),
        "apply": bool(args.apply),
        "candidate_count": len(cands),
        "candidates": [str(p.relative_to(ROOT)) for p in cands[:80]],
        "deleted": deleted,
        "scroll_log": scroll,
        "kept_rule": "core lua/objc/media_seed + knowledge/ERROR_DB/REPORT/DEVICE_DB",
    }
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")

    mode = "APPLY" if args.apply else "DRY-RUN"
    print(f"[{mode}] probe_scripts={len(cands)} deleted={len(deleted)} scroll={scroll}")
    for c in cands[:40]:
        print(" ", c.relative_to(ROOT))
    if len(cands) > 40:
        print(f"  ... +{len(cands) - 40} more")
    print("log →", LOG.relative_to(ROOT))


if __name__ == "__main__":
    main()
