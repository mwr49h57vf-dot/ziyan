#!/usr/bin/env bash
# 九号开发：HID 停后残留只读采证。严格串行，不启动 Lua，不写设备。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV09_AGENT_TRUE_HID_LEFTOVER_20260906"
BASE="$ROOT/tmp_shots/DEV08_AGENT_TRUE_HID_SAFE_GATE_20260906"
PASS="${ZY_SSH_PASS:-alpine}"
LEARN_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/学习数据"
RECORD_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"

[ ! -e "$OUT" ] || { printf 'evidence directory already exists: %s\n' "$OUT" >&2; exit 2; }
mkdir -p "$OUT"

SSH_KEY_OPTS=(
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=12
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)
SSH_PASS_OPTS=(
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=12
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

REMOTE=()
AUTH=""

connect_device() {
  local ip="$1"
  if ssh "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(ssh "${SSH_KEY_OPTS[@]}" "root@$ip")
    AUTH=publickey
    return 0
  fi
  if sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip")
    AUTH=password_fallback
    return 0
  fi
  return 1
}

read_remote() {
  local file="$1" command="$2"
  "${REMOTE[@]}" "$command" </dev/null >"$file" 2>"$file.stderr"
}

capture_marker() {
  local var="$1" name="$2" dir="$3" path
  path="$var/.ziyan_$name"
  if "${REMOTE[@]}" "test -e '$path'" </dev/null >"$dir/$name.exists" 2>"$dir/$name.exists.stderr"; then
    printf 'PRESENT\n' >"$dir/$name.state"
    "${REMOTE[@]}" "stat -c '%Y' '$path'; cat '$path'" </dev/null >"$dir/$name.snapshot" 2>"$dir/$name.snapshot.stderr"
  else
    printf 'ABSENT\n' >"$dir/$name.state"
    : >"$dir/$name.snapshot"
  fi
}

python_metrics() {
  local ps_file="$1" output="$2" frozen_sb="$3" frozen_bb="$4" frozen_fc="$5" frozen_zy="$6"
  python3 - "$ps_file" "$output" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy" <<'PY'
from pathlib import Path
import sys

ps_path, out_path, frozen_sb, frozen_bb, frozen_fc, frozen_zy = sys.argv[1:]
lines = Path(ps_path).read_text(encoding="utf-8", errors="replace").splitlines()

def excluded(args):
    return any(token in args for token in ("sh -c", "zsh -c", "bash -s", "grep", "sed"))

def rows_for_suffix(suffix):
    rows = []
    for line in lines:
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, args = parts
        if not excluded(args) and args.endswith(suffix):
            rows.append((pid, args))
    return rows

sb = rows_for_suffix("/System/Library/CoreServices/SpringBoard.app/SpringBoard")
bb = rows_for_suffix("backboardd")
fc = rows_for_suffix("ziyan_framecap serve")
zy = []
agent = []
for line in lines:
    parts = line.strip().split(None, 1)
    if len(parts) != 2:
        continue
    pid, args = parts
    if excluded(args):
        continue
    if "ziyadaemond" in args or "ziyan_zydaemond" in args:
        zy.append((pid, args))
    if "lua5.3" in args and "ziyan_agent_run.lua" in args:
        agent.append((pid, args))

def first(rows):
    return rows[0][0] if rows else ""

values = {
    "SB_PID": first(sb),
    "SB_LINE": sb[0][1] if sb else "",
    "BB_PID": first(bb),
    "BB_LINE": bb[0][1] if bb else "",
    "FC_PID": first(fc),
    "FC_LINE": fc[0][1] if fc else "",
    "FC_N": str(len(fc)),
    "REAL_AGENT_LUA_N": str(len(agent)),
    "REAL_AGENT_LUA_LINES": " || ".join(f"{pid} {args}" for pid, args in agent),
    "ZY_LINES": " || ".join(f"{pid} {args}" for pid, args in zy),
    "SB_FROZEN_MATCH": str(int(first(sb) == frozen_sb)),
    "BB_FROZEN_MATCH": str(int(first(bb) == frozen_bb)),
    "FC_FROZEN_MATCH": str(int(first(fc) == frozen_fc)),
    "ZY_FROZEN_PRESENT": str(int(any(pid == frozen_zy for pid, _ in zy))),
}
Path(out_path).write_text(
    "".join(f"{key}={value}\n" for key, value in values.items()),
    encoding="utf-8",
)
PY
}

value() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

list_new_files() {
  comm -13 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2")
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5"
  local frozen_fc="$6" frozen_zy="$7" tap_ts="$8" hid_record_1="$9"
  local hid_record_2="${10:-}" out="$OUT/$tag" var baseline_dir
  local failures=() profile front state active keep stop req drill_id
  local learn_list record_list baseline_learn baseline_records new_learns=0 new_records=0
  local record_path record_file new_tapped=0

  mkdir -p "$out"
  baseline_dir="$BASE/$tag/final"
  if [ "$scheme" = rootless ]; then
    var="/var/jb/usr/lib/ziyan/var"
  else
    var="/usr/lib/ziyan/var"
  fi

  printf 'TAG=.%s\nIP=%s\nSCHEME=%s\n' "$tag" "$ip" "$scheme" >"$out/TRANSCRIPT.log"
  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nSMOKE=FAIL\nREASON=ssh_connect\n' >>"$out/TRANSCRIPT.log"
    printf 'SMOKE=FAIL\nREASON=ssh_connect\n' >"$out/STATE.txt"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  read_remote "$out/PS.txt" 'ps -A -o pid=,args=' || failures+=(ps_read)
  read_remote "$out/SESSION.txt" "cat '$var/.ziyan_agent_session' 2>/dev/null" || failures+=(session_read)
  read_remote "$out/PROFILE.txt" "cat '$var/.ziyan_agent_current_profile' 2>/dev/null" || failures+=(profile_read)
  read_remote "$out/FRONT.txt" "cat '$var/.ziyan_front_bid' 2>/dev/null" || failures+=(front_read)
  read_remote "$out/REQ.txt" "cat '$var/.ziyan_agent_req' 2>/dev/null" || true
  read_remote "$out/FLAGS.txt" "test -e '$var/.ziyan_keep_daemon' && echo KEEP=PRESENT || echo KEEP=ABSENT
test -e '$var/.ziyan_agent_stop' && echo STOP=PRESENT || echo STOP=ABSENT
test -e '$var/.ziyan_drill_learn_id' && echo DRILL_LEARN_ID=PRESENT || echo DRILL_LEARN_ID=ABSENT" \
    || failures+=(flags_read)
  read_remote "$out/LEARN.txt" "find '$LEARN_ROOT' -maxdepth 1 -type f -print | sort" || failures+=(learn_read)
  read_remote "$out/RECORDS.txt" "find '$RECORD_ROOT' -maxdepth 1 -type f -print | sort" || failures+=(records_read)
  capture_marker "$var" tap_gate "$out" || failures+=(tap_gate_read)
  capture_marker "$var" tap_meta "$out" || failures+=(tap_meta_read)
  python_metrics "$out/PS.txt" "$out/METRICS.txt" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"

  profile="$(value "$out/PROFILE.txt" profile_id)"
  front="$(tr -d '\r\n' <"$out/FRONT.txt")"
  state="$(value "$out/SESSION.txt" state)"
  active="$(value "$out/SESSION.txt" active)"
  keep="$(value "$out/FLAGS.txt" KEEP)"
  stop="$(value "$out/FLAGS.txt" STOP)"
  req="$(tr '\n' ';' <"$out/REQ.txt")"
  drill_id="$(value "$out/FLAGS.txt" DRILL_LEARN_ID)"

  baseline_learn="$baseline_dir/learn_ls.txt"
  baseline_records="$baseline_dir/record_ls.txt"
  if [ ! -f "$baseline_learn" ] || [ ! -f "$baseline_records" ]; then
    failures+=(baseline_missing)
  else
    list_new_files "$baseline_learn" "$out/LEARN.txt" >"$out/NEW_LEARNING_FILES.txt"
    list_new_files "$baseline_records" "$out/RECORDS.txt" >"$out/NEW_RECORD_FILES.txt"
    new_learns="$(wc -l <"$out/NEW_LEARNING_FILES.txt" | tr -d ' ')"
    new_records="$(wc -l <"$out/NEW_RECORD_FILES.txt" | tr -d ' ')"
    while IFS= read -r record_path; do
      [ -n "$record_path" ] || continue
      record_file="$out/record_$(basename "$record_path")"
      read_remote "$record_file" "cat '$record_path'" || failures+=(new_record_read)
      if grep -qF 'tapped=1' "$record_file"; then
        new_tapped=$((new_tapped + 1))
      fi
    done <"$out/NEW_RECORD_FILES.txt"
  fi

  grep -qx "PRESENT" "$out/tap_gate.state" || failures+=(tap_gate_absent)
  grep -qx "PRESENT" "$out/tap_meta.state" || failures+=(tap_meta_absent)
  grep -q "^ts=$tap_ts " "$out/tap_gate.snapshot" || failures+=(tap_gate_ts)
  [ "$(head -n 1 "$out/tap_meta.snapshot")" = "$tap_ts" ] || failures+=(tap_meta_ts)
  grep -q "xy=" "$out/tap_meta.snapshot" || failures+=(tap_meta_shape)
  [ "$profile" = agent_default_observe ] || failures+=(profile_id)
  grep -qx 'bundle_id=com.ziyan.ziyan' "$out/PROFILE.txt" || failures+=(profile_bundle)
  [ "$front" = com.ziyan.ziyan ] || failures+=(front)
  [ "$(value "$out/METRICS.txt" SB_FROZEN_MATCH)" = 1 ] || failures+=(sb_frozen)
  [ "$(value "$out/METRICS.txt" BB_FROZEN_MATCH)" = 1 ] || failures+=(bb_frozen)
  [ "$(value "$out/METRICS.txt" FC_FROZEN_MATCH)" = 1 ] || failures+=(fc_frozen)
  [ "$(value "$out/METRICS.txt" FC_N)" = 1 ] || failures+=(fc_n)
  [ "$(value "$out/METRICS.txt" REAL_AGENT_LUA_N)" = 0 ] || failures+=(real_agent_lua)
  [ "$(value "$out/METRICS.txt" ZY_FROZEN_PRESENT)" = 1 ] || failures+=(zy_frozen)
  [ "$keep" = ABSENT ] || failures+=(keep_present)
  [ "$stop" = ABSENT ] || failures+=(stop_present)
  [ "$new_learns" = 0 ] || failures+=(new_learning_files)
  [ "$new_tapped" = 0 ] || failures+=(new_tapped_records)
  test -f "$RECORD_ROOT/$hid_record_1.txt" 2>/dev/null || true
  for required_id in "$hid_record_1" "$hid_record_2"; do
    [ -n "$required_id" ] || continue
    if ! grep -qF "$RECORD_ROOT/$required_id.txt" "$out/RECORDS.txt"; then
      failures+=(hid_record_missing)
    fi
  done

  {
    printf 'TAG=.%s\nAUTH=%s\n' "$tag" "$AUTH"
    printf 'SB_PID=%s\nBB_PID=%s\nFC_PID=%s\nFC_N=%s\n' \
      "$(value "$out/METRICS.txt" SB_PID)" "$(value "$out/METRICS.txt" BB_PID)" \
      "$(value "$out/METRICS.txt" FC_PID)" "$(value "$out/METRICS.txt" FC_N)"
    printf 'SB_FROZEN_MATCH=%s\nBB_FROZEN_MATCH=%s\nFC_FROZEN_MATCH=%s\nZY_FROZEN_PRESENT=%s\n' \
      "$(value "$out/METRICS.txt" SB_FROZEN_MATCH)" "$(value "$out/METRICS.txt" BB_FROZEN_MATCH)" \
      "$(value "$out/METRICS.txt" FC_FROZEN_MATCH)" "$(value "$out/METRICS.txt" ZY_FROZEN_PRESENT)"
    printf 'REAL_AGENT_LUA_N=%s\nKEEP=%s\nSTOP=%s\n' \
      "$(value "$out/METRICS.txt" REAL_AGENT_LUA_N)" "$keep" "$stop"
    printf 'FRONT=%s\nPROFILE_ID=%s\nPROFILE_BUNDLE=%s\nSESSION_STATE=%s\nSESSION_ACTIVE=%s\n' \
      "$front" "$profile" "$(value "$out/PROFILE.txt" bundle_id)" "$state" "$active"
    printf 'REQ_NOTE=%s\nDRILL_LEARN_ID=%s\n' "$req" "$drill_id"
    printf 'TAP_GATE_STATE=%s\nTAP_META_STATE=%s\nTAP_EXPECTED_TS=%s\n' \
      "$(cat "$out/tap_gate.state")" "$(cat "$out/tap_meta.state")" "$tap_ts"
    printf 'SEVEN_RECORD_1=%s\nSEVEN_RECORD_2=%s\nNEW_LEARNING_FILES=%s\nNEW_RECORD_FILES=%s\nNEW_TAPPED_RECORDS=%s\n' \
      "$hid_record_1" "$hid_record_2" "$new_learns" "$new_records" "$new_tapped"
    if [ "${#failures[@]}" -eq 0 ]; then
      printf 'SMOKE=OK\n'
    else
      printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; printf '%s' "${failures[*]}")"
    fi
  } >"$out/STATE.txt"
  cat "$out/STATE.txt" >>"$out/TRANSCRIPT.log"
  [ "${#failures[@]}" -eq 0 ]
}

