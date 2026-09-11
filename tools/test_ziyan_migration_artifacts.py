#!/usr/bin/env python3
"""Contract checks for the E48 migration artifacts and non-Agent sample."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ziyan_candidate_parser import dependency_gaps, dynamic_requires, requires
from tools.ziyan_migration_audit import resolve_dependencies


MAPPING = ROOT / "tests/touchsprite_migration/sample_mapping.json"
API_MAPPING = ROOT / "tests/touchsprite_migration/api_mapping.json"
AUDIT = ROOT / "tests/touchsprite_migration/api_101_static_audit.json"
SAMPLE = ROOT / "tests/touchsprite_migration/ziyan_business_sample.lua"
RESOLUTION = ROOT / "tests/touchsprite_migration/migration_resolution.json"
SYSTEM_TOOL_SAMPLE = ROOT / "tests/touchsprite_migration/ziyan_system_tool_sample.lua"


def assert_artifacts() -> None:
    mapping = json.loads(MAPPING.read_text(encoding="utf-8"))
    assert len(mapping["samples"]) == 22
    assert all(row["copyStatus"] == "verified" for row in mapping["samples"])
    assert all(row["sourceSha256"] == row["targetSha256"] for row in mapping["samples"])
    assert all(row.get("copiedAtUtc") for row in mapping["samples"])
    assert mapping["exclusions"]["count"] == 41
    assert mapping["exclusions"]["policy"]
    assert all(
        all(
            key in row
            for key in (
                "sourceRelativePath",
                "targetRelativePath",
                "sourceSha256",
                "targetSha256",
                "copiedAtUtc",
                "copyStatus",
                "sourceEntryFile",
                "sourceModules",
                "sourceDependencies",
                "sourceResources",
                "sourceApiFacts",
            )
        )
        for row in mapping["samples"]
    )

    audit = json.loads(AUDIT.read_text(encoding="utf-8"))
    assert audit["caseCount"] == 101
    assert audit["staticOnly"] is True
    assert audit["localFunctionalPass"] is False
    allowed_verdicts = {
        "NOT_RUN",
        "PARTIAL_RUNTIME_PRESENT",
        "BLOCKED_UNIMPLEMENTED",
    }
    assert all(
        set(row["deviceVerdicts"].values()) <= allowed_verdicts
        for row in audit["rows"]
    )
    api_mapping = json.loads(API_MAPPING.read_text(encoding="utf-8"))
    assert all(
        all(
            key in row
            for key in (
                "entryKind",
                "dynamicRequires",
                "dependencyStatus",
                "resolvedDependencies",
                "unresolvedDependencies",
                "ambiguousDependencies",
                "cycleDetected",
                "stopSemantics",
                "cleanupSemantics",
                "syntaxCheck",
            )
        )
        for row in api_mapping["samples"]
    )
    assert sum(
        row["syntaxCheck"]["status"] == "failed"
        for row in api_mapping["samples"]
    ) == 12

    probe = "local f,e=loadfile(arg[1]); assert(f,e)"
    lua = subprocess.run(
        ["lua", "-e", probe, "-", str(SAMPLE)],
        text=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
    )
    assert lua.returncode == 0, lua.stderr

    resolution = json.loads(RESOLUTION.read_text(encoding="utf-8"))
    assert resolution["candidateCount"] == 22
    assert len(resolution["candidates"]) == 22
    assert resolution["candidateCount"] > 0
    assert sum(
        row["status"] == "MIGRATED_BOUNDED_REWRITE"
        for row in resolution["candidates"]
    ) == 19
    assert all(
        row["status"]
        in {
            "MIGRATED_EXECUTABLE",
            "MIGRATED_RESOURCE",
            "MIGRATED_BOUNDED_REWRITE",
            "BLOCKED",
        }
        for row in resolution["candidates"]
    )
    assert all(row["sourceSha256"] and row["minimalRepro"] for row in resolution["candidates"])
    assert all(row["rollbackPoint"] and row["verdict"] for row in resolution["candidates"])
    assert all(row["evidence"] for row in resolution["candidates"])
    assert all(
        (ROOT / evidence).is_file()
        for row in resolution["candidates"]
        for evidence in row["evidence"]
    )

    system_tool_lua = subprocess.run(
        ["lua", "-e", probe, "-", str(SYSTEM_TOOL_SAMPLE)],
        text=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
    )
    assert system_tool_lua.returncode == 0, system_tool_lua.stderr


class ZiYanMigrationArtifactsContract(unittest.TestCase):
    def test_artifacts(self) -> None:
        assert_artifacts()

    def test_nested_dynamic_require_is_classified_without_execution(self) -> None:
        text = """
        -- require("ignored")
        require("TSLib")
        require(("" .. string.char(84) .. string.char(83)))
        dofile(module_path)
        """
        assert requires(text) == ["TSLib"]
        assert dynamic_requires(text) == ['("" .. string.char(84) .. string.char(83))']
        assert dependency_gaps(text) == [
            "dynamic_dofile_path_unresolved",
            "dynamic_module_path_unresolved",
        ]

    def test_dependency_cycle_is_marked_on_each_candidate(self) -> None:
        rows = [
            {
                "entryKind": "top_level_bootstrap",
                "sourceRelativePath": "a.lua",
                "requires": ["b"],
                "dynamicRequires": [],
                "unmigratableOrGaps": [],
            },
            {
                "entryKind": "library_or_unresolved",
                "sourceRelativePath": "b.lua",
                "requires": ["a"],
                "dynamicRequires": [],
                "unmigratableOrGaps": [],
            },
        ]
        resolve_dependencies(rows)
        assert all(row["cycleDetected"] for row in rows)
        assert all("dependency_cycle" in row["unmigratableOrGaps"] for row in rows)


def main() -> None:
    assert_artifacts()
    print("ZIYAN_MIGRATION_ARTIFACTS_CONTRACT=PASS samples=22 api_cases=101")


if __name__ == "__main__":
    main()
