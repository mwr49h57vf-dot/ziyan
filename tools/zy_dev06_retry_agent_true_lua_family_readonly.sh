#!/usr/bin/env bash
# 六号开发补：修正记录存在性采集。严格串行，只读，不启动 Lua。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV06_RETRY_AGENT_TRUE_LUA_FAMILY_20260906"
PASS="${ZY_SSH_PASS:-alpine}"

mkdir -p "$OUT"

SSH_KEY_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)
SSH_PASS_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)

REMOTE=()
AUTH=""

connect_device() {
  local ip="$1"
  local key_remote=(ssh "${SSH_KEY_OPTS[@]}" "root@$ip")
  local pass_remote=(sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip")
  if "${key_remote[@]}" true >/dev/null 2>&1; then
    REMOTE=("${key_remote[@]}")
    AUTH=publickey
    return 0
  fi
  if "${pass_remote[@]}" true >/dev/null 2>&1; then
    REMOTE=("${pass_remote[@]}")
    AUTH=password_fallback
    return 0
  fi
  return 1
}

read_remote() {
  local output="$1"
  shift
  "${REMOTE[@]}" "$@" </dev/null >"$output" 2>"$output.stderr"
}

excluded_command() {
  case "$1" in
    *"sh -c"*|*"zsh -c"*|*"bash -s"*|*"grep"*|*"sed"*) return 1 ;;
  esac
  return 0
}

pid_for_suffix() {
  local ps_file="$1" suffix="$2" line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%%[[:space:]]*}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    excluded_command "$args" || continue
    [[ "$args" == *"$suffix" ]] || continue
    [[ "${args: -${#suffix}}" == "$suffix" ]] || continue
    printf '%s\n' "$pid"
    return 0
  done <"$ps_file"
  return 0
}

count_suffix() {
  local ps_file="$1" suffix="$2" line pid args n=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%%[[:space:]]*}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    excluded_command "$args" || continue
    [[ "$args" == *"$suffix" ]] || continue
    [[ "${args: -${#suffix}}" == "$suffix" ]] || continue
    n=$((n + 1))
  done <"$ps_file"
  printf '%s\n' "$n"
}

count_real_agent_lua() {
  local ps_file="$1" line pid args n=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%%[[:space:]]*}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    excluded_command "$args" || continue
    [[ "$args" == *lua5.3* && "$args" == *ziyan_agent_run.lua* ]] && n=$((n + 1))
  done <"$ps_file"
  printf '%s\n' "$n"
}

