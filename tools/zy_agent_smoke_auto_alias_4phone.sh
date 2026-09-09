#!/usr/bin/env bash
# 七十一号：四机 Agent mode=auto 安全别名一次性采证。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/SEVENTYONE_AGENT_SMOKE_AUTO_ALIAS_20260905"
PASS="${ZY_SSH_PASS:-alpine}"
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

  ssh_r "$ip" \
    "TAG='$tag' SCHEME='$scheme' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' FROZEN_ZY='$frozen_zy' bash -s" \
    >"$out/TRANSCRIPT.log" 2>&1 <<'EOS'
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
$(ps -A -o pid=,comm=,args= 2>/dev/null)
EOF
}

snapshot() {
  local phase="$1"
  local ps_all line fc_n=0 agent_n=0 sb_pid="" bb_pid="" zy_pid=""
  ps_all=$(ps -A -o pid=,comm=,args= 2>/dev/null)
  log "=== ${phase} ==="
  log "DATE=$(date '+%Y-%m-%d %H:%M:%S %z')"
  log "VAR=$VAR"
  while IFS= read -r line; do
    case "$line" in
      *SpringBoard.app/SpringBoard*)
        log "SB_LINE=$line"
        [ -z "$sb_pid" ] && sb_pid="${line#"${line%%[![:space:]]*}"}"
        sb_pid="${sb_pid%% *}"
        ;;
      *backboardd*)
        log "BB_LINE=$line"
        [ -z "$bb_pid" ] && bb_pid="${line#"${line%%[![:space:]]*}"}"
        bb_pid="${bb_pid%% *}"
        ;;
      *'ziyan_framecap serve'*)
        log "FC_PROC=$line"
        fc_n=$((fc_n + 1))
        ;;
      *ziyadaemond*|*ziyan_zydaemond*)
        log "ZY_PROC=$line"
        [ -z "$zy_pid" ] && zy_pid="${line#"${line%%[![:space:]]*}"}"
        zy_pid="${zy_pid%% *}"
        ;;
    esac
    if is_real_agent_line "$line"; then
      log "REAL_AGENT_LUA=$line"
      agent_n=$((agent_n + 1))
    fi
  done <<EOF
$ps_all
EOF
  log "FC_N=$fc_n"
  log "REAL_AGENT_LUA_N=$agent_n"
  log "SB_PID=$sb_pid"
  log "BB_PID=$bb_pid"
  log "ZY_PID=$zy_pid"
  log "SB_FROZEN=$FROZEN_SB"
  log "BB_FROZEN=$FROZEN_BB"
  log "FC_FROZEN=$FROZEN_FC"
  log "ZY_FROZEN=$FROZEN_ZY"
  log "SB_FROZEN_MATCH=$([ "$sb_pid" = "$FROZEN_SB" ] && echo 1 || echo 0)"
  log "BB_FROZEN_MATCH=$([ "$bb_pid" = "$FROZEN_BB" ] && echo 1 || echo 0)"
  log "ZY_FROZEN_PRESENT=$([ "$zy_pid" = "$FROZEN_ZY" ] && echo 1 || echo 0)"
  log "HOOKS_BEGIN"
  cat "$VAR/.ziyan_hooks" 2>/dev/null
  log "HOOKS_END"
  log "FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
  log "SESSION_BEGIN"
  cat "$VAR/.ziyan_agent_session" 2>/dev/null
  log "SESSION_END"
  log "PROFILE_BEGIN"
  cat "$VAR/.ziyan_agent_current_profile" 2>/dev/null
  log "PROFILE_END"
  log "REQ_BEGIN"
  cat "$VAR/.ziyan_agent_req" 2>/dev/null
  log "REQ_END"
  if [ -e "$VAR/.ziyan_agent_stop" ]; then
    log "AGENT_STOP_MARKER=PRESENT"
    cat "$VAR/.ziyan_agent_stop" 2>/dev/null
  else
    log "AGENT_STOP_MARKER=ABSENT"
  fi
}

snapshot PRECHECK

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

FRONT=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
if [ "$FRONT" != com.ziyan.ziyan ]; then
  log "SMOKE=FRONT_NOT_ZIYAN"
  snapshot AFTER
  exit 0
fi

printf 'profile_id=agent_auto_alias\nbundle_id=com.ziyan.ziyan\ndisplay_name=自动别名\ngame_name=子砚\n' \
  > "$VAR/.ziyan_agent_current_profile"
printf 'mode=auto\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_current_profile" "$VAR/.ziyan_agent_req" 2>/dev/null
log "PROFILE_WRITTEN=agent_auto_alias"
log "REQ_WRITTEN=mode=auto"

RUN_LOG="$VAR/.ziyan_agent_auto_alias_71_run.log"
RUN_RC="$VAR/.ziyan_agent_auto_alias_71_rc"
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

STOPPED=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  STATE=$(sed -n 's/^state=//p' "$VAR/.ziyan_agent_session" 2>/dev/null | head -1)
  if [ -f "$RUN_RC" ] && [ "$STATE" = STOPPED ]; then
    STOPPED=1
    log "STOPPED_POLL=${i}s"
    break
  fi
  sleep 1
done

if [ "$STOPPED" = 1 ]; then
  log "SMOKE=OK"
else
  log "SMOKE=STOP_TIMEOUT"
fi
if [ -f "$RUN_RC" ]; then
  log "RUN_RC=$(cat "$RUN_RC" 2>/dev/null)"
else
  log "RUN_RC=ABSENT"
