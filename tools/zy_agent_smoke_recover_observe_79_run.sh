#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/SEVENTYNINE_AGENT_SMOKE_RECOVER_OBSERVE_20260905"
PASS="${ZY_SSH_PASS:-alpine}"
CONTINUE="${ZY_RECOVER_79_CONTINUE:-0}"

SSH_KEY_OPTS=(
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)
SSH_PASS_OPTS=(
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)

ssh_r() {
  local ip="$1"
  shift
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
  fi
}

run_one() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local frozen_sb="$4"
  local frozen_bb="$5"
  local frozen_fc="$6"
  local frozen_zy="$7"
  local out="$OUT/$tag"
  mkdir -p "$out"

  ssh_r "$ip" \
    "SCHEME='$scheme' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' FROZEN_ZY='$frozen_zy' bash -s" \
    >"$out/TRANSCRIPT.log" 2>&1 <<'REMOTE'
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  LUA=/var/jb/usr/lib/ziyan/bin/lua5.3
  RUN=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
  AGENT=/var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib
else
  VAR=/usr/lib/ziyan/var
  LUA=/usr/lib/ziyan/bin/lua5.3
  RUN=/usr/lib/ziyan/lib/lua/ziyan_run.lua
  AGENT=/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
fi
REPORT_ROOT=/private/var/mobile/Media/ZiYan/Agent游戏/错误报告
RECORD_ROOT=/private/var/mobile/Media/ZiYan/Agent游戏/运行记录

is_real_agent_line() {
  case "$1" in
    *lua5.3*ziyan_agent_run.lua*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *"sh -c"*|*"bash -s"*) return 1 ;;
  esac
  return 0
}

session_value() {
  sed -n "s/^$1=//p" "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p'
}

front_bid() {
  tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null
}

report_for_session() {
  local id="$1"
  if [ "$SCHEME" = rootless ]; then
    [ -f "$REPORT_ROOT/$id.txt" ] && printf '%s\n' "$REPORT_ROOT/$id.txt"
  else
    [ -f "$REPORT_ROOT/$id/report.txt" ] && printf '%s\n' "$REPORT_ROOT/$id/report.txt"
  fi
}

record_for_session() {
  local id="$1"
  [ -f "$RECORD_ROOT/$id.txt" ] && printf '%s\n' "$RECORD_ROOT/$id.txt"
}

latest_record_id() {
  ls -t "$RECORD_ROOT"/ags_*.txt 2>/dev/null |
    sed -n '1p' | sed 's#.*/##; s#\.txt$##'
}

snapshot() {
  local phase="$1"
  local line ps_all sb_pid="" bb_pid="" fc_pid="" fc_n=0 agent_n=0 zy_present=0
  ps_all=$(ps -A -o pid=,args= 2>/dev/null)
  printf '=== %s ===\n' "$phase"
  while IFS= read -r line; do
    case "$line" in
      *SpringBoard.app/SpringBoard*)
        printf '%s_SB_LINE=%s\n' "$phase" "$line"
        if [ -z "$sb_pid" ]; then
          sb_pid="${line#"${line%%[![:space:]]*}"}"
          sb_pid="${sb_pid%% *}"
        fi
        ;;
      *backboardd*)
        printf '%s_BB_LINE=%s\n' "$phase" "$line"
        if [ -z "$bb_pid" ]; then
          bb_pid="${line#"${line%%[![:space:]]*}"}"
          bb_pid="${bb_pid%% *}"
        fi
        ;;
      *'ziyan_framecap serve'*)
        printf '%s_FC_LINE=%s\n' "$phase" "$line"
        fc_n=$((fc_n + 1))
        if [ -z "$fc_pid" ]; then
          fc_pid="${line#"${line%%[![:space:]]*}"}"
          fc_pid="${fc_pid%% *}"
        fi
        ;;
      *ziyadaemond*|*ziyan_zydaemond*)
        printf '%s_ZY_LINE=%s\n' "$phase" "$line"
        case "$line" in
          "$FROZEN_ZY"*|*" $FROZEN_ZY "*) zy_present=1 ;;
        esac
        ;;
    esac
    if is_real_agent_line "$line"; then
      printf '%s_REAL_AGENT_LUA=%s\n' "$phase" "$line"
      agent_n=$((agent_n + 1))
    fi
  done <<EOF
