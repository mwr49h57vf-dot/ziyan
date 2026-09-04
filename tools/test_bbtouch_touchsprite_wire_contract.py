#!/usr/bin/env python3
"""Static contract for the iOS 11+ TSEventTweak hand+finger wire envelope."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOUCH = (ROOT / "objc/shared/ZiYanTouchBridge.m").read_text(encoding="utf-8")
OPTIMIZER = (ROOT / "objc/shared/ZiYanHIDOptimizer.m").read_text(encoding="utf-8")


def require(text: str) -> None:
    assert text in TOUCH, f"missing TouchSprite wire contract: {text}"


def main() -> None:
    # TSEventTweak arm64 iOS 13 assembly writes the parent event fields
    # 0xB0007/8/9 after appending its finger children.  Do not use the
    # unrelated 0xB0001/3/4 fields as a substitute.
    require("kZYFieldEventMask = (11 << 16) | 7")
    require("kZYFieldRange = (11 << 16) | 8")
    require("kZYFieldTouch = (11 << 16) | 9")
    require("kZYFieldDisplayIntegrated = (11 << 16) | 25")
    require("kZYFieldIsBuiltIn = 4")

    # The iOS 11+ slice builds an empty hand parent, then a normal (not
    # WithQuality) finger event. Constructor argument 5 is an event mask:
    # child down/up=3, while parent B0007 is down=35 and up=4.
    require("kZYTransducerTypeHand = 35")
    require("kZYTransducerTypeFinger = 4")
    require("boolean_t inRange = down;")
    require("uint32_t childMask = kZYDigitizerEventRange | kZYDigitizerEventTouch;")
    require("kZYDigitizerEventIdentity)")
    require(": kZYDigitizerEventPosition;")
    require("kCFAllocatorDefault, ts, kZYTransducerTypeHand, 0, 1, 0, 0, 0, 0, 0,")
    require("kCFAllocatorDefault, ts, idx, 2, childMask, nx, ny, 0, 0, 0, inRange,")
    require("ZYSetIntegerValue(hand, kZYFieldEventMask, (CFIndex)parentMask)")
    require("ZYSetIntegerValue(hand, kZYFieldDisplayIntegrated, 1)")
    require("ZYSetIntegerValue(hand, kZYFieldIsBuiltIn, 1)")
    # The TouchSprite event envelope does not replace the system digitizer
    # coordinate contract: BackBoard always receives portrait-glass HID.
    require("ZiYanMapLogicToNorm(sx, sy, &nx, &ny);")

    # The observed TouchSprite iOS 11+ path ends at the IOKit system client.
    # Preserve BKHID only as a compatibility fallback when that client is
    # unavailable; the device gate, not either dispatch call, proves UI use.
    require("IOHIDEventSystemClientDispatchEvent")
    require("shape=touchsprite_ios11_hand_finger")
    require('Class bk = NSClassFromString(@"BKHIDSystemInterface");')
    require("@selector(injectHIDEvent:)")
    require("if (ZYDispatch && _client)")
    require("if (!sent)")
    require('Class eventTimer = NSClassFromString(@"BKUserEventTimer");')
    assert "ZYCreateFingerEventWithQuality" not in TOUCH
    assert "ZYSetIntegerValueWithOptions" not in TOUCH
    assert "BKSHIDEventSetDigitizerInfo" not in TOUCH, (
        "unobserved BKS metadata must not mutate the TouchSprite-compatible event"
    )

    # SpringBoard foreground-App fallback must use the same proven envelope;
    # otherwise direct touch_req can report success while games ignore it.
    for needle in (
        "kIOHIDFieldEventMask = (11 << 16) | 7",
        "kIOHIDFieldRange = (11 << 16) | 8",
        "kIOHIDFieldTouch = (11 << 16) | 9",
        "boolean_t inRange = down;",
        "uint32_t childMask =",
        "uint32_t parentMask =",
        "kCFAllocatorDefault, ts, kIOHIDTransducerTypeHand, 0, 1, 0, 0, 0, 0, 0,",
        "HIDSetInt(hand, kIOHIDFieldEventMask, (CFIndex)parentMask)",
        "HIDSetSender(toSend, kZYModernTouchSpriteSenderID)",
    ):
        assert needle in OPTIMIZER, f"optimizer diverges from TouchSprite: {needle}"
    method = OPTIMIZER[
        OPTIMIZER.index("- (BOOL)injectNormPhase:")
        : OPTIMIZER.index("- (BOOL)injectTapNormX:")
    ]
    assert "if (HIDDispatch && self.client)" in method
    assert "!ok && dispatchBKHID()" in method
    assert 'route = "iohid_dispatch"' in method
    assert "IOHIDEventSystemConnectionDispatchEvent" not in OPTIMIZER
    assert "dispatchToFrontContext" not in OPTIMIZER
    assert "HIDCreateFingerWithQuality" not in method
    assert "HIDSetIntOptions" not in method
    assert "BKSSetDig" not in method
    print("PASS test_bbtouch_touchsprite_wire_contract")


if __name__ == "__main__":
    main()
