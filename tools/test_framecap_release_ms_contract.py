#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cap = (root / "objc/shared/ZiYanFrameCapture.m").read_text()
hdr = (root / "objc/shared/ZiYanFrameCapture.h").read_text()
main = (root / "tools/ziyan_framecap/main.m").read_text()
assert "ZiYanFrameCaptureLastReleaseMs" in hdr
assert "ZiYanFrameCaptureLastReleaseMs" in cap
assert "sLastCapReleaseMs" in cap
assert "release_ms=" in main
assert "src_lock_ms=" in main
assert "resident_ms=" in main
assert "heavy3x ? 2500 : 250" in main
assert "surfReuseMs" in main
print("FRAMECAP_RELEASE_MS_CONTRACT=PASS")
