#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/EIGHTY_RETRY_AGENT_SMOKE_SAFE_TOAST_20260905"
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

read_only() {
  local tag="$1"
  local ip="$2"
  local var="$3"
  local frozen_sb="$4"
  local frozen_bb="$5"
  local frozen_fc="$6"
  local expected_record="$7"
  local out="$OUT/$tag"
  mkdir -p "$out"

  ssh_r "$ip" \
    "VAR='$var' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' EXPECTED_RECORD='$expected_record' bash -s" \
    >"$out/READONLY.log" 2>&1 <<'REMOTE'
set +e
RECORD_ROOT=/private/var/mobile/Media/ZiYan/Agent游戏/运行记录
ps_all=$(ps -A -o pid=,args= 2>/dev/null)
sb_pid=
bb_pid=
fc_pid=
fc_n=0
agent_n=0

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

while IFS= read -r line; do
  case "$line" in
    *SpringBoard.app/SpringBoard*)
      printf 'READONLY_SB_LINE=%s\n' "$line"
      [ -n "$sb_pid" ] || sb_pid="${line%% *}"
      ;;
    *backboardd*)
      printf 'READONLY_BB_LINE=%s\n' "$line"
      [ -n "$bb_pid" ] || bb_pid="${line%% *}"
      ;;
  esac
  if is_real_framecap_line "$line"; then
    printf 'READONLY_FC_LINE=%s\n' "$line"
    fc_n=$((fc_n + 1))
    [ -n "$fc_pid" ] || fc_pid="${line%% *}"
  fi
  if is_real_agent_line "$line"; then
    printf 'READONLY_REAL_AGENT_LUA=%s\n' "$line"
    agent_n=$((agent_n + 1))
  fi
done <<EOF
$ps_all
EOF

latest="$(ls -t "$RECORD_ROOT"/ags_*.txt 2>/dev/null | sed -n '1p' | sed 's#.*/##; s#\.txt$##')"
printf 'READONLY_SB_PID=%s\n' "$sb_pid"
printf 'READONLY_BB_PID=%s\n' "$bb_pid"
printf 'READONLY_FC_PID=%s\n' "$fc_pid"
printf 'READONLY_FC_N=%s\n' "$fc_n"
printf 'READONLY_REAL_AGENT_LUA_N=%s\n' "$agent_n"
printf 'READONLY_FRONT=%s\n' "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
printf 'READONLY_LATEST_RECORD_ID=%s\n' "$latest"
printf 'READONLY_EXPECTED_RECORD_ID=%s\n' "$EXPECTED_RECORD"
printf 'READONLY_FROZEN_MATCH=%s\n' "$([ "$sb_pid" = "$FROZEN_SB" ] && [ "$bb_pid" = "$FROZEN_BB" ] && [ "$fc_pid" = "$FROZEN_FC" ] && [ "$fc_n" = 1 ] && echo 1 || echo 0)"
printf 'READONLY_OK=%s\n' "$([ "$sb_pid" = "$FROZEN_SB" ] && [ "$bb_pid" = "$FROZEN_BB" ] && [ "$fc_pid" = "$FROZEN_FC" ] && [ "$fc_n" = 1 ] && [ "$agent_n" = 0 ] && [ "$latest" = "$EXPECTED_RECORD" ] && echo 1 || echo 0)"
REMOTE
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
  local line ps_all sb_pid= bb_pid= fc_pid= fc_n=0 agent_n=0 zy_present=0
  ps_all=$(ps -A -o pid=,args= 2>/dev/null)
  printf '=== %s ===\n' "$phase"
  while IFS= read -r line; do
    case "$line" in
      *SpringBoard.app/SpringBoard*)
        printf '%s_SB_LINE=%s\n' "$phase" "$line"
        [ -n "$sb_pid" ] || sb_pid="${line%% *}"
        ;;
      *backboardd*)
        printf '%s_BB_LINE=%s\n' "$phase" "$line"
        [ -n "$bb_pid" ] || bb_pid="${line%% *}"
        ;;
      *ziyadaemond*|*ziyan_zydaemond*)
        printf '%s_ZY_LINE=%s\n' "$phase" "$line"
        case "$line" in
          "$FROZEN_ZY"*|*" $FROZEN_ZY "*) zy_present=1 ;;
        esac
        ;;
    esac
    if is_real_framecap_line "$line"; then
      printf '%s_FC_LINE=%s\n' "$phase" "$line"
      fc_n=$((fc_n + 1))
      [ -n "$fc_pid" ] || fc_pid="${line%% *}"
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
  printf '%s_SB_FROZEN_MATCH=%s\n' "$phase" "$([ "$sb_pid" = "$FROZEN_SB" ] && echo 1 || echo 0)"
  printf '%s_BB_FROZEN_MATCH=%s\n' "$phase" "$([ "$bb_pid" = "$FROZEN_BB" ] && echo 1 || echo 0)"
  printf '%s_FC_FROZEN_MATCH=%s\n' "$phase" "$([ "$fc_pid" = "$FROZEN_FC" ] && echo 1 || echo 0)"
  printf '%s_HOOKS_BEGIN\n' "$phase"
  cat "$VAR/.ziyan_hooks" 2>/dev/null
  printf '%s_HOOKS_END\n' "$phase"
  printf '%s_FRONT=%s\n' "$phase" "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)"
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
   [ "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)" != com.ziyan.ziyan ] ||
   [ "$PRECHECK_LATEST_RECORD_ID" != "$OLD_RECORD" ]; then
  blocked FROZEN_FRONT_AGENT_OR_OLD_RECORD_MISMATCH
