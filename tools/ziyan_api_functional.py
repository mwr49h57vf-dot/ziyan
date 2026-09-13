#!/usr/bin/env python3
"""Evidence ledger and bounded device checks. Never infer full API PASS."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import plistlib
import re
import shlex
import subprocess
import tarfile
from collections import Counter
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MATRIX = ROOT / "api_spec/device_function_matrix.json"
FIXTURE = ROOT / "tests/api_functional/scenarios.lua"
DEVICES = ["101", "112", "166", "53", "61"]
FAMILIES = ("file", "codec", "memory", "sys", "touch", "screen", "image", "ocr", "app", "net", "control", "orient")
SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=12",
               "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def save(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def _checkpoint_package_field(text: str, scheme: str, kind: str) -> str:
    """Parse checkpoint package anchors in both known formats.

    Legacy: ``rootful=<version>; ...`` / ``rootful:<sha64>``.
    Current: ``17-164-1 rootful(...) / 17-164-2 rootless(...)`` /
    ``164-1: <sha64>; 164-2: <sha64>``. Fail closed on unknown input.
    """
    text = text or ""
    if kind == "version":
        legacy = re.search(scheme + r"=([^; ]+)", text)
        if legacy:
            return legacy.group(1)
        for token in re.split(r"\s*/\s*", text):
            found = re.search(r"((?:17-)?\d+-\d+)\s+" + scheme, token)
            if found:
                tail = found.group(1)
                tail = tail if tail.startswith("17-") else "17-" + tail
                # 真相源是 dpkg/文件名(带 +debug 后缀); control 声明无后缀, 解析必须补后缀。
                return "0.0.92-8-161-205-C-65.11-98+debug-10-38-" + tail + "+debug"
    else:
        legacy = re.search(scheme + r":([a-f0-9]{64})", text)
        if legacy:
            return legacy.group(1)
        for token in re.split(r"\s*;\s*", text):
            found = re.match(r"((?:17-)?\d+-\d+)\s*:\s*([a-f0-9]{64})", token)
            if not found:
                continue
            tail = found.group(1)
            tail = tail if tail.startswith("17-") else "17-" + tail
            if (scheme == "rootful" and tail.endswith("-1")) or (
                scheme == "rootless" and tail.endswith("-2")
            ):
                return found.group(2)
    raise ValueError(f"checkpoint package {kind} unparsable for {scheme}")


def command(args: list[str], log: Path, *, input: str | None = None,
            timeout: int = 120) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        def text(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
        result = subprocess.CompletedProcess(args, 124, text(exc.stdout), text(exc.stderr) + "\nHOST_TIMEOUT")
    log.write_text(result.stdout + "\nSTDERR:\n" + result.stderr + f"\nEXIT_CODE={result.returncode}\n")
    return result


def inventory(out: Path) -> dict:
    matrix = json.loads(MATRIX.read_text())
    catalog = json.loads((ROOT / "api_spec/catalog.json").read_text())
    rows = []
    for case in matrix["cases"]:
        rows.append({
            "case_id": case["case_id"], "family": case["module"],
            "signature": case["args"], "returns": case["returns"],
            "catalog_status": case["catalog_status"],
            "contract": str(ROOT / "api_spec" / catalog["modules"][case["module"]]["file_lua"]),
            "contract_is_functional_fixture": False,
            "binding_evidence": case["device_verdicts"],
            "functional_fixture": str(FIXTURE) if case["module"] in FAMILIES else None,
            "generator_entry": str(ROOT / "lua/modules/TestMatrix.lua"),
            "functional_devices": {
                "." + device: {"verdict": "NOT_RUN", "coverage": {
                    dimension: "NOT_FUNCTIONALLY_TESTED" for dimension in case["coverage"]}}
                for device in DEVICES},
        })
    result = {
        "run_id": out.name, "created_at": datetime.now().astimezone().isoformat(),
        "matrix_sha256": digest(MATRIX), "fixture_sha256": digest(FIXTURE),
        "case_count": len(rows), "families": dict(Counter(row["family"] for row in rows)),
        "functional_pass": False, "local_simulation_is_not_pass": True,
        "notes": [
            "Historical binding evidence is retained, never inherited as current functional PASS.",
            "Direct installed-engine scenarios do not validate the AI generator or embedded lifecycle.",
            "Normal checks repeat three times. Timeout/abnormal-exit/stop coverage remains untested.",
            "chat/rules/decision/non_visual are business capabilities, not the 12 catalog API families.",
        ],
        "cases": rows,
    }
    save(out / "inventory.json", result)
    return result


def package_identity(scheme: str, *, embedded: bool = False) -> tuple[Path, str, str, dict[str, str]]:
    checkpoint = json.loads((ROOT / ".codex/ZIYAN_ACTIVE_CHECKPOINT.json").read_text())
    version = _checkpoint_package_field(checkpoint["artifacts"]["packageVersion"], scheme, "version")
    sha = _checkpoint_package_field(checkpoint["artifacts"]["packageSha256"], scheme, "sha256")
    arch = "iphoneos-arm" if scheme == "rootful" else "iphoneos-arm64"
    package = ROOT / "packages" / f"com.ziyan.ziyan_{version}_{arch}.deb"
    if not package.exists():
        package = ROOT / "packages" / f"com.ziyan.ziyan_{version}+debug_{arch}.deb"
    if digest(package) != sha:
        raise ValueError("checkpoint package SHA mismatch")
    prefix = "/usr/lib/ziyan" if scheme == "rootful" else "/var/jb/usr/lib/ziyan"
    hashes = {}
    members = subprocess.check_output(["ar", "t", str(package)], text=True).splitlines()
    data_member = next(name.strip() for name in members if name.strip().startswith("data.tar"))
    payload = subprocess.check_output(["ar", "p", str(package), data_member])
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:*") as archive:
        for entry in archive:
            name = "/" + entry.name.removeprefix("./").lstrip("/")
            if entry.isfile() and (name.startswith(prefix + "/lib/lua/") or name == prefix + "/bin/lua5.3"
                                   or name == prefix + "/bin/ziyan_plist"
                                   or (embedded and name == prefix + "/bin/ziyan_framecap")):
                hashes[name] = hashlib.sha256(archive.extractfile(entry).read()).hexdigest()
    if not hashes:
        raise ValueError("package contains no Lua payload")
    return package, version, sha, hashes


def parse_state(text: str) -> dict:
    result = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"version", "fc_n", "sb_pid", "lua_n", "keep", "active", "embed", "locked",
                       "sample_ts", "framecap_owner", "framecap_alive"}:
                result[key] = value.strip()
    if "PROCESSES_BEGIN\n" in text and "\nPROCESSES_END" in text:
        process_text = text.split("PROCESSES_BEGIN\n", 1)[1].split("\nPROCESSES_END", 1)[0]
        processes = [line.split() for line in process_text.splitlines()]
        processes = [row for row in processes if len(row) >= 2 and row[0].isdigit()]
        full = [row for row in processes if len(row) >= 3
                and row[1].endswith("/ziyan_framecap") and row[2] == "serve"]
        redacted = [row for row in processes if row[1] == "(ziyan_framecap)"]
        result["fc_n"] = str(len(full) + len(redacted))
        result["fc_identity"] = "full_argv" if not redacted else "UNVERIFIED"
        # iOS hides root argv from mobile; require both current owner and heartbeat.
        if len(redacted) == 1 and not full:
            owner = dict(re.findall(r"(\w+)=(\d+)", result.get("framecap_owner", "")))
            alive = dict(re.findall(r"(\w+)=(\d+)", result.get("framecap_alive", "")))
            stamp = result.get("sample_ts", "")
            now = int(stamp) if stamp.isdigit() else 0
            if (owner.get("pid") == alive.get("pid") == redacted[0][0]
                    and all(0 <= now - int(value.get("ts", "0")) <= 12 for value in (owner, alive))
                    and now > 0):
                result["fc_identity"] = "redacted_comm_live_owner"
        result["lua_n"] = str(sum(row[1].endswith("/lua5.3") or row[1] == "(lua5.3)"
                                 for row in processes))
        result["sb_pid"] = ",".join(row[0] for row in processes if row[1].endswith("/SpringBoard.app/SpringBoard"))
    return result


def cleanup_complete(before: dict, after: dict, returncode: int) -> bool:
    return (returncode == 0 and after.get("lua_n") == "0"
            and after.get("fc_n") == "1"
            and after.get("fc_identity") in {"full_argv", "redacted_comm_live_owner"}
            and bool(before.get("sb_pid")) and after.get("sb_pid") == before["sb_pid"]
            and all(after.get(key) == "0" for key in ("keep", "active", "embed")))


STATE = r"""
printf 'version='; dpkg-query -W -f='${Version}\n' com.ziyan.ziyan
ps -A -o pid=,command= > "$D/processes.txt"
echo PROCESSES_BEGIN
cat "$D/processes.txt"
echo PROCESSES_END
printf 'sample_ts='; date +%s
printf 'framecap_owner='; cat "$R/var/.ziyan_framecap_owner" 2>/dev/null; echo
printf 'framecap_alive='; cat "$R/var/.ziyan_framecap_alive" 2>/dev/null; echo
for pair in 'keep:.ziyan_keep_daemon' 'active:.ziyan_active' 'embed:.ziyan_lua_embedded'; do
  key=${pair%%:*}; file=${pair#*:}; printf '%s=' "$key"
  if [ -e "$R/var/$file" ]; then echo 1; else echo 0; fi
done
"""


def run_device(out: Path, family: str, device: str, ledger: dict, *, embedded: bool = False) -> None:
    scheme = "rootful" if device in DEVICES[:3] else "rootless"
    remote_root = "/usr/lib/ziyan" if scheme == "rootful" else "/var/jb/usr/lib/ziyan"
    user = "mobile" if device == "61" else "root"
    target = f"{user}@192.168.31.{device}"
    ssh = ["ssh", *SSH_OPTIONS, target, "bash -s"]
    local = out / family / device
    if embedded:
        local = out / family / (device + "_embed_" + datetime.now().strftime("%H%M%S"))
    if local.exists():
        local = out / family / (device + "_retry_" + datetime.now().strftime("%H%M%S"))
    local.mkdir(parents=True, exist_ok=True)
    run_id = f"{out.name}_{family}_{local.name}"
    remote = f"/tmp/{run_id}"
    package, version, sha, hashes = package_identity(scheme, embedded=embedded)
    save(local / "package.json", {"path": str(package), "version": version, "sha256": sha,
                                 "runtime_payload_sha256": hashes})
    env = f"R={shlex.quote(remote_root)}\nD={shlex.quote(remote)}\n"
    pre = command(ssh, local / "pre.txt", input=env + 'mkdir -p "$D"\n' + STATE)
    before = parse_state(pre.stdout)
    record = {
        "device": "." + device, "family": family, "run_id": run_id,
        "verdict": "DEVICE_INCONCLUSIVE", "package_version": version,
        "package_sha256": sha, "package_path": str(package),
        "fixture_sha256": digest(FIXTURE), "evidence": str(local),
        "execution_host": "embedded" if embedded else "standalone",
        "before": before, "cleanup": "NOT_RUN", "reason": "",
    }
    started = False
    rows = []
    try:
        if pre.returncode or before.get("version") != version:
            record["reason"] = "transport_or_package_version_mismatch"
            return
        if (before.get("fc_n") != "1" or before.get("lua_n") != "0"
                or before.get("fc_identity") not in {"full_argv", "redacted_comm_live_owner"}):
            record["reason"] = "precondition_process_counts"
            return
        if any(before.get(key) != "0" for key in ("keep", "active", "embed")):
            record["reason"] = "precondition_active_markers"
            return
        manifest = "\n".join(f"{value}  {path}" for path, value in hashes.items()) + "\n"
        verified = command(ssh, local / "payload.txt",
                           input="sha256sum -c - <<'API_HASHES'\n" + manifest + "API_HASHES\n")
        if verified.returncode:
            record["reason"] = "installed_runtime_differs_from_checkpoint_package"
            return
        record["runtime_payload_verified"] = len(hashes)
        save(local / "cases.json", {"cases": [
            {"case_id": row["case_id"], "function": row["case_id"].split(".", 1)[1]}
            for row in ledger["cases"] if row["family"] == family]})
        upload = [str(FIXTURE), str(local / "cases.json")]
        if embedded:
            wrapper = local / "entry.lua"
            config = {"root": remote_root, "out": remote, "family": family, "run_id": run_id}
            wrapper.write_text("function main()\n  API_FUNCTIONAL_CONFIG = {"
                               + ", ".join(key + "=" + json.dumps(value) for key, value in config.items())
                               + "}\n  dofile(" + json.dumps(remote + "/scenarios.lua") + ")\nend\n")
            upload.append(str(wrapper))
            record["entry_sha256"] = digest(wrapper)
        copied = command(["scp", *SSH_OPTIONS, *upload, target + ":" + remote + "/"],
                         local / "copy.txt")
        if copied.returncode:
            record["reason"] = "fixture_copy_failed"
            return
        script_hash = command(ssh, local / "fixture_sha.txt",
                              input=env + 'sha256sum "$D/scenarios.lua"\n')
        if script_hash.returncode or not script_hash.stdout.startswith(digest(FIXTURE) + " "):
            record["reason"] = "fixture_sha_mismatch"
            return
        if embedded:
            entry_hash = command(ssh, local / "entry_sha.txt",
                                 input=env + 'sha256sum "$D/entry.lua"\n')
            if entry_hash.returncode or not entry_hash.stdout.startswith(record["entry_sha256"] + " "):
                record["reason"] = "entry_sha_mismatch"
                return
        started = True
        # Bound only this standalone fixture PID, never the framecap host.
        setup = env + f"""
export PATH="$R/bin:/var/jb/usr/bin:/var/jb/bin:$PATH"
export API_ROOT="$R" API_OUT="$D" API_FAMILY={family} API_RUN_ID={run_id}
for name in .ziyan_filelist.txt .ziyan_plist.json .ziyan_plist_w.json; do
  if [ -e "$R/var/$name" ]; then cp -p "$R/var/$name" "$D/backup_$name"; fi
done
touch "$D/started"
"""
        execute_script = """
"$R/bin/lua5.3" "$D/scenarios.lua" > "$D/stdout.txt" 2>&1 &
p=$!
echo "$p" > "$D/pid"
i=0
while kill -0 "$p" 2>/dev/null && [ "$i" -lt 60 ]; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$p" 2>/dev/null; then kill -TERM "$p" 2>/dev/null; fi
wait "$p"; rc=$?
echo "$rc" > "$D/exit_code"
cat "$D/results.jsonl" 2>/dev/null
exit "$rc"
"""
        if embedded:
            execute_script = """
rm -f "$R/var/.ziyan_user_stopped" "$R/var/.ziyan_stop" "$R/var/.ziyan_kill_scripts"
printf 'path=%s/entry.lua\\nstop=0\\n' "$D" > "$R/var/.ziyan_run_intent"
printf '%s/entry.lua\\n' "$D" > "$R/var/.ziyan_embed_script"
echo "nonce=$API_RUN_ID" > "$R/var/.ziyan_embed_go"
chmod 666 "$R/var/.ziyan_run_intent" "$R/var/.ziyan_embed_script" "$R/var/.ziyan_embed_go"
i=0
while [ "$i" -lt 60 ]; do
  if grep -q '"terminal":true' "$D/results.jsonl" 2>/dev/null; then
    echo 0 > "$D/exit_code"; cat "$D/results.jsonl"; exit 0
  fi
  sleep 1; i=$((i + 1))
done
echo 124 > "$D/exit_code"
exit 124
"""
        execution = command(ssh, local / "run.txt", timeout=90, input=setup + execute_script)
        command(["scp", "-r", *SSH_OPTIONS, target + ":" + remote + "/.", str(local / "device")],
                local / "collect.txt")
        results = local / "device/results.jsonl"
        if results.exists():
            rows = [json.loads(line) for line in results.read_text().splitlines()]
        complete = bool(rows and rows[-1].get("terminal") is True
                        and execution.returncode == 0
                        and all(row.get("run_id") == run_id for row in rows))
        if embedded:
            record["embedded_host_verified"] = any(row.get("event") == "host"
                                                   and row.get("embedded") is True for row in rows)
            complete = complete and record["embedded_host_verified"]
        record["terminal"] = complete
        record["exit_code"] = execution.returncode
        # Independent artifact oracles, not encode/decode round-trip self-approval.
        plist = local / "device/written.plist"
        if plist.exists():
            try:
                record["plist_content_verified"] = plistlib.loads(plist.read_bytes()) == {
                    "marker": run_id, "count": 7, "empty": {}}
            except (ValueError, plistlib.InvalidFileException):
                record["plist_content_verified"] = False
        record["reason"] = "coverage_incomplete" if complete else "device_terminal_missing"
        record["scenario_counts"] = dict(Counter(row["status"] for row in rows if row.get("event") == "result"))
    finally:
        stop = ""
        if embedded and started:
            stop = """
if grep -Fq "$D/entry.lua" "$R/var/.ziyan_run_intent" 2>/dev/null; then
  echo 1 > "$R/var/.ziyan_kill_scripts"
  sleep 2
  rm -f "$R/var/.ziyan_run_intent" "$R/var/.ziyan_embed_script" "$R/var/.ziyan_embed_go"
  sleep 2
  rm -f "$R/var/.ziyan_kill_scripts"
fi
"""
        cleanup = command(ssh, local / "cleanup.txt", input=env + stop + f"""
if [ -f "$D/pid" ]; then
  p=$(cat "$D/pid")
  cmd=$(ps -p "$p" -o command= 2>/dev/null)
  case "$cmd" in *"$D/scenarios.lua"*) kill -TERM "$p" 2>/dev/null; sleep 1;; esac
