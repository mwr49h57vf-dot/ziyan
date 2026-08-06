#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""实时刷新 mmbert + TS spider 进度到 LIVE_PROGRESS.md，并打印到 stdout。"""
from __future__ import annotations

import json
import subprocess
import time
from datetime import datetime
from pathlib import Path

OUT = Path("/Users/mac/Desktop/ZiYan_副本/tmp_shots/PHASE763R8")
LIVE = OUT / "LIVE_PROGRESS.md"
HIST = OUT / "LIVE_PROGRESS_HISTORY.log"
MM = Path(
    "/Users/mac/Desktop/ZiYan_副本/vendor/hf_models/"
    "llm-semantic-router__mmbert-jailbreak-detector-merged/model.safetensors"
)
EXP = 1230141424
FN = OUT / "ts_docs_archive" / "functions.jsonl"
SPLOG = OUT / "ts_docs_archive" / "spider.log"
CKPT = OUT / "ts_docs_archive" / "checkpoint.json"
SPIDER = Path("/Users/mac/Desktop/ZiYan_副本/tools/doc_spider/ts_helpdoc_spider.py")
MM_SCRIPT = Path("/tmp/ziyan_dl_mmbert.py")


def alive(pat: str) -> bool:
    r = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True)
    return r.returncode == 0 and bool(r.stdout.strip())


def revive() -> None:
    sz = MM.stat().st_size if MM.exists() else 0
    if sz < EXP and not alive("ziyan_dl_mmbert.py") and MM_SCRIPT.exists():
        subprocess.Popen(
            ["python3", str(MM_SCRIPT)],
            stdout=open(OUT / "hf_py_mmbert_outer.log", "a"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    done = False
    if SPLOG.exists():
        done = "DONE pages=" in SPLOG.read_text(encoding="utf-8", errors="replace")
    if not done and not alive("ts_helpdoc_spider.py"):
        subprocess.Popen(
            ["python3", str(SPIDER)],
            stdout=open(OUT / "ts_docs_archive" / "spider_outer.log", "a"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


def snap() -> dict:
    sz = MM.stat().st_size if MM.exists() else 0
    pages = sum(1 for _ in FN.open("rb")) if FN.exists() else 0
    last = ""
    slog = ""
    if SPLOG.exists():
        slog = SPLOG.read_text(encoding="utf-8", errors="replace")
        ls = slog.strip().splitlines()
        last = ls[-1] if ls else ""
    next_url, page_no, toc = "", pages, 573
    if CKPT.exists():
        try:
            ck = json.loads(CKPT.read_text(encoding="utf-8"))
            next_url = ck.get("next_url") or ""
            page_no = int(ck.get("page_no") or pages)
            toc = len(ck.get("toc") or []) or 573
        except Exception:
            pass
    return {
        "ts": datetime.now().strftime("%H:%M:%S"),
        "mm_pct": 100.0 * sz / EXP,
        "mm_mb": sz / 1024 / 1024,
        "mm_remain": max(0, EXP - sz) / 1024 / 1024,
        "mm_on": alive("ziyan_dl_mmbert.py"),
        "mm_done": sz >= EXP,
        "sp_pages": page_no,
        "sp_toc": toc,
        "sp_pct": 100.0 * page_no / toc if toc else 0,
        "sp_on": alive("ts_helpdoc_spider.py"),
        "sp_done": ("DONE pages=" in slog) or (page_no >= toc and not next_url),
        "sp_last": last,
        "sp_next": next_url,
        "sz": sz,
    }


def write_live(s: dict, d_mm_kb: float | None, d_pg: int | None) -> str:
    dmm = f" · Δ{d_mm_kb:.0f}KB/周期" if d_mm_kb is not None else ""
    dpg = f" · Δ{d_pg}页/周期" if d_pg is not None else ""
    md = "\n".join(
        [
            f"# 实时进度 · {s['ts']}",
            "",
            "| 任务 | 进度 | 详情 | 进程 |",
            "|------|------|------|------|",
            (
                f"| **mmbert** | **{s['mm_pct']:.2f}%** | "
                f"{s['mm_mb']:.1f}/1173.2 MB · 剩余 {s['mm_remain']:.0f} MB{dmm} | "
                f"{'运行' if s['mm_on'] else '停止'} |"
            ),
            (
                f"| **TS spider** | **{s['sp_pct']:.1f}%** | "
                f"{s['sp_pages']}/{s['sp_toc']} 页{dpg} | "
                f"{'运行' if s['sp_on'] else '停止'} |"
            ),
            "",
            f"- spider last: `{s['sp_last']}`",
            f"- spider next: `{s['sp_next']}`",
            f"- mmbert COMPLETE: {s['mm_done']} · spider COMPLETE: {s['sp_done']}",
            "",
            "文件：`tmp_shots/PHASE763R8/LIVE_PROGRESS.md` · 历史：`LIVE_PROGRESS_HISTORY.log`",
            "",
        ]
    )
    LIVE.write_text(md, encoding="utf-8")
    line = (
        f"[{s['ts']}] mmbert {s['mm_pct']:6.2f}% "
        f"{s['mm_mb']:7.1f}MB remain={s['mm_remain']:.0f} "
        f"{'ON' if s['mm_on'] else 'OFF'}{dmm} | "
        f"spider {s['sp_pages']:3d}/{s['sp_toc']} ({s['sp_pct']:5.1f}%) "
        f"{'ON' if s['sp_on'] else 'OFF'}{dpg}\n"
    )
    with HIST.open("a", encoding="utf-8") as f:
        f.write(line)
    return line


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    prev_sz = None
    prev_pg = None
    # 先刷 12 次（约 1 分钟，每 5 秒），再转 10 秒周期长跑
    intervals = [5] * 12 + [10] * 720  # ~2h
    for wait in intervals:
        revive()
        s = snap()
        d_mm = None if prev_sz is None else (s["sz"] - prev_sz) / 1024
        d_pg = None if prev_pg is None else (s["sp_pages"] - prev_pg)
        prev_sz, prev_pg = s["sz"], s["sp_pages"]
        print(write_live(s, d_mm, d_pg), end="", flush=True)
        if s["mm_done"] and s["sp_done"]:
            print("BOTH_COMPLETE", flush=True)
            break
        time.sleep(wait)


if __name__ == "__main__":
    main()
