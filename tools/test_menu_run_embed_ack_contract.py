#!/usr/bin/env python3
"""Static contract for the single menu_run embed start handshake."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "objc/shared/ZiYanScriptRunner.m").read_text(encoding="utf-8")
EMBED = (ROOT / "tools/ziyan_framecap/ZiYanLuaEmbed.m").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


embed_runner = RUNNER[RUNNER.index("+ (NSDictionary *)runLuaViaEmbedAtPath:") :]
embed_runner = embed_runner[: embed_runner.index("+ (NSDictionary *)runLuaViaSpringBoardAtPath:")]
ack_loop = "for (int i = 0; i < 160; i++)"
require(ack_loop in embed_runner, "menu_run ACK wait must remain 8s (160 x 50ms)")
require("for (int i = 0; i < 30; i++)" not in embed_runner,
        "old 1.5s ACK timeout returned")

run_method = RUNNER[RUNNER.index("+ (void)runFileAtPath:") :]
run_method = run_method[: run_method.index("+ (NSDictionary *)runLuaViaEmbedAtPath:")]
require(run_method.count("runLuaViaEmbedAtPath:") == 1, "menu_run must use one embed attempt")
require("ensureFramecapAlive" not in run_method[run_method.index("runLuaViaEmbedAtPath:") :],
        "embed failure must not trigger a second start attempt")

poll = EMBED[EMBED.index("void ZiYanLuaEmbedPoll(void)") :]
start = poll.index("BOOL ok = StartEmbedThread(script);")
ack_write = poll.index('writeToFile:ackPath', start)
require(start < ack_write, "framecap must publish ACK after accepting the start")
require("ok ? @\"running\" : @\"idle\"" in poll[start:],
        "failed start must publish idle session state")

print("MENU_RUN_EMBED_ACK_CONTRACT=PASS")
