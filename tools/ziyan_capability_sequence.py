#!/usr/bin/env python3
"""Fail-closed per-capability device-order ledger for real-device gates."""
from __future__ import annotations

import argparse
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "tmp_shots" / "CAPABILITY_SEQUENCE" / "ledger.json"
DEVICES = [".101", ".112", ".166", ".53", ".61"]
CAPABILITIES = {"chat", "rules", "decision", "non_visual"}


def load() -> dict:
    if not LEDGER.exists():
        return {"schema_version": 1, "capabilities": {}}
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def save(data: dict) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".ledger.", dir=str(LEDGER.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(name, LEDGER)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def validate(cap: str, device: str) -> None:
    if cap not in CAPABILITIES:
        raise SystemExit(f"invalid_capability:{cap}")
    if device not in DEVICES:
        raise SystemExit(f"invalid_device:{device}")


def check(cap: str, device: str) -> None:
    validate(cap, device)
    rows = load().setdefault("capabilities", {}).setdefault(cap, {})
    current = rows.get(device, {})
    if current.get("verdict") == "DEVICE_PASS":
        raise SystemExit(f"already_passed:{cap}:{device}")
    index = DEVICES.index(device)
    for previous in DEVICES[:index]:
        verdict = rows.get(previous, {}).get("verdict")
        if verdict != "DEVICE_PASS":
            raise SystemExit(f"sequence_blocked:{cap}:{previous}:{verdict or 'NOT_RUN'}")
    print(f"SEQUENCE_ALLOWED capability={cap} device={device}")


def record(args: argparse.Namespace) -> None:
    validate(args.capability, args.device)
    data = load()
    rows = data.setdefault("capabilities", {}).setdefault(args.capability, {})
    rows[args.device] = {
        "verdict": args.verdict,
        "status": args.verdict,
        "evidence": args.evidence,
        "package_version": args.package_version,
        "package_sha256": args.package_sha256,
        "fixture": args.fixture,
        "blocked_reason": args.blocked_reason,
        "tested_at": datetime.now(timezone.utc).isoformat(),
    }
    save(data)
    print(f"SEQUENCE_RECORDED capability={args.capability} device={args.device} verdict={args.verdict}")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    check_parser = sub.add_parser("check")
    check_parser.add_argument("--capability", required=True)
    check_parser.add_argument("--device", required=True)
    record_parser = sub.add_parser("record")
    record_parser.add_argument("--capability", required=True)
    record_parser.add_argument("--device", required=True)
    record_parser.add_argument("--verdict", required=True)
    record_parser.add_argument("--evidence", default="")
    record_parser.add_argument("--package-version", default="")
    record_parser.add_argument("--package-sha256", default="")
    record_parser.add_argument("--fixture", default="com.xztl.ios")
    record_parser.add_argument("--blocked-reason", default="")
    args = parser.parse_args()
    if args.command == "check":
        check(args.capability, args.device)
    else:
        record(args)


if __name__ == "__main__":
    main()