$ps_all
EOF
  printf '%s_SB_PID=%s\n' "$phase" "$sb_pid"
  printf '%s_BB_PID=%s\n' "$phase" "$bb_pid"
  printf '%s_FC_PID=%s\n' "$phase" "$fc_pid"
  printf '%s_FC_N=%s\n' "$phase" "$fc_n"
  printf '%s_REAL_AGENT_LUA_N=%s\n' "$phase" "$agent_n"
  printf '%s_ZY_FROZEN_PRESENT=%s\n' "$phase" "$zy_present"
  printf '%s_SB_FROZEN_MATCH=%s\n' "$phase" "$([ "$sb_pid" = "$FROZEN_SB" ] && echo 1 || echo 0)"
  printf '%s_BB_FROZEN_MATCH=%s\n' "$phase" "$([ "$bb_pid" = "$FROZEN_BB" ] && echo 1 || echo 0)"
  printf '%s_FC_FROZEN_MATCH=%s\n' "$phase" "$([ "$fc_pid" = "$FROZEN_FC" ] && echo 1 || echo 0)"
  printf '%s_HOOKS_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_hooks" 2>/dev/null
  printf '%s_HOOKS_END\n' "$phase"
  printf '%s_FRONT=%s\n' "$phase" "$(front_bid)"
  printf '%s_SESSION_STATE=%s\n' "$phase" "$(session_value state)"
  printf '%s_SESSION_ID=%s\n' "$phase" "$(session_value session_id)"
  printf '%s_APP_CLOSED_MARKER=%s\n' "$phase" \
    "$([ -e "$VAR/.ziyan_app_user_closed" ] && echo PRESENT || echo ABSENT)"
  printf '%s_AGENT_STOP_MARKER=%s\n' "$phase" "$([ -e "$VAR/.ziyan_agent_stop" ] && echo PRESENT || echo ABSENT)"
  LAST_SB_PID="$sb_pid"
  LAST_BB_PID="$bb_pid"
  LAST_FC_PID="$fc_pid"
  LAST_FC_N="$fc_n"
  LAST_AGENT_N="$agent_n"
  LAST_ZY_PRESENT="$zy_present"
}

pre_blocked() {
  printf 'SMOKE=PRE_BLOCKED\nREASON=%s\nNEXT_ALLOWED=0\n' "$1"
  snapshot AFTER
  exit 0
}

snapshot PRECHECK
PRECHECK_SESSION_ID="$(session_value session_id)"
PRECHECK_FRONT="$(front_bid)"
PRECHECK_LATEST_RECORD_ID="$(latest_record_id)"
PRECHECK_OK=0
if [ "$LAST_SB_PID" = "$FROZEN_SB" ] &&
   [ "$LAST_BB_PID" = "$FROZEN_BB" ] &&
   [ "$LAST_FC_PID" = "$FROZEN_FC" ] &&
   [ "$LAST_FC_N" = 1 ] &&
   [ "$LAST_ZY_PRESENT" = 1 ] &&
   [ "$LAST_AGENT_N" = 0 ] &&
   [ "$PRECHECK_FRONT" = com.apple.springboard ]; then
  PRECHECK_OK=1
fi
printf 'PRECHECK_SESSION_ID=%s\nPRECHECK_RESULT=%s\n' \
  "$PRECHECK_SESSION_ID" "$([ "$PRECHECK_OK" = 1 ] && echo PASS || echo FROZEN_OR_AGENT_MISMATCH)"
