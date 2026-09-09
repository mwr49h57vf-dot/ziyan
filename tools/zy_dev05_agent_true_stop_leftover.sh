#!/usr/bin/env bash
# 五号开发：learn/drill/auto 停后残留只读采证。严格串行，不启动 Lua。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV05_AGENT_TRUE_STOP_LEFTOVER_20260906"
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
  if ssh "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(ssh "${SSH_KEY_OPTS[@]}" "root@$ip")
    AUTH="publickey"
    return 0
  fi
  if sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip")
    AUTH="password_fallback"
    return 0
  fi
  return 1
}

excluded_command() {
  [[ "$1" =~ (^|[[:space:]])(sh[[:space:]]+-c|zsh[[:space:]]+-c|bash[[:space:]]+-s|grep|sed)([[:space:]]|$) ]]
}

pid_for_exact_suffix() {
  local suffix="$1" line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    excluded_command "$args" && continue
    [[ "$args" == *"$suffix" ]] && [[ "$args" == "${args%"$suffix"}$suffix" ]] || continue
    [[ "${args: -${#suffix}}" == "$suffix" ]] || continue
    printf '%s\n' "$pid"
    return 0
  done
  return 0
}

count_agent_lua() {
  local line pid args n=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    excluded_command "$args" && continue
    [[ "$args" == *lua5.3* && "$args" == *ziyan_agent_run.lua* ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

frozen_pid_present() {
  local ps_file="$1" wanted="$2"
  awk -v wanted="$wanted" '$1 == wanted { found=1 } END { print found + 0 }' "$ps_file"
}

read_remote() {
  local file="$1"
  shift
  "${REMOTE[@]}" "$@" </dev/null >"$file" 2>"$file.stderr"
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5" frozen_fc="$6" frozen_zy="$7"
  local learn_id="$8" drill_id="$9" auto_id="${10}" out="$OUT/$tag"
  local var ps_file session_file records_file flags_file profile_file req_file
  local sb bb fc fc_n agent_n zy keep stop state active profile_id bundle record_ok learn_ok drill_ok auto_ok
  local drill_learn_id="ABSENT" req_note="ABSENT" failures=()

  mkdir -p "$out"
  if [ "$scheme" = "rootless" ]; then
    var="/var/jb/usr/lib/ziyan/var"
  else
    var="/usr/lib/ziyan/var"
  fi

  if ! connect_device "$ip"; then
    printf 'SMOKE=FAIL\nREASON=ssh_connect\n' >"$out/STATE.txt"
    return 1
  fi

  ps_file="$out/PS.txt"
  session_file="$out/SESSION.txt"
  records_file="$out/RECORDS.txt"
  flags_file="$out/FLAGS.txt"
  profile_file="$out/PROFILE.txt"
  req_file="$out/REQ.txt"
  read_remote "$ps_file" "ps -A -o pid=,args=" || failures+=("ps_read")
  read_remote "$session_file" "cat '$var/.ziyan_agent_session' 2>/dev/null" || true
  read_remote "$flags_file" "test -e '$var/.ziyan_keep_daemon' && echo KEEP=PRESENT || echo KEEP=ABSENT; test -e '$var/.ziyan_agent_stop' && echo STOP=PRESENT || echo STOP=ABSENT; test -e '$var/.ziyan_drill_learn_id' && echo DRILL_LEARN_ID=PRESENT || echo DRILL_LEARN_ID=ABSENT" || failures+=("flags_read")
  read_remote "$profile_file" "cat '$var/.ziyan_agent_current_profile' 2>/dev/null" || true
  read_remote "$req_file" "cat '$var/.ziyan_agent_req' 2>/dev/null" || true
  read_remote "$records_file" "for f in '/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/$learn_id.txt' '/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/$drill_id.txt' '/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/$auto_id.txt'; do test -f \"\$f\" && printf 'PRESENT %s\n' \"\$f\" || printf 'MISSING %s\n' \"\$f\"; done" || failures+=("records_read")

  sb="$(pid_for_exact_suffix "/System/Library/CoreServices/SpringBoard.app/SpringBoard" <"$ps_file")"
  bb="$(pid_for_exact_suffix "backboardd" <"$ps_file")"
  fc_n="$(grep -v -E '(^|[[:space:]])(sh[[:space:]]+-c|zsh[[:space:]]+-c|bash[[:space:]]+-s|grep|sed)([[:space:]]|$)' "$ps_file" | awk '$0 ~ /ziyan_framecap serve$/ { n++ } END { print n + 0 }')"
  fc="$(pid_for_exact_suffix "ziyan_framecap serve" <"$ps_file")"
  agent_n="$(count_agent_lua <"$ps_file")"
  zy="$(frozen_pid_present "$ps_file" "$frozen_zy")"
  keep="$(sed -n 's/^KEEP=//p' "$flags_file" | head -1)"
  stop="$(sed -n 's/^STOP=//p' "$flags_file" | head -1)"
  drill_learn_id="$(sed -n 's/^DRILL_LEARN_ID=//p' "$flags_file" | head -1)"
  state="$(sed -n 's/^state=//p' "$session_file" | head -1)"
  active="$(sed -n 's/^active=//p' "$session_file" | head -1)"
  profile_id="$(sed -n 's/^profile_id=//p' "$profile_file" | head -1)"
  bundle="$(sed -n 's/^bundle_id=//p' "$profile_file" | head -1)"
  req_note="$(tr '\n' ';' <"$req_file" 2>/dev/null)"
  grep -q "^PRESENT .*$learn_id\\.txt$" "$records_file" && learn_ok=1 || learn_ok=0
  grep -q "^PRESENT .*$drill_id\\.txt$" "$records_file" && drill_ok=1 || drill_ok=0
  grep -q "^PRESENT .*$auto_id\\.txt$" "$records_file" && auto_ok=1 || auto_ok=0

  [ "$sb" = "$frozen_sb" ] || failures+=("sb_frozen")
  [ "$bb" = "$frozen_bb" ] || failures+=("bb_frozen")
  [ "$fc" = "$frozen_fc" ] || failures+=("fc_frozen")
  [ "$fc_n" = "1" ] || failures+=("fc_n")
  [ "$zy" = "1" ] || failures+=("zy_frozen_absent")
  [ "$agent_n" = "0" ] || failures+=("real_agent_lua")
  [ "$keep" = "ABSENT" ] || failures+=("keep")
  [ "$stop" = "ABSENT" ] || failures+=("stop")
  [ "$state" = "STOPPED" ] || failures+=("session_state")
  [ "$active" = "0" ] || failures+=("session_active")
  [ "$profile_id" = "agent_default_observe" ] || failures+=("profile_id")
  [ "$bundle" = "com.ziyan.ziyan" ] || failures+=("profile_bundle")
  [ "$learn_ok" = "1" ] || failures+=("learn_record_missing")
  [ "$drill_ok" = "1" ] || failures+=("drill_record_missing")
  [ "$auto_ok" = "1" ] || failures+=("auto_record_missing")

  {
    printf 'TAG=.%s\nAUTH=%s\n' "$tag" "$AUTH"
    printf 'SB_PID=%s\nBB_PID=%s\nFC_PID=%s\nFC_N=%s\nZY_FROZEN_PRESENT=%s\n' "$sb" "$bb" "$fc" "$fc_n" "$zy"
    printf 'REAL_AGENT_LUA_N=%s\nKEEP=%s\nSESSION_STATE=%s\nSESSION_ACTIVE=%s\nSTOP=%s\n' "$agent_n" "$keep" "$state" "$active" "$stop"
    printf 'PROFILE_ID=%s\nPROFILE_BUNDLE=%s\nREQ_NOTE=%s\nDRILL_LEARN_ID=%s\n' "$profile_id" "$bundle" "$req_note" "$drill_learn_id"
    printf 'LEARN_RECORD_PRESENT=%s\nDRILL_RECORD_PRESENT=%s\nAUTO_RECORD_PRESENT=%s\n' "$learn_ok" "$drill_ok" "$auto_ok"
    if [ "${#failures[@]}" -eq 0 ]; then
      printf 'SMOKE=OK\n'
    else
      printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; echo "${failures[*]}")"
    fi
  } >"$out/STATE.txt"

  [ "${#failures[@]}" -eq 0 ]
}

overall_status=0
run_if_clean() {
  [ "$overall_status" = 0 ] || return 0
  run_one "$@" || overall_status=1
}

run_if_clean 101 192.168.31.101 rootful 87863 87862 47853 96 ags_17886130846274 ags_17886236835498 ags_17886296402152
run_if_clean 112 192.168.31.112 rootful 79809 79808 98110 92 ags_17886130889526 ags_17886277372496 ags_17886296471822
run_if_clean 166 192.168.31.166 rootful 25025 25024 52622 82626 ags_17886130933873 ags_17886277436109 ags_17886296545352
run_if_clean 53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886131005180 ags_17886278684212 ags_17886296643544

python3 - "$OUT" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
rows = []
for tag in ("101", "112", "166", "53"):
    state_file = out / tag / "STATE.txt"
    if not state_file.exists():
        rows.append((tag, "NOT_RUN", "prior_device_not_clean"))
        continue
    text = state_file.read_text(encoding="utf-8", errors="replace")
    smoke = "OK" if "SMOKE=OK\n" in text else "FAIL"
    reason = next((line.split("=", 1)[1] for line in text.splitlines() if line.startswith("REASON=")), "none")
    rows.append((tag, smoke, reason))

all_ok = all(smoke == "OK" for _, smoke, _ in rows)
lines = [
    "# 五号开发：Agent 停后残留只读采证",
    "",
    "这是五号开发停后残留，不是四号重做。",
    "未启动 Lua，未 scp，未改设备文件，未 sbreload。",
    "不是 AGENT_TRUE_LUA_FAMILY；不是 AGENT_MVP_4PHONE_PASS；不是 G0。",
    "",
]
lines.extend(f"- .{tag}: SMOKE={smoke} REASON={reason}" for tag, smoke, reason in rows)
lines.extend([
    "",
    "AGENT_TRUE_STOP_LEFTOVER=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN"),
    "NEXT_ACTION=等待人工最终审核",
])
(out / "VERDICT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
overall = "PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN"
(out / "OVERALL.txt").write_text(overall + "\n", encoding="utf-8")
print((out / "VERDICT.md").read_text(encoding="utf-8"), end="")
PY

overall="$(cat "$OUT/OVERALL.txt")"
python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "五号开发：learn/drill/auto 停后残留只读采证完成" \
  --last-command "bash tools/zy_dev05_agent_true_stop_leftover.sh；严格串行 .101 -> .112 -> .166 -> .53；未启动 Lua、未 scp" \
  --result "AGENT_TRUE_STOP_LEFTOVER=$overall；详见 VERDICT；未启动 Lua、未 scp、未改设备" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV05_AGENT_TRUE_STOP_LEFTOVER_20260906/VERDICT.md；四机 PS.txt、SESSION.txt、FLAGS.txt、PROFILE.txt、REQ.txt、RECORDS.txt、STATE.txt" \
  --latest-verdict "AGENT_TRUE_STOP_LEFTOVER=$overall；不是 AGENT_TRUE_LUA_FAMILY；不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改设备 runtime，未触发 .53 复跑" \
  --device-state ".101/.112/.166/.53 严格串行只读完成；profile=agent_default_observe/com.ziyan.ziyan；冻结 MATCH" \
  --running-processes ".101 SB=87863 BB=87862 FC=47853 zy=96；.112 SB=79809 BB=79808 FC=98110 zy=92；.166 SB=25025 BB=25024 FC=52622 zy=82626；.53 SB=46408 BB=74318 FC=49176 zy=93705；四机 FC_N=1、REAL_AGENT_LUA_N=0" \
  --cleanup-status "四机 session=STOPPED/active=0；keep/stop ABSENT；req/drill_learn_id 仅记录，不清理；未 sbreload/ldrestart/killall/dpkg"

[ "$overall" = "PASS_PENDING_HUMAN" ]
