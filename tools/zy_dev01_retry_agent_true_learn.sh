#!/usr/bin/env bash
# 一号开发补：只运行一次 mode=learn，所有 ps 筛选均在本机完成。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV01_RETRY_AGENT_TRUE_LEARN_20260905"
SOURCE="$ROOT/Agent/Core/agent_runtime.lua"
PASS="${ZY_SSH_PASS:-alpine}"
LEARN_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/学习数据"
RECORD_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"

if [ -e "$OUT" ]; then
  printf 'evidence directory already exists: %s\n' "$OUT" >&2
  exit 2
fi
if [ ! -f "$SOURCE" ]; then
  printf 'runtime source missing: %s\n' "$SOURCE" >&2
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

copy_from_device() {
  local ip="$1"
  local source="$2"
  local target="$3"
  local log="$4"
  "${SCP_REMOTE[@]}" "root@$ip:$source" "$target" >"$log" 2>&1
}

copy_to_device() {
  local ip="$1"
  local source="$2"
  local target="$3"
  local log="$4"
  "${SCP_REMOTE[@]}" "$source" "root@$ip:$target" >"$log" 2>&1
}

clean_ps_args() {
  local args="$1"
  case "$args" in
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

pid_for_zydaemon() {
  local ps_file="$1"
  local line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    case "$args" in
      *ziyadaemond*|*ziyan_zydaemond*) printf '%s\n' "$pid" ;;
    esac
  done <"$ps_file"
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

matching_new_ids() {
  local before="$1"
  local after="$2"
  comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after") |
    while IFS= read -r name; do
      case "$name" in
        ags_[A-Za-z0-9_]*.txt) printf '%s\n' "${name%.txt}" ;;
      esac
    done
}

read_value() {
  local file="$1"
  tr -d '\r\n' <"$file" 2>/dev/null || true
}

record_processes() {
  local out="$1"
  local phase="$2"
  local frozen_sb="$3"
  local frozen_bb="$4"
  local frozen_fc="$5"
  local frozen_zy="$6"
  local ps="$out/ps_${phase}.txt"
  local sb bb fc fc_n zy agent_n

  if ! remote_to_file "$ps" 'ps -A -o pid=,args='; then
    printf '%s_PS_READ=FAIL\n' "$phase" >>"$out/TRANSCRIPT.log"
    return 1
  fi
  sb="$(pid_for_args_ending "$ps" '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | head -n 1)"
  bb="$(pid_for_args_ending "$ps" 'backboardd' | head -n 1)"
  fc="$(pid_for_args_ending "$ps" 'ziyan_framecap serve' | head -n 1)"
  fc_n="$(count_for_args_ending "$ps" 'ziyan_framecap serve')"
  zy="$(pid_for_zydaemon "$ps" | head -n 1)"
  agent_n="$(real_agent_lua_n "$ps")"
  {
    printf '%s_SB_PID=%s\n%s_BB_PID=%s\n' "$phase" "$sb" "$phase" "$bb"
    printf '%s_FC_PID=%s\n%s_FC_N=%s\n' "$phase" "$fc" "$phase" "$fc_n"
    printf '%s_ZY_PID=%s\n%s_REAL_AGENT_LUA_N=%s\n' "$phase" "$zy" "$phase" "$agent_n"
    printf '%s_FROZEN_MATCH=%s\n' "$phase" \
      "$([[ "$sb" = "$frozen_sb" && "$bb" = "$frozen_bb" && "$fc" = "$frozen_fc" && "$zy" = "$frozen_zy" ]] && printf 1 || printf 0)"
  } >>"$out/TRANSCRIPT.log"
  [ "$sb" = "$frozen_sb" ] &&
    [ "$bb" = "$frozen_bb" ] &&
    [ "$fc" = "$frozen_fc" ] &&
    [ "$fc_n" = 1 ] &&
    [ "$zy" = "$frozen_zy" ] &&
    [ "$agent_n" = 0 ]
}