printf 'PRECHECK_FRONT=%s\n' "$PRECHECK_FRONT"
printf 'PRECHECK_LATEST_RECORD_ID=%s\n' "$PRECHECK_LATEST_RECORD_ID"
if [ "$PRECHECK_OK" != 1 ]; then
  pre_blocked FROZEN_OR_AGENT_MISMATCH
fi

if [ -e "$VAR/.ziyan_app_user_closed" ]; then
  rm -f "$VAR/.ziyan_app_user_closed"
  printf 'APP_CLOSED_MARKER_REMOVED=%s\n' \
    "$([ -e "$VAR/.ziyan_app_user_closed" ] && echo 0 || echo 1)"
else
  printf 'APP_CLOSED_MARKER_REMOVED=0\n'
fi
if [ -e "$VAR/.ziyan_app_user_closed" ]; then
  pre_blocked APP_CLOSED_MARKER_REMAINS
fi
printf 'APP_CLOSED_MARKER_ABSENT=1\n'

if [ -e "$VAR/.ziyan_agent_stop" ]; then
  pre_blocked STOP_MARKER_PRESENT
fi
printf 'STOP_MARKER_ABSENT=1\n'

OPEN_REQ="$VAR/.ziyan_open_app"
OPEN_REQ_TMP="$OPEN_REQ.79.tmp"
OPEN_BODY="com.ziyan.ziyan\n"
printf '%b' "$OPEN_BODY" > "$OPEN_REQ_TMP"
chmod 666 "$OPEN_REQ_TMP" 2>/dev/null
mv -f "$OPEN_REQ_TMP" "$OPEN_REQ"
OPEN_WRITE_RC=$?
OPEN_PRESENT_AFTER_WRITE=$([ -e "$OPEN_REQ" ] && echo 1 || echo 0)
printf 'OPEN_APP_BODY_BEGIN\n'; printf '%b' "$OPEN_BODY"; printf 'OPEN_APP_BODY_END\n'
printf 'OPEN_APP_WRITE_RC=%s\nOPEN_APP_PRESENT_AFTER_WRITE=%s\n' \
  "$OPEN_WRITE_RC" "$OPEN_PRESENT_AFTER_WRITE"
OPEN_FRONT=
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  OPEN_FRONT="$(front_bid)"
  if [ "$OPEN_FRONT" = com.ziyan.ziyan ]; then
    break
  fi
  sleep 1
done
OPEN_PRESENT_AFTER_WAIT=$([ -e "$OPEN_REQ" ] && echo 1 || echo 0)
printf 'OPEN_FRONT=%s\nOPEN_APP_PRESENT_AFTER_WAIT=%s\n' \
  "$OPEN_FRONT" "$OPEN_PRESENT_AFTER_WAIT"
if [ "$OPEN_WRITE_RC" != 0 ] || [ "$OPEN_FRONT" != com.ziyan.ziyan ] ||
   [ "$OPEN_PRESENT_AFTER_WAIT" != 0 ]; then
  pre_blocked OPEN_FAIL
fi

printf 'profile_id=agent_recover_observe\nbundle_id=com.ziyan.ziyan\ndisplay_name=收回前台\ngame_name=子砚\n' \
  > "$VAR/.ziyan_agent_current_profile"
printf 'mode=observe\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_current_profile" "$VAR/.ziyan_agent_req" 2>/dev/null
printf 'PROFILE_WRITTEN=agent_recover_observe\nPROFILE_BUNDLE_WRITTEN=com.ziyan.ziyan\nPROFILE_DISPLAY_WRITTEN=收回前台\nPROFILE_GAME_WRITTEN=子砚\nREQ_WRITTEN=mode=observe\n'

RUN_LOG="$VAR/.ziyan_agent_recover_observe_79_run.log"
RUN_RC_FILE="$VAR/.ziyan_agent_recover_observe_79_rc"
: > "$RUN_LOG"
: > "$RUN_RC_FILE"
(
  "$LUA" "$RUN" "$AGENT"
  printf '%s\n' "$?" > "$RUN_RC_FILE"
) > "$RUN_LOG" 2>&1 &
printf 'LAUNCH_PID=%s\n' "$!"

