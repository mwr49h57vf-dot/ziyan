#!/usr/bin/env bash
# 七十五补：仅 .53 再跑一次空 profile，取本次错误报告。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/SEVENTYFIVE_53_RETRY_NO_PROFILE_20260905"
PASS="${ZY_SSH_PASS:-alpine}"
IP=192.168.31.53

if [ -e "$OUT" ]; then
  printf 'evidence directory already exists: %s\n' "$OUT" >&2
  exit 2
fi
mkdir -p "$OUT"

SSH_OPTS=(
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
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)

ssh_r() {
  local target="$1"
  shift
  if ssh "${SSH_OPTS[@]}" "$target" true >/dev/null 2>&1; then
    ssh "${SSH_OPTS[@]}" "$target" "$@"
    return
  fi
  sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "$target" true >/dev/null 2>&1 || return
  sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "$target" "$@"
}

readonly_one() {
  local tag="$1" ip="$2" sb="$3" bb="$4" fc="$5" zy="$6"
  ssh_r "root@$ip" \
    "FROZEN_SB='$sb' FROZEN_BB='$bb' FROZEN_FC='$fc' FROZEN_ZY='$zy' bash -s" \
    >"$OUT/${tag}_READONLY.log" 2>&1 <<'REMOTE'
set +e
ps_all=$(ps -A -o pid=,args= 2>/dev/null)
sb_pid=
bb_pid=
fc_n=0
zy_present=0
while IFS= read -r line; do
  case "$line" in
    *SpringBoard.app/SpringBoard*)
      printf 'SPRINGBOARD_LINE=%s\n' "$line"
      [ -n "$sb_pid" ] || { sb_pid="${line#"${line%%[![:space:]]*}"}"; sb_pid="${sb_pid%% *}"; }
      ;;
    *backboardd*)
      [ -n "$bb_pid" ] || { bb_pid="${line#"${line%%[![:space:]]*}"}"; bb_pid="${bb_pid%% *}"; }
      ;;
    *'ziyan_framecap serve'*) fc_n=$((fc_n + 1)) ;;
    *ziyadaemond*|*ziyan_zydaemond*)
      case "$line" in "$FROZEN_ZY"*|*" $FROZEN_ZY "*) zy_present=1 ;; esac
      ;;
  esac
done <<EOF
$ps_all
EOF
VAR=/usr/lib/ziyan/var
printf 'SB_PID=%s\nBB_PID=%s\nFC_N=%s\nZY_FROZEN_PRESENT=%s\n' "$sb_pid" "$bb_pid" "$fc_n" "$zy_present"
printf 'FRONT=%s\n' "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
printf 'SESSION_BEGIN\n'
cat "$VAR/.ziyan_agent_session" 2>/dev/null
printf 'SESSION_END\n'
printf 'FROZEN_MATCH=%s\n' "$([ "$sb_pid" = "$FROZEN_SB" ] && [ "$bb_pid" = "$FROZEN_BB" ] && [ "$fc_n" = 1 ] && [ "$zy_present" = 1 ] && echo 1 || echo 0)"
REMOTE
}

# The three prior devices are read-only confirmation only; no agent dispatch.
readonly_one 101 192.168.31.101 87863 87862 47853 96
readonly_one 112 192.168.31.112 79809 79808 98110 92
readonly_one 166 192.168.31.166 25025 25024 52622 82626

ssh_r "root@$IP" \
  "FROZEN_SB=46408 FROZEN_BB=74318 FROZEN_FC=49176 FROZEN_ZY=93705 bash -s" \
  >"$OUT/TRANSCRIPT.log" 2>&1 <<'REMOTE'
set +e
VAR=/var/jb/usr/lib/ziyan/var
LUA=/var/jb/usr/lib/ziyan/bin/lua5.3
RUN=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
AGENT=/var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
REPORT_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/错误报告"

is_real_agent_line() {
  case "$1" in *lua5.3*ziyan_agent_run.lua*) ;; *) return 1 ;; esac
  case "$1" in *"sh -c"*|*"bash -s"*) return 1 ;; esac
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

snapshot() {
  local phase="$1" line ps_all sb_pid= bb_pid= fc_n=0 zy_present= agent_n=0
  ps_all=$(ps -A -o pid=,args= 2>/dev/null)
  printf '=== %s ===\n' "$phase"
  while IFS= read -r line; do
    case "$line" in
      *SpringBoard.app/SpringBoard*)
        printf '%s_SPRINGBOARD_LINE=%s\n' "$phase" "$line"
        [ -n "$sb_pid" ] || { sb_pid="${line#"${line%%[![:space:]]*}"}"; sb_pid="${sb_pid%% *}"; }
        ;;
      *backboardd*)
        printf '%s_BACKBOARDD_LINE=%s\n' "$phase" "$line"
        [ -n "$bb_pid" ] || { bb_pid="${line#"${line%%[![:space:]]*}"}"; bb_pid="${bb_pid%% *}"; }
        ;;
      *'ziyan_framecap serve'*) fc_n=$((fc_n + 1)); printf '%s_FC_LINE=%s\n' "$phase" "$line" ;;
      *ziyadaemond*|*ziyan_zydaemond*) printf '%s_ZY_LINE=%s\n' "$phase" "$line"; case "$line" in "$FROZEN_ZY"*|*" $FROZEN_ZY "*) zy_present=1 ;; esac ;;
    esac
    if is_real_agent_line "$line"; then
      agent_n=$((agent_n + 1))
      printf '%s_REAL_AGENT_LUA=%s\n' "$phase" "$line"
    fi
  done <<EOF
