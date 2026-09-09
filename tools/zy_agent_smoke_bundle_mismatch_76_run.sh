#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/SEVENTYSIX_RETRY_BUNDLE_MISMATCH_20260905"
PASS="${ZY_SSH_PASS:-alpine}"

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
REPORT_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/错误报告"

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

real_agent_lines() {
  local line
  while IFS= read -r line; do
    if is_real_agent_line "$line"; then
      printf '%s\n' "$line"
    fi
  done <<EOF
$(ps -A -o pid=,args= 2>/dev/null)
EOF
}

session_state() {
  sed -n 's/^state=\([^[:space:]]*\).*/\1/p' "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p'
}

session_id() {
  sed -n 's/^session_id=//p' "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p'
}

report_for_session() {
  local id="$1"
  if [ "$SCHEME" = rootless ]; then
    if [ -f "$REPORT_ROOT/$id.txt" ]; then
      printf '%s\n' "$REPORT_ROOT/$id.txt"
      return 0
    fi
  else
    if [ -f "$REPORT_ROOT/$id/report.txt" ]; then
      printf '%s\n' "$REPORT_ROOT/$id/report.txt"
      return 0
    fi
  fi
  return 1
}

snapshot() {
  local phase="$1"
  local line ps_all fc_n=0 agent_n=0 sb_pid="" bb_pid="" zy_present=0
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
        printf '%s_FC_PROC=%s\n' "$phase" "$line"
        fc_n=$((fc_n + 1))
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
  printf '%s_FC_N=%s\n' "$phase" "$fc_n"
  printf '%s_REAL_AGENT_LUA_N=%s\n' "$phase" "$agent_n"
  printf '%s_SB_PID=%s\n' "$phase" "$sb_pid"
  printf '%s_BB_PID=%s\n' "$phase" "$bb_pid"
  printf '%s_SB_FROZEN_MATCH=%s\n' "$phase" "$([ "$sb_pid" = "$FROZEN_SB" ] && echo 1 || echo 0)"
  printf '%s_BB_FROZEN_MATCH=%s\n' "$phase" "$([ "$bb_pid" = "$FROZEN_BB" ] && echo 1 || echo 0)"
  printf '%s_ZY_FROZEN_PRESENT=%s\n' "$phase" "$zy_present"
  printf '%s_HOOKS_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_hooks" 2>/dev/null
  printf '%s_HOOKS_END\n' "$phase"
  printf '%s_FRONT=%s\n' "$phase" "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
  printf '%s_SESSION_STATE=%s\n' "$phase" "$(session_state)"
  printf '%s_SESSION_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_agent_session" 2>/dev/null
  printf '%s_SESSION_END\n' "$phase"
  printf '%s_PROFILE_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_agent_current_profile" 2>/dev/null
  printf '%s_PROFILE_END\n' "$phase"
  printf '%s_REQ_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_agent_req" 2>/dev/null
  printf '%s_REQ_END\n' "$phase"
  if [ -e "$VAR/.ziyan_agent_stop" ]; then
    printf '%s_AGENT_STOP_MARKER=PRESENT\n' "$phase"
  else
    printf '%s_AGENT_STOP_MARKER=ABSENT\n' "$phase"
  fi
  LAST_FC_N="$fc_n"
  LAST_REAL_AGENT_LUA_N="$agent_n"
  LAST_SB_PID="$sb_pid"
  LAST_BB_PID="$bb_pid"
  LAST_ZY_FROZEN_PRESENT="$zy_present"
}

snapshot PRECHECK
PRECHECK_SB_PID="$LAST_SB_PID"
PRECHECK_BB_PID="$LAST_BB_PID"
PRECHECK_FC_N="$LAST_FC_N"
PRECHECK_ZY_FROZEN_PRESENT="$LAST_ZY_FROZEN_PRESENT"
PRECHECK_REAL_AGENT_LUA_N="$LAST_REAL_AGENT_LUA_N"
if [ "$PRECHECK_SB_PID" = "$FROZEN_SB" ] &&
   [ "$PRECHECK_BB_PID" = "$FROZEN_BB" ] &&
   [ "$PRECHECK_FC_N" = 1 ] &&
   [ "$PRECHECK_ZY_FROZEN_PRESENT" = 1 ] &&
   [ "$PRECHECK_REAL_AGENT_LUA_N" = 0 ]; then
  PRECHECK_RESULT=PASS
