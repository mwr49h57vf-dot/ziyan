#!/usr/bin/env python3
from pathlib import Path

text = Path(__file__).resolve().parents[1].joinpath(
    "tools/ziyan_framecap/main.m"
).read_text()
assert "surfReuseMs" in text
assert "heavy3x ? 2500 : 250" in text
assert "softForce" in text
print("FRAMECAP_UISURFACE_REUSE_CONTRACT=PASS")
