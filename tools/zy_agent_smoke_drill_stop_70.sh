#!/usr/bin/env bash
# 七十号：四机串行 drill -> 确认真实 agent lua/DRILLING -> 2 秒后 stop。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/SEVENTY_AGENT_SMOKE_DRILL_STOP_20260905"
PASS="${ZY_SSH_PASS:-alpine}"

if [ -e "$OUT" ]; then
  printf 'evidence directory already exists: %s\n' "$OUT" >&2
  exit 2
fi
mkdir -p "$OUT"

SSH_KEY_OPTS=(
  -o BatchMode=yes
  -o PasswordAuthentication=no
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)
SSH_PASS_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)

ssh_r() {
  local ip="$1"
  shift
  if ssh "${SSH_KEY_OPTS[@]}" "root@$ip" true </dev/null >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
  fi
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5"
  local frozen_fc="$6" frozen_zy="$7" out="$OUT/$tag"
  mkdir -p "$out"

  printf 'SERIAL_START=.%s\n' "$tag" | tee "$out/HOST.log"
  ssh_r "$ip" \
    "TAG='$tag' SCHEME='$scheme' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' FROZEN_ZY='$frozen_zy' bash -s" \
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
RECORDS="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"

log() {
  printf '%s\n' "$1"
}

real_agent_lines() {
  ps -A -o pid=,args= 2>/dev/null |
    grep '[l]ua5.3' |
    grep 'ziyan_agent_run.lua' |
    grep -v 'sh -c' |
    grep -v 'bash -s'
}

session_state() {
  sed -n 's/^state=\([^[:space:]]*\).*/\1/p' "$VAR/.ziyan_agent_session" 2>/dev/null |
    sed -n '1p'
}

pid_line() {
  local pid="$1"
  printf '%s\n' "$PS_ALL" |
    sed -n "/^[[:space:]]*$pid[[:space:]]/p" |
    sed -n '1p'
}

record_snapshot() {
  local phase="$1" latest
  latest=$(ls -t "$RECORDS"/ags_*.txt 2>/dev/null |
    grep -v '_drill\.txt$' |
    sed -n '1p')
  log "${phase}_LATEST_RECORD_PATH=${latest:-ABSENT}"
  if [ -n "$latest" ] && [ -f "$latest" ]; then
    log "${phase}_LATEST_RECORD_BEGIN"
    cat "$latest"
    log "${phase}_LATEST_RECORD_END"
    if grep -q 'mode=drill[[:space:]]*$' "$latest"; then
      log "${phase}_LATEST_RECORD_MODE_DRILL=1"
    else
      log "${phase}_LATEST_RECORD_MODE_DRILL=0"
    fi
    if grep -q 'drill_timeout' "$latest"; then
      log "${phase}_LATEST_RECORD_TIMEOUT=1"
    else
      log "${phase}_LATEST_RECORD_TIMEOUT=0"
    fi
  else
    log "${phase}_LATEST_RECORD_MODE_DRILL=0"
    log "${phase}_LATEST_RECORD_TIMEOUT=0"
  fi
}

snapshot() {
  local phase="$1" line
  PS_ALL=$(ps -A -o pid=,args= 2>/dev/null)
  SB_LINE=$(printf '%s\n' "$PS_ALL" |
    sed -n '/SpringBoard\.app\/SpringBoard/{p;q;}')
  BB_LINE=$(printf '%s\n' "$PS_ALL" |
    sed -n '/backboardd/{p;q;}')
  FC_N=0
  FC_LINE=
  while IFS= read -r line; do
    case "$line" in
      *'ziyan_framecap serve'*)
        FC_N=$((FC_N + 1))
        if [ -z "$FC_LINE" ]; then
          FC_LINE="$line"
        fi
        ;;
    esac
  done <<EOF
$PS_ALL
EOF
  SB_PID=$(printf '%s\n' "$SB_LINE" |
    sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  BB_PID=$(printf '%s\n' "$BB_LINE" |
    sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  FC_FROZEN_LINE=$(pid_line "$FROZEN_FC")
  ZY_FROZEN_LINE=$(pid_line "$FROZEN_ZY")
  AGENT_LINES=$(real_agent_lines)

  log "=== ${phase} ==="
  log "${phase}_DATE=$(date '+%Y-%m-%d %H:%M:%S %z')"
  log "${phase}_VAR=$VAR"
  log "${phase}_SB_LINE=${SB_LINE:-ABSENT}"
  log "${phase}_BB_LINE=${BB_LINE:-ABSENT}"
  log "${phase}_FC_LINE=${FC_LINE:-ABSENT}"
  log "${phase}_FC_N=$FC_N"
  log "${phase}_SB_PID=${SB_PID:-ABSENT}"
  log "${phase}_BB_PID=${BB_PID:-ABSENT}"
  log "${phase}_SB_FROZEN=$FROZEN_SB"
  log "${phase}_BB_FROZEN=$FROZEN_BB"
  log "${phase}_FC_FROZEN=$FROZEN_FC"
  log "${phase}_ZY_FROZEN=$FROZEN_ZY"
  log "${phase}_SB_FROZEN_MATCH=$([ "$SB_PID" = "$FROZEN_SB" ] && echo 1 || echo 0)"
  log "${phase}_BB_FROZEN_MATCH=$([ "$BB_PID" = "$FROZEN_BB" ] && echo 1 || echo 0)"
  case "$FC_FROZEN_LINE" in
    *'ziyan_framecap serve'*) log "${phase}_FC_FROZEN_MATCH=1" ;;
    *) log "${phase}_FC_FROZEN_MATCH=0" ;;
  esac
  if [ -n "$ZY_FROZEN_LINE" ]; then
    log "${phase}_ZY_FROZEN_PRESENT=1"
  else
    log "${phase}_ZY_FROZEN_PRESENT=0"
  fi
  log "${phase}_HOOKS_BEGIN"
  cat "$VAR/.ziyan_hooks" 2>/dev/null
  log "${phase}_HOOKS_END"
  log "${phase}_FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
  log "${phase}_SESSION_BEGIN"
  cat "$VAR/.ziyan_agent_session" 2>/dev/null
  log "${phase}_SESSION_END"
  log "${phase}_SESSION_STATE=$(session_state)"
  if [ -e "$VAR/.ziyan_agent_stop" ]; then
    log "${phase}_STOP_MARKER=PRESENT"
    log "${phase}_STOP_CONTENT_BEGIN"
    cat "$VAR/.ziyan_agent_stop" 2>/dev/null
    log "${phase}_STOP_CONTENT_END"
  else
    log "${phase}_STOP_MARKER=ABSENT"
  fi
  if [ -n "$AGENT_LINES" ]; then
    log "${phase}_AGENT_LUA=PRESENT"
    log "${phase}_AGENT_LUA_ARGS_BEGIN"
    printf '%s\n' "$AGENT_LINES"
    log "${phase}_AGENT_LUA_ARGS_END"
  else
    log "${phase}_AGENT_LUA=ABSENT"
  fi
  if [ "$phase" = AFTER ]; then
    record_snapshot "$phase"
  fi
}

