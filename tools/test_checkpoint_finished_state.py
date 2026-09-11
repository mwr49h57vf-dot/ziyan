#!/usr/bin/env python3
"""Contract test for the unfinished/finished checkpoint state.

This test MUST NOT touch the real checkpoint. The previous version wrote to
.codex/ZIYAN_ACTIVE_CHECKPOINT.json directly, so finishing the suite silently
overwrote the live breakpoint with stage=checkpoint-contract /
unfinished=false / nextAction=等待人工最终审核 -- a fake "done" state that
looked like a completed plan (found 2026-09-10).
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKPOINT = ROOT / "tools" / "ziyan_codex_checkpoint.py"
REAL_STATE = ROOT / ".codex" / "ZIYAN_ACTIVE_CHECKPOINT.json"


def run(state, *args):
    return subprocess.run(
        [sys.executable, str(CHECKPOINT), "write", "--state", str(state), *args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )


def read_state(state):
    return json.loads(Path(state).read_text(encoding="utf-8"))


def real_digest():
    import hashlib

    if not REAL_STATE.exists():
        return None
    return hashlib.sha256(REAL_STATE.read_bytes()).hexdigest()


before = real_digest()
with tempfile.TemporaryDirectory() as td:
    STATE = Path(td) / "ZIYAN_ACTIVE_CHECKPOINT.json"
    common = [
        "--stage", "checkpoint-contract",
        "--last-command", "test_checkpoint_finished_state.py",
        "--result", "contract test",
        "--next-action", "等待人工最终审核",
        "--device-state", "本轮未连接设备",
        "--running-processes", "本轮未读取或改变设备进程",
        "--cleanup-status", "本轮未部署或写入设备",
    ]
    run(STATE, *common)
    assert read_state(STATE)["unfinished"] is True
    run(STATE, *common, "--no-unfinished")
    state = read_state(STATE)
    assert state["unfinished"] is False
    assert state["nextAction"] == "等待人工最终审核"
    assert not (Path(td) / "ZIYAN_ACTIVE_CHECKPOINT.tmp").exists()

after = real_digest()
assert before == after, (
    "checkpoint contract test modified the real checkpoint "
    f"({before} -> {after})"
)
print("CHECKPOINT_FINISHED_STATE_CONTRACT=PASS")
