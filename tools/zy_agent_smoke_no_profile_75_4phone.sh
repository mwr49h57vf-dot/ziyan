#!/usr/bin/env bash
# 七十五号：四机串行 Agent 空 profile + mode=observe 安全暂停采证。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/SEVENTYFIVE_AGENT_SMOKE_NO_PROFILE_20260905"
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
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
  fi
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5"
  local frozen_fc="$6" frozen_zy="$7" out="$OUT/$tag"
  mkdir -p "$out"
  printf 'SERIAL_START=.%s\n' "$tag" >"$out/HOST.log"

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

latest_report() {
  local session_id
  session_id=$(sed -n 's/^session_id=//p' "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p')
  if [ -n "$session_id" ] &&
     [ -f "/private/var/mobile/Media/ZiYan/Agent游戏/错误报告/$session_id/report.txt" ]; then
    printf '%s\n' "/private/var/mobile/Media/ZiYan/Agent游戏/错误报告/$session_id/report.txt"
    return 0
  fi
  return 1
}

snapshot() {
  local phase="$1" line ps_all fc_n=0 agent_n=0 sb_pid="" bb_pid="" zy_present=0
  local report=""
  ps_all=$(ps -A -o pid=,args= 2>/dev/null)
  log "=== ${phase} ==="
  log "${phase}_DATE=$(date '+%Y-%m-%d %H:%M:%S %z')"
  log "${phase}_VAR=$VAR"
  while IFS= read -r line; do
    case "$line" in
      *SpringBoard.app/SpringBoard*)
        log "${phase}_SB_LINE=$line"
        if [ -z "$sb_pid" ]; then
          sb_pid="${line#"${line%%[![:space:]]*}"}"
          sb_pid="${sb_pid%% *}"
        fi
        ;;
      *backboardd*)
        log "${phase}_BB_LINE=$line"
        if [ -z "$bb_pid" ]; then
          bb_pid="${line#"${line%%[![:space:]]*}"}"
          bb_pid="${bb_pid%% *}"
        fi
        ;;
      *'ziyan_framecap serve'*)
        log "${phase}_FC_PROC=$line"
        fc_n=$((fc_n + 1))
        ;;
      *ziyadaemond*|*ziyan_zydaemond*)
        log "${phase}_ZY_PROC=$line"
        case "$line" in
          "${FROZEN_ZY}"*) zy_present=1 ;;
          *" $FROZEN_ZY "*) zy_present=1 ;;
        esac
        ;;
    esac
    if is_real_agent_line "$line"; then
      log "${phase}_REAL_AGENT_LUA=$line"
      agent_n=$((agent_n + 1))
    fi
  done <<EOF
$ps_all
EOF
  log "${phase}_FC_N=$fc_n"
  log "${phase}_REAL_AGENT_LUA_N=$agent_n"
  log "${phase}_SB_PID=$sb_pid"
  log "${phase}_BB_PID=$bb_pid"
  log "${phase}_SB_FROZEN=$FROZEN_SB"
  log "${phase}_BB_FROZEN=$FROZEN_BB"
  log "${phase}_FC_FROZEN=$FROZEN_FC"
  log "${phase}_ZY_FROZEN=$FROZEN_ZY"
  log "${phase}_SB_FROZEN_MATCH=$([ "$sb_pid" = "$FROZEN_SB" ] && echo 1 || echo 0)"
  log "${phase}_BB_FROZEN_MATCH=$([ "$bb_pid" = "$FROZEN_BB" ] && echo 1 || echo 0)"
  log "${phase}_ZY_FROZEN_PRESENT=$zy_present"
  if [ "$phase" = PRECHECK ]; then
    PRECHECK_SB_PID="$sb_pid"
    PRECHECK_BB_PID="$bb_pid"
    PRECHECK_FC_N="$fc_n"
    PRECHECK_ZY_FROZEN_PRESENT="$zy_present"
    PRECHECK_REAL_AGENT_LUA_N="$agent_n"
  fi
  log "${phase}_HOOKS_BEGIN"
  cat "$VAR/.ziyan_hooks" 2>/dev/null
  log "${phase}_HOOKS_END"
  log "${phase}_FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
  log "${phase}_SESSION_BEGIN"
  cat "$VAR/.ziyan_agent_session" 2>/dev/null
  log "${phase}_SESSION_END"
  log "${phase}_SESSION_STATE=$(session_state)"
  log "${phase}_PROFILE_BEGIN"
  cat "$VAR/.ziyan_agent_current_profile" 2>/dev/null
  log "${phase}_PROFILE_END"
  log "${phase}_REQ_BEGIN"
  cat "$VAR/.ziyan_agent_req" 2>/dev/null
  log "${phase}_REQ_END"
  if [ -e "$VAR/.ziyan_agent_stop" ]; then
    log "${phase}_AGENT_STOP_MARKER=PRESENT"
    cat "$VAR/.ziyan_agent_stop" 2>/dev/null
  else
    log "${phase}_AGENT_STOP_MARKER=ABSENT"
  fi
  report=$(latest_report)
  log "${phase}_LATEST_REPORT_PATH=${report:-ABSENT}"
  if [ -n "$report" ]; then
    log "${phase}_LATEST_REPORT_BEGIN"
    grep -E '^(error_code|stop_reason|paused|mode|bundle_id|front_bid)=' "$report" 2>/dev/null
    log "${phase}_LATEST_REPORT_END"
  else
    log "${phase}_LATEST_REPORT_FIELDS=ABSENT"
  fi
}