is_quiescent_after() {
  current_agent=$(real_agent_lines)
  current_state=$(session_state)
  if [ -z "$current_agent" ] &&
     [ "$current_state" = STOPPED ] &&
     [ ! -e "$VAR/.ziyan_agent_stop" ]; then
    return 0
  fi
  return 1
}

snapshot PRECHECK
PRECHECK_RESULT=PASS
if [ "$SB_PID" != "$FROZEN_SB" ] ||
   [ "$BB_PID" != "$FROZEN_BB" ] ||
   [ "$FC_N" != 1 ] ||
   [ -z "$FC_FROZEN_LINE" ] ||
   [ -z "$ZY_FROZEN_LINE" ]; then
  PRECHECK_RESULT=FROZEN_MISMATCH
fi
if [ -n "$AGENT_LINES" ]; then
  PRECHECK_RESULT=PREEXISTING_AGENT_LUA
fi
log "PRECHECK_RESULT=$PRECHECK_RESULT"

if [ -e "$VAR/.ziyan_agent_stop" ]; then
  rm -f "$VAR/.ziyan_agent_stop"
  log "LEFTOVER_STOP_CLEARED=1"
else
  log "LEFTOVER_STOP_CLEARED=0"
fi
if [ -e "$VAR/.ziyan_agent_stop" ]; then
  log "STOP_AFTER_CLEAR=PRESENT"
else
  log "STOP_AFTER_CLEAR=ABSENT"
fi

if [ "$PRECHECK_RESULT" != PASS ]; then
  log "SMOKE=PRE_BLOCKED"
  snapshot AFTER
  if is_quiescent_after; then
    log "NEXT_ALLOWED=1"
  else
    log "NEXT_ALLOWED=0"
  fi
  exit 0
fi

FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
if [ "$FRONT" = com.ziyan.ziyan ]; then
  log "OPEN_APP=SKIPPED_ALREADY_FRONT"
