#!/usr/bin/env bash
# 二号开发：learn 安全门。严格 .101 -> .112 -> .166 -> .53 串行。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV02_AGENT_TRUE_LEARN_SAFE_GATE_20260905"
PASS="${ZY_SSH_PASS:-alpine}"
LEARN_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/学习数据"
RECORD_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"
REPORT_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/错误报告"

if [ -e "$OUT" ]; then
  printf 'evidence directory already exists: %s\n' "$OUT" >&2
  exit 2
fi
mkdir -p "$OUT"

SSH_KEY_OPTS=(
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=12
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)
SSH_PASS_OPTS=(
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=12
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

REMOTE=()
SCP_REMOTE=()
AUTH=""

connect_device() {
  local ip="$1"
  if ssh "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(ssh "${SSH_KEY_OPTS[@]}" "root@$ip")
    SCP_REMOTE=(scp "${SSH_KEY_OPTS[@]}")
    AUTH=publickey
    return 0
  fi
  if sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip")
    SCP_REMOTE=(sshpass -p "$PASS" scp "${SSH_PASS_OPTS[@]}")
    AUTH=password_fallback
    return 0
  fi
  return 1
}

remote_to_file() {
  local file="$1"
  local command="$2"
  "${REMOTE[@]}" "$command" </dev/null >"$file" 2>"$file.stderr"
}

copy_to_device() {
  local ip="$1"
  local source="$2"
  local target="$3"
  local log="$4"
  "${SCP_REMOTE[@]}" "$source" "root@$ip:$target" >"$log" 2>&1
}

read_value() {
  tr -d '\r\n' <"$1" 2>/dev/null || true
}

clean_ps_args() {
  case "$1" in
    *"sh -c"*|*"zsh -c"*|*"bash -s"*|*grep*|*sed*) return 1 ;;
  esac
  return 0
}

pid_for_args_ending() {
  local ps_file="$1"
  local suffix="$2"
  local line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    if [[ "$args" == *"$suffix" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done <"$ps_file"
}

count_for_args_ending() {
  local ps_file="$1"
  local suffix="$2"
  local line pid args n=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    [[ "$args" == *"$suffix" ]] && n=$((n + 1))
  done <"$ps_file"
  printf '%s\n' "$n"
}

frozen_zy_present() {
  local ps_file="$1"
  local frozen="$2"
  local line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    case "$args" in
      *ziyadaemond*|*ziyan_zydaemond*)
        [ "$pid" = "$frozen" ] && printf '1\n' && return 0
        ;;
    esac
  done <"$ps_file"
  printf '0\n'
}

real_agent_lua_n() {
  local ps_file="$1"
  local line pid args n=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    [[ "$args" == *lua5.3* && "$args" == *ziyan_agent_run.lua* ]] && n=$((n + 1))
  done <"$ps_file"
  printf '%s\n' "$n"
}

new_learn_ids() {
  local before="$1"
  local after="$2"
  comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after") |
    while IFS= read -r name; do
      case "$name" in
        ags_[A-Za-z0-9_]*.txt) printf '%s\n' "${name%.txt}" ;;
      esac
    done
}

session_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

write_transcript() {
  local out="$1"
  shift
  printf '%s\n' "$@" >>"$out/TRANSCRIPT.log"
}

