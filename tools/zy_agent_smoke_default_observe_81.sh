#!/usr/bin/env bash
# 八十一号：缺 mode 的 Agent 请求必须默认走 observe。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/EIGHTYONE_AGENT_SMOKE_DEFAULT_OBSERVE_20260905"
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
  local expected_old_record="$8"
  local out="$OUT/$tag"
  mkdir -p "$out"

  ssh_r "$ip" \
    "SCHEME='$scheme' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' FROZEN_ZY='$frozen_zy' EXPECTED_OLD_RECORD='$expected_old_record' bash -s" \
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

RECORD_ROOT=/private/var/mobile/Media/ZiYan/Agent游戏/运行记录

is_real_framecap_line() {
  case "$1" in
    *grep*|*sed*|*"sh -c"*|*"bash -s"*) return 1 ;;
    *"/ziyan_framecap serve"*|*" ziyan_framecap serve"*) return 0 ;;
    *) return 1 ;;
  esac
}

is_real_agent_line() {
  case "$1" in
    *lua5.3*ziyan_agent_run.lua*) return 0 ;;
    *) return 1 ;;
  esac
}

session_value() {
  sed -n "s/^$1=//p" "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p'
}

latest_record_id() {
  ls -t "$RECORD_ROOT"/ags_*.txt 2>/dev/null |
    sed -n '1p' | sed 's#.*/##; s#\.txt$##'
}

snapshot() {
  local phase="$1"
  local ps_all line sb_pid= bb_pid= fc_pid= fc_n=0 agent_n=0 zy_present=0
  ps_all=$(ps -A -o pid=,args= 2>/dev/null)
  printf '=== %s ===\n' "$phase"
  while IFS= read -r line; do
    case "$line" in
      *SpringBoard.app/SpringBoard*)
        printf '%s_SB_LINE=%s\n' "$phase" "$line"
        if [ -z "$sb_pid" ]; then
          set -- $line
          sb_pid="${1:-}"
        fi
        ;;
      *backboardd*)
        printf '%s_BB_LINE=%s\n' "$phase" "$line"
        if [ -z "$bb_pid" ]; then
          set -- $line
          bb_pid="${1:-}"
        fi
        ;;
      *ziyadaemond*|*ziyan_zydaemond*)
        printf '%s_ZY_LINE=%s\n' "$phase" "$line"
        set -- $line
        [ "${1:-}" = "$FROZEN_ZY" ] && zy_present=1
        ;;
    esac
    if is_real_framecap_line "$line"; then
      printf '%s_FC_LINE=%s\n' "$phase" "$line"
      fc_n=$((fc_n + 1))
      if [ -z "$fc_pid" ]; then
        set -- $line
        fc_pid="${1:-}"
      fi
    fi
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
  printf '%s_HOOKS_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_hooks" 2>/dev/null
  printf '%s_HOOKS_END\n' "$phase"
  printf '%s_FRONT=%s\n' "$phase" "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
  printf '%s_SESSION_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_agent_session" 2>/dev/null
  printf '%s_SESSION_END\n' "$phase"
  LAST_SB_PID="$sb_pid"
  LAST_BB_PID="$bb_pid"
  LAST_FC_PID="$fc_pid"
  LAST_FC_N="$fc_n"
  LAST_AGENT_N="$agent_n"
  LAST_ZY_PRESENT="$zy_present"
}

blocked() {
  printf 'SMOKE=PRE_BLOCKED\nREASON=%s\n' "$1"
  snapshot AFTER
  exit 1
}

snapshot PRECHECK
PRECHECK_LATEST_RECORD_ID="$(latest_record_id)"
printf 'PRECHECK_EXPECTED_OLD_RECORD_ID=%s\n' "$EXPECTED_OLD_RECORD"
printf 'PRECHECK_LATEST_RECORD_ID=%s\n' "$PRECHECK_LATEST_RECORD_ID"

if [ "$LAST_SB_PID" != "$FROZEN_SB" ] ||
   [ "$LAST_BB_PID" != "$FROZEN_BB" ] ||
   [ "$LAST_FC_PID" != "$FROZEN_FC" ] ||
   [ "$LAST_FC_N" != 1 ] ||
   [ "$LAST_ZY_PRESENT" != 1 ] ||
   [ "$LAST_AGENT_N" != 0 ] ||
   [ "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)" != com.ziyan.ziyan ] ||
   [ "$PRECHECK_LATEST_RECORD_ID" != "$EXPECTED_OLD_RECORD" ]; then
  blocked FROZEN_FRONT_AGENT_OR_OLD_RECORD_MISMATCH
fi

if [ -e "$VAR/.ziyan_agent_stop" ]; then
  blocked STOP_MARKER_PRESENT
fi

printf 'profile_id=agent_default_observe\nbundle_id=com.ziyan.ziyan\ndisplay_name=缺省观察\ngame_name=子砚\n' \
  > "$VAR/.ziyan_agent_current_profile"
printf '#no_mode\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_current_profile" "$VAR/.ziyan_agent_req" 2>/dev/null
printf 'PROFILE_WRITTEN=agent_default_observe\n'
printf 'REQ_ORIGINAL_BEGIN\n'
cat "$VAR/.ziyan_agent_req" 2>/dev/null
printf 'REQ_ORIGINAL_END\n'
if grep -q '^mode=' "$VAR/.ziyan_agent_req" 2>/dev/null; then
  printf 'REQ_HAS_MODE_LINE=1\nSMOKE=FAIL\n'
  snapshot AFTER
  exit 1
fi
printf 'REQ_HAS_MODE_LINE=0\n'

"$LUA" "$RUN" "$AGENT"
RUN_RC=$?
printf 'RUN_RC=%s\n' "$RUN_RC"