run_one() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local frozen_sb="$4"
  local frozen_bb="$5"
  local frozen_fc="$6"
  local frozen_zy="$7"
  local var runtime run_cmd out front bundle profile req session
  local start_s end_s run_rc learn_id record_id new_learn_n new_record_n smoke=0

  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
    runtime=/var/jb/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
    run_cmd='DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua /var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua'
  else
    var=/usr/lib/ziyan/var
    runtime=/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
    run_cmd='/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua /usr/lib/ziyan/lib/lua/ziyan_agent_run.lua'
  fi
  out="$OUT/${tag#.}"
  mkdir -p "$out"
  : >"$out/TRANSCRIPT.log"

  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nPRECHECK=FAIL\nREASON=SSH_CONNECT\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  remote_to_file "$out/ziyan_hooks.txt" "cat '$var/.ziyan_hooks'" || true
  remote_to_file "$out/ziyan_agent_current_profile.before.txt" "cat '$var/.ziyan_agent_current_profile'" || true
  remote_to_file "$out/ziyan_front_bid.before.txt" "cat '$var/.ziyan_front_bid'" || true
  remote_to_file "$out/ziyan_frame_seq.before.txt" "cat '$var/.ziyan_frame_seq'" || true
  remote_to_file "$out/ziyan_agent_session.before.txt" "cat '$var/.ziyan_agent_session'" || true
  front="$(read_value "$out/ziyan_front_bid.before.txt")"
  bundle="$(sed -n 's/^bundle_id=//p' "$out/ziyan_agent_current_profile.before.txt" | head -n 1)"
  profile="$(sed -n 's/^profile_id=//p' "$out/ziyan_agent_current_profile.before.txt" | head -n 1)"
  {
    printf 'PRE_FRONT=%s\nPRE_BUNDLE=%s\nPRE_PROFILE_ID=%s\n' "$front" "$bundle" "$profile"
    printf 'PROFILE_NAME_ACCEPTED=%s\n' "$([[ -n "$profile" ]] && printf 1 || printf 0)"
  } >>"$out/TRANSCRIPT.log"
  if ! record_processes "$out" PRE "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"; then
    printf 'PRECHECK=FAIL\nREASON=FROZEN_OR_RESIDUAL\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if [ "$front" != com.ziyan.ziyan ] || [ "$bundle" != com.ziyan.ziyan ]; then
    printf 'PRECHECK=FAIL\nREASON=FRONT_OR_BUNDLE\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if ! copy_from_device "$ip" "$runtime" "$out/agent_runtime.before.lua" "$out/scp_backup.log"; then
    printf 'PRECHECK=FAIL\nREASON=BACKUP_FAILED\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if ! remote_to_file "$out/learn_before_ls.txt" "ls -1 '$LEARN_ROOT'"; then
    printf 'PRECHECK=FAIL\nREASON=LEARN_DIR_UNREADABLE\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if ! remote_to_file "$out/record_before_ls.txt" "ls -1 '$RECORD_ROOT'"; then
    printf 'PRECHECK=FAIL\nREASON=RECORD_DIR_UNREADABLE\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'PRECHECK=OK\n' >>"$out/TRANSCRIPT.log"

  if ! copy_to_device "$ip" "$SOURCE" "$runtime" "$out/scp_deploy.log"; then
    printf 'DEPLOY=FAIL\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if ! copy_from_device "$ip" "$runtime" "$out/agent_runtime.deployed.lua" "$out/scp_verify.log" ||
    ! cmp -s "$SOURCE" "$out/agent_runtime.deployed.lua"; then
    printf 'DEPLOY=FAIL\nREASON=RUNTIME_VERIFY\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'DEPLOY=OK\n' >>"$out/TRANSCRIPT.log"

  if ! remote_to_file "$out/ziyan_agent_req.write.txt" "printf 'mode=learn\n' > '$var/.ziyan_agent_req'"; then
    printf 'REQ_WRITE=FAIL\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if ! remote_to_file "$out/ziyan_agent_req.txt" "cat '$var/.ziyan_agent_req'" ||
    ! cmp -s <(printf 'mode=learn\n') "$out/ziyan_agent_req.txt"; then
    printf 'REQ_WRITE=FAIL\nREASON=REQ_NOT_EXACT_LEARN\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'REQ_EXACT=mode=learn\n' >>"$out/TRANSCRIPT.log"

  start_s="$(date +%s)"
  run_rc=0
  remote_to_file "$out/run.stdout.txt" "$run_cmd" || run_rc=$?
  end_s="$(date +%s)"
  printf 'RUN_RC=%s\nRUN_SECONDS=%s\n' "$run_rc" "$((end_s - start_s))" >>"$out/TRANSCRIPT.log"
  if [ "$run_rc" != 0 ] || [ "$((end_s - start_s))" -gt 15 ]; then
    printf 'RUN=FAIL\nREASON=RUN_RC_OR_DURATION\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi

  remote_to_file "$out/ziyan_agent_session.after.txt" "cat '$var/.ziyan_agent_session'" || true
  remote_to_file "$out/ziyan_front_bid.after.txt" "cat '$var/.ziyan_front_bid'" || true
  remote_to_file "$out/ziyan_agent_current_profile.after.txt" "cat '$var/.ziyan_agent_current_profile'" || true
  if ! remote_to_file "$out/learn_after_ls.txt" "ls -1 '$LEARN_ROOT'" ||
    ! remote_to_file "$out/record_after_ls.txt" "ls -1 '$RECORD_ROOT'"; then
    printf 'POSTCHECK=FAIL\nREASON=ARTIFACT_DIR_UNREADABLE\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  learn_ids=()
  while IFS= read -r id; do
    [ -n "$id" ] && learn_ids+=("$id")
  done < <(matching_new_ids "$out/learn_before_ls.txt" "$out/learn_after_ls.txt")
  record_ids=()
  while IFS= read -r id; do
    [ -n "$id" ] && record_ids+=("$id")
  done < <(matching_new_ids "$out/record_before_ls.txt" "$out/record_after_ls.txt")
  new_learn_n="${#learn_ids[@]}"
  new_record_n="${#record_ids[@]}"
  learn_id="${learn_ids[0]:-}"
  record_id="${record_ids[0]:-}"
  {
    printf 'NEW_LEARN_N=%s\nNEW_RECORD_N=%s\n' "$new_learn_n" "$new_record_n"
    printf 'LEARN_SESSION_ID=%s\nRECORD_SESSION_ID=%s\n' "$learn_id" "$record_id"
  } >>"$out/TRANSCRIPT.log"
  if [ "$new_learn_n" != 1 ] || [ "$new_record_n" != 1 ] || [ "$learn_id" != "$record_id" ]; then
    printf 'POSTCHECK=FAIL\nREASON=NEW_ARTIFACT_COUNT_OR_ID\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  remote_to_file "$out/learn_${learn_id}.txt" "cat '$LEARN_ROOT/$learn_id.txt'" || true
  remote_to_file "$out/record_${record_id}.txt" "cat '$RECORD_ROOT/$record_id.txt'" || true

  if ! record_processes "$out" POST "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"; then
    printf 'POSTCHECK=FAIL\nREASON=FROZEN_OR_RESIDUAL\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  front="$(read_value "$out/ziyan_front_bid.after.txt")"
  bundle="$(sed -n 's/^bundle_id=//p' "$out/ziyan_agent_current_profile.after.txt" | head -n 1)"
  if [ "$front" != com.ziyan.ziyan ] || [ "$bundle" != com.ziyan.ziyan ]; then
    printf 'POSTCHECK=FAIL\nREASON=FRONT_OR_BUNDLE\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if ! grep -qx 'state=STOPPED' "$out/ziyan_agent_session.after.txt" ||
    ! grep -qx 'active=0' "$out/ziyan_agent_session.after.txt" ||
    ! grep -qx 'front_bid=com.ziyan.ziyan' "$out/learn_${learn_id}.txt" ||
    ! grep -Eq '^frame_seq=[1-9][0-9]*$' "$out/learn_${learn_id}.txt" ||
    ! grep -qx 'bundle_id=com.ziyan.ziyan' "$out/learn_${learn_id}.txt" ||
    ! grep -q '^profile_id=.+$' "$out/learn_${learn_id}.txt" ||
    ! grep -Eq '^ts=[0-9]+$' "$out/learn_${learn_id}.txt" ||
    ! grep -q 'STOPPED .*mode=learn' "$out/record_${record_id}.txt" ||
    grep -Eq 'learn_delegate_app|learn_owned_by_app' \
      "$out/run.stdout.txt" "$out/ziyan_agent_session.after.txt" "$out/record_${record_id}.txt"; then
    printf 'POSTCHECK=FAIL\nREASON=LEARN_SEMANTICS\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  smoke=1
  [ "$smoke" = 1 ] && printf 'POSTCHECK=OK\nSMOKE=OK\n' >>"$out/TRANSCRIPT.log"
  return 0
}

