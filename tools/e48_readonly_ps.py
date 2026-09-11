#!/usr/bin/env python3
"""Run the fixed E48 PowerShell inventory through the configured SSH wrapper."""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCRIPT = ROOT / "tools" / "e48_legend_readonly_manifest.ps1"
DEFAULT_SSH = Path("/Users/mac/.codex/windows-assistant/bin/windows-ssh")
LIST_FIELDS = (
    "modules",
    "fileDependencies",
    "resources",
    "touchSpriteApiCalls",
)


def encoded_command() -> str:
    bootstrap = """$payload = [Console]::In.ReadToEnd()
$source = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($payload))
& ([scriptblock]::Create($source))
"""
    return base64.b64encode(bootstrap.encode("utf-16le")).decode("ascii")


def encoded_script(script: Path) -> bytes:
    return base64.b64encode(script.read_text(encoding="utf-8").encode("utf-16le"))


def as_list(value: object) -> list:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def normalize_result(result: dict) -> dict:
    for entry in result.get("files", []):
        for field in LIST_FIELDS:
            entry[field] = as_list(entry.get(field))
    exclusions = result.get("exclusions")
    if isinstance(exclusions, dict):
        exclusions["records"] = as_list(exclusions.get("records"))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Execute the fixed E48 read-only inventory with PowerShell -EncodedCommand."
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Local path for the validated JSON result.",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not DEFAULT_SCRIPT.is_file():
        parser.error(f"missing fixed script: {DEFAULT_SCRIPT}")
    if not DEFAULT_SSH.is_file():
        parser.error(f"missing configured SSH wrapper: {DEFAULT_SSH}")

    command = [
        str(DEFAULT_SSH),
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        encoded_command(),
    ]
    if args.dry_run:
        print("E48_READONLY_DRY_RUN")
        print("remote_root=E:\\传奇世界")
        print("transport=windows-ssh powershell.exe -EncodedCommand")
        return 0
    if args.output is None:
        parser.error("--output is required unless --dry-run is used")

    completed = subprocess.run(
        command,
        input=encoded_script(DEFAULT_SCRIPT),
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr.decode("utf-8", errors="replace"))
        return completed.returncode

    try:
        result = normalize_result(json.loads(completed.stdout.decode("utf-8")))
    except json.JSONDecodeError as error:
        sys.stderr.write(f"E48_JSON_INVALID: {error}\n")
        return 2

    if result.get("sourceRoot") != "E:\\传奇世界":
        sys.stderr.write("E48_ROOT_REJECTED\n")
        return 3
    if result.get("accessMode") != "read_only":
        sys.stderr.write("E48_ACCESS_MODE_REJECTED\n")
        return 4
    if not isinstance(result.get("files"), list):
        sys.stderr.write("E48_FILES_REJECTED\n")
        return 5

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "E48_READONLY_OK"
        f" files={len(result['files'])}"
        f" exclusions={result.get('exclusions', {}).get('count', 0)}"
        f" output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
