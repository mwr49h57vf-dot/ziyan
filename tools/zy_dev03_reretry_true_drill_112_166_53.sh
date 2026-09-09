#!/usr/bin/env bash
# 三号开发再补续：.101 合同成立后，仅串行执行 .112 -> .166 -> .53。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV03_RERETRY_CONTINUE_20260906"
PASS="${ZY_SSH_PASS:-alpine}"
SOURCE="$ROOT/Agent/Core/agent_runtime.lua"

mkdir -p "$OUT"

SSH_KEY_OPTS=(
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
  -o KbdInteractiveAuthentication=no
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
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
  "${SCP_REMOTE[@]}" "$source" "root@$ip:$target"
}

pid_present() {
  local ps_file="$1"
  local wanted="$2"
  awk -v wanted="$wanted" '$1 == wanted { found=1 } END { print found + 0 }' "$ps_file"
}

sb_pid() {
  awk '
    /(^|[[:space:]])(sh|zsh|bash)[[:space:]]+-[cs]([[:space:]]|$)/ { next }
    /(^|[[:space:]])(grep|sed)([[:space:]]|$)/ { next }
    /\/System\/Library\/CoreServices\/SpringBoard\.app\/SpringBoard$/ {
      sub(/^[[:space:]]*/, "", $0); print $1; exit
    }'
}

bb_pid() {
  awk '
    /(^|[[:space:]])(sh|zsh|bash)[[:space:]]+-[cs]([[:space:]]|$)/ { next }
    /(^|[[:space:]])(grep|sed)([[:space:]]|$)/ { next }
    /(^|\/)backboardd$/ {
      sub(/^[[:space:]]*/, "", $0); print $1; exit
    }'
}

fc_count() {
  awk '
    /(^|[[:space:]])(sh|zsh|bash)[[:space:]]+-[cs]([[:space:]]|$)/ { next }
    /(^|[[:space:]])(grep|sed)([[:space:]]|$)/ { next }
    /ziyan_framecap[[:space:]]serve$/ { n++ }
    END { print n + 0 }'
}

fc_pid() {
  awk '
    /(^|[[:space:]])(sh|zsh|bash)[[:space:]]+-[cs]([[:space:]]|$)/ { next }
    /(^|[[:space:]])(grep|sed)([[:space:]]|$)/ { next }
    /ziyan_framecap[[:space:]]serve$/ {
      sub(/^[[:space:]]*/, "", $0); print $1; exit
    }'
}

agent_count() {
  awk '
    /(^|[[:space:]])(sh|zsh|bash)[[:space:]]+-[cs]([[:space:]]|$)/ { next }
    /(^|[[:space:]])(grep|sed)([[:space:]]|$)/ { next }
    /lua5\.3/ && /ziyan_agent_run\.lua/ { n++ }
    END { print n + 0 }'
}

list_true_files() {
  local ip="$1"
  local path="$2"
  "${REMOTE[@]}" "$ip" 2>/dev/null
}

