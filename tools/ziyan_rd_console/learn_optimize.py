#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
阶段9：自主优化学习记录 — 只从真实数据提炼条目，禁止无测试改稳定模块。
读取：ERROR_DB / GAME_KNOWLEDGE / experiment_log / LEARNING_LOGIN_NOTES / REPORT
输出：tmp_shots/LEARN_OPTIMIZE.jsonl + 摘要
"""
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT / "tmp_shots"
OUT = TMP / "LEARN_OPTIMIZE.jsonl"


def read_jsonl(path: Path, limit: int = 50) -> list:
    if not path.exists():
        return []
    rows = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                rows.append({"raw": line[:200]})
    return rows[-limit:]


def main() -> None:
    TMP.mkdir(parents=True, exist_ok=True)
    errors = read_jsonl(TMP / "ERROR_DB.jsonl")
    knowledge = read_jsonl(TMP / "GAME_KNOWLEDGE.jsonl")
    experiments = read_jsonl(TMP / "experiments" / "experiment_log.jsonl")
    notes = ""
    np = TMP / "LEARNING_LOGIN_NOTES.md"
    if np.exists():
        notes = np.read_text(encoding="utf-8", errors="replace")[-1500:]

    # 从真实错误提炼优化方向（不自动改代码）
    directions = []
    for e in errors:
        directions.append({
            "source": "ERROR_DB",
            "type": e.get("type") or e.get("cause"),
            "module": e.get("module"),
            "fix_hint": e.get("fix"),
            "action": "propose_only",
            "note": "须真机复测后才允许改稳定模块",
        })
    for ex in experiments:
        directions.append({
            "source": "experiment",
            "name": ex.get("name") or ex.get("version"),
            "keep": ex.get("keep"),
            "change": ex.get("change"),
            "action": "retain" if ex.get("keep") else "discard_or_hold",
        })

    row = {
        "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "rule": "采集→分析→方案→修改→真机测→比较→保留；禁止无数据/无测试改稳定模块",
        "inputs": {
            "error_db": len(errors),
            "knowledge": len(knowledge),
            "experiments": len(experiments),
            "notes_tail_bytes": len(notes),
        },
        "optimize_directions": directions[-20:],
        "blocked_by": "阶段3 登录进角仍 FAIL（缺有效凭证/免密无响应）— 不自动大改 Game 稳定路径",
        "ts_habit_only": True,
    }
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(json.dumps({
        "out": str(OUT.relative_to(ROOT)),
        "directions": len(directions),
        "errors": len(errors),
        "knowledge": len(knowledge),
        "blocked_by": row["blocked_by"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
