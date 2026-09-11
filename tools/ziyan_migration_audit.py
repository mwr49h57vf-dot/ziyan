#!/usr/bin/env python3
"""Build traceable E48 migration mappings and a static 101-API audit."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

try:
    from ziyan_candidate_parser import parse_candidate
except ModuleNotFoundError:
    from tools.ziyan_candidate_parser import parse_candidate


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/touchsprite_migration/source"
MAPPING = ROOT / "tests/touchsprite_migration/sample_mapping.json"
MANIFEST = ROOT / "e48_legend_manifest.json"
MATRIX = ROOT / "api_spec/device_function_matrix.json"
CATALOG = ROOT / "api_spec/catalog.json"
OUT = ROOT / "tests/touchsprite_migration"
REWRITES = OUT / "rewrites" / "manifest.json"


def clean_manifest_value(value: object) -> object:
    if value == [{}] or value == {}:
        return []
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def syntax_check(path: Path) -> dict[str, str]:
    probe = (
        "local f,e=loadfile(arg[1]); "
        "if not f then io.stderr:write(e or 'loadfile failed'); os.exit(1) end"
    )
    try:
        result = subprocess.run(
            ["lua", "-e", probe, "-", str(path)],
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        return {
            "mode": "loadfile_only",
            "status": "tool_missing",
            "detail": str(error),
        }
    if result.returncode == 0:
        return {"mode": "loadfile_only", "status": "pass", "detail": ""}
    return {
        "mode": "loadfile_only",
        "status": "failed",
        "detail": (result.stderr or result.stdout).strip().splitlines()[0],
    }


def valid_bounded_rewrite(row: dict) -> bool:
    relative = row.get("rewriteRelativePath")
    target = ROOT / relative if isinstance(relative, str) else None
    if target is None or not target.is_file():
        return False
    if row.get("rewriteSha256") != sha256(target):
        return False
    loadfile = row.get("loadfile") or {}
    return loadfile.get("mode") == "loadfile_only" and loadfile.get("status") == "pass"


def resolve_dependencies(rows: list[dict]) -> None:
    candidates = [row for row in rows if row["entryKind"] != "resource"]
    by_basename: dict[str, list[str]] = {}
    for row in candidates:
        path = Path(row["sourceRelativePath"])
        by_basename.setdefault(path.stem.lower(), []).append(row["sourceRelativePath"])

    for row in candidates:
        source = Path(row["sourceRelativePath"])
        resolved = []
        unresolved = []
        ambiguous = []
        for name in row["requires"]:
            matches = []
            sibling = source.parent / f"{name}.lua"
            if any(item["sourceRelativePath"] == sibling.as_posix() for item in candidates):
                matches = [sibling.as_posix()]
            else:
                matches = by_basename.get(Path(name).stem.lower(), [])
            if len(matches) == 1:
                resolved.append(matches[0])
            elif len(matches) > 1:
                ambiguous.append({"require": name, "candidates": sorted(matches)})
            else:
                unresolved.append(name)
        row["resolvedDependencies"] = sorted(set(resolved))
        row["unresolvedDependencies"] = sorted(set(unresolved))
        row["ambiguousDependencies"] = ambiguous
        row["dependencyStatus"] = (
            "dynamic_and_static_unresolved"
            if row.get("dynamicRequires") and (unresolved or ambiguous)
            else "dynamic_unresolved"
            if row.get("dynamicRequires")
            else "static_ambiguous"
            if ambiguous
            else "static_unresolved"
            if unresolved
            else "resolved_or_external"
        )

    graph = {
        row["sourceRelativePath"]: set(row.get("resolvedDependencies", []))
        for row in candidates
    }
    cycles = []

    def visit(node: str, path: list[str], active: set[str]) -> None:
        if node in active:
            cycle = path[path.index(node):] + [node]
            if cycle not in cycles:
                cycles.append(cycle)
            return
        if node not in graph:
            return
        for child in sorted(graph[node]):
            visit(child, path + [child], active | {node})

    for node in sorted(graph):
        visit(node, [node], set())
    cycle_nodes = {item for cycle in cycles for item in cycle}
    for row in candidates:
        row["cycleDetected"] = row["sourceRelativePath"] in cycle_nodes
        if row["cycleDetected"] and "dependency_cycle" not in row["unmigratableOrGaps"]:
            row["unmigratableOrGaps"].append("dependency_cycle")
            row["unmigratableOrGaps"].sort()


def build_mapping() -> dict:
    mapping_data = json.loads(MAPPING.read_text(encoding="utf-8"))
    samples = mapping_data["samples"]
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if mapping_data.get("sourceManifestSha256") != sha256(MANIFEST):
        raise ValueError("sample mapping source manifest SHA-256 is stale")
    manifest_by_path = {
        item["relativePath"]: item
        for item in manifest.get("files", [])
        if item.get("classification") == "migration_candidate"
    }
    rows = []
    for sample in samples:
        target = ROOT / sample["targetRelativePath"]
        source = manifest_by_path.get(sample["sourceRelativePath"], {})
        if not target.is_file():
            raise FileNotFoundError(target)
        if sample.get("copyStatus") != "verified":
            raise ValueError(f"unverified copy: {sample['sourceRelativePath']}")
        target_digest = sha256(target)
        if target_digest != sample.get("targetSha256"):
            raise ValueError(f"target SHA-256 mismatch: {sample['sourceRelativePath']}")
        if target_digest != sample.get("sourceSha256"):
            raise ValueError(f"source/target SHA-256 mismatch: {sample['sourceRelativePath']}")
        if source.get("sha256") != sample.get("sourceSha256"):
            raise ValueError(f"manifest SHA-256 mismatch: {sample['sourceRelativePath']}")
        row = {
            "sourceRelativePath": sample["sourceRelativePath"],
            "targetRelativePath": sample["targetRelativePath"],
            "sourceSha256": sample["sourceSha256"],
            "sourceSize": source.get("size", sample.get("sourceSize")),
            "sourceMtimeUtc": source.get("mtimeUtc", sample.get("sourceMtimeUtc")),
            "sourceExtension": source.get("extension", sample.get("sourceExtension")),
            "sourceTextEncoding": source.get(
                "textEncoding", sample.get("sourceTextEncoding")
            ),
            "sourceClassification": source.get(
                "classification", sample.get("sourceClassification")
            ),
            "sourceEntryFile": bool(
                source.get("entryFile", sample.get("sourceEntryFile", False))
            ),
            "sourceModules": clean_manifest_value(
                source.get("modules", sample.get("sourceModules", []))
            ),
            "sourceDependencies": clean_manifest_value(
                source.get("fileDependencies", sample.get("sourceDependencies", []))
            ),
            "sourceResources": clean_manifest_value(
                source.get("resources", sample.get("sourceResources", []))
            ),
            "sourceApiFacts": clean_manifest_value(
                source.get("touchSpriteApiCalls", sample.get("sourceApiFacts", []))
            ),
            "targetSha256": sample["targetSha256"],
            "targetSize": target.stat().st_size,
            "copyStatus": sample["copyStatus"],
            "copiedAtUtc": sample.get("copiedAtUtc"),
        }
        if not row["copiedAtUtc"]:
            raise ValueError(f"missing copy timestamp: {sample['sourceRelativePath']}")
        if target.suffix.lower() == ".lua":
            row.update(
                parse_candidate(
                    sample["sourceRelativePath"],
                    target.read_text(encoding="utf-8", errors="replace"),
                )
            )
            row["syntaxCheck"] = syntax_check(target)
        else:
            row.update(
                {
                    "entryKind": "resource",
                    "requires": [],
                    "dynamicRequires": [],
                    "dependencyStatus": "none_detected",
                    "apiCalls": {},
                    "apiMapping": {},
                    "migrationStatus": "resource_only",
                    "unmigratableOrGaps": [],
                    "resolvedDependencies": [],
                    "unresolvedDependencies": [],
                    "ambiguousDependencies": [],
                    "cycleDetected": False,
                    "stopSemantics": {
                        "closeApp": False,
                        "lua_exit": False,
                        "unboundedLoop": False,
                    },
                    "cleanupSemantics": {
                        "directFileIo": False,
                        "shellMutation": False,
                        "remoteFtp": False,
                    },
                    "syntaxCheck": {
                        "mode": "loadfile_only",
                        "status": "not_applicable",
                        "detail": "",
                    },
                }
            )
        rows.append(row)
    resolve_dependencies(rows)
    return {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "sourceManifestMapping": str(MAPPING.relative_to(ROOT)),
        "sourceRoot": "E:\\传奇世界",
        "sourceBoundary": {
            "accessMode": "read_only_copy",
            "manifestSha256": mapping_data.get("sourceManifestSha256"),
            "root": "E:\\传奇世界",
        },
        "exclusions": json.loads(MAPPING.read_text(encoding="utf-8")).get(
            "exclusions", {}
        ),
        "staticOnly": True,
        "samples": rows,
    }


def build_migration_resolution(mapping: dict) -> dict:
    """Give every copied candidate one terminal migration disposition."""
    executable_targets = {
        "系统工具/main.lua": "tests/touchsprite_migration/ziyan_business_sample.lua",
        "系统工具/ZYXiTongGongJu.lua": (
            "tests/touchsprite_migration/ziyan_system_tool_sample.lua"
        ),
    }
    rewrite_rows = {}
    if REWRITES.is_file():
        rewrite_data = json.loads(REWRITES.read_text(encoding="utf-8"))
        rewrite_rows = {
            row["sourceRelativePath"]: row for row in rewrite_data["rewrites"]
        }
    rows = []
    for source in mapping["samples"]:
        relative = source["sourceRelativePath"]
        target = executable_targets.get(relative)
        bounded = rewrite_rows.get(relative)
        if bounded and valid_bounded_rewrite(bounded):
            status = "MIGRATED_BOUNDED_REWRITE"
            migrated_target = bounded["rewriteRelativePath"]
            verdict = bounded["localVerdict"]
            evidence = [
                bounded["rewriteRelativePath"],
                "tests/touchsprite_migration/rewrites/manifest.json",
            ]
            reasons = list(bounded["retainedBlockers"])
            minimal_repro = bounded["localRepro"]
        elif source["entryKind"] == "resource":
            status = "MIGRATED_RESOURCE"
            migrated_target = source["targetRelativePath"]
            verdict = "STATIC_RESOURCE_SHA_VERIFIED"
            evidence = ["tests/touchsprite_migration/sample_mapping.json"]
            reasons = []
            minimal_repro = f"shasum -a 256 '{migrated_target}'"
        elif target:
            status = "MIGRATED_EXECUTABLE"
            migrated_target = target
            verdict = (
                "DEVICE_PASS_E48_FIVE_DEVICE"
                if relative == "系统工具/main.lua"
                else "DEVICE_PASS_101"
            )
            evidence = (
                [
                    "tmp_shots/E48_DEVICE101_20260909_211121/SUMMARY.txt",
                    "tmp_shots/E48_DEVICE112_20260909_204440/SUMMARY.txt",
                    "tmp_shots/E48_DEVICE166_20260909_213954/SUMMARY.txt",
                    "tmp_shots/E48_DEVICE166_20260909_214618/SUMMARY.txt",
                    "tmp_shots/E48_DEVICE53_20260910_002642/SUMMARY.txt",
                    "tmp_shots/E48_DEVICE53_20260910_121759/device_verdicts/cold_start_device.txt",
                    "tmp_shots/E48_DEVICE61_20260910_121258/SUMMARY.txt",
                ]
                if relative == "系统工具/main.lua"
                else [
                    "tmp_shots/MIGRATION_SYSTEM_TOOL_101_20260910_1221/VERDICT.txt"
                ]
            )
            reasons = []
            minimal_repro = f"lua '{target}'"
        else:
            status = "BLOCKED"
            migrated_target = None
            verdict = "BLOCKED_STATIC_EVIDENCE"
            evidence = ["tests/touchsprite_migration/api_mapping.json"]
            reasons = list(source.get("unmigratableOrGaps", []))
            if source.get("unresolvedDependencies"):
                reasons.append("unresolved_dependencies")
            if source.get("ambiguousDependencies"):
                reasons.append("ambiguous_dependencies")
            if source.get("syntaxCheck", {}).get("status") == "failed":
                reasons.append("source_syntax_or_encryption_failure")
            if not reasons:
                reasons.append("dependency_only_no_runnable_entry")
            reasons = sorted(set(reasons))
            minimal_repro = (
                "PYTHONPATH=. python3 tools/ziyan_candidate_parser.py "
                f"'{source['targetRelativePath']}'"
            )
        target_sha = sha256(ROOT / migrated_target) if migrated_target else None
        rows.append(
            {
                "sourceRelativePath": relative,
                "sourceSha256": source["sourceSha256"],
                "status": status,
                "migratedTarget": migrated_target,
                "targetSha256": target_sha,
                "loadfile": bounded.get("loadfile")
                if bounded
                else {
                    "mode": "loadfile_only",
                    "status": "not_applicable",
                    "detail": "",
                },
                "blockers": reasons,
                "retainedBlockers": reasons if bounded else [],
                "minimalRepro": minimal_repro,
                "evidence": evidence,
                "rollbackPoint": (
                    f"remove {migrated_target}"
                    if migrated_target and migrated_target != source["targetRelativePath"]
                    else "source copy is immutable; no runtime change"
                ),
                "verdict": verdict,
            }
        )
    return {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "candidateCount": len(rows),
        "sourceCopiesImmutable": True,
        "candidates": rows,
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
            f"- dynamic requires: `{', '.join(row.get('dynamicRequires', [])) or 'none'}`"
        )
        lines.append(
            f"- dependency status: `{row.get('dependencyStatus', 'not_recorded')}`"
        )
        lines.append(
            f"- resolved: `{', '.join(row.get('resolvedDependencies', [])) or 'none'}`"
        )
        lines.append(
            f"- unresolved: `{', '.join(row.get('unresolvedDependencies', [])) or 'none'}`"
        )
        if row.get("ambiguousDependencies"):
            lines.append("- ambiguous: " + json.dumps(
                row["ambiguousDependencies"], ensure_ascii=False, sort_keys=True
            ))
        lines.append(f"- cycle: `{row.get('cycleDetected', False)}`")
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
    resolution = build_migration_resolution(mapping)
    (OUT / "migration_resolution.json").write_text(
        json.dumps(resolution, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
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