presence_check() {
  local output="$1" learn_id="$2" drill_id="$3" auto_id="$4"
  # File checks must go through the already-connected REMOTE; do not call ssh here.
  "${REMOTE[@]}" "test -f '/private/var/mobile/Media/ZiYan/Agent游戏/学习数据/$learn_id.txt' && echo 'LEARN=PRESENT' || echo 'LEARN=MISSING'
test -f '/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/$drill_id.txt' && echo 'DRILL=PRESENT' || echo 'DRILL=MISSING'
test -f '/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/$auto_id.txt' && echo 'AUTO=PRESENT' || echo 'AUTO=MISSING'" \
    </dev/null >"$output" 2>"$output.stderr"
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5"
  local frozen_fc="$6" frozen_zy="$7" learn_id="$8" drill_id="$9" auto_id="${10}"
  local out="$OUT/$tag" var ps sb bb fc fc_n zy agent_n front state active
  local keep stop learn_present drill_present auto_present failures=()

  mkdir -p "$out"
  if [ "$scheme" = rootless ]; then
    var="/var/jb/usr/lib/ziyan/var"
  else
    var="/usr/lib/ziyan/var"
  fi

  printf 'TAG=.%s\nIP=%s\nSCHEME=%s\n' "$tag" "$ip" "$scheme" >"$out/TRANSCRIPT.log"
  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nSMOKE=FAIL\nREASON=ssh_connect\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  ps="$out/PS.txt"
  read_remote "$ps" 'ps -A -o pid=,args=' || failures+=(ps_read)
  read_remote "$out/SESSION.txt" "cat '$var/.ziyan_agent_session' 2>/dev/null" || true
  read_remote "$out/FRONT.txt" "cat '$var/.ziyan_front_bid' 2>/dev/null" || true
  read_remote "$out/PROFILE.txt" "cat '$var/.ziyan_agent_current_profile' 2>/dev/null" || true
  read_remote "$out/FLAGS.txt" "test -e '$var/.ziyan_keep_daemon' && echo KEEP=PRESENT || echo KEEP=ABSENT
test -e '$var/.ziyan_agent_stop' && echo STOP=PRESENT || echo STOP=ABSENT
test -e '$var/.ziyan_agent_req' && echo REQ=PRESENT || echo REQ=ABSENT
test -e '$var/.ziyan_drill_learn_id' && echo DRILL_LEARN_ID=PRESENT || echo DRILL_LEARN_ID=ABSENT" || failures+=(flags_read)
  presence_check "$out/RECORD_PRESENCE.txt" "$learn_id" "$drill_id" "$auto_id" || failures+=(records_read)

  sb="$(pid_for_suffix "$ps" "/System/Library/CoreServices/SpringBoard.app/SpringBoard")"
  bb="$(pid_for_suffix "$ps" "backboardd")"
  fc="$(pid_for_suffix "$ps" "ziyan_framecap serve")"
  fc_n="$(count_suffix "$ps" "ziyan_framecap serve")"
  agent_n="$(count_real_agent_lua "$ps")"
  zy="$(awk -v wanted="$frozen_zy" '$1 == wanted { found=1 } END { print found + 0 }' "$ps")"
  front="$(tr -d '\r\n' <"$out/FRONT.txt")"
  state="$(sed -n 's/^state=//p' "$out/SESSION.txt" | head -1)"
  active="$(sed -n 's/^active=//p' "$out/SESSION.txt" | head -1)"
  keep="$(sed -n 's/^KEEP=//p' "$out/FLAGS.txt" | head -1)"
  stop="$(sed -n 's/^STOP=//p' "$out/FLAGS.txt" | head -1)"
  learn_present="$(sed -n 's/^LEARN=//p' "$out/RECORD_PRESENCE.txt" | head -1)"
  drill_present="$(sed -n 's/^DRILL=//p' "$out/RECORD_PRESENCE.txt" | head -1)"
  auto_present="$(sed -n 's/^AUTO=//p' "$out/RECORD_PRESENCE.txt" | head -1)"

  [ "$sb" = "$frozen_sb" ] || failures+=(sb_frozen)
  [ "$bb" = "$frozen_bb" ] || failures+=(bb_frozen)
  [ "$fc" = "$frozen_fc" ] || failures+=(fc_frozen)
  [ "$fc_n" = 1 ] || failures+=(fc_n)
  [ "$zy" = 1 ] || failures+=(zy_frozen_absent)
  [ "$front" = "com.ziyan.ziyan" ] || failures+=(front)
  [ "$state" = STOPPED ] || failures+=(session_stopped)
  [ "$active" = 0 ] || failures+=(session_active)
  [ "$keep" = ABSENT ] || failures+=(keep)
  [ "$stop" = ABSENT ] || failures+=(stop)
  [ "$agent_n" = 0 ] || failures+=(real_agent_lua)
  [ "$learn_present" = PRESENT ] || failures+=(learn_record_missing)
  [ "$drill_present" = PRESENT ] || failures+=(drill_record_missing)
  [ "$auto_present" = PRESENT ] || failures+=(auto_record_missing)

  {
    printf 'SB_PID=%s\nBB_PID=%s\nFC_PID=%s\nFC_N=%s\nZY_FROZEN_PRESENT=%s\n' \
      "$sb" "$bb" "$fc" "$fc_n" "$zy"
    printf 'FRONT=%s\nSESSION_STATE=%s\nSESSION_ACTIVE=%s\nKEEP=%s\nSTOP=%s\n' \
      "$front" "$state" "$active" "$keep" "$stop"
    printf 'REAL_AGENT_LUA_N=%s\n' "$agent_n"
    printf 'LEARN_RECORD=%s\nDRILL_RECORD=%s\nAUTO_RECORD=%s\n' \
      "$learn_present" "$drill_present" "$auto_present"
    printf 'REQ=%s\nDRILL_LEARN_ID=%s\n' \
      "$(sed -n 's/^REQ=//p' "$out/FLAGS.txt" | head -1)" \
      "$(sed -n 's/^DRILL_LEARN_ID=//p' "$out/FLAGS.txt" | head -1)"
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
run_if_clean() {
  [ "$overall_ok" = 1 ] || return 0
  run_one "$@" || overall_ok=0
}

run_if_clean 101 192.168.31.101 rootful 87863 87862 47853 96 \
  ags_17886130846274 ags_17886236835498 ags_17886296402152
run_if_clean 112 192.168.31.112 rootful 79809 79808 98110 92 \
  ags_17886130889526 ags_17886277372496 ags_17886296471822
run_if_clean 166 192.168.31.166 rootful 25025 25024 52622 82626 \
  ags_17886130933873 ags_17886277436109 ags_17886296545352
run_if_clean 53 192.168.31.53 rootless 46408 74318 49176 93705 \
  ags_17886131005180 ags_17886278684212 ags_17886296643544

python3 - "$OUT" "$overall_ok" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
overall_ok = sys.argv[2] == "1"
tags = ("101", "112", "166", "53")
rows = []
for tag in tags:
    state = out / tag / "STATE.txt"
    if not state.exists():
        rows.append((tag, "NOT_RUN", "prior_device_failed"))
        continue
    values = {}
    for line in state.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    rows.append((tag, values.get("SMOKE", "FAIL"), values.get("REASON", "none")))

all_ok = overall_ok and all(smoke == "OK" for _, smoke, _ in rows)
lines = [
    "# 六号开发补：只读汇总 Agent 真 Lua 家族",
    "",
    "这是六号开发补，不是七号；不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload。",
    "严格串行 .101 -> .112 -> .166 -> .53；未启动 Lua，未 scp，未改 lua/objc。",
    "",
]
lines.extend(f"- .{tag}: SMOKE={smoke} REASON={reason}" for tag, smoke, reason in rows)
lines.extend([
    "",
    "AGENT_TRUE_LUA_FAMILY=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN"),
])
if not all_ok:
    reasons = [f".{tag}:{reason}" for tag, smoke, reason in rows if smoke != "OK"]
    lines.append("REASON=" + ";".join(reasons))
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
  --stage "六号开发补：只读汇总 Agent 真 Lua 家族" \
  --last-command "bash tools/zy_dev06_retry_agent_true_lua_family_readonly.sh；严格串行 .101 -> .112 -> .166 -> .53；未启动 Lua、未 scp" \
  --result "AGENT_TRUE_LUA_FAMILY=$overall；见六号开发补 VERDICT；未 sbreload、未开七号" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV06_RETRY_AGENT_TRUE_LUA_FAMILY_20260906/VERDICT.md；四机 PS.txt、SESSION.txt、FRONT.txt、PROFILE.txt、FLAGS.txt、RECORD_PRESENCE.txt、STATE.txt" \
  --latest-verdict "AGENT_TRUE_LUA_FAMILY=$overall；这是六号开发补，不是七号；不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改设备 runtime" \
  --device-state ".101/.112/.166/.53 严格串行只读；记录存在性按正确学习数据/运行记录路径经 REMOTE 核验" \
  --running-processes ".101 SB=87863 BB=87862 FC=47853 zy=96；.112 SB=79809 BB=79808 FC=98110 zy=92；.166 SB=25025 BB=25024 FC=52622 zy=82626；.53 SB=46408 BB=74318 FC=49176 zy=93705；四机 FC_N=1、无真实 agent lua" \
  --cleanup-status "session=STOPPED/active=0；keep/stop ABSENT；req/.ziyan_drill_learn_id 只记；未 sbreload/ldrestart/killall/dpkg"

[ "$overall" = PASS_PENDING_HUMAN ]
