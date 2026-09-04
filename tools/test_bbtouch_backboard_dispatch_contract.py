#!/usr/bin/env python3
"""Regression contract for exact BBTouch dispatch-path evidence."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOUCH = (ROOT / "objc/shared/ZiYanTouchBridge.m").read_text(encoding="utf-8")


def main() -> None:
    assert "sendPhase:(NSString *)phase" in TOUCH
    assert "ZYSetSenderID(toSend, kZYModernTouchSpriteSenderID)" in TOUCH
    assert "IOHIDEventSystemClientDispatchEvent" in TOUCH
    assert 'Class bk = NSClassFromString(@"BKHIDSystemInterface");' in TOUCH
    assert "route=%s" in TOUCH, (
        "BBTouch logs sent=1 without identifying the actual BackBoard dispatch route"
    )
    assert 'route = "bk_injectHIDEvent"' in TOUCH
    assert 'route = "iohid_dispatch"' in TOUCH
    assert TOUCH.index('route = "iohid_dispatch"') < TOUCH.index(
        'route = "bk_injectHIDEvent"'
    ), "TouchSprite iOS 11+ IOHID dispatch must precede BKHID fallback"
    # The source-level tap coordinates remain the values received by sendPhase.
    assert "sx, sy" in TOUCH
    assert "%.0f,%.0f" in TOUCH
    print("PASS test_bbtouch_backboard_dispatch_contract")


if __name__ == "__main__":
    main()
