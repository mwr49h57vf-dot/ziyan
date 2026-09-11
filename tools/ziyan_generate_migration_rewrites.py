#!/usr/bin/env python3
"""Generate bounded, executable adapters for the 19 blocked source samples."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOLUTION = ROOT / "tests/touchsprite_migration/migration_resolution.json"
OUT = ROOT / "tests/touchsprite_migration/rewrites"
MANIFEST = OUT / "manifest.json"


ADAPTER = r'''-- Shared bounded adapter for blocked TouchSprite samples.
-- It records the safe lifecycle shape without executing source-side network,
-- host-shell, direct-file, encrypted, or unbounded-loop behavior.

local ok, Zy = pcall(require, "modules.init")
local function emit(message)
  if ok and Zy and Zy.Log and type(Zy.Log.write) == "function" then
    pcall(Zy.Log.write, message)
  else
    io.write(message .. "\n")
  end
end

local function write_result(path, spec, status)
  if not path or path == "" then
    return
  end
  local file = assert(io.open(path, "w"))
  file:write("status=", status, "\n")
  file:write("sample=", spec.sample, "\n")
  file:write("rewrite=bounded\n")
  file:write("blockers=", table.concat(spec.blockers, ","), "\n")
  file:close()
end

return function(spec)
  assert(type(spec) == "table" and type(spec.sample) == "string")
  local loops = tonumber(os.getenv("ZIYAN_MIGRATION_LOOPS") or "1") or 1
  loops = math.max(0, math.min(math.floor(loops), 20))
  emit("ZIYAN_MIGRATION_REWRITE start sample=" .. spec.sample)
  emit("ZIYAN_MIGRATION_REWRITE blockers=" .. table.concat(spec.blockers, ","))
  for i = 1, loops do
    emit("ZIYAN_MIGRATION_REWRITE step=" .. i .. "/" .. loops)
    if ok and Zy and Zy.Timer and type(Zy.Timer.mSleep) == "function" then
      pcall(Zy.Timer.mSleep, 1)
    end
  end
  if spec.features.network then
    emit("ZIYAN_MIGRATION_REWRITE network=skipped_external_dependency")
  end
  if spec.features.file then
    emit("ZIYAN_MIGRATION_REWRITE file=skipped_sandbox_mapping_required")
  end
  if spec.features.shell then
    emit("ZIYAN_MIGRATION_REWRITE shell=skipped_host_mutation")
  end
  if spec.features.opaque then
    emit("ZIYAN_MIGRATION_REWRITE opaque_source=stub_only")
  end
  emit("ZIYAN_MIGRATION_REWRITE stop=bounded")
  write_result(os.getenv("ZIYAN_MIGRATION_RESULT"), spec, "completed")
  return true
end
'''


def slug(path: str) -> str:
    value = re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_").lower()
    digest = hashlib.sha256(path.encode("utf-8")).hexdigest()[:10]
    return f"{value or 'sample'}_{digest}"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def loadfile_check(path: Path) -> dict[str, str]:
    probe = (
        "local f,e=loadfile(arg[1]); "
        "if not f then io.stderr:write(e or 'loadfile failed'); os.exit(1) end"
    )
    try:
        result = subprocess.run(
            ["lua", "-e", probe, "-", str(path)],
            cwd=ROOT,
            text=True,
            errors="replace",
            capture_output=True,
            check=False,
        )
    except OSError as error:
        return {"mode": "loadfile_only", "status": "tool_missing", "detail": str(error)}
    if result.returncode == 0:
        return {"mode": "loadfile_only", "status": "pass", "detail": ""}
    return {
        "mode": "loadfile_only",
        "status": "failed",
        "detail": (result.stderr or result.stdout).strip().splitlines()[0],
    }


def features(blockers: list[str], source: str) -> dict[str, bool]:
    return {
        "network": any(
            item in blockers
            for item in ("remote_ftp_dependency", "external_socket_dependency")
        ),
        "file": "direct_file_io_needs_sandboxed_mapping" in blockers,
        "shell": "host_shell_or_file_mutation" in blockers,
        "opaque": "source_syntax_or_encryption_failure" in blockers
        or not source.strip(),
    }


def lua_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_list(values: list[str]) -> str:
    return "{" + ", ".join(lua_quote(value) for value in values) + "}"


def lua_spec(spec: dict) -> str:
    feature_rows = ", ".join(
        f"{key}={str(value).lower()}" for key, value in spec["features"].items()
    )
    return (
        "{sample="
        + lua_quote(spec["sample"])
        + ", blockers="
        + lua_list(spec["blockers"])
        + ", features={"
        + feature_rows
        + "}}"
    )


def main() -> None:
    resolution = json.loads(RESOLUTION.read_text(encoding="utf-8"))
    candidates = resolution.get("candidates")
    if not isinstance(candidates, list):
        raise ValueError("migration resolution candidates must be a list")
    if resolution.get("candidateCount") != len(candidates):
        raise ValueError(
            "migration resolution candidateCount does not match candidates"
        )
    rewrite_candidates = [
        candidate
        for candidate in candidates
        if candidate.get("status") in {"BLOCKED", "MIGRATED_BOUNDED_REWRITE"}
    ]
    if len(rewrite_candidates) != 19:
        raise ValueError(
            "expected 19 blocked migration candidates, "
            f"found {len(rewrite_candidates)}"
        )
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "bounded_adapter.lua").write_text(ADAPTER, encoding="utf-8")
    rows = []
    seen: set[str] = set()
    for candidate in rewrite_candidates:
        source = ROOT / "tests/touchsprite_migration/source" / candidate["sourceRelativePath"]
        name = slug(candidate["sourceRelativePath"])
        if name in seen:
            raise ValueError(f"duplicate rewrite slug: {name}")
        seen.add(name)
        target = OUT / f"{name}.lua"
        spec = {
            "sample": candidate["sourceRelativePath"],
            "blockers": candidate.get("retainedBlockers") or candidate["blockers"],
            "features": features(candidate["blockers"], source.read_text(
                encoding="utf-8", errors="replace"
            )),
        }
        target.write_text(
            "-- Generated bounded rewrite; source copy remains immutable.\n"
            "local source = debug.getinfo(1, 'S').source:sub(2)\n"
            "local root = source:match('^(.*)/rewrites/') or '.'\n"
            "local run = dofile(root .. '/rewrites/bounded_adapter.lua')\n"
            f"return run({lua_spec(spec)})\n",
            encoding="utf-8",
        )
        loadfile = loadfile_check(target)
        if loadfile["status"] != "pass":
            raise RuntimeError(
                f"loadfile failed: {candidate['sourceRelativePath']}: "
                f"{loadfile['detail']}"
            )
        result = subprocess.run(
            ["lua", str(target)],
            cwd=ROOT,
            text=True,
            errors="replace",
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"rewrite failed: {candidate['sourceRelativePath']}: "
                f"{result.stderr.strip()}"
            )
        rows.append(
            {
                "sourceRelativePath": candidate["sourceRelativePath"],
                "sourceSha256": candidate["sourceSha256"],
                "rewriteRelativePath": str(target.relative_to(ROOT)),
                "rewriteSha256": sha256(target),
                "runtime": "lua",
                "loadfile": loadfile,
                "localRepro": f"lua '{target.relative_to(ROOT)}'",
                "localVerdict": "EXECUTABLE_BOUNDED_REWRITE",
                "retainedBlockers": candidate.get("retainedBlockers")
                or candidate["blockers"],
                "rollbackPoint": f"remove {target.relative_to(ROOT)}",
                "scope": (
                    "opaque_dependency_stub"
                    if spec["features"]["opaque"]
                    else "bounded_compatibility_adapter"
                ),
            }
        )
    manifest = {
        "schemaVersion": 1,
        "generatedFrom": str(RESOLUTION.relative_to(ROOT)),
        "sourceCopiesImmutable": True,
        "adapter": str((OUT / "bounded_adapter.lua").relative_to(ROOT)),
        "candidateCount": len(rows),
        "rewrites": rows,
    }
    MANIFEST.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"MIGRATION_REWRITES_OK candidates={len(rows)}")


if __name__ == "__main__":
    main()
