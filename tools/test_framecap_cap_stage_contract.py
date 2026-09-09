#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = (root / "tools/ziyan_framecap/main.m").read_text()
cap = (root / "objc/shared/ZiYanFrameCapture.m").read_text()
hdr = (root / "objc/shared/ZiYanFrameCapture.h").read_text()
assert "ZiYanFrameCaptureLastCapStages" in hdr
assert "ZiYanFrameCaptureLastCapStages" in cap
assert "sLastCapCreateMs" in cap
assert "sLastCapXferMs" in cap
assert "sLastCapCopyMs" in cap
assert "sLastCapDestLockMs" in cap
assert "create_ms=" in main
assert "xfer_ms=" in main
assert "copy_ms=" in main
assert "destlock_ms=" in main
print("FRAMECAP_CAP_STAGE_CONTRACT=PASS")