run_one() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local frozen_sb="$4"
  local frozen_bb="$5"
  local frozen_fc="$6"
  local frozen_zy="$7"
  local learn_id="$8"
  local out="$OUT/$tag"
  local var target tmp lua run agent launch backup local_sha remote_sha
  local ps pre_sb pre_bb pre_fc pre_fc_pid pre_zy front profile
  local record_before learn_before record_after learn_after new_record
  local run_log run_rc start_log run_rc_value session_body stop_marker
  local after_ps after_sb after_bb after_fc after_fc_pid after_zy agent_n
  local elapsed=0 start_epoch

  mkdir -p "$out"
  : >"$out/TRANSCRIPT.log"
  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
    target=/var/jb/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
    tmp=/var/jb/usr/lib/ziyan/lib/lua/agent/.agent_runtime.lua.drill.tmp
    lua=/var/jb/usr/lib/ziyan/bin/lua5.3
    run=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
    agent=/var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
  else
    var=/usr/lib/ziyan/var
    target=/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
    tmp=/usr/lib/ziyan/lib/lua/agent/.agent_runtime.lua.drill.tmp
    lua=/usr/lib/ziyan/bin/lua5.3
    run=/usr/lib/ziyan/lib/lua/ziyan_run.lua
    agent=/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
  fi
  if [ "$scheme" = rootless ]; then
    launch="DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib '$lua' '$run' '$agent'"
  else
    launch="'$lua' '$run' '$agent'"
  fi
  printf 'TAG=%s IP=%s SCHEME=%s LEARN_ID=%s\n' "$tag" "$ip" "$scheme" "$learn_id" >>"$out/TRANSCRIPT.log"

  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nSMOKE=FAIL\nREASON=ssh_connect\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  remote_to_file "$out/PRECHECK_PS.log" 'ps -A -o pid=,args=' || {
    printf 'SMOKE=FAIL\nREASON=precheck_ps\n' >>"$out/TRANSCRIPT.log"
    return 1
  }
  ps="$out/PRECHECK_PS.log"
  pre_sb=$(sb_pid <"$ps")
  pre_bb=$(bb_pid <"$ps")
  pre_fc=$(fc_count <"$ps")
  pre_fc_pid=$(fc_pid <"$ps")
  pre_zy=$(pid_present "$ps" "$frozen_zy")
  front="$("${REMOTE[@]}" "cat '$var/.ziyan_front_bid' 2>/dev/null" | tr -d '\r\n')"
  printf 'PRE_SB=%s\nPRE_BB=%s\nPRE_FC=%s\nPRE_FC_N=%s\nPRE_ZY_FROZEN_PRESENT=%s\nPRE_FRONT=%s\n' \
    "$pre_sb" "$pre_bb" "$pre_fc_pid" "$pre_fc" "$pre_zy" "$front" >>"$out/TRANSCRIPT.log"
  if [ "$pre_sb" != "$frozen_sb" ] || [ "$pre_bb" != "$frozen_bb" ] ||
     [ "$pre_fc_pid" != "$frozen_fc" ] || [ "$pre_fc" != 1 ] ||
     [ "$pre_zy" != 1 ] || [ "$front" != com.ziyan.ziyan ]; then
    printf 'SMOKE=FAIL\nREASON=precheck_frozen_or_front\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi

  local_sha=$(shasum -a 256 "$SOURCE" | awk '{print $1}')
  remote_sha="$("${REMOTE[@]}" "sha256sum '$target' 2>/dev/null" | awk '{print $1}')"
  backup="$target.drill-backup.$(date +%Y%m%d%H%M%S)"
  printf 'RUNTIME_SHA_LOCAL=%s\nRUNTIME_SHA_REMOTE_BEFORE=%s\nRUNTIME_BACKUP=%s\n' \
    "$local_sha" "$remote_sha" "$backup" >>"$out/TRANSCRIPT.log"
  if ! "${REMOTE[@]}" "cp '$target' '$backup'"; then
    printf 'SMOKE=FAIL\nREASON=runtime_backup\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if [ "$remote_sha" != "$local_sha" ]; then
    if ! copy_to_device "$ip" "$SOURCE" "$tmp" ||
       ! "${REMOTE[@]}" "mv '$tmp' '$target'"; then
      printf 'SMOKE=FAIL\nREASON=runtime_upload\n' >>"$out/TRANSCRIPT.log"
      return 1
    fi
    printf 'RUNTIME_UPLOAD=1\n' >>"$out/TRANSCRIPT.log"
  else
    printf 'RUNTIME_UPLOAD=SKIPPED_SHA_MATCH\n' >>"$out/TRANSCRIPT.log"
  fi
  remote_sha="$("${REMOTE[@]}" "sha256sum '$target' 2>/dev/null" | awk '{print $1}')"
  printf 'RUNTIME_SHA_REMOTE_AFTER=%s\n' "$remote_sha" >>"$out/TRANSCRIPT.log"
  if [ "$remote_sha" != "$local_sha" ]; then
    printf 'SMOKE=FAIL\nREASON=runtime_sha_after\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi

  profile="$("${REMOTE[@]}" "cat '$var/.ziyan_agent_current_profile' 2>/dev/null")"
  printf '%s\n' "$profile" >"$out/PROFILE_BEFORE.txt"
  if ! printf '%s\n' "$profile" | grep -q '^bundle_id=com\.ziyan\.ziyan$'; then
    printf 'SMOKE=FAIL\nREASON=profile_bundle\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  record_before="$out/RECORDS_BEFORE.txt"
  learn_before="$out/LEARN_BEFORE.txt"
  "${REMOTE[@]}" "find '/private/var/mobile/Media/ZiYan/Agent游戏/运行记录' -maxdepth 1 -type f -name 'ags_*.txt' -print" |
    sort >"$record_before"
  "${REMOTE[@]}" "find '/private/var/mobile/Media/ZiYan/Agent游戏/学习数据' -maxdepth 1 -type f -name 'ags_*.txt' -print" |
    sort >"$learn_before"

  if ! "${REMOTE[@]}" "printf '%s\\n' '$learn_id' > '$var/.ziyan_drill_learn_id' && printf 'mode=drill\\n' > '$var/.ziyan_agent_req'"; then
    printf 'SMOKE=FAIL\nREASON=request_write\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'REQ_WRITTEN=mode=drill\nLEARN_ID_WRITTEN=%s\n' "$learn_id" >>"$out/TRANSCRIPT.log"

  run_log="$var/.ziyan_agent_true_drill_run.log"
  run_rc="$var/.ziyan_agent_true_drill_rc"
  start_epoch=$(date +%s)
  "${REMOTE[@]}" "rm -f '$run_log' '$run_rc' '$var/.ziyan_agent_stop'; ( $launch; printf '%s\\n' \$? > '$run_rc' ) > '$run_log' 2>&1 & launch_pid=\$!; printf 'stop=1\\n' > '$var/.ziyan_agent_stop'; chmod 666 '$var/.ziyan_agent_stop' 2>/dev/null; printf 'LAUNCH_PID=%s\\n' \$launch_pid" \
    >"$out/START.log" 2>&1
  cat "$out/START.log" >>"$out/TRANSCRIPT.log"
  printf 'STOP_WRITE=IMMEDIATE_AFTER_BACKGROUND_START\n' >>"$out/TRANSCRIPT.log"

  while [ "$elapsed" -lt 15 ]; do
    sleep 1
    elapsed=$(( $(date +%s) - start_epoch ))
    session_body="$("${REMOTE[@]}" "cat '$var/.ziyan_agent_session' 2>/dev/null")"
    agent_n="$("${REMOTE[@]}" 'ps -A -o pid=,args=' | agent_count)"
    printf 'POLL=%ss SESSION=%s REAL_AGENT_LUA_N=%s\n' "$elapsed" \
      "$(printf '%s\n' "$session_body" | sed -n 's/^state=//p' | head -1)" "$agent_n" >>"$out/TRANSCRIPT.log"
    if printf '%s\n' "$session_body" | grep -q '^state=STOPPED$' && [ "$agent_n" = 0 ]; then
      break
    fi
  done

  remote_to_file "$out/AFTER_PS.log" 'ps -A -o pid=,args='
  after_ps="$out/AFTER_PS.log"
  after_sb=$(sb_pid <"$after_ps")
  after_bb=$(bb_pid <"$after_ps")
  after_fc=$(fc_count <"$after_ps")
  after_fc_pid=$(fc_pid <"$after_ps")
  after_zy=$(pid_present "$after_ps" "$frozen_zy")
  agent_n=$(agent_count <"$after_ps")
  session_body="$("${REMOTE[@]}" "cat '$var/.ziyan_agent_session' 2>/dev/null")"
  stop_marker="$("${REMOTE[@]}" "test -e '$var/.ziyan_agent_stop' && echo PRESENT || echo ABSENT")"
  run_rc_value="$("${REMOTE[@]}" "cat '$run_rc' 2>/dev/null" | tr -d '\r\n')"
  printf '%s\n' "$session_body" >"$out/SESSION_AFTER.txt"
  printf '%s\n' "$("${REMOTE[@]}" "cat '$run_log' 2>/dev/null" | tail -80)" >"$out/RUN_LOG.txt"
  record_after="$out/RECORDS_AFTER.txt"
  learn_after="$out/LEARN_AFTER.txt"
  "${REMOTE[@]}" "find '/private/var/mobile/Media/ZiYan/Agent游戏/运行记录' -maxdepth 1 -type f -name 'ags_*.txt' -print" |
    sort >"$record_after"
  "${REMOTE[@]}" "find '/private/var/mobile/Media/ZiYan/Agent游戏/学习数据' -maxdepth 1 -type f -name 'ags_*.txt' -print" |
    sort >"$learn_after"
  new_record=$(comm -13 "$record_before" "$record_after" | head -1)
  if [ -n "$new_record" ]; then
    "${REMOTE[@]}" "cat '$new_record'" >"$out/RUN_RECORD.txt" 2>"$out/RUN_RECORD.stderr"
  else
    : >"$out/RUN_RECORD.txt"
  fi
  printf 'AFTER_SB=%s\nAFTER_BB=%s\nAFTER_FC=%s\nAFTER_FC_N=%s\nAFTER_ZY_FROZEN_PRESENT=%s\nREAL_AGENT_LUA_N=%s\nSTOP_MARKER=%s\nRUN_RC=%s\nNEW_RECORD=%s\n' \
    "$after_sb" "$after_bb" "$after_fc_pid" "$after_fc" "$after_zy" "$agent_n" "$stop_marker" "$run_rc_value" "$new_record" >>"$out/TRANSCRIPT.log"

  if [ "$after_sb" = "$frozen_sb" ] && [ "$after_bb" = "$frozen_bb" ] &&
     [ "$after_fc_pid" = "$frozen_fc" ] && [ "$after_fc" = 1 ] &&
     [ "$after_zy" = 1 ] && [ "$agent_n" = 0 ] &&
     [ "$stop_marker" = ABSENT ] && printf '%s\n' "$session_body" | grep -q '^state=STOPPED$' &&
     [ "$run_rc_value" = 0 ] && cmp -s "$learn_before" "$learn_after" &&
     printf '%s\n' "$new_record" | grep -q '/ags_.*\.txt$' &&
     grep -q 'mode=drill' "$out/RUN_RECORD.txt" &&
     grep -q "learn_id=$learn_id" "$out/RUN_RECORD.txt" &&
     grep -q 'stop_reason=agent_stop' "$out/RUN_RECORD.txt"; then
    printf 'SMOKE=OK\n' >>"$out/TRANSCRIPT.log"
    return 0
  fi
  printf 'SMOKE=FAIL\nREASON=drill_contract\n' >>"$out/TRANSCRIPT.log"
  return 1
}