READY=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45; do
  RUN_RC="$(cat "$RUN_RC_FILE" 2>/dev/null)"
  CURRENT_ID="$(session_value session_id)"
  if [ -z "$CURRENT_ID" ]; then
    CURRENT_ID="$(latest_record_id)"
  fi
  CURRENT_STATE="$(session_value state)"
  CURRENT_AGENT_N=0
  while IFS= read -r line; do
    is_real_agent_line "$line" && CURRENT_AGENT_N=$((CURRENT_AGENT_N + 1))
  done <<EOF
$(ps -A -o pid=,args= 2>/dev/null)
EOF
  if [ "$RUN_RC" = 0 ] &&
     [ "$CURRENT_STATE" = STOPPED ] &&
     [ -n "$CURRENT_ID" ] &&
     [ "$CURRENT_ID" != "$PRECHECK_SESSION_ID" ] &&
     [ "$CURRENT_ID" != "$PRECHECK_LATEST_RECORD_ID" ] &&
     [ "$CURRENT_AGENT_N" = 0 ]; then
    READY=1
    printf 'STOPPED_POLL=%ss\n' "$i"
    break
  fi
  sleep 1
done
RUN_RC="$(cat "$RUN_RC_FILE" 2>/dev/null)"
printf 'RUN_RC=%s\n' "${RUN_RC:-ABSENT}"
printf 'RUN_LOG_BEGIN\n'
cat "$RUN_LOG" 2>/dev/null
printf 'RUN_LOG_END\n'

snapshot AFTER
NEW_SESSION_ID="$(session_value session_id)"
if [ -z "$NEW_SESSION_ID" ]; then
  NEW_SESSION_ID="$(latest_record_id)"
  printf 'SESSION_ID_RECOVERED_FROM_RECORD=%s\n' "$NEW_SESSION_ID"
fi
REPORT="$(report_for_session "$NEW_SESSION_ID")"
RECORD="$(record_for_session "$NEW_SESSION_ID")"
printf 'NEW_SESSION_ID=%s\nREPORT_PATH=%s\nRECORD_PATH=%s\n' \
  "$NEW_SESSION_ID" "${REPORT:-ABSENT}" "${RECORD:-ABSENT}"
if [ -n "$REPORT" ]; then
  printf 'REPORT_CONTENT_BEGIN\n'
  cat "$REPORT" 2>/dev/null
  printf 'REPORT_CONTENT_END\n'
fi
RECORD_OK=0
if [ -n "$RECORD" ]; then
  printf 'RECORD_CONTENT_BEGIN\n'
  cat "$RECORD" 2>/dev/null
  printf 'RECORD_CONTENT_END\n'
  if grep -q '^STOPPED .* mode=observe' "$RECORD"; then
    RECORD_OK=1
  fi
fi

SESSION_CHANGED=0
[ -n "$NEW_SESSION_ID" ] && [ "$NEW_SESSION_ID" != "$PRECHECK_SESSION_ID" ] && SESSION_CHANGED=1
if [ "$READY" = 1 ] &&
   [ "$RUN_RC" = 0 ] &&
   [ "$SESSION_CHANGED" = 1 ] &&
   [ "$(session_value state)" = STOPPED ] &&
   [ "$(front_bid)" = com.ziyan.ziyan ] &&
   [ "$LAST_AGENT_N" = 0 ] &&
   [ "$LAST_SB_PID" = "$FROZEN_SB" ] &&
   [ "$LAST_BB_PID" = "$FROZEN_BB" ] &&
   [ "$LAST_FC_PID" = "$FROZEN_FC" ] &&
   [ "$LAST_FC_N" = 1 ] &&
   [ "$LAST_ZY_PRESENT" = 1 ] &&
   [ "$RECORD_OK" = 1 ] &&
   [ ! -e "$VAR/.ziyan_app_user_closed" ]; then
  printf 'SMOKE=OK\nNEXT_ALLOWED=1\n'
