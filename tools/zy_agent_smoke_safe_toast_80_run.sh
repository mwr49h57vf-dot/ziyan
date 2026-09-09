#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/EIGHTY_AGENT_SMOKE_SAFE_TOAST_20260905"
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
  local old_record="$8"
  local out="$OUT/$tag"
  mkdir -p "$out"

  ssh_r "$ip" \
    "SCHEME='$scheme' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' FROZEN_ZY='$frozen_zy' OLD_RECORD='$old_record' bash -s" \
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

is_real_agent_line() {
  case "$1" in
    *lua5.3*ziyan_agent_run.lua*) return 0 ;;
    *) return 1 ;;
  esac
}

session_value() {
  sed -n "s/^$1=//p" "$VAR/.ziyan_agent_session" 2>/dev/null | sed -n '1p'
}

front_bid() {
  tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null
}

latest_record_id() {
  ls -t "$RECORD_ROOT"/ags_*.txt 2>/dev/null |
    sed -n '1p' | sed 's#.*/##; s#\.txt$##'
}

toast_count() {
  grep -xc 'text=agent_safe_action' "$1" 2>/dev/null || true
}

toast_evidence() {
  local phase="$1"
  local path="$2"
  printf '%s_LINE_COUNT=%s\n' "$phase" "$(wc -l < "$path" 2>/dev/null || printf 0)"
  printf '%s_TEXT_BEGIN\n' "$phase"
  grep '^text=' "$path" 2>/dev/null || true
  printf '%s_TEXT_END\n' "$phase"
  printf '%s_AGENT_SAFE_ACTION_COUNT=%s\n' "$phase" "$(toast_count "$path")"
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
  toast_evidence AFTER_TOAST_DUMP "$VAR/.ziyan_toast_dump"
  toast_evidence AFTER_TOAST_HIST "$VAR/.ziyan_toast_hist"
  exit 1
}

snapshot PRECHECK
PRECHECK_LATEST_RECORD_ID="$(latest_record_id)"
printf 'PRECHECK_EXPECTED_OLD_RECORD_ID=%s\n' "$OLD_RECORD"
printf 'PRECHECK_LATEST_RECORD_ID=%s\n' "$PRECHECK_LATEST_RECORD_ID"
toast_evidence PRECHECK_TOAST_DUMP "$VAR/.ziyan_toast_dump"
toast_evidence PRECHECK_TOAST_HIST "$VAR/.ziyan_toast_hist"
PRECHECK_HIST_COUNT="$(toast_count "$VAR/.ziyan_toast_hist")"
PRECHECK_DUMP_COUNT="$(toast_count "$VAR/.ziyan_toast_dump")"

if [ "$LAST_SB_PID" != "$FROZEN_SB" ] ||
   [ "$LAST_BB_PID" != "$FROZEN_BB" ] ||
   [ "$LAST_FC_PID" != "$FROZEN_FC" ] ||
   [ "$LAST_FC_N" != 1 ] ||
   [ "$LAST_ZY_PRESENT" != 1 ] ||
   [ "$LAST_AGENT_N" != 0 ] ||
   [ "$(front_bid)" != com.ziyan.ziyan ] ||
   [ "$PRECHECK_LATEST_RECORD_ID" != "$OLD_RECORD" ]; then
  blocked FROZEN_FRONT_AGENT_OR_OLD_RECORD_MISMATCH
fi

if [ -e "$VAR/.ziyan_agent_stop" ]; then
  blocked STOP_MARKER_PRESENT
fi

printf 'profile_id=agent_safe_toast\nbundle_id=com.ziyan.ziyan\ndisplay_name=安全动作\ngame_name=子砚\n' \
  > "$VAR/.ziyan_agent_current_profile"
printf 'mode=safe\n' > "$VAR/.ziyan_agent_req"
chmod 666 "$VAR/.ziyan_agent_current_profile" "$VAR/.ziyan_agent_req" 2>/dev/null
printf 'PROFILE_WRITTEN=agent_safe_toast\nPROFILE_BUNDLE_WRITTEN=com.ziyan.ziyan\nPROFILE_DISPLAY_WRITTEN=安全动作\nPROFILE_GAME_WRITTEN=子砚\nREQ_WRITTEN=mode=safe\n'

"$LUA" "$RUN" "$AGENT"
RUN_RC=$?
printf 'RUN_RC=%s\n' "$RUN_RC"

