#!/usr/bin/env python3
"""Keep SpringBoard tap success tied to actual HID/UIKit delivery."""

from pathlib import Path
import re
import sys


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "objc/tweak/springboard/ZiYanScreenBridge.m"
)


def method_body(source: str) -> str:
    match = re.search(
        r"^- \(BOOL\)hidTouchPhase:.*?(?=^@end$)",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError("missing hidTouchPhase")
    return match.group(0)


def main() -> int:
    source = SOURCE.read_text(encoding="utf-8")
    body = method_body(source)

    assert "ZiYanLaunchIconAtWindowPoint" not in source
    assert "iconTapped:" not in body
    assert "launchFromLocation:" not in body
    assert "return hidSent || uiSent;" in body
    assert "injectHIDEvent:" in body
    assert "_enqueueHIDEvent:" in body

    print("PASS: hidTouchPhase has no direct SpringBoard icon-launch fallback")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