fi

if [ -e "$VAR/.ziyan_agent_stop" ]; then
  blocked STOP_MARKER_PRESENT
fi

printf 'profile_id=agent_safe_toast\nbundle_id=com.ziyan.ziyan\ndisplay_name=安全动作\ngame_name=子砚\n' \
  > "$VAR/.ziyan_agent_current_profile"
printf 'mode=safe\n' > "$VAR/.ziyan_agent_req"
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
   [ "$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)" = com.ziyan.ziyan ] &&
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

read_only .101 192.168.31.101 /usr/lib/ziyan/var 87863 87862 47853 ags_17886027543490
read_only .112 192.168.31.112 /usr/lib/ziyan/var 79809 79808 98110 ags_17886027566825

readonly_ok=1
for tag in .101 .112; do
  if ! grep -qx 'READONLY_OK=1' "$OUT/$tag/READONLY.log"; then
    readonly_ok=0
  fi
done

overall=OK
if [ "$readonly_ok" = 1 ]; then
  run_one .166 192.168.31.166 rootful 25025 25024 52622 82626 ags_17886019287529 || overall=PARTIAL
  if [ "$overall" = OK ]; then
    run_one .53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886019413519 || overall=PARTIAL
  fi
else
  overall=PARTIAL
fi

{
  printf '# 八十补：.166/.53 mode=safe toast 一次\n\n'
  printf '.101/.112 只读复核，沿用八十号 safe_action 记录；本刀未写 profile，未跑 Lua。\n\n'
  for tag in .101 .112; do
    readonly="$(sed -n 's/^READONLY_OK=//p' "$OUT/$tag/READONLY.log" | tail -1)"
    record="$(sed -n 's/^READONLY_LATEST_RECORD_ID=//p' "$OUT/$tag/READONLY.log" | tail -1)"
    printf '%s: READONLY=%s LATEST_RECORD=%s\n' "$tag" "${readonly:-ABSENT}" "${record:-ABSENT}"
  done
  for tag in .166 .53; do
    log="$OUT/$tag/TRANSCRIPT.log"
    if [ -f "$log" ]; then
      smoke="$(sed -n 's/^SMOKE=//p' "$log" | tail -1)"
      old="$(sed -n 's/^PRECHECK_LATEST_RECORD_ID=//p' "$log" | tail -1)"
      new="$(sed -n 's/^NEW_RECORD_ID=//p' "$log" | tail -1)"
      toast="$(sed -n 's/^TOAST_WINDOW_AGENT_SAFE_ACTION_COUNT=//p' "$log" | tail -1)"
      printf '%s: SMOKE=%s PRECHECK_OLD=%s NEW_RECORD=%s TOAST_ONCE=%s\n' \
        "$tag" "${smoke:-NOT_RUN}" "${old:-ABSENT}" "${new:-ABSENT}" "${toast:-ABSENT}"
    else
      printf '%s: SMOKE=NOT_RUN\n' "$tag"
    fi
  done
  printf '\n'
  if [ "$overall" = OK ] &&
     grep -qx 'SMOKE=OK' "$OUT/.166/TRANSCRIPT.log" &&
     grep -qx 'SMOKE=OK' "$OUT/.53/TRANSCRIPT.log"; then
    printf 'AGENT_SMOKE_SAFE_TOAST=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_SMOKE_SAFE_TOAST=PARTIAL\n'
  fi
  printf 'NOT_TOAST_STORM=1\nNOT_REAL_CLICK=1\nNOT_MVP=1\nNO_SBRELOAD=1\n'
} > "$OUT/VERDICT.md"

cat "$OUT/VERDICT.md"

python3 tools/ziyan_codex_checkpoint.py write \
  --stage "八十补：只跑 .166/.53 mode=safe，toast agent_safe_action 至多一次" \
  --last-command "bash tools/zy_agent_smoke_safe_toast_80_retry.sh；.101/.112 仅读，严格串行 .166 -> .53" \
  --result "只补 .166/.53 的 run_safe_action；以 EIGHTY_RETRY VERDICT 与逐机 TRANSCRIPT 为准；不是 toast 风暴，不是真点击，不是 MVP" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/EIGHTY_RETRY_AGENT_SMOKE_SAFE_TOAST_20260905/VERDICT.md；.101/.112 READONLY.log；.166/.53 TRANSCRIPT.log" \
  --latest-verdict "$(sed -n 's/^AGENT_SMOKE_SAFE_TOAST=//p' "$OUT/VERDICT.md" | tail -1)" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包；沿用盘上既有版本" \
  --device-state "见 EIGHTY_RETRY_AGENT_SMOKE_SAFE_TOAST_20260905 逐机日志" \
  --running-processes "每台记录真实 FC_N、SB/BB 冻结、无真实 agent lua" \
  --cleanup-status "未写 open_app/user_closed/go_home；未 sbreload；停手等待人工最终审核"
