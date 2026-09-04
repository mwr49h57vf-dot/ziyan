#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE = (ROOT / "tools/zy_generated_capability_gate.sh").read_text(encoding="utf-8")


def main() -> None:
    for needle in (
        "RESULT_READY",
        "EXPECTED_PACKAGE_VERSION",
        "EXPECTED_PACKAGE_SHA",
        "package_version",
        "package_sha",
        "TARGET_BID",
        "NONCE_OK",
        "SESSION_OK",
        ".ziyan_capability_context",
        "pipeline_ok=",
        'FC_N" = "1"',
        'CLEANUP_ACTIVE" = "0"',
        'CLEANUP_EMBED" = "0"',
        "local_simulation_pass=false",
    ):
        assert needle in GATE, needle
    print("GENERATED_CAPABILITY_GATE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
