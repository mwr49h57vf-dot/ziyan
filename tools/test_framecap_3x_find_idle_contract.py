#!/usr/bin/env python3
from pathlib import Path

text = Path(__file__).resolve().parents[1].joinpath(
    "tools/ziyan_framecap/main.m"
).read_text()
assert "idle = heavy3x ? 25000 : 5000;" in text
print("FRAMECAP_3X_FIND_IDLE_CONTRACT=PASS")