fi
log "RUN_LOG_BEGIN"
tail -n 80 "$RUN_LOG" 2>/dev/null
log "RUN_LOG_END"
log "LATEST_RECORD_BEGIN"
RECORDS="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"
LATEST_RECORD=$(ls -t "$RECORDS"/ags_*.txt 2>/dev/null | head -1)
if [ -n "$LATEST_RECORD" ]; then
  log "LATEST_RECORD_PATH=$LATEST_RECORD"
  cat "$LATEST_RECORD" 2>/dev/null
fi
log "LATEST_RECORD_END"
snapshot AFTER
EOS

  python3 - "$out/TRANSCRIPT.log" "$out/PRECHECK.log" "$out/RUN.log" "$out/AFTER.log" <<'PY'
from pathlib import Path
import sys

source, pre_path, run_path, after_path = map(Path, sys.argv[1:])
text = source.read_text(errors="replace")
parts = text.split("=== PRECHECK ===", 1)
pre = parts[1].split("=== AFTER ===", 1)[0] if len(parts) == 2 else ""
run_start = text.find("PROFILE_WRITTEN=")
run = text[run_start:text.find("=== AFTER ===", run_start)] if run_start >= 0 else ""
after = text[text.find("=== AFTER ==="):] if "=== AFTER ===" in text else ""
pre_path.write_text(pre)
run_path.write_text(run)
after_path.write_text(after)
PY
}

run_one 101 192.168.31.101 rootful 87863 87862 47853 96
run_one 112 192.168.31.112 rootful 79809 79808 98110 92
run_one 166 192.168.31.166 rootful 25025 25024 52622 82626
run_one 53 192.168.31.53 rootless 46408 74318 49176 93705

python3 - "$OUT" <<'PY'
from pathlib import Path
import re
import sys

out = Path(sys.argv[1])
rows = []
all_ok = True
for tag in ("101", "112", "166", "53"):
    pre = (out / tag / "PRECHECK.log").read_text(errors="replace")
    run = (out / tag / "RUN.log").read_text(errors="replace")
    after = (out / tag / "AFTER.log").read_text(errors="replace")
    failures = []
    for needle, reason in (
        ("STOP_AFTER_CLEAR=ABSENT", "leftover_stop_not_cleared"),
        ("PROFILE_WRITTEN=agent_auto_alias", "profile_not_written"),
        ("REQ_WRITTEN=mode=auto", "req_not_written_auto"),
        ("SMOKE=OK", "smoke_not_ok"),
        ("RUN_RC=0", "run_rc_not_zero"),
        ("state=STOPPED", "session_not_stopped"),
        ("AGENT_STOP_MARKER=ABSENT", "stop_marker_present"),
    ):
        blob = pre if "clear" in reason else run if reason in {
            "profile_not_written", "req_not_written_auto", "smoke_not_ok",
            "run_rc_not_zero",
        } else after
        if needle not in blob:
            failures.append(reason)
    if "front=com.ziyan.ziyan" not in run:
        failures.append("record_front_not_ziyan")
    if "mode=safe_action" not in run:
        failures.append("record_not_safe_action_alias")
    if re.search(r"^FC_N=1$", after, re.M) is None:
        failures.append("fc_not_single")
    if re.search(r"^SB_FROZEN_MATCH=1$", after, re.M) is None:
        failures.append("springboard_changed")
    if re.search(r"^REAL_AGENT_LUA_N=0$", after, re.M) is None:
        failures.append("real_agent_lua_still_present")
    status = "OK" if not failures else "FAIL"
    all_ok &= status == "OK"
    rows.append((tag, status, ",".join(failures) or "none"))

verdict = [
    "# 七十一号 Agent mode=auto 安全别名 smoke",
    "",
    "本刀只验证当前 Lua dispatch 的停止路径：mode=auto 与 mode=safe 同路由到 run_safe_action。",
    "AUTO_DISPATCH_IS_SAFE=1",
    "DISPATCH_AUTO_TARGET=run_safe_action",
    "NOT_AGENT_AUTONOMOUS_ENGINE=1",
    "NOT_REAL_SELF_DEVELOPED_AGENT=1",
    "未改 dispatch；未改 lua/objc；未 sbreload。",
    "",
]
for tag, status, reason in rows:
    verdict.append(f"- .{tag}: SMOKE={status} REASON={reason}")
verdict.extend([
    "",
    "AGENT_SMOKE_AUTO_ALIAS=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL"),
    "NOT_G0=1",
    "NOT_AGENT_MVP=1",
    "NEXT_ACTION=等待人工最终审核",
])
(out / "VERDICT.md").write_text("\n".join(verdict) + "\n")
print((out / "VERDICT.md").read_text(), end="")
PY

python3 tools/ziyan_codex_checkpoint.py write \
  --stage "七十一号：四机 Agent mode=auto 安全别名一次 smoke，终态 STOPPED" \
  --last-command "bash tools/zy_agent_smoke_auto_alias_4phone.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "四机 mode=auto 仅走 run_safe_action 别名；以 VERDICT 与四机 PRECHECK/RUN/AFTER/TRANSCRIPT 为准；不是真实自研 Agent，不是 MVP" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/SEVENTYONE_AGENT_SMOKE_AUTO_ALIAS_20260905/VERDICT.md；四机 PRECHECK.log、RUN.log、AFTER.log、TRANSCRIPT.log" \
  --latest-verdict "AGENT_SMOKE_AUTO_ALIAS=见 VERDICT.md；AUTO_DISPATCH_IS_SAFE=1" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包；沿用盘上既有版本" \
  --device-state ".101/.112/.166/.53 依 VERDICT；冻结值与 FC_N 依四机 AFTER" \
  --running-processes "依四机 AFTER：无真实 args 同时含 lua5.3 与 ziyan_agent_run.lua 的残留进程" \
  --cleanup-status "依四机 AFTER：.ziyan_agent_stop=ABSENT；未执行下一刀"
