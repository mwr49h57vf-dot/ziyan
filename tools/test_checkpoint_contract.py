#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tools/ziyan_codex_checkpoint.py").read_text(encoding="utf-8")
EMIT = (ROOT / "tools/ziyan_codex_emit_continuation_prompt.py").read_text(encoding="utf-8")
TEMPLATE = (ROOT / ".codex/CONTINUATION_FIRST_MESSAGE.txt").read_text(encoding="utf-8")
STATE = (ROOT / ".codex/ZIYAN_ACTIVE_CHECKPOINT.json").read_text(encoding="utf-8")

for field in (
    "latestVerdict",
    "packageVersion",
    "packageSha256",
    "deviceState",
    "runningProcesses",
    "cleanupStatus",
    "nextAction",
):
    assert field in SOURCE, field

assert "template_is_stale_nine" in EMIT, "emit must reject stale 九号 template"
assert "本对话标题是「九号接棒任务」" not in TEMPLATE, "continuation template must not dump 九号 Chat"
assert "标题：「十八号" in TEMPLATE
assert "17-140" in TEMPLATE
assert "找图回退打进包" not in TEMPLATE
assert "17-140" in STATE
assert "本对话标题是「九号接棒任务」" not in STATE
print("CHECKPOINT_STRUCTURED_FIELDS_CONTRACT=PASS")
