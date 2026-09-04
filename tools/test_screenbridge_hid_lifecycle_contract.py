#!/usr/bin/env python3
"""Static contract for singleton IOHID-client ownership in ZiYanScreenBridge."""

from pathlib import Path
import re
import sys


SOURCE = Path(__file__).resolve().parents[1] / "objc/tweak/springboard/ZiYanScreenBridge.m"


def method_body(source: str, signature: str) -> str:
    match = re.search(
        rf"^- \(void\){re.escape(signature)} \{{(?P<body>.*?)(?=^- \(|\Z)",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"missing method: {signature}")
    return match.group(0)


def main() -> int:
    source = SOURCE.read_text(encoding="utf-8")

    ensure = method_body(source, "ensureHIDClient")
    assert "@synchronized(self)" in ensure
    assert "if (!_hidClient && ZiYanIOHIDEventSystemClientCreate)" in ensure
    assert ensure.count("ZiYanIOHIDEventSystemClientCreate(kCFAllocatorDefault)") == 1

    release = method_body(source, "releaseHIDClient")
    assert "_hidClient = NULL;" in release
    assert "CFRelease(client);" in release

    dealloc = method_body(source, "dealloc")
    assert "[self releaseHIDClient];" in dealloc

    for entrypoint in ("startInSpringBoard", "startInBackboardd"):
        body = method_body(source, entrypoint)
        assert "[self ensureHIDClient];" in body, entrypoint
        assert "ZiYanIOHIDEventSystemClientCreate(kCFAllocatorDefault)" not in body

    print("PASS: ZiYanScreenBridge owns one synchronized IOHID client per process")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