capture_state() {
  local ip="$1"
  local var="$2"
  local dir="$3"
  local label="$4"
  mkdir -p "$dir"
  remote_to_file "$dir/profile.txt" "cat '$var/.ziyan_agent_current_profile'" || true
  remote_to_file "$dir/session.txt" "cat '$var/.ziyan_agent_session'" || true
  remote_to_file "$dir/front.txt" "cat '$var/.ziyan_front_bid'" || true
  remote_to_file "$dir/req.txt" "cat '$var/.ziyan_agent_req'" || true
  remote_to_file "$dir/hooks.txt" "cat '$var/.ziyan_hooks'" || true
  remote_to_file "$dir/learn_ls.txt" "ls -1 '$LEARN_ROOT'" || true
  remote_to_file "$dir/record_ls.txt" "ls -1 '$RECORD_ROOT'" || true
  remote_to_file "$dir/ps.txt" 'ps -A -o pid=,args=' || true

  local ps="$dir/ps.txt"
  local sb bb fc fc_n zy agent_n front state sid profile bundle
  sb="$(pid_for_args_ending "$ps" '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | head -n 1)"
  bb="$(pid_for_args_ending "$ps" 'backboardd' | head -n 1)"
  fc="$(pid_for_args_ending "$ps" 'ziyan_framecap serve' | head -n 1)"
  fc_n="$(count_for_args_ending "$ps" 'ziyan_framecap serve')"
  zy="$(frozen_zy_present "$ps" "$FROZEN_ZY_CURRENT")"
  agent_n="$(real_agent_lua_n "$ps")"
  front="$(read_value "$dir/front.txt")"
  state="$(session_value "$dir/session.txt" state)"
  sid="$(session_value "$dir/session.txt" session_id)"
  profile="$(session_value "$dir/profile.txt" profile_id)"
  bundle="$(session_value "$dir/profile.txt" bundle_id)"
  {
    printf '%s_SB_PID=%s\n' "$label" "$sb"
    printf '%s_BB_PID=%s\n' "$label" "$bb"
    printf '%s_FC_PID=%s\n' "$label" "$fc"
    printf '%s_FC_N=%s\n' "$label" "$fc_n"
    printf '%s_ZY_FROZEN_PRESENT=%s\n' "$label" "$zy"
    printf '%s_REAL_AGENT_LUA_N=%s\n' "$label" "$agent_n"
    printf '%s_FRONT=%s\n' "$label" "$front"
    printf '%s_SESSION_ID=%s\n' "$label" "$sid"
    printf '%s_SESSION_STATE=%s\n' "$label" "$state"
    printf '%s_PROFILE_ID=%s\n' "$label" "$profile"
    printf '%s_BUNDLE_ID=%s\n' "$label" "$bundle"
    printf '%s_FROZEN_MATCH=%s\n' "$label" \
      "$([[ "$sb" = "$FROZEN_SB_CURRENT" && "$bb" = "$FROZEN_BB_CURRENT" &&
           "$fc" = "$FROZEN_FC_CURRENT" && "$fc_n" = 1 && "$zy" = 1 ]] &&
          printf 1 || printf 0)"
  } >>"$dir/STATE.txt"
}

