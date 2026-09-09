#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/SEVENTYSEVEN_RETRY_HOME_OBSERVE_20260905"
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
REPORT_ROOT=/private/var/mobile/Media/ZiYan/Agent游戏/错误报告

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
PRECHECK_OK=0
if [ "$LAST_SB_PID" = "$FROZEN_SB" ] &&
   [ "$LAST_BB_PID" = "$FROZEN_BB" ] &&
   [ "$LAST_FC_PID" = "$FROZEN_FC" ] &&
   [ "$LAST_FC_N" = 1 ] &&
   [ "$LAST_ZY_PRESENT" = 1 ] &&
   [ "$LAST_AGENT_N" = 0 ]; then
  PRECHECK_OK=1
fi
printf 'PRECHECK_SESSION_ID=%s\nPRECHECK_RESULT=%s\n' \
  "$PRECHECK_SESSION_ID" "$([ "$PRECHECK_OK" = 1 ] && echo PASS || echo FROZEN_OR_AGENT_MISMATCH)"
if [ "$PRECHECK_OK" != 1 ]; then
  pre_blocked FROZEN_OR_AGENT_MISMATCH
fi

if [ -e "$VAR/.ziyan_agent_stop" ]; then
  rm -f "$VAR/.ziyan_agent_stop"
  printf 'STOP_MARKER_CLEARED=%s\n' "$([ -e "$VAR/.ziyan_agent_stop" ] && echo 0 || echo 1)"
fi
if [ -e "$VAR/.ziyan_agent_stop" ]; then
  pre_blocked STOP_MARKER_REMAINS
fi
printf 'STOP_MARKER_ABSENT=1\n'

HOME_REQ="$VAR/.ziyan_go_home"
HOME_REQ_TMP="$HOME_REQ.77.tmp"
HOME_BODY="owner=com.ziyan.ziyan\nts=$(date +%s)\nsource=agent_smoke_77\n"
printf '%b' "$HOME_BODY" > "$HOME_REQ_TMP"
chmod 666 "$HOME_REQ_TMP" 2>/dev/null
mv -f "$HOME_REQ_TMP" "$HOME_REQ"
HOME_WRITE_RC=$?
HOME_PRESENT_AFTER_WRITE=$([ -e "$HOME_REQ" ] && echo 1 || echo 0)
printf 'GO_HOME_BODY_BEGIN\n'; printf '%b' "$HOME_BODY"; printf 'GO_HOME_BODY_END\n'
printf 'GO_HOME_WRITE_RC=%s\nGO_HOME_PRESENT_AFTER_WRITE=%s\n' \
  "$HOME_WRITE_RC" "$HOME_PRESENT_AFTER_WRITE"
HOME_FRONT=
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  HOME_FRONT="$(front_bid)"
  if [ "$HOME_FRONT" = com.apple.springboard ]; then
    break
  fi
  sleep 1
done
HOME_PRESENT_AFTER_WAIT=$([ -e "$HOME_REQ" ] && echo 1 || echo 0)
printf 'HOME_FRONT=%s\nGO_HOME_PRESENT_AFTER_WAIT=%s\n' \
  "$HOME_FRONT" "$HOME_PRESENT_AFTER_WAIT"
if [ "$HOME_WRITE_RC" != 0 ] || [ "$HOME_FRONT" != com.apple.springboard ] ||
   [ "$HOME_PRESENT_AFTER_WAIT" != 0 ]; then
  pre_blocked HOME_FAIL
fi

printf 'profile_id=agent_home_observe\nbundle_id=com.ziyan.ziyan\ndisplay_name=回桌面观察\ngame_name=子砚\n' \
  > "$VAR/.ziyan_agent_current_profile"
printf 'mode=observe\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_current_profile" "$VAR/.ziyan_agent_req" 2>/dev/null
printf 'PROFILE_WRITTEN=agent_home_observe\nPROFILE_BUNDLE_WRITTEN=com.ziyan.ziyan\nREQ_WRITTEN=mode=observe\n'

