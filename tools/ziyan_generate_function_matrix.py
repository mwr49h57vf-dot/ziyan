#!/usr/bin/env python3
"""Generate the device-only acceptance matrix from the canonical API catalog."""
from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "api_spec/catalog.json"
DEFAULT_OUT = ROOT / "api_spec/device_function_matrix.json"
DEVICE_PROBE = ROOT / "tests/touchsprite_migration/api_101_device_probe.lua"
DEVICES = [".101", ".112", ".166", ".53", ".61"]
COVERAGE = [
    "normal",
    "error",
    "repeated",
    "timeout",
    "abnormal_exit",
    "stop_cleanup",
    "rootful",
    "rootless",
]
GENERATOR = ["Zy.AI.pipeline", "Zy.Script.generateFromTask"]
EXCLUDED_KEYWORDS = ("account", "password", "captcha", "payment", "trade", "transaction")


def load_apis() -> list[dict]:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    rows: list[dict] = []
    for module, meta in catalog["modules"].items():
        source = ROOT / "api_spec" / meta["file_json"]
        data = json.loads(source.read_text(encoding="utf-8"))
        for api in data.get("apis", []):
            name = str(api["name"])
            lowered = name.lower()
            excluded = any(word in lowered for word in EXCLUDED_KEYWORDS)
            rows.append(
                {
                    "case_id": f"{module}.{name}",
                    "module": module,
                    "function": name,
                    "args": api.get("args", []),
                    "returns": api.get("returns", ""),
                    "catalog_status": api.get("status", "unknown"),
                    "excluded": excluded,
                    "excluded_reason": "account_or_payment_scope" if excluded else "",
                    "devices": DEVICES,
                    "coverage": COVERAGE,
                    "generator": GENERATOR,
                "pass_source": "device_final_verdict",
                "local_functional_pass": False,
                "device_verdicts": {
                    device: {
                        "status": "NOT_RUN",
                        "verdict": "NOT_RUN",
                        "evidence": "",
                        "package_version": "",
                        "package_sha256": "",
                        "tested_at": "",
                        "coverage": {item: "NOT_RUN" for item in COVERAGE},
                    }
                    for device in DEVICES
                },
            }
            )
    return rows


def write_device_probe(rows: list[dict]) -> None:
    """Generate the real-device binding probe consumed through Zy.TestMatrix."""
    lines = [
        "-- Generated from api_spec/catalog.json; do not hand-edit.",
        "-- This records runtime binding evidence only; it never upgrades it to functional PASS.",
        'local Zy = require("modules.init")',
        "local cases = {",
    ]
    for row in rows:
        lines.append(
            "  { case_id = %s, module = %s, fn = %s },"
            % (
                json.dumps(row["case_id"], ensure_ascii=False),
                json.dumps(row["module"], ensure_ascii=False),
                json.dumps(row["function"], ensure_ascii=False),
            )
        )
    lines.extend(
        [
            "}",
            "local function resolve(path)",
            "  local value = _G",
            '  for part in path:gmatch("[^.]+") do',
            '    if type(value) ~= "table" then return nil end',
            "    value = value[part]",
            "  end",
            "  return value",
            "end",
            'local output = assert(io.open(os.getenv("ZIYAN_API_MATRIX_RESULT") or "/tmp/ziyan_api_101.txt", "w"))',
            "local present = 0",
            "for _, case in ipairs(cases) do",
            '  local valid = Zy.TestMatrix.validate({ case_id = case.case_id, module = case.module, ["function"] = case.fn })',
            '  local status = valid and resolve(case.fn) ~= nil and "RUNTIME_PRESENT" or "MISSING_RUNTIME"',
            '  if status == "RUNTIME_PRESENT" then present = present + 1 end',
            '  output:write(case.case_id, "|", status, "\\n")',
            "end",
            'output:write("SUMMARY|total=", #cases, "|present=", present, "|missing=", #cases - present, "\\n")',
            "output:close()",
            'print(string.format("API_101_BINDINGS total=%d present=%d missing=%d", #cases, present, #cases - present))',
            "",
        ]
    )
    DEVICE_PROBE.parent.mkdir(parents=True, exist_ok=True)
    DEVICE_PROBE.write_text("\n".join(lines), encoding="utf-8")


def build(out: Path) -> None:
    rows = load_apis()
    active = [row for row in rows if not row["excluded"]]
    if len(rows) != 101:
        raise SystemExit(f"catalog_api_count_changed:{len(rows)}")
    payload = {
        "schema_version": 1,
        "generated_from": str(CATALOG.relative_to(ROOT)),
        "policy": {
            "functional_verdict_requires_real_device": True,
            "devices": DEVICES,
            "device_order": DEVICES,
            "generated_business_functions": GENERATOR,
            "local_simulation_is_not_pass": True,
            "excluded_scope": ["account", "password", "captcha", "payment", "trade", "transaction"],
        },
        "required_capabilities": [
            "chat_text_input_send_clear_copy_paste_multi_turn",
            "game_rules_state_turn_score_win_phase_transition",
            "automatic_decision_trace_replay_retry_degrade_pause_resume",
            "non_visual_input_clipboard_gesture_hardware_key_app_lifecycle",
        ],
        "counts": {
            "catalog_total": len(rows),
            "active_total": len(active),
            "excluded_total": len(rows) - len(active),
            "excluded_scope_items_not_counted": len(rows) - len(active),
        },
        "cases": rows,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_device_probe(rows)
    print(f"MATRIX_WRITTEN={out}")
    print(f"CATALOG_TOTAL={len(rows)} ACTIVE_TOTAL={len(active)} EXCLUDED_TOTAL={len(rows)-len(active)}")


if __name__ == "__main__":
    build(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_OUT)