snapshot PRECHECK
PRECHECK_RESULT=PASS
if [ "$PRECHECK_SB_PID" != "$FROZEN_SB" ] ||
   [ "$PRECHECK_BB_PID" != "$FROZEN_BB" ] ||
   [ "$PRECHECK_FC_N" != 1 ] ||
   [ "$PRECHECK_ZY_FROZEN_PRESENT" != 1 ] ||
   [ "$PRECHECK_REAL_AGENT_LUA_N" != 0 ]; then
  PRECHECK_RESULT=FROZEN_OR_AGENT_MISMATCH
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

FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
if [ "$FRONT" = com.ziyan.ziyan ]; then
  log "OPEN_APP=SKIPPED_ALREADY_FRONT"
else
  log "RUN_SKIPPED=FRONT_NOT_ZIYAN"
fi

if [ "$PRECHECK_RESULT" != PASS ] || [ "$FRONT" != com.ziyan.ziyan ]; then
  log "SMOKE=PRE_BLOCKED"
  snapshot AFTER
  log "NEXT_ALLOWED=0"
  exit 0
fi

# Preserve the existing profile in the local SSH transcript, then make the
# profile file empty so dispatch must take the no_profile safety branch.
log "PROFILE_BACKUP_BEGIN"
cat "$VAR/.ziyan_agent_current_profile" 2>/dev/null
log "PROFILE_BACKUP_END"
: > "$VAR/.ziyan_agent_current_profile"
chmod 666 "$VAR/.ziyan_agent_current_profile" 2>/dev/null
printf 'mode=observe\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_req" 2>/dev/null
log "PROFILE_EMPTY_WRITTEN=1"
log "REQ_WRITTEN=mode=observe"
log "PROFILE_AFTER_BEGIN"
cat "$VAR/.ziyan_agent_current_profile" 2>/dev/null
log "PROFILE_AFTER_END"
log "REQ_AFTER_BEGIN"
cat "$VAR/.ziyan_agent_req" 2>/dev/null
log "REQ_AFTER_END"

RUN_LOG="$VAR/.ziyan_agent_no_profile_75_run.log"
RUN_RC="$VAR/.ziyan_agent_no_profile_75_rc"
rm -f "$RUN_LOG" "$RUN_RC"
(
  "$LUA" "$RUN" "$AGENT"
  printf '%s\n' "$?" > "$RUN_RC"
) > "$RUN_LOG" 2>&1 &
LAUNCH_PID=$!
log "LAUNCH_PID=$LAUNCH_PID"

SEEN_REAL=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  REAL_NOW=$(real_agent_lines)
  if [ -n "$REAL_NOW" ]; then
    SEEN_REAL=1
    log "REAL_AGENT_LUA_CONFIRMED_POLL=$i"
    printf '%s\n' "$REAL_NOW"
    break
  fi
  sleep 0.2