else
  printf 'com.ziyan.ziyan\n' > "$VAR/.ziyan_open_app"
  chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
  log "OPEN_APP=WRITTEN_FRONT_WAS=$FRONT"
  for i in 1 2 3 4 5; do
    sleep 1
    FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
    log "OPEN_APP_WAIT=${i}s FRONT=$FRONT"
    [ "$FRONT" = com.ziyan.ziyan ] && break
  done
fi

if [ "$FRONT" != com.ziyan.ziyan ]; then
  log "SMOKE=OPEN_FAIL"
  snapshot AFTER
  if is_quiescent_after; then
    log "NEXT_ALLOWED=1"
  else
    log "NEXT_ALLOWED=0"
  fi
  exit 0
fi

printf 'profile_id=agent_drill\ndisplay_name=演练空转\ngame_name=子砚\nbundle_id=com.ziyan.ziyan\n' \
  > "$VAR/.ziyan_agent_current_profile"
printf 'mode=drill\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_current_profile" "$VAR/.ziyan_agent_req" 2>/dev/null
log "PROFILE_WRITTEN=agent_drill"
log "REQ_WRITTEN=mode=drill"

RUN_LOG="$VAR/.ziyan_agent_drill_70_run.log"
RUN_RC="$VAR/.ziyan_agent_drill_70_rc"
rm -f "$RUN_LOG" "$RUN_RC"
(
  "$LUA" "$RUN" "$AGENT"
  printf '%s\n' "$?" > "$RUN_RC"
) > "$RUN_LOG" 2>&1 &
LAUNCH_PID=$!
log "LAUNCH_PID=$LAUNCH_PID"

CONFIRMATION=
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  POLL_AGENT=$(real_agent_lines)
  POLL_STATE=$(session_state)
  log "DRILL_POLL=${i}/16 SESSION_STATE=${POLL_STATE:-ABSENT}"
  if [ -n "$POLL_AGENT" ]; then
    log "DRILL_POLL_AGENT_LUA_ARGS_BEGIN"
    printf '%s\n' "$POLL_AGENT"
    log "DRILL_POLL_AGENT_LUA_ARGS_END"
    CONFIRMATION=ARGS
    break
  fi
  if [ "$POLL_STATE" = DRILLING ]; then
    CONFIRMATION=DRILLING
    break
  fi
  sleep 0.5
done

if [ -z "$CONFIRMATION" ]; then
  log "CONFIRMATION=NONE"
  log "STOP_WRITE=SKIPPED_NO_CONFIRMATION"
  log "SMOKE=NO_DRILL"
  snapshot AFTER
  if is_quiescent_after; then
    log "NEXT_ALLOWED=1"
  else
    log "NEXT_ALLOWED=0"
  fi
  exit 0
fi

log "CONFIRMATION=$CONFIRMATION"
sleep 2
printf 'stop=1\n' > "$VAR/.ziyan_agent_stop"
chmod 666 "$VAR/.ziyan_agent_stop" 2>/dev/null
log "STOP_WRITE=AFTER_CONFIRM_PLUS_2S"

STOPPED=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  STOP_AGENT=$(real_agent_lines)
  STOP_STATE=$(session_state)
  log "STOP_POLL=${i}/10 SESSION_STATE=${STOP_STATE:-ABSENT} AGENT_LUA=$([ -n "$STOP_AGENT" ] && echo PRESENT || echo ABSENT)"
  if [ -z "$STOP_AGENT" ] && [ "$STOP_STATE" = STOPPED ]; then
    STOPPED=1
    break
  fi
  sleep 1
done

if [ "$STOPPED" = 1 ]; then
  log "SMOKE=OK"
else
  log "SMOKE=STOP_DIRTY"
  printf 'stop=1\n' > "$VAR/.ziyan_agent_stop"
  chmod 666 "$VAR/.ziyan_agent_stop" 2>/dev/null
  log "STOP_WRITE_RETRY=1"
fi

if [ -f "$RUN_RC" ]; then
  log "RUN_RC=$(cat "$RUN_RC" 2>/dev/null)"
else
  log "RUN_RC=BACKGROUND_NOT_REAPED"
fi
log "RUN_LOG_BEGIN"
tail -n 80 "$RUN_LOG" 2>/dev/null
log "RUN_LOG_END"
snapshot AFTER
if is_quiescent_after; then
  log "NEXT_ALLOWED=1"
else
  log "NEXT_ALLOWED=0"