overall=1
case "${1:-all}" in
  all)
    run_one 112 192.168.31.112 rootful 79809 79808 98110 92 ags_17886130889526 || overall=0
    if [ "$overall" = 1 ]; then
      run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 ags_17886130933873 || overall=0
    fi
    if [ "$overall" = 1 ]; then
      run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886131005180 || overall=0
    fi
    ;;
  53)
    run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886131005180 || overall=0
    ;;
  *)
    printf 'usage: %s [all|53]\n' "$0" >&2
    exit 2
    ;;
esac

{
  printf '# 三号开发再补续：真演练后三机\n\n'
  printf '`.101` 已先只读合同核验成立；本脚本仅执行 `.112 -> .166 -> .53`，不是四号开发。\n\n'
  for tag in 101 112 166 53; do
    if [ -f "$OUT/$tag/TRANSCRIPT.log" ]; then
      printf '## .%s\n\n' "$tag"
      grep -E '^(AUTH|PRE_|RUNTIME_|REQ_|STOP_|POLL=|AFTER_|REAL_|RUN_|NEW_RECORD|SMOKE=|REASON=)' "$OUT/$tag/TRANSCRIPT.log" || true
      printf '\n'
    else
      printf '.%s: %s\n\n' "$tag" "$([ "$tag" = 101 ] && printf 'READONLY_CONTRACT_OK' || printf 'NOT_RUN')"
    fi
  done
  printf 'NO_SBRELOAD=1\nNOT_AGENT_MVP=1\nNOT_G0=1\n'
  if [ "$overall" = 1 ]; then
    printf 'AGENT_TRUE_DRILL=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_TRUE_DRILL=PARTIAL_PENDING_HUMAN\n'
  fi
} >"$OUT/VERDICT.md"
cat "$OUT/VERDICT.md"
[ "$overall" = 1 ]
