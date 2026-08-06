#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每 15 分钟巡检 UPG / mmbert 权重下载；卡死则告警并可自动续传。

仅写巡检日志，不启动 AI 防御编码（权重未齐禁止）。
"""
from __future__ import annotations

import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
OUT = ROOT / "tmp_shots" / "PHASE763R8" / "model_watch"
OUT.mkdir(parents=True, exist_ok=True)
LOG = OUT / "hf_15m_watch.log"
STATUS = OUT / "hf_15m_status.md"
PROXY = "http://127.0.0.1:7897"

MODELS = [
    {
        "name": "UPG",
        "path": ROOT
        / "vendor/hf_models/ynyg__Unified_Prompt_Guard/model.safetensors",
        "expect": 1112205008,
        "script": "/tmp/ziyan_dl_upg.py",
        "proc": "ziyan_dl_upg.py",
    },
    {
        "name": "mmbert",
        "path": ROOT
        / "vendor/hf_models/llm-semantic-router__mmbert-jailbreak-detector-merged/model.safetensors",
        "expect": 1230141424,
        "script": "/tmp/ziyan_dl_mmbert.py",
        "proc": "ziyan_dl_mmbert.py",
    },
]

STALL_SEC = 20 * 60  # 20 分钟无增长视为卡死
INTERVAL = 15 * 60


def _alive(proc_needle: str) -> bool:
    try:
        r = subprocess.run(
            ["pgrep", "-f", proc_needle],
            capture_output=True,
            text=True,
        )
        return r.returncode == 0 and bool(r.stdout.strip())
    except Exception:
        return False


def _revive(script: str) -> None:
    if not Path(script).exists():
        return
    log = OUT / f"revive_{Path(script).stem}.log"
    subprocess.Popen(
        ["python3", script],
        stdout=open(log, "a"),
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )


def snapshot() -> list[dict]:
    rows = []
    now = time.time()
    for m in MODELS:
        p: Path = m["path"]
        sz = p.stat().st_size if p.exists() else 0
        mtime = p.stat().st_mtime if p.exists() else 0
        age = now - mtime if mtime else 1e9
        expect = m["expect"]
        pct = 100.0 * sz / expect if expect else 0.0
        done = sz >= expect
        alive = _alive(m["proc"])
        stall = (not done) and age >= STALL_SEC
        alert = []
        if done:
            state = "COMPLETE"
        elif stall and not alive:
            state = "STALLED_DEAD"
            alert.append("卡死且无下载进程")
        elif stall:
            state = "STALLED_ALIVE"
            alert.append("进程在但文件长时间无增长")
        elif not alive:
            state = "RUNNING_MISSING"
            alert.append("未完成但无下载进程")
        else:
            state = "DOWNLOADING"
        remain = max(0, expect - sz)
        rows.append(
            {
                "name": m["name"],
                "pct": pct,
                "sz": sz,
                "expect": expect,
                "remain": remain,
                "state": state,
                "alive": alive,
                "age_min": age / 60.0,
                "alert": alert,
                "script": m["script"],
                "done": done,
            }
        )
    return rows


def write_status(rows: list[dict]) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        f"# HF 模型 15 分钟巡检 · {ts}",
        "",
        "| 模型 | 进度 | 已下/总量 | 剩余 | 状态 | 进程 | 告警 |",
        "|------|------|-----------|------|------|------|------|",
    ]
    for r in rows:
        alert = ";".join(r["alert"]) if r["alert"] else "-"
        lines.append(
            f"| {r['name']} | {r['pct']:.2f}% | "
            f"{r['sz']/1024/1024:.1f}/{r['expect']/1024/1024:.1f}MB | "
            f"{r['remain']/1024/1024:.1f}MB | {r['state']} | "
            f"{'yes' if r['alive'] else 'no'} | {alert} |"
        )
    all_done = all(r["done"] for r in rows)
    lines += [
        "",
        f"**全部完整**: {'YES' if all_done else 'NO'}",
        f"**AI防御编码许可**: {'允许（权重齐）' if all_done else '禁止（权重未齐）'}",
        f"proxy={PROXY}",
        "",
    ]
    STATUS.write_text("\n".join(lines), encoding="utf-8")
    with LOG.open("a", encoding="utf-8") as f:
        f.write(f"\n--- {ts} ---\n")
        for r in rows:
            f.write(
                f"{r['name']} pct={r['pct']:.2f} state={r['state']} "
                f"remain={r['remain']} alive={r['alive']} alert={r['alert']}\n"
            )


def main() -> None:
    # 立即一拍，再循环
    while True:
        rows = snapshot()
        for r in rows:
            if r["done"]:
                continue
            if r["state"] in ("STALLED_DEAD", "RUNNING_MISSING"):
                _revive(r["script"])
                with LOG.open("a", encoding="utf-8") as f:
                    f.write(f"REVIVE {r['name']} script={r['script']}\n")
        write_status(rows)
        if all(r["done"] for r in rows):
            with LOG.open("a", encoding="utf-8") as f:
                f.write("ALL_MODELS_COMPLETE\n")
            break
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
