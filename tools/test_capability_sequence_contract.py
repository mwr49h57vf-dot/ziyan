#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tools/ziyan_capability_sequence.py").read_text(encoding="utf-8")
for needle in ("DEVICE_PASS", "sequence_blocked", ".101", ".112", ".166", ".53", ".61", "package_sha256"):
    assert needle in SOURCE, needle
print("CAPABILITY_SEQUENCE_CONTRACT=PASS")
