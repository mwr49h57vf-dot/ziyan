#!/usr/bin/env python3
"""Parse a copied Lua migration candidate without executing it."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


API_MAP = {
    "mSleep": "sys.mSleep",
    "getColor": "screen.getColor",
    "findColorInRegionFuzzy": "image.findColor",
    "findMultiColorInRegionFuzzy": "image.findMultiColorInRegionFuzzy",
    "findImage": "image.find",
    "findImageInRegionFuzzy": "image.find",
    "touchDown": "touch.touchDown",
    "touchMove": "touch.touchMove",
    "touchUp": "touch.touchUp",
    "runApp": "app.appRun",
    "closeApp": "app.appKill",
    "appRun": "app.appRun",
    "appKill": "app.appKill",
    "snapshot": "screen.snapshot",
    "keepScreen": "screen.keep",
    "toast": "sys.toast",
    "notifyMessage": "sys.notifyMessage",
    "lua_exit": "script.lua_exit",
    "setWifiEnable": "device.setWifiEnable",
    "getNetIP": "net.getNetIP",
}

BLOCKED_PATTERNS = {
    "os.execute": "host_shell_or_file_mutation",
    "socket": "external_socket_dependency",
    "ftp": "remote_ftp_dependency",
    "io.open": "direct_file_io_needs_sandboxed_mapping",
    "while (true)": "unbounded_loop_requires_stop_token",
    "while true": "unbounded_loop_requires_stop_token",
    "require(DXMC": "dynamic_module_path_unresolved",
}


def mask_comments(text: str) -> str:
    text = re.sub(r"--\[(=*)\[(.*?)\]\1\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def call_counts(text: str) -> dict[str, int]:
    active = mask_comments(text)
    return {
        name: len(re.findall(rf"(?<![A-Za-z0-9_%]){re.escape(name)}\s*\(", active))
        for name in API_MAP
        if re.search(rf"(?<![A-Za-z0-9_%]){re.escape(name)}\s*\(", active)
    }


def call_arguments(text: str, function_name: str) -> list[str]:
    active = mask_comments(text)
    arguments = []
    pattern = re.compile(rf"\b{re.escape(function_name)}\s*\(")
    for match in pattern.finditer(active):
        start = match.end()
        depth = 1
        quote = None
        escaped = False
        for index in range(start, len(active)):
            char = active[index]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                continue
            if char in ("'", '"'):
                quote = char
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    arguments.append(active[start:index].strip())
                    break
    return arguments


def quoted_argument(argument: str) -> str | None:
    match = re.fullmatch(r"""(['"])(.*)\1""", argument, flags=re.S)
    return match.group(2) if match else None


def requires(text: str) -> list[str]:
    values = [
        value
        for argument in call_arguments(text, "require")
        if (value := quoted_argument(argument)) is not None
    ]
    return sorted(set(values))


def dynamic_requires(text: str) -> list[str]:
    return sorted(
        {
            argument
            for argument in call_arguments(text, "require")
            if quoted_argument(argument) is None
        }
    )


def dependency_gaps(text: str) -> list[str]:
    gaps = set()
    if dynamic_requires(text):
        gaps.add("dynamic_module_path_unresolved")
    if any(quoted_argument(argument) is None for argument in call_arguments(text, "dofile")):
        gaps.add("dynamic_dofile_path_unresolved")
    return sorted(gaps)


def entry_kind(relative: str, text: str) -> str:
    active = mask_comments(text)
    if relative.endswith("/main.lua"):
        return "top_level_entry"
    if re.search(r"^\s*function\s+main\s*\(", active, re.M):
        return "main_function"
    if re.search(r"^\s*(require|dofile|mSleep|closeApp|runApp)\b", active, re.M):
        return "top_level_bootstrap"
    return "library_or_unresolved"


def status_for(relative: str, text: str, counts: dict[str, int]) -> tuple[str, list[str]]:
    active = mask_comments(text)
    gaps = sorted(
        {
            reason
            for needle, reason in BLOCKED_PATTERNS.items()
            if needle in active
        }
    )
    gaps = sorted(set(gaps) | set(dependency_gaps(active)))
    if not text.strip():
        return "unmigratable_encrypted_or_empty", ["empty_source"]
    if not counts and gaps:
        return "unmigratable_static_only", gaps
    if gaps:
        return "partial_mapping_requires_rewrite", gaps
    if counts:
        return "direct_api_mapping", []
    return "dependency_only_or_no_allowlisted_api", []


def parse_candidate(relative: str, text: str) -> dict:
    counts = call_counts(text)
    status, gaps = status_for(relative, text, counts)
    static_requires = requires(text)
    dynamic = dynamic_requires(text)
    return {
        "entryKind": entry_kind(relative, text),
        "requires": static_requires,
        "dynamicRequires": dynamic,
        "dependencyStatus": (
            "dynamic_unresolved"
            if dynamic
            else "static_candidates_unresolved"
            if static_requires
            else "none_detected"
        ),
        "apiCalls": counts,
        "apiMapping": {name: API_MAP[name] for name in counts},
        "stopSemantics": {
            "closeApp": counts.get("closeApp", 0) > 0,
            "lua_exit": counts.get("lua_exit", 0) > 0,
            "unboundedLoop": "unbounded_loop_requires_stop_token" in gaps,
        },
        "cleanupSemantics": {
            "directFileIo": "direct_file_io_needs_sandboxed_mapping" in gaps,
            "shellMutation": "host_shell_or_file_mutation" in gaps,
            "remoteFtp": "remote_ftp_dependency" in gaps,
        },
        "migrationStatus": status,
        "unmigratableOrGaps": gaps,
    }


def parse_file(path: Path, relative: str | None = None) -> dict:
    relative = relative or path.as_posix()
    return parse_candidate(
        relative,
        path.read_text(encoding="utf-8", errors="replace"),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--relative-path")
    args = parser.parse_args()
    print(json.dumps(parse_file(args.path, args.relative_path), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