all_ok=1
reasons=()
run_one .101 192.168.31.101 rootful 87863 87862 47853 96 || {
  all_ok=0
  reasons+=(".101")
}
if [ "$all_ok" = 1 ]; then
  run_one .112 192.168.31.112 rootful 79809 79808 98110 92 || {
    all_ok=0
    reasons+=(".112")
  }
fi
if [ "$all_ok" = 1 ]; then
  run_one .166 192.168.31.166 rootful 25025 25024 52622 82626 || {
    all_ok=0
    reasons+=(".166")
  }
fi
if [ "$all_ok" = 1 ]; then
  run_one .53 192.168.31.53 rootless 46408 74318 49176 93705 || {
    all_ok=0
    reasons+=(".53")
  }
fi

{
  printf '# 一号开发补：真学习最小切片四机补跑\n\n'
  printf '这是**一号开发补跑**，不是八十六只读汇总；不是真自研，不是真演练。\n\n'
  printf '本刀只备份并替换 `agent_runtime.lua`，写入精确 `mode=learn` 请求，前台运行一次入口；未 sbreload、未 dpkg、未改 profile、未操作游戏。\n\n'
  for tag in 101 112 166 53; do
    printf '## .%s\n\n' "$tag"
    if [ -f "$OUT/$tag/TRANSCRIPT.log" ]; then
      grep -E '^(AUTH|PRECHECK|DEPLOY|REQ_EXACT|RUN_RC|RUN_SECONDS|NEW_LEARN_N|NEW_RECORD_N|LEARN_SESSION_ID|RECORD_SESSION_ID|POSTCHECK|SMOKE|REASON|PRE_FROZEN_MATCH|POST_FROZEN_MATCH|PRE_FC_N|POST_FC_N|PRE_REAL_AGENT_LUA_N|POST_REAL_AGENT_LUA_N)=' \
        "$OUT/$tag/TRANSCRIPT.log" || true
    else
      printf 'SMOKE=NOT_RUN\n'
    fi
    printf '\n'
  done
  printf 'NOT_TRUE_RESEARCH=1\nNOT_TRUE_DRILL=1\nNOT_AGENT_MVP_4PHONE_PASS=1\nNOT_G0=1\nNO_SBRELOAD_EXECUTED=1\n'
  if [ "$all_ok" = 1 ]; then
    printf 'AGENT_TRUE_LEARN=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_TRUE_LEARN=PARTIAL_PENDING_HUMAN\nREASON=%s\n' "$(IFS=,; printf '%s' "${reasons[*]}")"
  fi
} >"$OUT/VERDICT.md"