overall_ok=1
reasons=()
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 1788633746 ags_17886337469438 || { overall_ok=0; reasons+=(.101); }
run_one 112 192.168.31.112 rootful 79809 79808 98110 92 1788633753 ags_17886337525795 || { overall_ok=0; reasons+=(.112); }
run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 1788633761 ags_17886337609702 || { overall_ok=0; reasons+=(.166); }
run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 1788634174 ags_17886337703981 ags_17886341743064 || { overall_ok=0; reasons+=(.53); }

python3 - "$OUT" "$overall_ok" "${reasons[*]:-}" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
overall_ok = sys.argv[2] == "1"
reasons = sys.argv[3]
rows = []
for tag in ("101", "112", "166", "53"):
    state = out / tag / "STATE.txt"
    if not state.exists():
        rows.append((tag, "NOT_RUN", "prior_device_not_clean"))
        continue
    values = {}
    for line in state.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    rows.append((tag, values.get("SMOKE", "FAIL"), values.get("REASON", "none")))

all_ok = overall_ok and all(smoke == "OK" for _, smoke, _ in rows)
lines = [
    "# 九号开发：HID 停后残留只读审核",
    "",
    "这是九号开发，不是十号；不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload。",
    "严格串行 `.101 -> .112 -> .166 -> .53`；未启动 Lua、未 scp、未改 lua/objc、未点游戏。",
    "session=PAUSED_SAFE 仅记录，不为 STOPPED 再跑 Lua；req 与 drill_learn_id 仅记录。",
    "",
]
lines.extend(f"- .{tag}: SMOKE={smoke} REASON={reason}" for tag, smoke, reason in rows)
lines.append("")
lines.append("AGENT_TRUE_HID_LEFTOVER=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN"))
if not all_ok:
    lines.append("REASON=" + (reasons or ";".join(f".{tag}:{reason}" for tag, smoke, reason in rows if smoke != "OK")))