else
  printf 'SMOKE=FAIL\nNEXT_ALLOWED=0\n'
fi
REMOTE

  python3 - "$out/TRANSCRIPT.log" "$out/PRECHECK.log" "$out/RUN.log" "$out/AFTER.log" "$out/RUN_RECORD.txt" <<'PY'
from pathlib import Path
import sys

source, pre_path, run_path, after_path, record_path = map(Path, sys.argv[1:])
text = source.read_text(errors="replace")
pre_start = text.find("=== PRECHECK ===")
run_start = text.find("PROFILE_WRITTEN=")
after_start = text.find("=== AFTER ===")
record_start = text.find("RECORD_CONTENT_BEGIN")
record_end = text.find("RECORD_CONTENT_END")
pre_path.write_text(
    text[pre_start:run_start] if pre_start >= 0 and run_start >= 0 else ""
)
run_path.write_text(
    text[run_start:after_start] if run_start >= 0 and after_start >= 0 else ""
)
after_path.write_text(text[after_start:] if after_start >= 0 else "")
record_path.write_text(
    text[record_start + len("RECORD_CONTENT_BEGIN\n"):record_end]
    if record_start >= 0 and record_end >= 0 else ""
)
PY

  grep -q '^NEXT_ALLOWED=1$' "$out/TRANSCRIPT.log"
}

mkdir -p "$OUT"
serial_ok=1
if [ "$CONTINUE" = 1 ]; then
  if grep -q '^RECOVERY_CONFIRMED=1$' "$OUT/101/RECOVERY_READ.log" 2>/dev/null; then
    printf 'CONTINUE_FROM_101=1\n'
  else
    printf 'CONTINUE_FROM_101=0\n'
    serial_ok=0
  fi
else
  run_one 101 192.168.31.101 rootful 87863 87862 47853 96 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  if [ "$CONTINUE" = 1 ] &&
     grep -q '^RECOVERY_CONFIRMED=1$' "$OUT/112/RECOVERY_READ.log" 2>/dev/null; then
    printf 'CONTINUE_FROM_112=1\n'
  else
    run_one 112 192.168.31.112 rootful 79809 79808 98110 92 || serial_ok=0
  fi
fi
if [ "$serial_ok" = 1 ]; then
  run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 || serial_ok=0
fi

printf 'SERIAL_OK=%s\n' "$serial_ok" | tee "$OUT/SERIAL.log"

python3 - "$OUT" <<'PY'
from pathlib import Path
import re
import sys

