#!/usr/bin/env python3
"""Static regression contract for generic foreground architecture.

The reference packages place their persistent control plane in SpringBoard /
daemon layers. ZiYan follows that shape: target game Bundle IDs are observed
from the authoritative SpringBoard reducer, IOHID is injected in backboardd,
and AppTouch is never a per-game product allowlist.
"""
from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]
PLIST = plistlib.loads((ROOT / "ZiYanAppTouch.plist").read_bytes())
SB = (ROOT / "objc/tweak/springboard/Tweak.m").read_text()
CLIENT = (ROOT / "tools/ziyan_framecap/ZiYanAppFrameClient.m").read_text()
HEADER = (ROOT / "tools/ziyan_framecap/ZiYanAppFrameClient.h").read_text()
MAIN = (ROOT / "tools/ziyan_framecap/main.m").read_text()
BB_PLIST = plistlib.loads((ROOT / "ZiYanBBTouch.plist").read_bytes())

LEGACY_GAME_BIDS = {
    "com.xztl.ios",
    "com.ychj.hlhjlygr",
    "com.zsyxs180.game",
    "com.ljzbbadao.game",
    "com.ownbook.notes",
}


def require(text: str, needle: str) -> None:
    assert needle in text, needle


def main() -> None:
    assert PLIST["Filter"]["Classes"] == ["UIApplication"], PLIST
    assert "Bundles" not in PLIST["Filter"], PLIST

    bb_filter = BB_PLIST["Filter"]
    assert bb_filter["Bundles"] == ["com.apple.backboardd"], bb_filter
    assert bb_filter["Executables"] == ["backboardd"], bb_filter

    require(SB, '.ziyan_front_active_evidence')
    require(SB, 'source=springboard_front_reducer')
    require(SB, 'now - sLastFrontWrite >= 1.0')

    require(CLIENT, 'ZAF_HasFreshSpringBoardFrontEvidence')
    require(CLIENT, 'ZAF_HasFreshAppActiveEvidenceForBid')
    require(CLIENT, '@"app_window_unavailable"')
    require(HEADER, 'ZiYanAppFrameHasFreshAppActiveEvidence')

    require(MAIN, 'if (ZiYanAppFrameHasFreshAppActiveEvidence())')
    assert 'if (ZiYanAppFrameCurrentFrontEligible()) {' not in MAIN
    require((ROOT / "objc/tweak/apptouch/ZiYanAppTouch.m").read_text(),
            'isEqualToString:@"com.apple.springboard"')
    require((ROOT / "objc/tweak/apptouch/ZiYanAppTouch.m").read_text(),
            'isEqualToString:@"com.ziyan.ziyan"')
    print("SPRINGBOARD_GENERIC_FRONT_CONTRACT=PASS")


if __name__ == "__main__":
    main()