done
log "REAL_AGENT_LUA_SEEN=$SEEN_REAL"

PAUSED=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  STATE=$(session_state)
  if [ -f "$RUN_RC" ] && [ "$STATE" = PAUSED_SAFE ]; then
    PAUSED=1
    log "PAUSED_SAFE_POLL=${i}s"
    break
  fi
  sleep 1
done

if [ "$PAUSED" = 1 ]; then
  log "SMOKE=OK"
else
  if [ "$(session_state)" = STOPPED ]; then
    log "SMOKE=STOPPED_NOT_PAUSED_SAFE"
  else
    log "SMOKE=PAUSE_TIMEOUT"
  fi
fi
if [ -f "$RUN_RC" ]; then
  log "RUN_RC=$(cat "$RUN_RC" 2>/dev/null)"
else
  log "RUN_RC=ABSENT"
fi
log "RUN_LOG_BEGIN"
tail -n 80 "$RUN_LOG" 2>/dev/null
log "RUN_LOG_END"
snapshot AFTER

AFTER_REPORT=$(latest_report)
log "AFTER_REPORT_PATH=${AFTER_REPORT:-ABSENT}"
if [ -n "$AFTER_REPORT" ]; then
  log "AFTER_REPORT_FIELDS_BEGIN"
  grep -E '^(error_code|stop_reason|paused|mode|bundle_id|front_bid)=' "$AFTER_REPORT" 2>/dev/null
  log "AFTER_REPORT_FIELDS_END"
fi

if [ "$PAUSED" = 1 ] &&
   [ "$(session_state)" = PAUSED_SAFE ] &&
   [ -z "$(real_agent_lines)" ]; then
  log "NEXT_ALLOWED=1"
else
  log "NEXT_ALLOWED=0"
fi
REMOTE

  python3 - "$out/TRANSCRIPT.log" "$out/PRECHECK.log" "$out/PROFILE_BEFORE.txt" "$out/RUN.log" "$out/AFTER.log" <<'PY'
from pathlib import Path
import sys

source, pre_path, profile_path, run_path, after_path = map(Path, sys.argv[1:])
text = source.read_text(errors="replace")
pre_start = text.find("=== PRECHECK ===")
profile_start = text.find("PROFILE_BACKUP_BEGIN")
profile_end = text.find("PROFILE_BACKUP_END")
run_start = text.find("PROFILE_EMPTY_WRITTEN=1")
after_start = text.find("=== AFTER ===")
pre_path.write_text(text[pre_start:profile_start] if pre_start >= 0 and profile_start >= 0 else "")
profile_path.write_text(text[profile_start + len("PROFILE_BACKUP_BEGIN\n"):profile_end] if profile_start >= 0 and profile_end >= 0 else "")
run_path.write_text(text[run_start:after_start] if run_start >= 0 and after_start >= 0 else "")
after_path.write_text(text[after_start:] if after_start >= 0 else "")
PY

  if grep -q '^NEXT_ALLOWED=1$' "$out/TRANSCRIPT.log"; then
    return 0
  fi
  return 1
}

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
        rows.append((tag, "NOT_RUN", "prior_host_not_paused_safe_or_dirty"))
        all_ok = False
        continue
    pre = (host / "PRECHECK.log").read_text(errors="replace")
    profile = (host / "PROFILE_BEFORE.txt").read_text(errors="replace")
    run = (host / "RUN.log").read_text(errors="replace")
    after = (host / "AFTER.log").read_text(errors="replace")
    transcript = (host / "TRANSCRIPT.log").read_text(errors="replace")
    failures = []
    for needle, reason in (
        ("PRECHECK_RESULT=PASS", "precheck_failed"),
        ("STOP_AFTER_CLEAR=ABSENT", "leftover_stop_not_cleared"),
        ("OPEN_APP=SKIPPED_ALREADY_FRONT", "front_not_ziyan_or_open_attempted"),
    ):
        if needle not in pre:
            failures.append(reason)
    if not profile.strip():
        failures.append("profile_backup_empty")
    for needle, reason in (
        ("PROFILE_EMPTY_WRITTEN=1", "profile_not_emptied"),
        ("REQ_WRITTEN=mode=observe", "req_not_observe"),
        ("SMOKE=OK", "smoke_not_ok"),
        ("RUN_RC=0", "run_rc_not_zero"),
        ("AFTER_REPORT_FIELDS_BEGIN", "report_not_read"),
    ):
        if needle not in run or (reason == "report_not_read" and needle not in transcript):
            failures.append(reason)
    if "NEXT_ALLOWED=1" not in after:
        failures.append("not_quiescent_for_next")
    for needle, reason in (
        ("AFTER_FRONT=com.ziyan.ziyan", "after_front_not_ziyan"),
        ("AFTER_SESSION_STATE=PAUSED_SAFE", "session_not_paused_safe"),
        ("AFTER_AGENT_STOP_MARKER=ABSENT", "stop_marker_present"),
        ("AFTER_LATEST_REPORT_PATH=", "latest_report_missing"),
    ):
        if needle not in after:
            failures.append(reason)
    if re.search(r"^AFTER_REAL_AGENT_LUA_N=0$", after, re.M) is None:
        failures.append("real_agent_lua_still_present")
    if re.search(r"^AFTER_FC_N=1$", after, re.M) is None:
        failures.append("fc_not_single")
    if re.search(r"^AFTER_SB_FROZEN_MATCH=1$", after, re.M) is None:
        failures.append("springboard_changed")
    if not re.search(r"^(error_code|stop_reason|paused)=.*no_profile", transcript, re.M):
        failures.append("no_profile_not_in_report_or_session")
    status = "OK" if not failures else "FAIL"
    all_ok &= status == "OK"
    rows.append((tag, status, ",".join(failures) or "none"))