$ps_all
EOF
  printf '%s_SB_PID=%s\n%s_BB_PID=%s\n%s_FC_N=%s\n%s_ZY_FROZEN_PRESENT=%s\n%s_REAL_AGENT_LUA_N=%s\n' \
    "$phase" "$sb_pid" "$phase" "$bb_pid" "$phase" "$fc_n" "$phase" "$zy_present" "$phase" "$agent_n"
  printf '%s_HOOKS_BEGIN\n' "$phase"; cat "$VAR/.ziyan_hooks" 2>/dev/null; printf '%s_HOOKS_END\n' "$phase"
  printf '%s_FRONT=%s\n' "$phase" "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
  printf '%s_SESSION_BEGIN\n' "$phase"; cat "$VAR/.ziyan_agent_session" 2>/dev/null; printf '%s_SESSION_END\n' "$phase"
  printf '%s_PROFILE_BEGIN\n' "$phase"; cat "$VAR/.ziyan_agent_current_profile" 2>/dev/null; printf '%s_PROFILE_END\n' "$phase"
  printf '%s_REQ_BEGIN\n' "$phase"; cat "$VAR/.ziyan_agent_req" 2>/dev/null; printf '%s_REQ_END\n' "$phase"
}

snapshot PRECHECK
printf 'REPORT_DIR_BEFORE_BEGIN\n'; ls -lt "$REPORT_ROOT" 2>&1; printf 'REPORT_DIR_BEFORE_END\n'
PRE_STATE=$(sed -n 's/^state=\([^[:space:]]*\).*/\1/p' "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p')
FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
PROFILE_BYTES=$(wc -c < "$VAR/.ziyan_agent_current_profile" 2>/dev/null)
PRE_PS=$(ps -A -o pid=,args= 2>/dev/null)
PRE_SB=$(printf '%s\n' "$PRE_PS" | sed -n '/SpringBoard.app\/SpringBoard/{s/^[[:space:]]*//;s/[[:space:]].*$//;p;q;}')
PRE_BB=$(printf '%s\n' "$PRE_PS" | sed -n '/backboardd/{s/^[[:space:]]*//;s/[[:space:]].*$//;p;q;}')
PRE_FC_N=$(printf '%s\n' "$PRE_PS" | sed -n '/ziyan_framecap serve/p' | sed -n '$=')
PRE_ZY_PRESENT=0
while IFS= read -r line; do
  case "$line" in "$FROZEN_ZY"*|*" $FROZEN_ZY "*) PRE_ZY_PRESENT=1 ;; esac
done <<EOF
$(printf '%s\n' "$PRE_PS" | sed -n '/ziyadaemond\|ziyan_zydaemond/p')
EOF
PRE_AGENT_N=$(real_agent_lines | wc -l | tr -d '[:space:]')

if [ "$FRONT" != com.ziyan.ziyan ]; then
  printf 'SMOKE=PRE_BLOCKED\nREASON=FRONT_NOT_ZIYAN\n'
  exit 0
fi
if [ "$PRE_SB" != "$FROZEN_SB" ] ||
   [ "$PRE_BB" != "$FROZEN_BB" ] ||
   [ "$PRE_FC_N" != 1 ] ||
   [ "$PRE_ZY_PRESENT" != 1 ] ||
   [ "$PRE_AGENT_N" != 0 ]; then
  printf 'SMOKE=PRE_BLOCKED\nREASON=FROZEN_OR_REAL_AGENT_MISMATCH\n'
  exit 0
fi
if [ "$PROFILE_BYTES" != 0 ]; then
  printf 'SMOKE=PRE_BLOCKED\nREASON=PROFILE_NOT_EMPTY\n'
  exit 0
fi
if [ "$PRE_STATE" != PAUSED_SAFE ]; then
  printf 'SMOKE=PRE_BLOCKED\nREASON=SESSION_NOT_PAUSED_SAFE\n'
  exit 0
fi

