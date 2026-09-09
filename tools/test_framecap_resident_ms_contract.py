#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
res_h = (root / "objc/shared/ZiYanFrameResident.h").read_text()
res_m = (root / "objc/shared/ZiYanFrameResident.m").read_text()
main = (root / "tools/ziyan_framecap/main.m").read_text()
assert "ZiYanFrameResidentLastRenewMs" in res_h
assert "ZiYanFrameResidentLastRenewMs" in res_m
assert "sLastResidentMs" in res_m
assert "resident_ms=" in main
assert "destlock_ms=" in main
assert "skip_px=" in main
assert "heavy3x ? 2500 : 250" in main
assert "surfReuseMs" in main
print("FRAMECAP_RESIDENT_MS_CONTRACT=PASS")
