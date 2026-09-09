#!/usr/bin/env python3
"""Single auditable SpringBoard PID stability/rollover decision seam."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


EXPECTED_SB_IMAGE_PATH = "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
MAX_HEARTBEAT_AGE_SECONDS = 12

_REQUIRED_FIELDS = (
    "sb_image_path",
    "sb_instance_count",
    "framecap_pid",
    "framecap_continuous",
    "framecap_sha256",
    "frozen_framecap_pid",
    "frozen_framecap_sha256",
    "owner_continuous",
    "heartbeat_current",
    "heartbeat_age_seconds",
    "heartbeat_epoch",
    "current_epoch",
    "embed",
    "keep",
    "kill",
    "stop_only",
)


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        return int(str(value).strip(), 10)
    except (TypeError, ValueError):
        return None


def _bool(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "present", "active"}:
            return True
        if normalized in {"0", "false", "no", "absent", "inactive"}:
            return False
    return None


def _text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _first(raw: Mapping[str, Any], *names: str) -> Any:
    for name in names:
        if name in raw:
            return raw[name]
    return None


def parse_raw_evidence(raw: Mapping[str, Any]) -> dict[str, Any]:
    """Normalize raw snapshot fields without filling absent evidence."""

    if not isinstance(raw, Mapping):
        raise TypeError("raw snapshot evidence must be a mapping")

    parsed: dict[str, Any] = {}
    parsed["sb_image_path"] = _text(
        _first(raw, "sb_image_path", "springboard_image_path", "sb_path")
    )
    parsed["sb_instance_count"] = _int(
        _first(raw, "sb_instance_count", "springboard_instance_count", "sb_n")
    )
    parsed["framecap_pid"] = _int(_first(raw, "framecap_pid", "fc_pid"))
    parsed["framecap_continuous"] = _bool(
        _first(raw, "framecap_continuous", "fc_continuous")
    )
    parsed["framecap_sha256"] = _text(
        _first(raw, "framecap_sha256", "fc_sha256")
    )
    parsed["frozen_framecap_pid"] = _int(
        _first(raw, "frozen_framecap_pid", "frozen_fc_pid")
    )
    parsed["frozen_framecap_sha256"] = _text(
        _first(raw, "frozen_framecap_sha256", "frozen_fc_sha256")
    )
    parsed["owner_continuous"] = _bool(
        _first(raw, "owner_continuous", "owner_alive", "owner_ok")
    )
    parsed["heartbeat_current"] = _bool(
        _first(raw, "heartbeat_current", "heartbeat_fresh")
    )
    parsed["heartbeat_age_seconds"] = _int(
        _first(raw, "heartbeat_age_seconds", "heartbeat_age")
    )
    parsed["heartbeat_epoch"] = _int(
        _first(raw, "heartbeat_epoch", "heartbeat_ts")
    )
    parsed["current_epoch"] = _int(
        _first(raw, "current_epoch", "now_epoch", "snapshot_epoch")
    )
    parsed["embed"] = _int(_first(raw, "embed", "embed_active"))
    parsed["keep"] = _int(_first(raw, "keep", "keep_active"))
    parsed["kill"] = _int(_first(raw, "kill", "kill_active"))
    parsed["stop_only"] = _bool(_first(raw, "stop_only", "stop_only_state"))
    return parsed


def _invariant_reasons(evidence: Mapping[str, Any]) -> list[str]:
    parsed = parse_raw_evidence(evidence)
    reasons: list[str] = []

    for field in _REQUIRED_FIELDS:
        if parsed.get(field) is None:
            reasons.append(f"evidence_missing_{field}")

    if parsed["sb_image_path"] is not None and parsed["sb_image_path"] != EXPECTED_SB_IMAGE_PATH:
        reasons.append("sb_image_path_mismatch")
    if parsed["sb_instance_count"] is not None and parsed["sb_instance_count"] != 1:
        reasons.append("sb_multiple_instances")

    if parsed["framecap_pid"] is not None and parsed["framecap_pid"] <= 1:
        reasons.append("framecap_missing")
    if parsed["framecap_pid"] is not None and parsed["frozen_framecap_pid"] is not None:
        if parsed["framecap_pid"] != parsed["frozen_framecap_pid"]:
            reasons.append("framecap_pid_mismatch")
    if parsed["framecap_continuous"] is False:
        reasons.append("framecap_continuity_missing")
    if (
        parsed["framecap_sha256"] is not None
        and parsed["frozen_framecap_sha256"] is not None
        and parsed["framecap_sha256"] != parsed["frozen_framecap_sha256"]
    ):
        reasons.append("framecap_sha_mismatch")
    if parsed["owner_continuous"] is False:
        reasons.append("owner_continuity_missing")

    heartbeat_age = parsed["heartbeat_age_seconds"]
    heartbeat_epoch = parsed["heartbeat_epoch"]
    current_epoch = parsed["current_epoch"]
    heartbeat_stale = parsed["heartbeat_current"] is False
    if heartbeat_age is not None and heartbeat_age > MAX_HEARTBEAT_AGE_SECONDS:
        heartbeat_stale = True
    if heartbeat_age is not None and heartbeat_age < 0:
        heartbeat_stale = True
    if heartbeat_epoch is not None and current_epoch is not None:
        if heartbeat_epoch <= 0 or current_epoch < heartbeat_epoch:
            heartbeat_stale = True
        elif current_epoch - heartbeat_epoch > MAX_HEARTBEAT_AGE_SECONDS:
            heartbeat_stale = True
    if heartbeat_stale:
        reasons.append("heartbeat_stale")

    for field, reason in (
        ("embed", "embed_active"),
        ("keep", "keep_active"),
        ("kill", "kill_active"),
    ):
        if parsed[field] is not None and parsed[field] != 0:
            reasons.append(reason)
    if parsed["stop_only"] is False:
        reasons.append("stop_only_missing")
    return reasons


def evaluate_sb_state(
    frozen_sb_pid: Any,
    current_sb_pid: Any,
    evidence: Mapping[str, Any],
    verdict: str,
) -> dict[str, Any]:
    """Return a stable, rollover, or mismatch decision without verdict promotion."""

    frozen_pid = _int(frozen_sb_pid)
    current_pid = _int(current_sb_pid)
    reasons = _invariant_reasons(evidence)

    if frozen_pid is None or frozen_pid <= 1:
        reasons.append("frozen_sb_pid_missing")
    if current_pid is None or current_pid <= 1:
        reasons.append("current_sb_pid_missing")

    if frozen_pid is not None and current_pid is not None and frozen_pid == current_pid:
        if reasons:
            status = "STATE_MISMATCH"
        else:
            status = "stable"
            reasons = ["sb_pid_unchanged"]
    elif not reasons:
        status = "SB_ROLLOVER"
        reasons = ["sb_pid_changed", "rollover_invariants_hold"]
    else:
        status = "STATE_MISMATCH"
        if "sb_pid_changed" not in reasons:
            reasons.insert(0, "sb_pid_changed")

    event = None
    if status == "SB_ROLLOVER":
        event = {
            "type": "SB_ROLLOVER",
            "frozen_sb_pid": frozen_pid,
            "current_sb_pid": current_pid,
        }

    return {
        "status": status,
        "verdict": verdict,
        "event": event,
        "frozen_sb_pid": frozen_pid,
        "current_sb_pid": current_pid,
        "reasons": reasons,
    }


def evaluate_raw_snapshot(
    frozen_sb_pid: Any,
    current_sb_pid: Any,
    raw_snapshot: Mapping[str, Any],
    verdict: str,
) -> dict[str, Any]:
    """Explicit raw-snapshot entry point for shell/fixture consumers."""

    return evaluate_sb_state(
        frozen_sb_pid,
        current_sb_pid,
        parse_raw_evidence(raw_snapshot),
        verdict,
    )