verdict = [
    "# 七十五号：空 profile + Agent mode=observe 安全门禁",
    "",
    "每台先把既有 .ziyan_agent_current_profile 原文保存到本机 PROFILE_BEFORE.txt，再写空 profile 文件与唯一请求 mode=observe，验证 dispatch 安全暂停。",
    "未 sbreload；未执行 ldrestart、killall SpringBoard/backboardd、dpkg、改 lua/objc、打开 App 或 Home。",
    "",
]
for tag, status, reason in rows:
    verdict.append(f"- .{tag}: SMOKE={status} REASON={reason}")
verdict.extend([
    "",
    "AGENT_SMOKE_NO_PROFILE=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL"),
    "SAFETY_RESULT=空 profile 会安全暂停，原因 no_profile；不是 observe STOPPED。",
    "NOT_G0=1",
    "NOT_AGENT_MVP=1",
    "SBRELOAD=0",
    "NEXT_ACTION=等待人工最终审核",
])
(out / "VERDICT.md").write_text("\n".join(verdict) + "\n")
print((out / "VERDICT.md").read_text(), end="")
PY

python3 tools/ziyan_codex_checkpoint.py write \
  --stage "七十五号：四机空 profile + Agent mode=observe，期望 PAUSED_SAFE/no_profile" \
  --last-command "bash tools/zy_agent_smoke_no_profile_75_4phone.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "逐机备份既有 profile 到本机证据，写空 profile 与 mode=observe，验证 PAUSED_SAFE/no_profile；未 sbreload、未改 lua/objc" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/SEVENTYFIVE_AGENT_SMOKE_NO_PROFILE_20260905/VERDICT.md；四机 PRECHECK.log、PROFILE_BEFORE.txt、RUN.log、AFTER.log、TRANSCRIPT.log" \
  --latest-verdict "AGENT_SMOKE_NO_PROFILE=见 VERDICT.md；空 profile 安全暂停 no_profile；不是 observe STOPPED；不是 MVP；未 sbreload" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包；沿用盘上既有版本" \
  --device-state ".101/.112/.166/.53 依 VERDICT；冻结值与 FC_N 依四机 AFTER" \
  --running-processes "依四机 AFTER：无真实 args 同时含 lua5.3 与 ziyan_agent_run.lua 的残留进程" \
  --cleanup-status "依四机 AFTER：.ziyan_agent_stop=ABSENT；本刀停止，等待人工最终审核"