RUN_LOG="$VAR/.ziyan_agent_home_observe_77_run.log"
RUN_RC_FILE="$VAR/.ziyan_agent_home_observe_77_rc"
: > "$RUN_LOG"
: > "$RUN_RC_FILE"
(
  "$LUA" "$RUN" "$AGENT"
  printf '%s\n' "$?" > "$RUN_RC_FILE"
) > "$RUN_LOG" 2>&1 &
printf 'LAUNCH_PID=%s\n' "$!"

READY=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  RUN_RC="$(cat "$RUN_RC_FILE" 2>/dev/null)"
  CURRENT_ID="$(session_value session_id)"
  CURRENT_STATE="$(session_value state)"
  CURRENT_AGENT_N=0
  while IFS= read -r line; do
    is_real_agent_line "$line" && CURRENT_AGENT_N=$((CURRENT_AGENT_N + 1))
  done <<EOF
$(ps -A -o pid=,args= 2>/dev/null)
EOF
  if [ "$RUN_RC" = 0 ] &&
     [ "$CURRENT_STATE" = PAUSED_SAFE ] &&
     [ -n "$CURRENT_ID" ] &&
     [ "$CURRENT_ID" != "$PRECHECK_SESSION_ID" ] &&
     [ "$CURRENT_AGENT_N" = 0 ]; then
    READY=1
    printf 'READY_POLL=%ss\n' "$i"
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
REPORT="$(report_for_session "$NEW_SESSION_ID")"
printf 'NEW_SESSION_ID=%s\nREPORT_PATH=%s\n' "$NEW_SESSION_ID" "${REPORT:-ABSENT}"
REPORT_OK=0
if [ -n "$REPORT" ]; then
  sed -n -e '/^error_code=/p' -e '/^stop_reason=/p' -e '/^paused=/p' "$REPORT"
  if grep -q '^error_code=PAUSED_SAFE$' "$REPORT" &&
     grep -q '^stop_reason=bundle_mismatch$' "$REPORT" &&
     grep -q '^paused=bundle_mismatch$' "$REPORT"; then
    REPORT_OK=1
  fi
fi

SESSION_CHANGED=0
[ -n "$NEW_SESSION_ID" ] && [ "$NEW_SESSION_ID" != "$PRECHECK_SESSION_ID" ] && SESSION_CHANGED=1
if [ "$READY" = 1 ] &&
   [ "$RUN_RC" = 0 ] &&
   [ "$SESSION_CHANGED" = 1 ] &&
   [ "$(session_value state)" = PAUSED_SAFE ] &&
   [ "$(front_bid)" = com.apple.springboard ] &&
   [ "$LAST_AGENT_N" = 0 ] &&
   [ "$LAST_SB_PID" = "$FROZEN_SB" ] &&
   [ "$LAST_BB_PID" = "$FROZEN_BB" ] &&
   [ "$LAST_FC_PID" = "$FROZEN_FC" ] &&
   [ "$LAST_FC_N" = 1 ] &&
   [ "$LAST_ZY_PRESENT" = 1 ] &&
   [ "$REPORT_OK" = 1 ]; then
  printf 'SMOKE=OK\nNEXT_ALLOWED=1\n'
else
  printf 'SMOKE=FAIL\nNEXT_ALLOWED=0\n'
fi
REMOTE

  grep -q '^NEXT_ALLOWED=1$' "$out/TRANSCRIPT.log"
}

mkdir -p "$OUT"
serial_ok=1
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 || serial_ok=0
if [ "$serial_ok" = 1 ]; then
  run_one 112 192.168.31.112 rootful 79809 79808 98110 92 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 || serial_ok=0
fi

printf 'SERIAL_OK=%s\n' "$serial_ok" | tee "$OUT/SERIAL.log"
exit "$([ "$serial_ok" = 1 ] && echo 0 || echo 1)"
