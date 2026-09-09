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
    # /snapshot 禁止 HTTP 线程重入 HandleOnce / force_recap。
    # 只写 .ziyan_snap_http_want 给 ServeLoop；无已提交帧则 503。
    snapshot_handler = SNAPSHOT[
        SNAPSHOT.index('if ([pathOnly isEqualToString:@"/snapshot"])') :
    ]
    encode_at = snapshot_handler.index("EncodeCanonicalPNG")
    before_encode = snapshot_handler[:encode_at]
    assert 'ZiYanWriteVarText(@".ziyan_snap_http_want"' in before_encode
    assert "sCaptureHook();" not in before_encode
    assert 'ZiYanWriteVarText(@".ziyan_force_recap"' not in before_encode
    assert "HandleOnce(" not in before_encode
    drive = MAIN[
        MAIN.index("static void SnapDriveCapture(void)") : MAIN.index(
            "static void ServeLoop(void)"
        )
    ]
    assert 'ZiYanWriteVarText(@".ziyan_force_recap"' not in drive
    assert "HandleOnce(" not in drive
    print("P4_FRAMECAP_EMPTY_SHM_ACTIVE_EVIDENCE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
