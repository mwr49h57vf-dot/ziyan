#!/usr/bin/env python3
"""Contract checks for the AI pipeline's real-device-only verdict semantics."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AI = (ROOT / "lua/modules/AI.lua").read_text(encoding="utf-8")


def require(text: str, needle: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing contract text: {needle}")


def main() -> None:
    # A skipped or load-only run must never become a functional PASS.
    require(AI, 'reason = "REAL_DEVICE_TEST_REQUIRED"')
    require(AI, 'report.ok = verified')
    require(AI, 'detail.real_device')
    require(AI, 'opts.real_device == true')

    # The real-device path must execute the generated script, not force a
    # no-shot/light mode that avoids the actual visual and interaction path.
    require(AI, 'light_test = false')
    require(AI, 'real_device = true')
    require(AI, 'RESULT_READY')
    require(AI, 'capability_evidence')
    require(AI, 'session_id')
    require(AI, 'nonce')
    require(AI, 'cleanup_active')

    # Generated business code remains constrained to the Zy module surface.
    require(AI, 'L("-- AI-GENERATED')
    require(AI, 'Zy.* only')

    print("AI_REAL_DEVICE_ONLY_CONTRACT=PASS")


if __name__ == "__main__":
    main()