fi
REMOTE
  local ssh_rc=$?
  printf 'SSH_RC=%s\n' "$ssh_rc" | tee -a "$out/HOST.log"

  sed -n '/^=== PRECHECK ===$/,/^PROFILE_WRITTEN=/p' "$out/TRANSCRIPT.log" >"$out/PRECHECK.log"
  sed -n '/^PROFILE_WRITTEN=/,/^RUN_LOG_END$/p' "$out/TRANSCRIPT.log" >"$out/RUN.log"
  sed -n '/^=== AFTER ===$/,$p' "$out/TRANSCRIPT.log" >"$out/AFTER.log"
  sed -n '/^AFTER_LATEST_RECORD_BEGIN$/,/^AFTER_LATEST_RECORD_END$/p' \
    "$out/TRANSCRIPT.log" >"$out/RUN_RECORD.txt"

  if grep -q '^NEXT_ALLOWED=1$' "$out/TRANSCRIPT.log"; then
    return 0
  fi
  return 1
}

halted_at=
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 || halted_at=101
if [ -z "$halted_at" ]; then
  run_one 112 192.168.31.112 rootful 79809 79808 98110 92 || halted_at=112
fi
if [ -z "$halted_at" ]; then
  run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 || halted_at=166
fi
if [ -z "$halted_at" ]; then
  run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 || halted_at=53
fi

python3 - "$OUT" "${halted_at:-}" <<'PY'
from pathlib import Path
import re
import sys

out = Path(sys.argv[1])
halted_at = sys.argv[2]
rows = []
all_ok = not halted_at
for tag in ("101", "112", "166", "53"):
    transcript = out / tag / "TRANSCRIPT.log"
    if not transcript.exists():
        rows.append((tag, "NOT_RUN", "serial_halted_before_device"))
        all_ok = False
        continue
    text = transcript.read_text(errors="replace")
    smoke = re.findall(r"^SMOKE=([A-Z_]+)$", text, re.M)
    status = smoke[-1] if smoke else "NO_STATUS"
    failures = []
    required = {
        "PRECHECK_RESULT=PASS": "precheck_failed",
        "STOP_AFTER_CLEAR=ABSENT": "leftover_stop_present",
        "CONFIRMATION=": "no_confirmation",
        "STOP_WRITE=AFTER_CONFIRM_PLUS_2S": "stop_not_after_confirmation",
        "AFTER_SESSION_STATE=STOPPED": "session_not_stopped",
        "AFTER_AGENT_LUA=ABSENT": "agent_lua_still_present",
        "AFTER_FC_N=1": "fc_not_single",
        "AFTER_SB_FROZEN_MATCH=1": "springboard_changed",
        "AFTER_BB_FROZEN_MATCH=1": "backboard_changed",
        "AFTER_FC_FROZEN_MATCH=1": "framecap_changed",
        "AFTER_ZY_FROZEN_PRESENT=1": "zydaemon_missing",
        "AFTER_STOP_MARKER=ABSENT": "stop_not_cleared",
        "AFTER_LATEST_RECORD_MODE_DRILL=1": "latest_record_not_drill",
        "AFTER_LATEST_RECORD_TIMEOUT=0": "latest_record_timeout",
    }
    for marker, reason in required.items():
        if marker not in text:
            failures.append(reason)
    if "CONFIRMATION=ARGS" not in text and "CONFIRMATION=DRILLING" not in text:
        failures.append("confirmation_invalid")
    if status != "OK":
        failures.append(f"smoke_{status.lower()}")
    result = "OK" if not failures else "FAIL"
    rows.append((tag, result, ",".join(dict.fromkeys(failures)) or "none"))
    all_ok &= result == "OK"

verdict = [
    "# 七十号 Agent drill stop 补跑",
    "",
    "补跑 drill；确认真实 agent lua args 或 DRILLING 后才写 stop；最新运行记录要求 mode=drill 且不是 drill_timeout；不是真演练；未 sbreload。",
    "",
]
for tag, result, reason in rows:
    verdict.append(f"- .{tag}: SMOKE={result} REASON={reason}")
if halted_at:
    verdict.append(f"- SERIAL_HALTED_AT=.{halted_at}")
verdict.extend([
    "",
    "AGENT_SMOKE_DRILL=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL"),
    "NOT_REAL_EXERCISE=1",
    "NOT_G0=1",
    "NOT_AGENT_MVP=1",
    "NO_SBRELOAD=1",
])
(out / "VERDICT.md").write_text("\n".join(verdict) + "\n")
print((out / "VERDICT.md").read_text(), end="")
PY
