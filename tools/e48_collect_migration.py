#!/usr/bin/env python3
"""Copy only manifest-approved E48 migration inputs and verify every digest."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = r"E:\传奇世界"
SCP_FROM = Path("/Users/mac/.codex/windows-assistant/bin/windows-scp-from")
COPY_EXTENSIONS = {
    ".lua",
    ".json",
    ".ini",
    ".cfg",
    ".conf",
    ".xml",
    ".png",
    ".jpg",
    ".jpeg",
    ".bmp",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_relative_path(value: object) -> PurePosixPath:
    if not isinstance(value, str) or not value:
        raise ValueError("invalid relativePath")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise ValueError(f"unsafe relativePath: {value!r}")
    return path


def candidates(data: dict) -> list[dict]:
    if data.get("sourceRoot") != SOURCE_ROOT:
        raise ValueError("manifest source root does not match E48 policy")
    if data.get("accessMode") != "read_only":
        raise ValueError("manifest access mode is not read_only")

    selected = []
    for entry in data.get("files", []):
        if entry.get("classification") != "migration_candidate":
            continue
        path = checked_relative_path(entry.get("relativePath"))
        if path.suffix.lower() not in COPY_EXTENSIONS:
            continue
        digest = entry.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise ValueError(f"invalid SHA-256 for {path.as_posix()}")
        selected.append(entry)
    return selected


def clean_manifest_value(value: object) -> object:
    if value == [{}] or value == {}:
        return []
    return value


def remote_path(relative_path: PurePosixPath) -> str:
    return SOURCE_ROOT.replace("\\", "/") + "/" + relative_path.as_posix()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--destination",
        type=Path,
        default=ROOT / "tests" / "touchsprite_migration" / "source",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--verify-existing",
        action="store_true",
        help="verify already-copied targets without contacting the source",
    )
    args = parser.parse_args()
    destination = args.destination.resolve()

    if not SCP_FROM.is_file():
        parser.error(f"missing configured read-only SCP wrapper: {SCP_FROM}")

    try:
        source_data = json.loads(args.manifest.read_text(encoding="utf-8"))
        selected = candidates(source_data)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))

    mappings = []
    for entry in selected:
        relative = checked_relative_path(entry["relativePath"])
        target = destination / Path(*relative.parts)
        mapping = {
            "sourceRelativePath": relative.as_posix(),
            "sourceSha256": entry["sha256"],
            "sourceSize": entry.get("size"),
            "sourceMtimeUtc": entry.get("mtimeUtc"),
            "sourceExtension": entry.get("extension"),
            "sourceTextEncoding": entry.get("textEncoding"),
            "sourceClassification": entry.get("classification"),
            "sourceEntryFile": bool(entry.get("entryFile", False)),
            "sourceModules": clean_manifest_value(entry.get("modules", [])),
            "sourceDependencies": clean_manifest_value(entry.get("fileDependencies", [])),
            "sourceResources": clean_manifest_value(entry.get("resources", [])),
            "sourceApiFacts": clean_manifest_value(entry.get("touchSpriteApiCalls", [])),
            "targetRelativePath": str(target.relative_to(ROOT)),
            "targetSha256": None,
            "targetSize": None,
            "copiedAtUtc": None,
            "copyStatus": "planned" if args.dry_run else "pending",
        }
        if not args.dry_run and not args.verify_existing:
            target.parent.mkdir(parents=True, exist_ok=True)
            completed = subprocess.run(
                [str(SCP_FROM), remote_path(relative), str(target)],
                text=True,
                capture_output=True,
                check=False,
            )
            if completed.returncode != 0:
                sys.stderr.write(completed.stderr)
                return completed.returncode
            target_sha = sha256(target)
            mapping["targetSha256"] = target_sha
            mapping["targetSize"] = target.stat().st_size
            if target_sha != entry["sha256"]:
                target.unlink(missing_ok=True)
                sys.stderr.write(f"SHA256_MISMATCH {relative.as_posix()}\n")
                return 2
            mapping["copyStatus"] = "verified"
            mapping["copiedAtUtc"] = datetime.now(timezone.utc).isoformat()
        elif args.verify_existing:
            if not target.is_file():
                sys.stderr.write(f"EXISTING_TARGET_MISSING {relative.as_posix()}\n")
                return 3
            target_sha = sha256(target)
            mapping["targetSha256"] = target_sha
            mapping["targetSize"] = target.stat().st_size
            if target_sha != entry["sha256"]:
                sys.stderr.write(f"SHA256_MISMATCH {relative.as_posix()}\n")
                return 2
            mapping["copyStatus"] = "verified"
            mapping["copiedAtUtc"] = datetime.fromtimestamp(
                target.stat().st_mtime, tz=timezone.utc
            ).isoformat()
        mappings.append(mapping)

    exclusions = source_data.get("exclusions") or {}
    result = {
        "schemaVersion": 1,
        "sourceRoot": SOURCE_ROOT,
        "accessMode": "read_only_copy",
        "sourceManifestSha256": sha256(args.manifest),
        "sourceBoundary": {
            "root": SOURCE_ROOT,
            "accessMode": "read_only",
            "manifest": str(args.manifest.resolve()),
        },
        "exclusions": {
            "count": exclusions.get("count", 0),
            "policy": exclusions.get("policy", ""),
        },
        "samples": mappings,
    }
    if not args.dry_run or args.verify_existing:
        destination.mkdir(parents=True, exist_ok=True)
        (destination.parent / "sample_mapping.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print(
        "E48_MIGRATION_COLLECTION_OK"
        f" samples={len(mappings)}"
        f" mode={'dry_run' if args.dry_run else 'verified_copy'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
