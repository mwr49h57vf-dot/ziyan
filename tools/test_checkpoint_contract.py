#!/usr/bin/env python3
"""Structural contract for the checkpoint + continuation prompt.

Earlier versions asserted a specific historical stage string
(`E48-101-...-61-TRANSPORT_BLOCKED`) and `TRANSPORT_BLOCKED` in the template.
That pinned the test to one past task, so every later rewrite of the live
checkpoint broke it. Assert structure and the stale-template guards instead.
"""
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tools/ziyan_codex_checkpoint.py").read_text(encoding="utf-8")
EMIT = (ROOT / "tools/ziyan_codex_emit_continuation_prompt.py").read_text(encoding="utf-8")
TEMPLATE = (ROOT / ".codex/CONTINUATION_FIRST_MESSAGE.txt").read_text(encoding="utf-8")
STATE_TEXT = (ROOT / ".codex/ZIYAN_ACTIVE_CHECKPOINT.json").read_text(encoding="utf-8")
STATE = json.loads(STATE_TEXT)

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
assert "找图回退打进包" not in TEMPLATE
assert "本对话标题是「九号接棒任务」" not in STATE_TEXT

# 断点只断言结构：历史 stage 字符串会被下一个任务覆盖，不得写死。
for field in ("stage", "lastSuccessfulCommand", "literalResult", "nextAction"):
    assert STATE.get(field), f"checkpoint missing {field}"
assert isinstance(STATE.get("unfinished"), bool), "unfinished must be a bool"
assert STATE["deviceOrder"] == [".101", ".112", ".166", ".53", ".61"]
assert "PROMPT_END" in TEMPLATE

# 合同测试不得改写真实断点（2026-09-10 曾被写坏成 fake finished）。
assert 'if not STATE.exists():' not in SOURCE, "checkpoint must accept --state override"
assert "WORKTREE_STATE" not in SOURCE, "hardcoded worktree fallback must stay removed"
print("CHECKPOINT_STRUCTURED_FIELDS_CONTRACT=PASS")