poll_run() {
  local ip="$1"
  local var="$2"
  local rc_file="$3"
  local session_file="$4"
  local poll_file="$5"
  local rc_blob state sid
  : >"$poll_file"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    rc_blob="$("${REMOTE[@]}" "printf 'RC='; cat '$rc_file' 2>/dev/null; printf '\nSESSION_BEGIN\n'; cat '$session_file' 2>/dev/null; printf 'SESSION_END\n'" 2>/dev/null || true)"
    printf 'POLL=%s\n%s\n' "$i" "$rc_blob" >>"$poll_file"
    state="$(printf '%s\n' "$rc_blob" | sed -n '/^SESSION_BEGIN$/,/^SESSION_END$/p' | sed -n 's/^state=//p' | head -n 1)"
    sid="$(printf '%s\n' "$rc_blob" | sed -n '/^SESSION_BEGIN$/,/^SESSION_END$/p' | sed -n 's/^session_id=//p' | head -n 1)"
    if printf '%s\n' "$rc_blob" | grep -q '^RC=[0-9][0-9]*$' &&
       [ "$state" = PAUSED_SAFE ] && [ -n "$sid" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_case() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local var="$4"
  local lua="$5"
  local run="$6"
  local agent="$7"
  local expected_reason="$8"
  local profile_mode="$9"
  local out="${CASE_OUT}/${tag}"
  local req="$var/.ziyan_agent_req"
  local profile_path="$var/.ziyan_agent_current_profile"
  local run_log="$var/.ziyan_agent_dev02_${tag}_run.log"
  local run_rc="$var/.ziyan_agent_dev02_${tag}_rc"
  local launch_cmd
  local pre_sid after_sid report
  local new_ids
  local case_ok=1

  mkdir -p "$out"
  capture_state "$ip" "$var" "$out/pre" PRE
  pre_sid="$(session_value "$out/pre/session.txt" session_id)"
  cp "$out/pre/learn_ls.txt" "$out/learn_before.txt"

  if [ "$profile_mode" = empty ]; then
    "${REMOTE[@]}" ": > '$profile_path'; printf '%s\n' 'mode=learn' > '$req'; chmod 666 '$profile_path' '$req' 2>/dev/null" \
      >"$out/mutate.log" 2>&1 || case_ok=0
  else
    "${REMOTE[@]}" "printf '%s\n' 'profile_id=agent_wrong_bundle' 'bundle_id=com.apple.Preferences' 'display_name=错包名' 'game_name=子砚' > '$profile_path'; printf '%s\n' 'mode=learn' > '$req'; chmod 666 '$profile_path' '$req' 2>/dev/null" \
      >"$out/mutate.log" 2>&1 || case_ok=0
  fi

  capture_state "$ip" "$var" "$out/armed" ARMED
  printf '%s\n' "profile_mode=$profile_mode" "request=mode=learn" >>"$out/STATE.txt"

  if [ "$scheme" = rootless ]; then
    launch_cmd="DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib '$lua' '$run' '$agent'"
  else
    launch_cmd="'$lua' '$run' '$agent'"
  fi
  "${REMOTE[@]}" "rm -f '$run_log' '$run_rc'; ( $launch_cmd > '$run_log' 2>&1; printf '%s\n' \"\$?\" > '$run_rc' ) & printf '%s\n' \"\$!\"" \
    >"$out/launch.txt" 2>&1 || case_ok=0
  poll_run "$ip" "$var" "$run_rc" "$var/.ziyan_agent_session" "$out/poll.log" || case_ok=0
  remote_to_file "$out/run.log" "cat '$run_log'" || true
  remote_to_file "$out/run.rc" "cat '$run_rc'" || true
  capture_state "$ip" "$var" "$out/post" POST

  after_sid="$(session_value "$out/post/session.txt" session_id)"
  if [ -n "$after_sid" ]; then
    report="$REPORT_ROOT/$after_sid.txt"
    remote_to_file "$out/report.txt" "cat '$report'" || true
  else
    : >"$out/report.txt"
  fi
  new_learn_ids "$out/pre/learn_ls.txt" "$out/post/learn_ls.txt" >"$out/new_learn_ids.txt"
  new_ids="$(tr '\n' ' ' <"$out/new_learn_ids.txt")"

  {
    printf 'EXPECTED_REASON=%s\n' "$expected_reason"
    printf 'NEW_LEARN_IDS=%s\n' "$new_ids"
    printf 'SESSION_CHANGED=%s\n' "$([[ -n "$after_sid" && "$after_sid" != "$pre_sid" ]] && printf 1 || printf 0)"
    printf 'RUN_RC=%s\n' "$(read_value "$out/run.rc")"
    printf 'REPORT_REASON_OK=%s\n' "$(
      grep -q '^error_code=PAUSED_SAFE$' "$out/report.txt" &&
      grep -q "^stop_reason=$expected_reason$" "$out/report.txt" &&
      grep -q "^paused=$expected_reason$" "$out/report.txt" &&
      printf 1 || printf 0)"
    printf 'NO_NEW_LEARN=%s\n' "$([ ! -s "$out/new_learn_ids.txt" ] && printf 1 || printf 0)"
  } >>"$out/STATE.txt"

  grep -q '^POST_FROZEN_MATCH=1$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_FC_N=1$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_REAL_AGENT_LUA_N=0$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_FRONT=com.ziyan.ziyan$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_SESSION_STATE=PAUSED_SAFE$' "$out/post/STATE.txt" || case_ok=0
  grep -q 'SESSION_CHANGED=1' "$out/STATE.txt" || case_ok=0
  grep -q 'RUN_RC=0' "$out/STATE.txt" || case_ok=0
  grep -q 'REPORT_REASON_OK=1' "$out/STATE.txt" || case_ok=0
  grep -q 'NO_NEW_LEARN=1' "$out/STATE.txt" || case_ok=0
  if [ "$profile_mode" = empty ]; then
    [ ! -s "$out/post/profile.txt" ] || case_ok=0
  else
    grep -q '^profile_id=agent_wrong_bundle$' "$out/post/profile.txt" || case_ok=0
    grep -q '^bundle_id=com.apple.Preferences$' "$out/post/profile.txt" || case_ok=0
  fi

  if [ "$case_ok" = 1 ]; then
    printf 'CASE=OK\n' >>"$out/STATE.txt"
    return 0
  fi
  printf 'CASE=FAIL\n' >>"$out/STATE.txt"
  return 1
}

