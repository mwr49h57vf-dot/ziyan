#!/usr/bin/env python3
"""Minimal local contract for empty-SHM App active-evidence scheduling."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "tools/ziyan_framecap/ZiYanAppFrameClient.h").read_text()
CLIENT = (ROOT / "tools/ziyan_framecap/ZiYanAppFrameClient.m").read_text()
MAIN = (ROOT / "tools/ziyan_framecap/main.m").read_text()
SNAPSHOT = (ROOT / "tools/ziyan_framecap/ZiYanSnapshotHttp.m").read_text()


def main() -> None:
    assert "BOOL ZiYanAppFrameHasFreshActiveEvidence(void);" in HEADER
    assert "BOOL ZiYanAppFrameHasFreshActiveEvidence(void)" in CLIENT
    assert "ZAF_EligibleBid(bid) && ZAF_HasFreshActiveEvidence(bid)" in CLIENT
    assert "BOOL appActiveEvidenceEmpty =" in MAIN
    assert "emptyShm && ZiYanAppFrameHasFreshActiveEvidence()" in MAIN
    assert "appActiveEvidenceEmpty) &&" in MAIN
    # 空 SHM 时，/snapshot 必须使用已注册的唯一 capture hook 先驱动一帧，
    # 再编码 canonical frame；否则点击验收在无证据时恒为 HTTP 503。
    snapshot_handler = SNAPSHOT[
        SNAPSHOT.index('if ([pathOnly isEqualToString:@"/snapshot"])') :
    ]
    assert "if (sCaptureHook)" in snapshot_handler
    assert "sCaptureHook();" in snapshot_handler
    assert snapshot_handler.index("sCaptureHook();") < snapshot_handler.index(
        "EncodeCanonicalPNG"
    )
    print("P4_FRAMECAP_EMPTY_SHM_ACTIVE_EVIDENCE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
