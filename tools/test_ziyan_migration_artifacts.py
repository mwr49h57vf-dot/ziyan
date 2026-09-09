#!/usr/bin/env python3
"""Contract checks for the E48 migration artifacts and non-Agent sample."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAPPING = ROOT / "tests/touchsprite_migration/sample_mapping.json"
AUDIT = ROOT / "tests/touchsprite_migration/api_101_static_audit.json"
SAMPLE = ROOT / "tests/touchsprite_migration/ziyan_business_sample.lua"


def assert_artifacts() -> None:
    mapping = json.loads(MAPPING.read_text(encoding="utf-8"))
    assert len(mapping["samples"]) == 22
    assert all(row["copyStatus"] == "verified" for row in mapping["samples"])
    assert all(row["sourceSha256"] == row["targetSha256"] for row in mapping["samples"])

    audit = json.loads(AUDIT.read_text(encoding="utf-8"))
    assert audit["caseCount"] == 101
    assert audit["staticOnly"] is True
    assert audit["localFunctionalPass"] is False
    assert all(set(row["deviceVerdicts"].values()) == {"NOT_RUN"} for row in audit["rows"])

    probe = "local f,e=loadfile(arg[1]); assert(f,e)"
    lua = subprocess.run(
        ["lua", "-e", probe, "-", str(SAMPLE)],
        text=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
    )
    assert lua.returncode == 0, lua.stderr


class ZiYanMigrationArtifactsContract(unittest.TestCase):
    def test_artifacts(self) -> None:
        assert_artifacts()


def main() -> None:
    assert_artifacts()
    print("ZIYAN_MIGRATION_ARTIFACTS_CONTRACT=PASS samples=22 api_cases=101")


if __name__ == "__main__":
    main()