out = Path(sys.argv[1])
rows = []
all_ok = True
for tag in ("101", "112", "166", "53"):
    host = out / tag
    if not host.exists():
        rows.append((tag, "NOT_RUN", "prior_host_not_stopped_or_dirty"))
        all_ok = False
        continue
    text = (host / "TRANSCRIPT.log").read_text(errors="replace")
    failures = []
    recovery = host / "RECOVERY_READ.log"
    if recovery.exists():
        recovery_text = recovery.read_text(errors="replace")
        if "RECOVERY_CONFIRMED=1" in recovery_text:
            rows.append((tag, "OK", "record_recovered_after_session_cleanup"))
            continue
    for needle, reason in (
        ("PRECHECK_RESULT=PASS", "precheck_failed"),
        ("PRECHECK_SESSION_ID=", "precheck_session_missing"),
        ("PRECHECK_FRONT=com.apple.springboard", "precheck_front_not_springboard"),
        ("APP_CLOSED_MARKER_ABSENT=1", "marker_not_absent"),
        ("OPEN_APP_WRITE_RC=0", "open_write_failed"),
        ("OPEN_FRONT=com.ziyan.ziyan", "open_front_failed"),
        ("OPEN_APP_PRESENT_AFTER_WAIT=0", "open_request_not_consumed"),
        ("PROFILE_WRITTEN=agent_recover_observe", "profile_not_written"),
        ("PROFILE_BUNDLE_WRITTEN=com.ziyan.ziyan", "bundle_not_written"),
        ("REQ_WRITTEN=mode=observe", "req_not_observe"),
        ("RUN_RC=0", "run_rc_not_zero"),
        ("NEW_SESSION_ID=", "new_session_missing"),
        ("SMOKE=OK", "smoke_not_ok"),
        ("AFTER_FRONT=com.ziyan.ziyan", "after_front_not_ziyan"),
        ("AFTER_SESSION_STATE=STOPPED", "session_not_stopped"),
        ("AFTER_AGENT_STOP_MARKER=ABSENT", "stop_marker_present"),
        ("AFTER_APP_CLOSED_MARKER=ABSENT", "marker_present_after"),
        ("AFTER_FC_N=1", "fc_not_single"),
        ("AFTER_SB_FROZEN_MATCH=1", "springboard_changed"),
        ("AFTER_REAL_AGENT_LUA_N=0", "real_agent_lua_still_present"),
        ("RECORD_PATH=/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/", "record_missing"),
        ("RECORD_CONTENT_BEGIN", "record_not_read"),
    ):
        if needle not in text:
            failures.append(reason)
    if not re.search(r"^RECORD_CONTENT_BEGIN\nSTOPPED .* mode=observe", text, re.M):
        failures.append("record_mode_not_observe")
    status = "OK" if not failures else "FAIL"
    all_ok &= status == "OK"
    rows.append((tag, status, ",".join(failures) or "none"))

verdict = [
    "# 七十九号：收回子砚后一次 observe",
    "",
    "本刀只是安全门禁后收回子砚前台，再跑一次 mode=observe；不是六十五号家族重做。",
    "未 sbreload；未改 lua/objc；不是 G0；不是 Agent MVP。",
    "",
]
for tag, status, reason in rows:
    verdict.append(f"- .{tag}: SMOKE={status} REASON={reason}")
verdict.extend([
    "",
    "AGENT_SMOKE_RECOVER_OBSERVE=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL"),
    "NOT_G0=1",
    "NOT_AGENT_MVP=1",
    "NEXT_ACTION=等待人工最终审核",
])
(out / "VERDICT.md").write_text("\n".join(verdict) + "\n")
print((out / "VERDICT.md").read_text(), end="")
PY

python3 tools/ziyan_codex_checkpoint.py write \
  --stage "七十九号：授权四机确认无门禁残留后收回子砚并跑一次 observe，终态 STOPPED" \
  --last-command "bash tools/zy_agent_smoke_recover_observe_79_run.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "四机执行前台收回与一次 mode=observe；必须是新 session STOPPED、运行记录 mode=observe、无真实 agent lua；只是收回子砚后的一次 observe，不是六十五重做，不是 MVP" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/SEVENTYNINE_AGENT_SMOKE_RECOVER_OBSERVE_20260905/VERDICT.md；四机 PRECHECK.log、RUN.log、AFTER.log、TRANSCRIPT.log、RUN_RECORD.txt" \
  --latest-verdict "AGENT_SMOKE_RECOVER_OBSERVE=见 VERDICT.md；未 sbreload" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包；沿用盘上既有版本" \
  --device-state ".101/.112/.166/.53 依 VERDICT；冻结值与 FC_N 依四机 AFTER" \
  --running-processes "依四机 AFTER：无真实 args 同时含 lua5.3 与 ziyan_agent_run.lua 的残留进程" \
  --cleanup-status "依四机 AFTER：门禁文件 ABSENT、.ziyan_agent_stop=ABSENT；本刀停止，等待人工最终审核"
exit "$([ "$serial_ok" = 1 ] && echo 0 || echo 1)"
