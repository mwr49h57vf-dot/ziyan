#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    checks = {
        "Chat.lua": (
            "function M.send",
            "function M.clear",
            "function M.copyLast",
            "function M.pasteLast",
            "function M.verifyLast",
            "Zy.Input.text",
            "Zy.OCR.find",
            "Zy.Image.find",
            "find_by_image",
        ),
        "RuleEngine.lua": ("function M.add", "function M.step", "function M.pause", "function M.replay"),
        "Decision.lua": ("function M.choose", "function M.retry", "function M.pause", "function M.replay"),
        "Touch.lua": ("function M.longPress", "function M.longPressRatio", "function M.pinch"),
    }
    init = (ROOT / "lua/modules/init.lua").read_text(encoding="utf-8")
    for name, needles in checks.items():
        src = (ROOT / "lua/modules" / name).read_text(encoding="utf-8")
        for needle in needles:
            assert needle in src, f"{name}:{needle}"
        assert name[:-4] in init, f"module_not_registered:{name}"
    print("CHAT_RULE_DECISION_MODULE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
