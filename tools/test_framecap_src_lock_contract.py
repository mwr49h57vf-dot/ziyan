#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cap = (root / "objc/shared/ZiYanFrameCapture.m").read_text()
hdr = (root / "objc/shared/ZiYanFrameCapture.h").read_text()
main = (root / "tools/ziyan_framecap/main.m").read_text()
assert "ZiYanFrameCaptureLastSrcLockMs" in hdr
assert "ZiYanFrameCaptureLastSrcLockMs" in cap
assert "sLastCapSrcLockMs" in cap
assert "src_lock_ms=" in main
assert "resident_ms=" in main
assert "destlock_ms=" in main
assert "heavy3x ? 2500 : 250" in main
assert "surfReuseMs" in main
print("FRAMECAP_SRC_LOCK_CONTRACT=PASS")
