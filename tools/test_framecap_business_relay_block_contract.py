#!/usr/bin/env python3
"""Business Lua must never gain a SpringBoard UICreate relay exception."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tools/ziyan_framecap/main.m").read_text(encoding="utf-8")


def main() -> None:
    required = [
        'ZiYanVarFile(@".ziyan_project_active")',
        'ZiYanVarFile(@".ziyan_script_session")',
        "BOOL businessSession =",
        "ZiYanLuaEmbedIsPrewarming() && emptyShmAtEntry && !businessSession",
        "BOOL businessHot = businessSession ||",
        '@"relay_forbidden_business"',
    ]
    for token in required:
        assert token in SOURCE, f"missing business relay gate: {token}"
    print("PASS test_framecap_business_relay_block_contract")


if __name__ == "__main__":
    main()
