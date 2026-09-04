#!/usr/bin/env python3
"""Static regression contract for target-Bundle generalization.

The product accepts the business Bundle ID from the run session/current
foreground app. ios7.lua remains a test fixture, not a product allowlist.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRAME = (ROOT / "tools/ziyan_framecap/ZiYanAppFrameClient.m").read_text()
TOUCH = (ROOT / "lua/ziyan_engine/touch.lua").read_text()
CV = (ROOT / "lua/ziyan_engine/cv.lua").read_text()
SB = (ROOT / "objc/tweak/springboard/Tweak.m").read_text()


def require(text: str, needle: str) -> None:
    assert needle in text, needle


def forbid(text: str, needle: str) -> None:
    assert needle not in text, needle


def main() -> None:
    require(FRAME, "characterSetWithCharactersInString")
    require(FRAME, "ZAF_HasFreshActiveEvidence")
    forbid(FRAME, '@"com.xztl.ios", @"com.ychj.hlhjlygr"')
    forbid(FRAME, '@"com.ljzbbadao.game"')

    require(TOUCH, "eligible_target_bid")
    require(TOUCH, 'intent:match("[\\r\\n]target_bid=')
    require(TOUCH, 'read_line(ZIYAN_VAR .. "/.ziyan_front_bid")')
    forbid(TOUCH, 'return "com.xztl.ios"')
    forbid(TOUCH, 'return "com.ljzbbadao.game"')

    require(CV, 'intent:match("[\\r\\n]target_bid=')
    require(CV, "frontAppBid")
    forbid(CV, 'bid = "com.xztl.ios"')
    forbid(CV, 'bid = "com.ljzbbadao.game"')

    require(SB, "target_bid_explicit")
    forbid(SB, 'tbid = @"com.xztl.ios"')
    forbid(SB, 'tbid = @"com.ljzbbadao.game"')
    print("GENERIC_BUNDLE_TARGET_CONTRACT=PASS")


if __name__ == "__main__":
    main()
