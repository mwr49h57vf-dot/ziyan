#!/usr/bin/env python3
"""Fail-closed provenance gate for the P4 generation-bound frame candidate.

The gate rejects a candidate if its source revision, source hashes, package
hashes or embedded framecap payload hashes no longer match the manifest.
It is local-only and never contacts a device.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {
    "objc/shared/ZiYanFrameResident.h",
    "objc/shared/ZiYanFrameResident.m",
    "objc/shared/ZiYanPaths.h",
    "tools/ziyan_framecap/ZiYanLuaEmbed.m",
    "tools/ziyan_framecap/ZiYanSnapshotHttp.m",
    "tools/ziyan_framecap/main.m",
    "tools/test_p4_frame_commit_snapshot_contract.py",
}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args: str, input_: bytes | None = None) -> bytes:
    return subprocess.run(args, input=input_, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


def embedded_sha(package: Path, payload_path: str) -> str:
    data = next(x for x in run("ar", "t", str(package)).decode().splitlines()
                if x.startswith("data.tar"))
    archive = run("ar", "p", str(package), data)
    payload = run("bsdtar", "-xOf", "-", payload_path, input_=archive)
    return hashlib.sha256(payload).hexdigest()


def fail(message: str) -> None:
    print(f"FAIL {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    args = ap.parse_args()
    manifest_path = Path(args.manifest).resolve()
    data = json.loads(manifest_path.read_text())

    if data.get("source_revision") != run("git", "rev-parse", "HEAD").decode().strip():
        fail("stale_source_revision")
    hashes = data.get("file_sha256")
    if not isinstance(hashes, dict) or not REQUIRED.issubset(hashes):
        fail("missing_required_source_hash")
    for rel in sorted(REQUIRED):
        if sha256_file(ROOT / rel) != hashes[rel]:
            fail(f"source_manifest_mismatch:{rel}")

    candidates = data.get("candidate")
    if not isinstance(candidates, dict):
        fail("missing_candidate")
    for name, expected_payload in (
        ("rootful", "./usr/lib/ziyan/bin/ziyan_framecap"),
        ("rootless", "./var/jb/usr/lib/ziyan/bin/ziyan_framecap"),
    ):
        item = candidates.get(name)
        if not isinstance(item, dict):
            fail(f"missing_{name}")
        package = Path(item.get("path", ""))
        if not package.is_file():
            fail(f"missing_package:{name}")
        if sha256_file(package) != item.get("sha256"):
            fail(f"package_sha_mismatch:{name}")
        if embedded_sha(package, expected_payload) != item.get("framecap_payload_sha256"):
            fail(f"payload_sha_mismatch:{name}")

    if data.get("local_contract") != "PASS_LOCAL_CONTRACT":
        fail("local_contract_not_pass")
    print("P4_GENERATION_CANDIDATE_PROVENANCE_GATE=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