else
  PRECHECK_RESULT=FROZEN_OR_AGENT_MISMATCH
fi
  printf 'PRECHECK_SB_PID=%s\nPRECHECK_BB_PID=%s\nPRECHECK_FC_N=%s\nPRECHECK_ZY_FROZEN_PRESENT=%s\nPRECHECK_REAL_AGENT_LUA_N=%s\nPRECHECK_RESULT=%s\n' \
  "$PRECHECK_SB_PID" "$PRECHECK_BB_PID" "$PRECHECK_FC_N" "$PRECHECK_ZY_FROZEN_PRESENT" "$PRECHECK_REAL_AGENT_LUA_N" "$PRECHECK_RESULT"
PRECHECK_SESSION_ID=$(session_id)
printf 'PRECHECK_SESSION_ID=%s\n' "$PRECHECK_SESSION_ID"

FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
if [ "$PRECHECK_RESULT" != PASS ] || [ "$FRONT" != com.ziyan.ziyan ]; then
  printf 'SMOKE=PRE_BLOCKED\nREASON=%s\n' "$([ "$FRONT" = com.ziyan.ziyan ] && echo FROZEN_OR_REAL_AGENT_MISMATCH || echo FRONT_NOT_ZIYAN)"
  snapshot AFTER
  exit 0
fi

if [ -e "$VAR/.ziyan_agent_stop" ]; then
  printf 'STOP_MARKER_PRESENT=1\nSMOKE=PRE_BLOCKED\nREASON=STOP_MARKER_REMAINS\n'
  snapshot AFTER
  exit 0
else
  printf 'STOP_MARKER_PRESENT=0\n'
fi
if [ -e "$VAR/.ziyan_agent_stop" ]; then
  printf 'STOP_AFTER_CLEAR=PRESENT\nSMOKE=PRE_BLOCKED\nREASON=STOP_MARKER_REMAINS\n'
  snapshot AFTER
  exit 0
else
  printf 'STOP_MARKER_ABSENT=1\n'
fi

printf 'profile_id=agent_mismatch\nbundle_id=com.apple.Preferences\ndisplay_name=错包名\ngame_name=子砚\n' > "$VAR/.ziyan_agent_current_profile"
printf 'mode=observe\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_current_profile" "$VAR/.ziyan_agent_req" 2>/dev/null
printf 'PROFILE_WRITTEN=agent_mismatch\nPROFILE_BUNDLE_WRITTEN=com.apple.Preferences\nPROFILE_DISPLAY_WRITTEN=错包名\nPROFILE_GAME_WRITTEN=子砚\nREQ_WRITTEN=mode=observe\n'

RUN_LOG="$VAR/.ziyan_agent_bundle_mismatch_76_run.log"
RUN_RC="$VAR/.ziyan_agent_bundle_mismatch_76_rc"
: > "$RUN_LOG"
: > "$RUN_RC"
(
  "$LUA" "$RUN" "$AGENT"
  printf '%s\n' "$?" > "$RUN_RC"
) > "$RUN_LOG" 2>&1 &
printf 'LAUNCH_PID=%s\n' "$!"

PAUSED=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  CURRENT_RUN_RC=$(cat "$RUN_RC" 2>/dev/null)
  CURRENT_SESSION_ID=$(session_id)
  CURRENT_AGENT_N=$(real_agent_lines | wc -l | tr -d '[:space:]')
  if [ "$CURRENT_RUN_RC" = 0 ] &&
     [ "$(session_state)" = PAUSED_SAFE ] &&
     [ -n "$CURRENT_SESSION_ID" ] &&
     [ "$CURRENT_SESSION_ID" != "$PRECHECK_SESSION_ID" ] &&
     [ "$CURRENT_AGENT_N" = 0 ]; then
    PAUSED=1
    printf 'PAUSED_SAFE_POLL=%ss\n' "$i"
    break
  fi
  sleep 1
