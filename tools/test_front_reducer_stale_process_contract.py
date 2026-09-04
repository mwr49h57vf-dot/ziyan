#!/usr/bin/env python3
"""Contract for rejecting a dead SBApplication foreground residue."""

from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "objc/tweak/springboard/Tweak.m"


def main() -> int:
    source = SOURCE.read_text(encoding="utf-8")
    marker = 'NSString *out = [ZiYanVarDirectory()\n'
    start = source.index('void ZiYanVolTrigPollOnce(void)')
    reducer = source[start : source.index(marker, start)]
    assert "ZiYanBundleProcessAliveState(bid) == 0" in reducer
    assert 'bid = @"com.apple.springboard";' in reducer
    print("PASS: front reducer clears confirmed-dead foreground residue")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