restore_profile() {
  local ip="$1"
  local var="$2"
  local out="$3"
  copy_to_device "$ip" "$out/pre/profile.txt" "$var/.ziyan_agent_current_profile" "$out/restore.log"
  remote_to_file "$out/profile.restored.txt" "cat '$var/.ziyan_agent_current_profile'" || true
  cmp -s "$out/pre/profile.txt" "$out/profile.restored.txt"
}

run_one() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local sb="$4"
  local bb="$5"
  local fc="$6"
  local zy="$7"
  local var lua run agent
  local out="$OUT/${tag#.}"
  local ok=1
  CASE_OUT="$out"
  FROZEN_SB_CURRENT="$sb"
  FROZEN_BB_CURRENT="$bb"
  FROZEN_FC_CURRENT="$fc"
  FROZEN_ZY_CURRENT="$zy"
  mkdir -p "$out"
  : >"$out/TRANSCRIPT.log"

  if ! connect_device "$ip"; then
    write_transcript "$out" "AUTH=FAIL" "SMOKE=FAIL" "REASON=SSH_CONNECT"
    return 1
  fi
  write_transcript "$out" "AUTH=$AUTH"

  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
    lua=/var/jb/usr/lib/ziyan/bin/lua5.3
    run=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
    agent=/var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
  else
    var=/usr/lib/ziyan/var
    lua=/usr/lib/ziyan/bin/lua5.3
    run=/usr/lib/ziyan/lib/lua/ziyan_run.lua
    agent=/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
  fi

  capture_state "$ip" "$var" "$out/pre" PRE
  cp "$out/pre/profile.txt" "$out/profile_backup.txt"
  cat "$out/profile_backup.txt" >>"$out/TRANSCRIPT.log"
  if ! grep -q '^profile_id=agent_default_observe$' "$out/profile_backup.txt" ||
     ! grep -q '^bundle_id=com.ziyan.ziyan$' "$out/profile_backup.txt" ||
     ! grep -q '^PRE_FRONT=com.ziyan.ziyan$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_FROZEN_MATCH=1$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_FC_N=1$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_REAL_AGENT_LUA_N=0$' "$out/pre/STATE.txt"; then
    write_transcript "$out" "PRECHECK=FAIL" "SMOKE=FAIL" "REASON=PROFILE_FRONT_OR_FROZEN"
    return 1
  fi
  write_transcript "$out" "PRECHECK=OK"

  run_case no_profile "$ip" "$scheme" "$var" "$lua" "$run" "$agent" no_profile empty || ok=0
  if ! restore_profile "$ip" "$var" "$out/no_profile"; then
    ok=0
    write_transcript "$out" "RESTORE_AFTER_NO_PROFILE=FAIL"
  else
    write_transcript "$out" "RESTORE_AFTER_NO_PROFILE=OK"
  fi

  if [ "$ok" = 1 ]; then
    capture_state "$ip" "$var" "$out/between" BETWEEN
    grep -q '^BETWEEN_FROZEN_MATCH=1$' "$out/between/STATE.txt" || ok=0
    grep -q '^BETWEEN_REAL_AGENT_LUA_N=0$' "$out/between/STATE.txt" || ok=0
    grep -q '^BETWEEN_FRONT=com.ziyan.ziyan$' "$out/between/STATE.txt" || ok=0
    cmp -s "$out/profile_backup.txt" "$out/between/profile.txt" || ok=0
  fi

  if [ "$ok" = 1 ]; then
    run_case wrong_bundle "$ip" "$scheme" "$var" "$lua" "$run" "$agent" bundle_mismatch wrong || ok=0
    if ! restore_profile "$ip" "$var" "$out/wrong_bundle"; then
      ok=0
      write_transcript "$out" "RESTORE_AFTER_WRONG_BUNDLE=FAIL"
    else
      write_transcript "$out" "RESTORE_AFTER_WRONG_BUNDLE=OK"
    fi
  fi

  capture_state "$ip" "$var" "$out/final" FINAL
  cmp -s "$out/profile_backup.txt" "$out/final/profile.txt" || ok=0
  grep -q '^FINAL_PROFILE_ID=agent_default_observe$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_BUNDLE_ID=com.ziyan.ziyan$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_FROZEN_MATCH=1$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_FC_N=1$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_REAL_AGENT_LUA_N=0$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_FRONT=com.ziyan.ziyan$' "$out/final/STATE.txt" || ok=0

  if [ "$ok" = 1 ]; then
    write_transcript "$out" "SMOKE=OK"
    return 0
  fi
  write_transcript "$out" "SMOKE=FAIL"
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

