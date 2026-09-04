#!/usr/bin/env python3
"""Fail-closed structural contract for the four-device API matrix."""
from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MATRIX = ROOT / "api_spec/device_function_matrix.json"
DEVICES = [".101", ".112", ".166", ".53"]
REQUIRED_CAPABILITIES = {
    "chat_text_input_send_clear_copy_paste_multi_turn",
    "game_rules_state_turn_score_win_phase_transition",
    "automatic_decision_trace_replay_retry_degrade_pause_resume",
    "non_visual_input_clipboard_gesture_hardware_key_app_lifecycle",
}


def main() -> None:
    data = json.loads(MATRIX.read_text(encoding="utf-8"))
    assert data["counts"]["catalog_total"] == 101
    assert data["policy"]["functional_verdict_requires_real_device"] is True
    assert data["policy"]["local_simulation_is_not_pass"] is True
    assert data["policy"]["device_order"] == DEVICES
    assert set(data["required_capabilities"]) == REQUIRED_CAPABILITIES

    cases = data["cases"]
    assert len(cases) == 101
    for case in cases:
        assert case["devices"] == DEVICES
        assert case["pass_source"] == "device_final_verdict"
        assert case["local_functional_pass"] is False
        assert case["generator"] == ["Zy.AI.pipeline", "Zy.Script.generateFromTask"]
        assert "normal" in case["coverage"]
        assert "stop_cleanup" in case["coverage"]

    print("DEVICE_FUNCTION_MATRIX_CONTRACT=PASS cases=101 devices=4")


if __name__ == "__main__":
    main()
