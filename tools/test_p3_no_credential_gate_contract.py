#!/usr/bin/env python3
"""P3 AI gameplay must not require filling account/password."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"{label}: missing {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"{label}: forbidden gate text still present: {needle}")


def main() -> None:
    ai = (ROOT / "lua/modules/AI.lua").read_text(encoding="utf-8")
    game = (ROOT / "lua/modules/Game.lua").read_text(encoding="utf-8")
    sm = (ROOT / "lua/ziyan_engine/state_machine.lua").read_text(encoding="utf-8")
    handoff = (ROOT / ".codex/skills/ziyan-compact-handoff/SKILL.md").read_text(
        encoding="utf-8"
    )
    design = (ROOT / "Agent设计方案.txt").read_text(encoding="utf-8")
    app = (ROOT / "objc/app/AgentGameViewController.m").read_text(encoding="utf-8")
    engine = (ROOT / "objc/app/AgentAutonomousEngine.m").read_text(encoding="utf-8")

    require(ai, 'capability = "gameplay"', "AI.lua")
    require(ai, "Chat.playTurn", "AI.lua")
    require(ai, "pause_auth", "AI.lua")
    require(ai, "p3_skip_credentials", "AI.lua")
    require(ai, "login_credentials_not_a_p3_gate", "AI.lua")
    require(ai, 'tasks[#tasks + 1] = "skip_auth"', "AI.lua")
    forbid(ai, 'action.rx, action.ry, action.label = 0.64, 0.72, "ai_login"', "AI.lua")
    forbid(ai, 'ctx.findText("登录")', "AI.lua")
    forbid(ai, 'words[#words + 1] = "登录"', "AI.lua")

    require(game, "pause_auth_skip_credentials", "Game.lua")
    require(game, "login_credentials_not_a_p3_gate", "Game.lua")
    forbid(game, 'login = "analyze_auth_ui_then_act"', "Game.lua")

    require(sm, "pause_auth_skip_credentials", "state_machine.lua")
    forbid(sm, 'login = "analyze_auth_ui_then_act"', "state_machine.lua")

    forbid(handoff, "登录页立刻点登录", "compact-handoff")
    require(handoff, "禁止填写账号密码", "compact-handoff")

    require(design, "登录页不是门禁", "Agent设计方案.txt")
    require(design, "禁止填写账号密码", "Agent设计方案.txt")

    forbid(app, "本轮冻结", "AgentGameViewController.m")
    require(app, "beginAutonomousExploreName", "AgentGameViewController.m")
    require(engine, "startExploreName", "AgentAutonomousEngine.m")
    require(engine, "Zy.AI.pipeline", "AgentAutonomousEngine.m")
    forbid(engine, "NOT_IMPLEMENTED", "AgentAutonomousEngine.m")

    print("P3_NO_CREDENTIAL_GATE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
