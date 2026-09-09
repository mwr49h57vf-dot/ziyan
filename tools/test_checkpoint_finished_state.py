#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKPOINT = ROOT / "tools" / "ziyan_codex_checkpoint.py"
STATE = ROOT / ".codex" / "ZIYAN_ACTIVE_CHECKPOINT.json"


def run(*args):
    return subprocess.run(
        [sys.executable, str(CHECKPOINT), "write", *args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )


def read_state():
    return json.loads(STATE.read_text(encoding="utf-8"))


with tempfile.TemporaryDirectory():
    common = [
        "--stage", "checkpoint-contract",
        "--last-command", "test_checkpoint_finished_state.py",
        "--result", "contract test",
        "--next-action", "等待人工最终审核",
        "--device-state", "本轮未连接设备",
        "--running-processes", "本轮未读取或改变设备进程",
        "--cleanup-status", "本轮未部署或写入设备",
    ]
    run(*common)
    assert read_state()["unfinished"] is True
    run(*common, "--no-unfinished")
    state = read_state()
    assert state["unfinished"] is False
    assert state["nextAction"] == "等待人工最终审核"
print("CHECKPOINT_FINISHED_STATE_CONTRACT=PASS")
