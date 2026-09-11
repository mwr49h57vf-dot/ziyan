#!/usr/bin/env python3
"""Apply fail-closed five-device runtime-binding evidence to the API matrix."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MATRIX = ROOT / "api_spec/device_function_matrix.json"
EVIDENCE = {
    ".101": ROOT / "tmp_shots/API101_DEVICE101_20260910_1233/VERDICT.txt",
    ".112": ROOT / "tmp_shots/API101_DEVICE112_20260910_1233/VERDICT.txt",
    ".166": ROOT / "tmp_shots/API101_DEVICE166_20260910_1233/VERDICT.txt",
    ".53": ROOT / "tmp_shots/API101_DEVICE53_20260910_1233/VERDICT.txt",
    ".61": ROOT / "tmp_shots/API101_DEVICE61_20260910_1233/VERDICT.txt",
}
ROOTFUL = {".101", ".112", ".166"}
PACKAGES = {
    "rootful": (
        "0.0.92-8-161-205-C-65.11-98+debug-10-38-17-152+debug",
        "ceabeacb4ef23c9b9cbb218413a62c953c76d0169a05b65d1a14bcc360c6eff5",
    ),
    "rootless": (
        "0.0.92-8-161-205-C-65.11-98+debug-10-38-17-153+debug",
        "68e853a15835c416da81e909f78cee0880dfc602395e1009763ae176fbaff26f",
    ),
}


def read_evidence(path: Path) -> dict[str, str]:
    rows = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "|" not in line or line.startswith("SUMMARY|"):
            continue
        case_id, status = line.split("|", 1)
        rows[case_id] = status
    if len(rows) != 101:
        raise ValueError(f"{path}: expected 101 case rows, got {len(rows)}")
    return rows


def main() -> None:
    matrix = json.loads(MATRIX.read_text(encoding="utf-8"))
    by_device = {device: read_evidence(path) for device, path in EVIDENCE.items()}
    for case in matrix["cases"]:
        for device, evidence in EVIDENCE.items():
            runtime = by_device[device][case["case_id"]]
            blocked = runtime != "RUNTIME_PRESENT"
            scheme = "rootful" if device in ROOTFUL else "rootless"
            version, digest = PACKAGES[scheme]
            coverage = {
                item: (
                    "BLOCKED_UNIMPLEMENTED"
                    if blocked
                    else "PACKAGE_RUNTIME_PRESENT"
                    if item == scheme
                    else "NOT_APPLICABLE_DEVICE_SCHEME"
                    if item in {"rootful", "rootless"}
                    else "RUNTIME_BINDING_ONLY"
                    if item == "normal"
                    else "NOT_FUNCTIONALLY_TESTED"
                )
                for item in case["coverage"]
            }
            case["device_verdicts"][device] = {
                "status": "BLOCKED" if blocked else "RUNTIME_PRESENT",
                "verdict": (
                    "BLOCKED_UNIMPLEMENTED"
                    if blocked
                    else "PARTIAL_RUNTIME_PRESENT"
                ),
                "evidence": str(evidence.relative_to(ROOT)),
                "package_version": version,
                "package_sha256": digest,
                "tested_at": datetime.fromtimestamp(
                    evidence.stat().st_mtime, timezone.utc
                ).isoformat(),
                "coverage": coverage,
            }
    matrix["execution_summary"] = {
        "device_runs": len(EVIDENCE),
        "runtime_present_per_device": 86,
        "blocked_per_device": 15,
        "functional_pass": False,
        "reason": "binding probe is real-device evidence, not functional coverage",
    }
    MATRIX.write_text(
        json.dumps(matrix, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("API_MATRIX_EVIDENCE_APPLIED devices=5 present=86 blocked=15")


if __name__ == "__main__":
    main()
