#!/usr/bin/env python3
"""Build traceable E48 migration mappings and a static 101-API audit."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

try:
    from ziyan_candidate_parser import parse_candidate
except ModuleNotFoundError:
    from tools.ziyan_candidate_parser import parse_candidate


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/touchsprite_migration/source"
MAPPING = ROOT / "tests/touchsprite_migration/sample_mapping.json"
MATRIX = ROOT / "api_spec/device_function_matrix.json"
CATALOG = ROOT / "api_spec/catalog.json"
OUT = ROOT / "tests/touchsprite_migration"

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_mapping() -> dict:
    samples = json.loads(MAPPING.read_text(encoding="utf-8"))["samples"]
    rows = []
    for sample in samples:
        target = ROOT / sample["targetRelativePath"]
        row = {
            "sourceRelativePath": sample["sourceRelativePath"],
            "targetRelativePath": sample["targetRelativePath"],
            "sourceSha256": sample["sourceSha256"],
            "targetSha256": sample["targetSha256"],
            "copyStatus": sample["copyStatus"],
            "copiedAtUtc": datetime.fromtimestamp(
                target.stat().st_mtime, tz=timezone.utc
            ).isoformat(),
        }
        if target.suffix.lower() == ".lua":
            row.update(
                parse_candidate(
                    sample["sourceRelativePath"],
                    target.read_text(encoding="utf-8", errors="replace"),
                )
            )
        else:
            row.update(
                {
                    "entryKind": "resource",
                    "requires": [],
                    "apiCalls": {},
                    "apiMapping": {},
                    "migrationStatus": "resource_only",
                    "unmigratableOrGaps": [],
                }
            )
        rows.append(row)
    return {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "sourceManifestMapping": str(MAPPING.relative_to(ROOT)),
        "sourceRoot": "E:\\传奇世界",
        "staticOnly": True,
        "samples": rows,
    }


def implementation_candidates(module: str, function: str) -> list[str]:
    names = {function, function[0].upper() + function[1:]}
    candidates = []
    paths = [
        ROOT / f"lua/modules/{module.capitalize()}.lua",
        ROOT / f"lua/ziyan_engine/{module}.lua",
        ROOT / "lua/ziyan_engine/compat_impl.lua",
        ROOT / f"api_spec/modules/{module}_contract.lua",
    ]
    for path in paths:
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if any(re.search(rf"\b{re.escape(name)}\b", text) for name in names):
            candidates.append(str(path.relative_to(ROOT)))
    return candidates


def build_api_audit() -> dict:
    matrix = json.loads(MATRIX.read_text(encoding="utf-8"))
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    rows = []
    for case in matrix["cases"]:
        module = case["module"]
        function = case["function"]
        locations = implementation_candidates(module, function)
        status = "source_present_device_unverified" if locations else "missing_source_candidate"
        rows.append(
            {
                "caseId": case["case_id"],
                "module": module,
                "function": function,
                "codeLocations": locations,
                "catalogStatus": case["catalog_status"],
                "implementationStatus": status,
                "minimalRepro": f"lua -e 'require(\"{module}\").{function}()' "
                "(args per api_spec catalog)",
                "fixOrGap": (
                    "Run ordered four-device final verdict; local/static evidence is not PASS."
                    if locations
                    else "Add implementation or mark unsupported with a contract-level gap."
                ),
                "deviceVerdicts": {
                    device: value["verdict"]
                    for device, value in case["device_verdicts"].items()
                },
            }
        )
    return {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "catalogCount": len(catalog["modules"]),
        "caseCount": len(rows),
        "staticOnly": True,
        "localFunctionalPass": False,
        "rows": rows,
    }


def write_dependency_graph(mapping: dict) -> None:
    lines = [
        "# E48 TouchSprite to ZiYan Dependency and Semantics Map",
        "",
        "Generated from verified `sample_mapping.json`; source analysis is static and does not prove runtime compatibility.",
        "",
    ]
    for row in mapping["samples"]:
        if row["entryKind"] == "resource":
            continue
        lines.append(f"## `{row['sourceRelativePath']}`")
        lines.append(f"- entry: `{row['entryKind']}`")
        lines.append(f"- status: `{row['migrationStatus']}`")
        lines.append(f"- requires: `{', '.join(row['requires']) or 'none'}`")
        lines.append(
            "- API mapping: "
            + (", ".join(f"`{k}` -> `{v}`" for k, v in row["apiMapping"].items()) or "none")
        )
        lines.append(
            "- stop: "
            + json.dumps(row["stopSemantics"], ensure_ascii=False, sort_keys=True)
        )
        lines.append(
            "- cleanup: "
            + json.dumps(row["cleanupSemantics"], ensure_ascii=False, sort_keys=True)
        )
        if row["unmigratableOrGaps"]:
            lines.append("- gaps: " + ", ".join(f"`{x}`" for x in row["unmigratableOrGaps"]))
        lines.append("")
    (OUT / "dependency_graph.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    mapping = build_mapping()
    (OUT / "api_mapping.json").write_text(
        json.dumps(mapping, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    audit = build_api_audit()
    (OUT / "api_101_static_audit.json").write_text(
        json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    write_dependency_graph(mapping)
    print(
        "MIGRATION_AUDIT_OK "
        f"samples={len(mapping['samples'])} api_cases={audit['caseCount']} "
        f"static_only={audit['staticOnly']}"
    )


if __name__ == "__main__":
    main()