printf 'PROFILE_ALREADY_EMPTY=1\n'
printf 'mode=observe\n' > "$VAR/.ziyan_agent_req"
printf 'REQ_WRITTEN=mode=observe\n'
printf 'REAL_AGENT_ARGS=%s %s %s\n' "$LUA" "$RUN" "$AGENT"
RUN_LOG="$VAR/.ziyan_agent_no_profile_75_53_retry.log"
RUN_RC="$VAR/.ziyan_agent_no_profile_75_53_retry.rc"
rm -f "$RUN_LOG" "$RUN_RC"
(
  DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua /var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
  printf '%s\n' "$?" > "$RUN_RC"
) >"$RUN_LOG" 2>&1 &
LAUNCH_PID=$!
printf 'LAUNCH_PID=%s\n' "$LAUNCH_PID"

PAUSED=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  STATE=$(sed -n 's/^state=\([^[:space:]]*\).*/\1/p' "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p')
  if [ -f "$RUN_RC" ] && [ "$STATE" = PAUSED_SAFE ]; then
    PAUSED=1
    printf 'PAUSED_SAFE_POLL=%ss\n' "$i"
    break
  fi
  sleep 1
done
printf 'RUN_RC=%s\n' "$(cat "$RUN_RC" 2>/dev/null || printf ABSENT)"
printf 'RUN_LOG_BEGIN\n'; cat "$RUN_LOG" 2>&1; printf 'RUN_LOG_END\n'
snapshot AFTER
SESSION_ID=$(sed -n 's/^session_id=//p' "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p')
REPORT="$REPORT_ROOT/$SESSION_ID/report.txt"
printf 'NEW_SESSION_ID=%s\nREPORT_PATH=%s\n' "$SESSION_ID" "$REPORT"
if [ -f "$REPORT" ]; then
  printf 'REPORT_PRESENT=1\nREPORT_FIELDS_BEGIN\n'
  grep -E '^(error_code|stop_reason|paused)=' "$REPORT" 2>/dev/null
  printf 'REPORT_FIELDS_END\n'
else
  printf 'REPORT_PRESENT=0\n'
fi
printf 'REPORT_DIR_AFTER_BEGIN\n'; ls -lt "$REPORT_ROOT" 2>&1; printf 'REPORT_DIR_AFTER_END\n'

AFTER_STATE=$(sed -n 's/^state=\([^[:space:]]*\).*/\1/p' "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p')
AFTER_PROFILE_BYTES=$(wc -c < "$VAR/.ziyan_agent_current_profile" 2>/dev/null)
AFTER_AGENT_N=$(real_agent_lines | wc -l | tr -d '[:space:]')
AFTER_SB=$(ps -A -o pid=,args= 2>/dev/null | sed -n '/SpringBoard.app\/SpringBoard/{s/^[[:space:]]*//;s/[[:space:]].*$//;p;q;}')
AFTER_FC_N=$(ps -A -o pid=,args= 2>/dev/null | sed -n '/ziyan_framecap serve/p' | sed -n '$=')
if [ "$PAUSED" = 1 ] &&
   [ "$AFTER_STATE" = PAUSED_SAFE ] &&
   [ "$AFTER_PROFILE_BYTES" = 0 ] &&
   [ "$AFTER_AGENT_N" = 0 ] &&
   [ "$AFTER_SB" = "$FROZEN_SB" ] &&
   [ "$AFTER_FC_N" = 1 ] &&
   [ -f "$REPORT" ] &&
   grep -q '^stop_reason=no_profile$' "$REPORT" &&
   grep -q '^paused=no_profile$' "$REPORT"; then
  printf 'SMOKE=OK\n'
else
  printf 'SMOKE=REPORT_STILL_ABSENT\n'
fi
REMOTE

python3 - "$OUT" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
text = (out / "TRANSCRIPT.log").read_text(errors="replace")
(out / "RUN.log").write_text(
    text[text.find("PROFILE_ALREADY_EMPTY=1"):text.find("=== AFTER ===")]
    if "PROFILE_ALREADY_EMPTY=1" in text and "=== AFTER ===" in text else ""
)
(out / "AFTER.log").write_text(text[text.find("=== AFTER ==="):] if "=== AFTER ===" in text else "")
status = "OK" if "\nSMOKE=OK\n" in f"\n{text}" else "REPORT_STILL_ABSENT"
report_path = next((line.split("=", 1)[1] for line in text.splitlines() if line.startswith("REPORT_PATH=")), "ABSENT")
verdict = [
    "# 七十五补：.53 空 profile 错误报告",
    "",
    f"SMOKE={status}",
    "AGENT_SMOKE_NO_PROFILE=" + ("PASS_PENDING_HUMAN" if status == "OK" else "PARTIAL_PENDING_HUMAN REASON=53_REPORT_STILL_ABSENT"),
    f"REPORT_PATH={report_path}",
    "NOT_OBSERVE_STOPPED=1",
    "NOT_AGENT_MVP=1",
    "SBRELOAD=0",
    "LUA_OBJC_CHANGED=0",
    "THREE_OTHER_DEVICES_RERUN=0",
    "NEXT_ACTION=等待人工最终审核",
]
(out / "VERDICT.md").write_text("\n".join(verdict) + "\n")
print((out / "VERDICT.md").read_text(), end="")
PY