snapshot AFTER
NEW_RECORD_ID="$(latest_record_id)"
RECORD="$RECORD_ROOT/$NEW_RECORD_ID.txt"
printf 'NEW_RECORD_ID=%s\nRECORD_PATH=%s\n' "$NEW_RECORD_ID" "$RECORD"
RECORD_OK=0
RECORD_SAFE_ACTION=0
if [ -f "$RECORD" ]; then
  printf 'RECORD_CONTENT_BEGIN\n'
  cat "$RECORD"
  printf 'RECORD_CONTENT_END\n'
  if grep -q '^STOPPED .* mode=observe' "$RECORD"; then
    RECORD_OK=1
  fi
  if grep -q 'mode=safe_action' "$RECORD"; then
    RECORD_SAFE_ACTION=1
  fi
fi
printf 'RECORD_MODE_OBSERVE=%s\nRECORD_SAFE_ACTION=%s\n' "$RECORD_OK" "$RECORD_SAFE_ACTION"

SESSION_STATE="$(session_value state)"
SESSION_ID="$(session_value session_id)"
printf 'AFTER_SESSION_STATE=%s\nAFTER_SESSION_ID=%s\n' "$SESSION_STATE" "$SESSION_ID"

if [ "$RUN_RC" = 0 ] &&
   [ "$LAST_SB_PID" = "$FROZEN_SB" ] &&
   [ "$LAST_BB_PID" = "$FROZEN_BB" ] &&
   [ "$LAST_FC_PID" = "$FROZEN_FC" ] &&
   [ "$LAST_FC_N" = 1 ] &&
   [ "$LAST_ZY_PRESENT" = 1 ] &&
   [ "$LAST_AGENT_N" = 0 ] &&
   [ "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)" = com.ziyan.ziyan ] &&
   [ "$SESSION_STATE" = STOPPED ] &&
   [ "$NEW_RECORD_ID" != "$PRECHECK_LATEST_RECORD_ID" ] &&
   [ "$RECORD_OK" = 1 ] &&
   [ "$RECORD_SAFE_ACTION" = 0 ]; then
  printf 'SMOKE=OK\n'
  exit 0
fi

printf 'SMOKE=FAIL\n'
exit 1
REMOTE
}

mkdir -p "$OUT"

overall=OK
run_one .101 192.168.31.101 rootful 87863 87862 47853 96 ags_17886027543490 || overall=PARTIAL
if [ "$overall" = OK ]; then
  run_one .112 192.168.31.112 rootful 79809 79808 98110 92 ags_17886027566825 || overall=PARTIAL
fi
if [ "$overall" = OK ]; then
  run_one .166 192.168.31.166 rootful 25025 25024 52622 82626 ags_17886034343236 || overall=PARTIAL
fi
if [ "$overall" = OK ]; then
  run_one .53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886034369522 || overall=PARTIAL
fi

{
  printf '# 八十一号：缺 mode 默认 observe\n\n'
  for tag in .101 .112 .166 .53; do
    log="$OUT/$tag/TRANSCRIPT.log"
    if [ -f "$log" ]; then
      smoke="$(sed -n 's/^SMOKE=//p' "$log" | tail -1)"
      old="$(sed -n 's/^PRECHECK_LATEST_RECORD_ID=//p' "$log" | tail -1)"
      new="$(sed -n 's/^NEW_RECORD_ID=//p' "$log" | tail -1)"
      printf '%s: SMOKE=%s PRECHECK_OLD=%s NEW_RECORD=%s\n' \
        "$tag" "${smoke:-NOT_RUN}" "${old:-ABSENT}" "${new:-ABSENT}"
    else
      printf '%s: SMOKE=NOT_RUN\n' "$tag"
    fi
  done
  printf '\n'
  if [ "$overall" = OK ] &&
     grep -qx 'SMOKE=OK' "$OUT/.101/TRANSCRIPT.log" &&
     grep -qx 'SMOKE=OK' "$OUT/.112/TRANSCRIPT.log" &&
     grep -qx 'SMOKE=OK' "$OUT/.166/TRANSCRIPT.log" &&
     grep -qx 'SMOKE=OK' "$OUT/.53/TRANSCRIPT.log"; then
    printf 'AGENT_SMOKE_DEFAULT_OBSERVE=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_SMOKE_DEFAULT_OBSERVE=PARTIAL\n'
  fi
  printf 'MISSING_MODE_IS_OBSERVE=1\nNOT_HIDDEN_AUTO_OR_SAFE=1\nNOT_MVP=1\nNO_SBRELOAD=1\n'
} > "$OUT/VERDICT.md"

cat "$OUT/VERDICT.md"

python3 tools/ziyan_codex_checkpoint.py write \
  --stage "八十一号：四机各跑一次无 mode 的 Agent req，确认默认 observe 后 STOPPED" \
  --last-command "bash tools/zy_agent_smoke_default_observe_81.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "缺 mode 只默认 run_observe；以 EIGHTYONE VERDICT 与四机 TRANSCRIPT 为准；不是 hidden auto/safe，不是 MVP" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/EIGHTYONE_AGENT_SMOKE_DEFAULT_OBSERVE_20260905/VERDICT.md；.101/.112/.166/.53 TRANSCRIPT.log" \
  --latest-verdict "$(sed -n 's/^AGENT_SMOKE_DEFAULT_OBSERVE=//p' "$OUT/VERDICT.md" | tail -1)" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包；沿用盘上既有版本" \
  --device-state "见 EIGHTYONE_AGENT_SMOKE_DEFAULT_OBSERVE_20260905 逐机日志" \
  --running-processes "每台记录真实 FC_N、SB/BB 冻结、无真实 agent lua" \
  --cleanup-status "前台保持既有子砚；未执行重载；停手等待人工最终审核"