snapshot AFTER
NEW_RECORD_ID="$(latest_record_id)"
RECORD="$RECORD_ROOT/$NEW_RECORD_ID.txt"
printf 'NEW_RECORD_ID=%s\nRECORD_PATH=%s\n' "$NEW_RECORD_ID" "$RECORD"
RECORD_OK=0
if [ -f "$RECORD" ]; then
  printf 'RECORD_CONTENT_BEGIN\n'
  cat "$RECORD"
  printf 'RECORD_CONTENT_END\n'
  if grep -q '^STOPPED .* mode=safe_action' "$RECORD"; then
    RECORD_OK=1
  fi
fi

toast_evidence AFTER_TOAST_DUMP "$VAR/.ziyan_toast_dump"
toast_evidence AFTER_TOAST_HIST "$VAR/.ziyan_toast_hist"
AFTER_HIST_COUNT="$(toast_count "$VAR/.ziyan_toast_hist")"
AFTER_DUMP_COUNT="$(toast_count "$VAR/.ziyan_toast_dump")"
HIST_DELTA=$((AFTER_HIST_COUNT - PRECHECK_HIST_COUNT))
DUMP_DELTA=$((AFTER_DUMP_COUNT - PRECHECK_DUMP_COUNT))
WINDOW_TOAST_COUNT="$HIST_DELTA"
if [ "$WINDOW_TOAST_COUNT" -lt 0 ]; then
  WINDOW_TOAST_COUNT="$DUMP_DELTA"
fi
printf 'TOAST_WINDOW_HIST_DELTA=%s\nTOAST_WINDOW_DUMP_DELTA=%s\nTOAST_WINDOW_AGENT_SAFE_ACTION_COUNT=%s\n' \
  "$HIST_DELTA" "$DUMP_DELTA" "$WINDOW_TOAST_COUNT"

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
   [ "$(front_bid)" = com.ziyan.ziyan ] &&
   [ "$SESSION_STATE" = STOPPED ] &&
   [ "$NEW_RECORD_ID" != "$OLD_RECORD" ] &&
   [ "$RECORD_OK" = 1 ] &&
   [ "$WINDOW_TOAST_COUNT" -le 1 ]; then
  printf 'SMOKE=OK\n'
  exit 0
fi

printf 'SMOKE=FAIL\n'
exit 1
REMOTE
}

mkdir -p "$OUT"
printf '# 八十号：四机 mode=safe toast 一次对齐\n\n' > "$OUT/VERDICT.md"
printf '串行顺序：.101 -> .112 -> .166 -> .53。每台只在上一台 `SMOKE=OK` 后继续。\n\n' >> "$OUT/VERDICT.md"

overall=OK
completed=0
for spec in \
  ".101 192.168.31.101 rootful 87863 87862 47853 96 ags_17886013788551" \
  ".112 192.168.31.112 rootful 79809 79808 98110 92 ags_17886017461017" \
  ".166 192.168.31.166 rootful 25025 25024 52622 82626 ags_17886019287529" \
  ".53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886019413519"
do
  set -- $spec
  if run_one "$@"; then
    completed=$((completed + 1))
  else
    overall=PARTIAL
    break
  fi
done

for tag in .101 .112 .166 .53; do
  log="$OUT/$tag/TRANSCRIPT.log"
  if [ -f "$log" ]; then
    smoke="$(sed -n 's/^SMOKE=//p' "$log" | tail -1)"
    old="$(sed -n 's/^PRECHECK_LATEST_RECORD_ID=//p' "$log" | tail -1)"
    new="$(sed -n 's/^NEW_RECORD_ID=//p' "$log" | tail -1)"
    toast="$(sed -n 's/^TOAST_WINDOW_AGENT_SAFE_ACTION_COUNT=//p' "$log" | tail -1)"
    printf '%s: SMOKE=%s PRECHECK_OLD=%s NEW_RECORD=%s TOAST_ONCE=%s\n' \
      "$tag" "${smoke:-NOT_RUN}" "${old:-ABSENT}" "${new:-ABSENT}" "${toast:-ABSENT}" >> "$OUT/VERDICT.md"
  else
    printf '%s: SMOKE=NOT_RUN\n' "$tag" >> "$OUT/VERDICT.md"
  fi
done

printf '\n' >> "$OUT/VERDICT.md"
if [ "$overall" = OK ] && [ "$completed" = 4 ]; then
  printf 'AGENT_SMOKE_SAFE_TOAST=PASS_PENDING_HUMAN\n' >> "$OUT/VERDICT.md"
else
  printf 'AGENT_SMOKE_SAFE_TOAST=PARTIAL\n' >> "$OUT/VERDICT.md"
fi
printf 'NOT_TOAST_STORM=1\nNOT_REAL_CLICK=1\nNOT_MVP=1\nNO_SBRELOAD=1\n' >> "$OUT/VERDICT.md"

cat "$OUT/VERDICT.md"
