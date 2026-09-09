#!/usr/bin/env python3
from pathlib import Path

text = Path(__file__).resolve().parents[1].joinpath(
    "tools/ziyan_framecap/main.m"
).read_text()
assert "CapWriteCost(" in text
assert ".ziyan_last_cap_cost" in text
assert ".ziyan_cap_cost.log" in text
assert 'via=%s\\ncost_ms=' in text or "via=%s\ncost_ms=" in text
print("FRAMECAP_CAP_COST_CONTRACT=PASS")
