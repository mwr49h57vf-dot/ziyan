#!/usr/bin/env python3
"""Emit the exact first-message prompt for a successor Codex task.

Run this immediately before a manual compact/handoff continuation.
This script does not create tasks.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".codex" / "ZIYAN_ACTIVE_CHECKPOINT.json"
TEMPLATE = ROOT / ".codex" / "CONTINUATION_FIRST_MESSAGE.txt"
CHECKPOINT_PY = ROOT / "tools" / "ziyan_codex_checkpoint.py"


def load_checkpoint():
    if not STATE.exists():
        print("CHECKPOINT_MISSING", file=sys.stderr)
        sys.exit(2)
    return json.loads(STATE.read_text())


def maybe_write(d, args):
    nxt = (d.get("nextAction") or "").strip()
    unfinished = d.get("unfinished", True)
    stop = (not unfinished) or nxt.startswith("等待人工") or nxt.startswith("WAIT_HUMAN")
    if not args.write or stop:
        return d
    cmd = [
        sys.executable,
        str(CHECKPOINT_PY),
        "write",
        "--stage", args.stage or d.get("stage") or "handoff",
        "--last-command", args.last_command or d.get("lastSuccessfulCommand") or "compact-handoff",
        "--result", args.result or d.get("literalResult") or "context compacted; spawning successor thread",
        "--next-action", args.next_action or d.get("nextAction") or "python3 tools/ziyan_codex_checkpoint.py show",
        "--evidence", args.evidence or d.get("evidence") or "",
        "--latest-verdict", args.latest_verdict or d.get("latestVerdict") or "NOT_RECORDED",
        "--package-version", (d.get("artifacts") or {}).get("packageVersion") or "NOT_RECORDED",
        "--package-sha256", (d.get("artifacts") or {}).get("packageSha256") or "NOT_RECORDED",
        "--device-state", d.get("deviceState") or "NOT_RECORDED",
        "--running-processes", d.get("runningProcesses") or "NOT_RECORDED",
        "--cleanup-status", d.get("cleanupStatus") or "NOT_RECORDED",
    ]
    subprocess.run(cmd, cwd=ROOT, check=True)
    return load_checkpoint()


STALE_NINE_MARKERS = (
    "本对话标题是「九号接棒任务」",
    "标题是「九号接棒任务」",
    "把仓库 `lua/modules/Chat.lua` 的找图回退打进包",
    "登记 `python3 tools/ziyan_capability_sequence.py record --capability chat --device .112",
    "E48 .112 INVALID_RUN",
    "仅修复测试通道：检查并修复 E48 matrix runner",
)

STALE_MANUAL_GATE_MARKERS = (
    "由人工在 `.101` 实机上确认屏幕真实画面",
    "唯一动作：\n由人工",
)


def stage_is_nine_chat(d):
    stage = str(d.get("stage") or "")
    return ("九号" in stage) or stage.startswith("chat-112")


def template_is_stale_nine(body, d):
    if stage_is_nine_chat(d):
        return False
    return any(marker in body for marker in STALE_NINE_MARKERS)


def template_is_stale_manual_gate(body, d):
    if not d.get("unfinished", True):
        return False
    return any(marker in body for marker in STALE_MANUAL_GATE_MARKERS)


def build_prompt_from_checkpoint(d):
    arts = d.get("artifacts") or {}
    return (
        f"继续 ZiYan。标题：「{d.get('stage') or 'continue'}」。不从头审计。"
        "禁止 worktree / create_thread / fork / resume。\n"
        "cwd=/Users/mac/Desktop/ZiYan_副本\n\n"
        "禁止输出「九号接棒任务」或改 Chat.lua 找图中心。只做下面 nextAction。\n"
        f"- lastSuccessfulCommand={d.get('lastSuccessfulCommand')}\n"
        f"- literalResult={d.get('literalResult')}\n"
        f"- latestVerdict={d.get('latestVerdict')}\n"
        f"- packageVersion={arts.get('packageVersion')}\n"
        f"- packageSha256={arts.get('packageSha256')}\n"
        f"- deviceState={d.get('deviceState')}\n"
        f"- evidence={d.get('evidence')}\n\n"
        "唯一动作：\n"
        f"{d.get('nextAction') or ''}\n"
        "禁止点登录、点击前往、go_home、夹具、杀 SB/BB。"
        "坐标只用 ScreenTransform / tapRatio。\n"
        "完成或阻塞后，必须主动发送任务回执：完成了什么、没有完成什么、阻塞原因、checkpoint 状态和还剩哪些主计划任务。\n"
    )


def build_prompt(d):
    body = TEMPLATE.read_text()
    nxt = (d.get("nextAction") or "").strip()
    unfinished = d.get("unfinished", True)
    stop = (not unfinished) or nxt.startswith("等待人工") or nxt.startswith("WAIT_HUMAN")
    if stop:
        body = build_prompt_from_checkpoint(d)
    if template_is_stale_nine(body, d):
        print(
            "TEMPLATE_STALE: CONTINUATION_FIRST_MESSAGE.txt 仍是九号 Chat，已改用 checkpoint 正文",
            file=sys.stderr,
        )
        body = build_prompt_from_checkpoint(d)
    if template_is_stale_manual_gate(body, d):
        print(
            "TEMPLATE_STALE: CONTINUATION_FIRST_MESSAGE.txt 仍是人工门禁正文，已改用 checkpoint 正文",
            file=sys.stderr,
        )
        body = build_prompt_from_checkpoint(d)
    nxt = d.get("nextAction") or ""
    stage = d.get("stage") or ""
    unfinished = d.get("unfinished", True)
    extra = (
        "\n\n当前磁盘断点（禁止忽略）：\n"
        f"- stage={stage}\n"
        f"- unfinished={unfinished}\n"
        f"- nextAction={nxt}\n"
        f"- latestVerdict={d.get('latestVerdict')}\n"
        f"- packageSha256={(d.get('artifacts') or {}).get('packageSha256')}\n"
        "用户明确要求：这是人工粘贴到 Codex 新任务的首条消息，禁止 create_thread / worktree。"
        "再次压缩就必须再 emit 并人工新开任务，循环直到 unfinished=false 且 nextAction 为等待人工最终审核。\n"
        "若正文出现「九号接棒任务」而 stage 不是九号/chat-112：丢掉九号，只执行上面 nextAction。\n"
    )
    return body.rstrip() + extra


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="write checkpoint before emitting prompt")
    ap.add_argument("--stage", default="")
    ap.add_argument("--last-command", default="")
    ap.add_argument("--result", default="")
    ap.add_argument("--next-action", default="")
    ap.add_argument("--evidence", default="")
    ap.add_argument("--latest-verdict", default="")
    args = ap.parse_args()
    d = load_checkpoint()
    d = maybe_write(d, args)
    nxt = (d.get("nextAction") or "").strip()
    unfinished = d.get("unfinished", True)
    stop = (not unfinished) or nxt.startswith("等待人工") or nxt.startswith("WAIT_HUMAN")
    prompt = build_prompt(d)
    if args.write:
        TEMPLATE.write_text(prompt.rstrip() + "\n", encoding="utf-8")
    print("SPAWN_REQUIRED=" + ("0" if stop else "1"))
    print("STAGE=" + str(d.get("stage") or ""))
    print("NEXT_ACTION=" + nxt)
    print("TITLE=ZiYan续接-" + str(d.get("stage") or "continue"))
    print("PROJECT_CWD=/Users/mac/Desktop/ZiYan_副本")
    print("PROMPT_BEGIN")
    print(prompt)
    print("PROMPT_END")
    if stop:
        print("STOP_LOOP=1  任务已到人工审核，不要再 create_thread", file=sys.stderr)


if __name__ == "__main__":
    main()
