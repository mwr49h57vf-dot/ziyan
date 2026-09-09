#!/usr/bin/env python3
"""Contract tests for auditable SpringBoard PID rollover decisions."""

from sb_rollover_contract import evaluate_sb_state


def evidence(**overrides):
    state = {
        "sb_image_path": "/System/Library/CoreServices/SpringBoard.app/SpringBoard",
        "sb_instance_count": 1,
        "framecap_pid": 11601,
        "framecap_continuous": True,
        "framecap_sha256": "b380ecdd69fa2133e28b57e1e766ff7623bba9b5a065fee0efcfab95a4889e0d",
        "frozen_framecap_pid": 11601,
        "frozen_framecap_sha256": "b380ecdd69fa2133e28b57e1e766ff7623bba9b5a065fee0efcfab95a4889e0d",
        "owner_continuous": True,
        "heartbeat_current": True,
        "heartbeat_age_seconds": 4,
        "heartbeat_epoch": 1788797940,
        "current_epoch": 1788797944,
        "embed": 0,
        "keep": 0,
        "kill": 0,
        "stop_only": True,
    }
    state.update(overrides)
    return state


def assert_reasons(result, *reasons):
    assert result["reasons"] == list(reasons)


def test_unchanged_pid_is_stable():
    result = evaluate_sb_state(46408, 46408, evidence(), "PASS_PENDING_HUMAN")

    assert result["status"] == "stable"
    assert result["event"] is None
    assert result["frozen_sb_pid"] == 46408
    assert result["current_sb_pid"] == 46408
    assert_reasons(result, "sb_pid_unchanged")


def test_pid_rollover_is_allowed_when_all_invariants_hold():
    result = evaluate_sb_state(46408, 99702, evidence(), "PASS_PENDING_HUMAN")

    assert result["status"] == "SB_ROLLOVER"
    assert result["event"] == {
        "type": "SB_ROLLOVER",
        "frozen_sb_pid": 46408,
        "current_sb_pid": 99702,
    }
    assert result["frozen_sb_pid"] == 46408
    assert result["current_sb_pid"] == 99702
    assert result["verdict"] == "PASS_PENDING_HUMAN"
    assert_reasons(result, "sb_pid_changed", "rollover_invariants_hold")


def test_rollover_rejects_each_broken_invariant():
    cases = [
        ({"framecap_sha256": "changed"}, "framecap_sha_mismatch"),
        ({"framecap_continuous": False}, "framecap_continuity_missing"),
        ({"framecap_pid": 0}, "framecap_missing"),
        ({"owner_continuous": False}, "owner_continuity_missing"),
        ({"heartbeat_current": False}, "heartbeat_stale"),
        ({"heartbeat_age_seconds": 999}, "heartbeat_stale"),
        ({"sb_image_path": "/wrong/SpringBoard"}, "sb_image_path_mismatch"),
        ({"sb_instance_count": 2}, "sb_multiple_instances"),
        ({"embed": 1}, "embed_active"),
        ({"keep": 1}, "keep_active"),
        ({"kill": 1}, "kill_active"),
        ({"stop_only": False}, "stop_only_missing"),
    ]

    for overrides, reason in cases:
        result = evaluate_sb_state(46408, 99702, evidence(**overrides), "PASS_PENDING_HUMAN")
        assert result["status"] == "STATE_MISMATCH", (overrides, result)
        assert result["event"] is None
        assert result["frozen_sb_pid"] == 46408
        assert result["current_sb_pid"] == 99702
        assert reason in result["reasons"]


def test_rollover_requires_exact_framecap_sha():
    result = evaluate_sb_state(
        46408,
        99702,
        evidence(
            framecap_sha256="new",
            frozen_framecap_sha256="old",
        ),
        "PASS_PENDING_HUMAN",
    )

    assert result["status"] == "STATE_MISMATCH"
    assert "framecap_sha_mismatch" in result["reasons"]


def test_rollover_requires_framecap_pid_and_fresh_heartbeat():
    result = evaluate_sb_state(
        46408,
        99702,
        evidence(framecap_pid=11602),
        "PASS_PENDING_HUMAN",
    )

    assert result["status"] == "STATE_MISMATCH"
    assert "framecap_pid_mismatch" in result["reasons"]


def test_missing_raw_evidence_never_defaults_to_allow():
    result = evaluate_sb_state(46408, 99702, {}, "PASS_PENDING_HUMAN")

    assert result["status"] == "STATE_MISMATCH"
    assert "evidence_missing_heartbeat_epoch" in result["reasons"]
    assert result["event"] is None


def test_pending_human_verdict_is_never_promoted():
    result = evaluate_sb_state(46408, 99702, evidence(), "PASS_PENDING_HUMAN")

    assert result["verdict"] == "PASS_PENDING_HUMAN"
    assert result["verdict"] != "PASS"


if __name__ == "__main__":
    test_unchanged_pid_is_stable()
    test_pid_rollover_is_allowed_when_all_invariants_hold()
    test_rollover_rejects_each_broken_invariant()
    test_rollover_requires_exact_framecap_sha()
    test_rollover_requires_framecap_pid_and_fresh_heartbeat()
    test_missing_raw_evidence_never_defaults_to_allow()
    test_pending_human_verdict_is_never_promoted()
    print("PASS test_sb_rollover_contract")
