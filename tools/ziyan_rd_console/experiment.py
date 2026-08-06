#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段5：实验记录（真实结果入库，失败不自动宣称成功）。"""
from __future__ import annotations

import json
import shutil
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT / "tmp_shots"
EXP = TMP / "experiments"
EXP.mkdir(parents=True, exist_ok=True)
LOG = EXP / "experiment_log.jsonl"
ERRDB = TMP / "ERROR_DB.jsonl"
KB = TMP / "GAME_KNOWLEDGE.jsonl"


def record_experiment(
    name: str,
    change: str,
    reason: str,
    modules: list,
    env: dict,
    result: dict,
    keep: bool | None = None,
) -> Path:
    row = {
        "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "epoch": int(time.time()),
        "name": name,
        "change": change,
        "reason": reason,
        "modules": modules,
        "env": env,
        "result": result,
        "keep": keep if keep is not None else bool(result.get("pass")),
    }
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    # snapshot game.lua on keep
    if row["keep"]:
        snap = EXP / f"keep_{row['epoch']}_{name}.lua"
        src = ROOT / "lua" / "ziyan_engine" / "game.lua"
        if src.exists():
            shutil.copy2(src, snap)
    else:
        # failure note only
        pass
    return LOG


def record_error(etype: str, module: str, cause: str, fix: str) -> None:
    row = {
        "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "type": etype,
        "module": module,
        "cause": cause,
        "fix": fix,
    }
    with ERRDB.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def record_knowledge(entry: dict) -> None:
    entry = dict(entry)
    entry.setdefault("ts", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    with KB.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    record_knowledge({
        "game": "bootstrap",
        "note": "knowledge base created",
        "source": "tools/ziyan_rd_console/experiment.py",
    })
    print("OK", LOG, ERRDB, KB)