done
printf 'RUN_RC=%s\n' "$(cat "$RUN_RC" 2>/dev/null || printf ABSENT)"
printf 'RUN_LOG_BEGIN\n'
cat "$RUN_LOG" 2>/dev/null
printf 'RUN_LOG_END\n'

snapshot AFTER
SESSION_ID=$(session_id)
RUN_RC_VALUE=$(cat "$RUN_RC" 2>/dev/null)
REPORT=""
if [ "$PAUSED" = 1 ] &&
   [ "$RUN_RC_VALUE" = 0 ] &&
   [ "$SESSION_ID" != "$PRECHECK_SESSION_ID" ] &&
   [ "$LAST_REAL_AGENT_LUA_N" = 0 ]; then
  REPORT=$(report_for_session "$SESSION_ID") || REPORT=""
fi
printf 'NEW_SESSION_ID=%s\nREPORT_PATH=%s\n' "$SESSION_ID" "${REPORT:-ABSENT}"
if [ -n "$REPORT" ]; then
  printf 'REPORT_CONTENT_BEGIN\n'
  cat "$REPORT" 2>/dev/null
  printf 'REPORT_CONTENT_END\n'
fi

AFTER_STATE=$(session_state)
AFTER_FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
AFTER_AGENT_N="$LAST_REAL_AGENT_LUA_N"
AFTER_SB="$LAST_SB_PID"
AFTER_FC_N="$LAST_FC_N"
SESSION_CHANGED=0
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "$PRECHECK_SESSION_ID" ]; then
  SESSION_CHANGED=1
fi
REASON_OK=0
if [ -n "$REPORT" ] &&
   grep -q '^error_code=PAUSED_SAFE$' "$REPORT" &&
   grep -q '^stop_reason=bundle_mismatch$' "$REPORT" &&
   grep -q '^paused=bundle_mismatch$' "$REPORT"; then
  REASON_OK=1
fi
if [ "$PAUSED" = 1 ] &&
   [ "$(cat "$RUN_RC" 2>/dev/null)" = 0 ] &&
   [ "$SESSION_CHANGED" = 1 ] &&
   [ "$AFTER_STATE" = PAUSED_SAFE ] &&
   [ "$AFTER_FRONT" = com.ziyan.ziyan ] &&
   [ "$AFTER_AGENT_N" = 0 ] &&
   [ "$AFTER_SB" = "$FROZEN_SB" ] &&
   [ "$AFTER_FC_N" = 1 ] &&
   [ "$REASON_OK" = 1 ]; then
  printf 'SMOKE=OK\nNEXT_ALLOWED=1\n'
else
  printf 'SMOKE=FAIL\nNEXT_ALLOWED=0\n'
fi
REMOTE

  python3 - "$out/TRANSCRIPT.log" "$out/PRECHECK.log" "$out/RUN.log" "$out/AFTER.log" "$out/REPORT.txt" <<'PY'
from pathlib import Path
import sys

source, pre, run, after, report = map(Path, sys.argv[1:])
text = source.read_text(errors="replace")
pre_start = text.find("=== PRECHECK ===")
profile_start = text.find("PROFILE_WRITTEN=")
after_start = text.find("=== AFTER ===")
pre.write_text(text[pre_start:profile_start] if pre_start >= 0 and profile_start >= 0 else "")
run.write_text(text[profile_start:after_start] if profile_start >= 0 and after_start >= 0 else "")
after.write_text(text[after_start:] if after_start >= 0 else "")
report_start = text.find("REPORT_CONTENT_BEGIN")
report_end = text.find("REPORT_CONTENT_END")
report.write_text(
    text[report_start + len("REPORT_CONTENT_BEGIN\n"):report_end]
    if report_start >= 0 and report_end >= 0 else ""
)
PY

  grep -q '^NEXT_ALLOWED=1$' "$out/TRANSCRIPT.log"
}

serial_ok=1
run_one 112 192.168.31.112 rootful 79809 79808 98110 92 || serial_ok=0
if [ "$serial_ok" = 1 ]; then
  run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 || serial_ok=0
fi

printf 'SERIAL_OK=%s\n' "$serial_ok"