fi
rm -f "$R/var/memory/com.ziyan.api-functional.{run_id}.json"
if [ -e "$D/started" ]; then
  for name in .ziyan_filelist.txt .ziyan_plist.json .ziyan_plist_w.json; do
    if [ -e "$D/backup_$name" ]; then
      cp -p "$D/backup_$name" "$R/var/$name"
    else
      rm -f "$R/var/$name"
    fi
  done
fi
""" + STATE + """
rm -f "$D/scenarios.lua" "$D/entry.lua" "$D/cases.json" "$D/a.txt" "$D/b.txt" "$D/c.txt" "$D/input.plist" "$D/corrupt.plist" "$D/written.plist"
""")
        record["after"] = parse_state(cleanup.stdout)
        record["cleanup"] = "PASS" if cleanup_complete(before, record["after"], cleanup.returncode) else "INCONCLUSIVE"
        record["started"] = started
        save(local / "VERDICT.json", record)
        for case in ledger["cases"]:
            if case["family"] != family:
                continue
            result = {**record, "coverage": {
                key: "NOT_FUNCTIONALLY_TESTED"
                for key in case["functional_devices"]["." + device]["coverage"]}}
            checks = [row for row in rows if row.get("event") == "result" and row.get("case_id") == case["case_id"]]
            if record.get("terminal") and record.get("runtime_payload_verified") and record["cleanup"] == "PASS":
                for dimension in ("normal", "error", "timeout", "abnormal_exit", "stop_cleanup"):
                    selected = [row for row in checks if row["dimension"] == dimension]
                    if not selected:
                        continue
                    if any(row["status"] == "SCENARIO_SKIPPED" for row in selected):
                        # 设备停止态等跳过：不加戏也不判 PASS/FAIL，保持未测并留原因
                        result.setdefault("skipped", {})[dimension] = sorted(
                            {row.get("detail", "") for row in selected
                             if row["status"] == "SCENARIO_SKIPPED"})
                        continue
                    result["coverage"][dimension] = (
                        "DEVICE_SCENARIO_PASS" if all(row["status"] == "SCENARIO_PASS" for row in selected)
                        else "DEVICE_SCENARIO_FAIL")
                if len([row for row in checks if row["dimension"] == "normal"]) == 3:
                    result["coverage"]["repeated"] = result["coverage"]["normal"]
                if case["case_id"] == "file.PlistWrite" and not record.get("plist_content_verified"):
                    result["coverage"]["normal"] = "DEVICE_SCENARIO_FAIL"
                    result["coverage"]["repeated"] = "DEVICE_SCENARIO_FAIL"
            if not checks:
                binding = next((row for row in rows if row.get("event") == "binding"
                                and row.get("case_id") == case["case_id"]), None)
                if binding:
                    result["reason"] = ("MISSING_RUNTIME" if binding["status"] == "MISSING_RUNTIME"
                                        else "FUNCTIONAL_FIXTURE_MISSING")
                    result["runtime_binding"] = binding["status"]
            case["functional_devices"]["." + device] = result
        save(out / "inventory.json", ledger)
        print(f"{family} .{device}: {record['reason']} {record.get('scenario_counts', {})} cleanup={record['cleanup']}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["inventory", "run"])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--family", choices=FAMILIES)
    parser.add_argument("--device", choices=DEVICES)
    parser.add_argument("--embedded", action="store_true")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.action == "inventory":
        result = inventory(out)
        print(f"INVENTORY cases={result['case_count']} families={result['families']} out={out}")
    else:
        if not args.family or not args.device:
            parser.error("run requires --family and --device")
        ledger = json.loads((out / "inventory.json").read_text())
        for previous in DEVICES[:DEVICES.index(args.device)]:
            if not (out / args.family / previous / "VERDICT.json").exists():
                parser.error("previous device evidence missing")
        run_device(out, args.family, args.device, ledger, embedded=args.embedded)


if __name__ == "__main__":
    main()
