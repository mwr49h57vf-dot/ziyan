#!/usr/bin/env python3
"""Contract checks for the bounded rewrite artifacts."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "tools/ziyan_generate_migration_rewrites.py"
RESOLUTION = ROOT / "tests/touchsprite_migration/migration_resolution.json"
MANIFEST = ROOT / "tests/touchsprite_migration/rewrites/manifest.json"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    subprocess.run(
        [sys.executable, str(ROOT / "tools" / "ziyan_migration_audit.py")],
        cwd=ROOT,
        check=True,
    )
    subprocess.run([sys.executable, str(GENERATOR)], cwd=ROOT, check=True)
    subprocess.run(
        [sys.executable, str(ROOT / "tools" / "ziyan_migration_audit.py")],
        cwd=ROOT,
        check=True,
    )
    resolution = json.loads(RESOLUTION.read_text(encoding="utf-8"))
    rewrite_candidates = [
        row
        for row in resolution["candidates"]
        if row["status"] in {"BLOCKED", "MIGRATED_BOUNDED_REWRITE"}
    ]
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert manifest["sourceCopiesImmutable"] is True
    assert manifest["candidateCount"] == len(rewrite_candidates) == 19
    assert len(manifest["rewrites"]) == 19
    assert all(
        row["loadfile"]["mode"] == "loadfile_only"
        and row["loadfile"]["status"] == "pass"
        for row in manifest["rewrites"]
    )
    for row in manifest["rewrites"]:
        target = ROOT / row["rewriteRelativePath"]
        assert target.is_file()
        assert sha256(target) == row["rewriteSha256"]
        assert row["sourceSha256"]
        assert row["retainedBlockers"]
        assert row["rollbackPoint"].startswith("remove ")
        result = subprocess.run(
            ["lua", str(target)],
            cwd=ROOT,
            text=True,
            errors="replace",
            capture_output=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        assert "ZIYAN_MIGRATION_REWRITE stop=bounded" in result.stdout
        loadfile = subprocess.run(
            [
                "lua",
                "-e",
                (
                    "local f,e=loadfile(arg[1]); "
                    "assert(f,e or 'loadfile failed')"
                ),
                "-",
                str(target),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        assert loadfile.returncode == 0, loadfile.stderr
    print("MIGRATION_REWRITES_CONTRACT=PASS candidates=19")


if __name__ == "__main__":
    main()