lines.append("NEXT_ACTION=等待人工最终审核")
(out / "VERDICT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
(out / "OVERALL.txt").write_text(
    ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN") + "\n",
    encoding="utf-8",
)
print((out / "VERDICT.md").read_text(encoding="utf-8"), end="")
PY

overall="$(cat "$OUT/OVERALL.txt")"
python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "九号开发：HID 停后残留只读采证完成" \
  --last-command "bash tools/zy_dev09_agent_true_hid_leftover.sh；严格串行 .101 -> .112 -> .166 -> .53；未启动 Lua、未 scp" \
  --result "AGENT_TRUE_HID_LEFTOVER=$overall；详见 VERDICT；未 sbreload、未点游戏" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV09_AGENT_TRUE_HID_LEFTOVER_20260906/VERDICT.md；四机 STATE、PS、METRICS、PROFILE、SESSION、FLAGS、REQ、marker、七号记录与新增文件证据" \
  --latest-verdict "AGENT_TRUE_HID_LEFTOVER=$overall；这是九号开发，不是十号；不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload" \
  --package-version "本刀未安装、重建、改包或 scp runtime" \
  --package-sha256 "本刀未改设备 runtime；未触发任何部署" \
  --device-state "严格串行 .101/.112/.166/.53 只读；profile=agent_default_observe/com.ziyan.ziyan；tap_gate/tap_meta 与七号 ts 核验" \
  --running-processes "冻结 SB/BB/FC 与 zy 逐机核验；四机 FC_N=1；真实 agent lua 按 lua5.3+ziyan_agent_run.lua 同时筛选" \
  --cleanup-status "keep/stop ABSENT；session=PAUSED_SAFE 仅记录；req/.ziyan_drill_learn_id 仅记录；未 sbreload/ldrestart/killall/dpkg"

[ "$overall" = "PASS_PENDING_HUMAN" ]