{
  printf '# 二号开发：真学习安全门\n\n'
  printf '这是二号开发安全门，不是一号补重做；不是真自研、不是真演练；不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload。\n\n'
  for tag in 101 112 166 53; do
    printf '## .%s\n\n' "$tag"
    if [ -f "$OUT/$tag/TRANSCRIPT.log" ]; then
      grep -E '^(AUTH|PRECHECK|RESTORE_|SMOKE|REASON)=' "$OUT/$tag/TRANSCRIPT.log" || true
      grep -hE '^(CASE|EXPECTED_REASON|NEW_LEARN_IDS|SESSION_CHANGED|RUN_RC|REPORT_REASON_OK|NO_NEW_LEARN)=' \
        "$OUT/$tag"/no_profile/STATE.txt "$OUT/$tag"/wrong_bundle/STATE.txt 2>/dev/null || true
    else
      printf 'SMOKE=NOT_RUN\n'
    fi
    printf '\n'
  done
  printf 'NOT_AGENT_MVP_4PHONE_PASS=1\nNOT_G0=1\nNO_SBRELOAD_EXECUTED=1\n'
  if [ "$serial_ok" = 1 ]; then
    printf 'AGENT_TRUE_LEARN_SAFE_GATE=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_TRUE_LEARN_SAFE_GATE=PARTIAL_PENDING_HUMAN\n'
    printf 'REASON=see per-device TRANSCRIPT.log and STATE.txt\n'
  fi
} >"$OUT/VERDICT.md"

python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "二号开发：真学习安全门；空 profile 与错 bundle 均 PAUSED_SAFE" \
  --last-command "tools/zy_dev02_agent_true_learn_safe_gate.sh 串行执行 .101 -> .112 -> .166 -> .53" \
  --result "$([ "$serial_ok" = 1 ] && printf '四机空 profile/no_profile 与错 bundle/bundle_mismatch 均 PAUSED_SAFE；两步均无新学习文件；profile 已恢复；冻结 MATCH；未 sbreload。' || printf '二号开发安全门未四机全通过；已按串行规则停止后续设备；未 sbreload。')" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV02_AGENT_TRUE_LEARN_SAFE_GATE_20260905/VERDICT.md；四机 TRANSCRIPT.log、STATE.txt、report.txt、学习目录前后清单与 ps 原文" \
  --latest-verdict "$([ "$serial_ok" = 1 ] && printf 'AGENT_TRUE_LEARN_SAFE_GATE=PASS_PENDING_HUMAN' || printf 'AGENT_TRUE_LEARN_SAFE_GATE=PARTIAL_PENDING_HUMAN')" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未触碰包" \
  --device-state "严格串行；空 profile 与错 bundle 各运行一次 learn；profile 原文已逐步恢复；未 Home/设置/游戏；.53 冻结 zy 93705 仍按冻结 PID 判定" \
  --running-processes "SpringBoard 仅本机按完整路径结尾筛选；FC_N 仅本机按 ziyan_framecap serve 结尾筛选；残留仅本机按 lua5.3 与 ziyan_agent_run.lua 同时筛选" \
  --cleanup-status "每步入口结束后核对 PAUSED_SAFE、无真实 agent lua、冻结 MATCH；最终 profile=agent_default_observe/com.ziyan.ziyan；停手等待人工最终审核"

printf '%s\n' "$OUT/VERDICT.md"
exit "$([ "$serial_ok" = 1 ] && printf 0 || printf 1)"