if [ "$all_ok" = 1 ]; then
  latest='AGENT_TRUE_LEARN=PASS_PENDING_HUMAN'
  result='四机串行真学习均 SMOKE=OK；每台新学习文件、mode=learn 运行记录、STOPPED、冻结与 FC_N=1 已由本刀证据记录；未 sbreload；等待人工最终审核。'
else
  latest='AGENT_TRUE_LEARN=PARTIAL_PENDING_HUMAN'
  result="串行停在 ${reasons[*]}；仅已完成设备以本刀 TRANSCRIPT 为准；未 sbreload；等待人工最终审核。"
fi
python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "一号开发补：真学习最小切片四机补跑" \
  --last-command "bash tools/zy_dev01_retry_agent_true_learn.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "$result" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV01_RETRY_AGENT_TRUE_LEARN_20260905/VERDICT.md；四机 TRANSCRIPT.log；每台运行前备份与部署后 agent_runtime.lua" \
  --latest-verdict "$latest" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包" \
  --device-state "严格串行；仅本地筛选 ps；冻结不匹配或残留即停止后续设备；未 sbreload" \
  --running-processes "SpringBoard args 仅完整路径结尾；FC_N 仅 ziyan_framecap serve 结尾；真实 agent lua 同时含 lua5.3 与 ziyan_agent_run.lua" \
  --cleanup-status "每台完成即 STOPPED；未 sbreload/ldrestart/killall/dpkg；停手等待人工最终审核"

printf '%s\n' "$OUT/VERDICT.md"
