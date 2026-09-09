#!/usr/bin/env bash
# 四机 Agent 真演练补跑：严格串行，启动入口后立即写 stop=1。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/AGENT_TRUE_DRILL_20260905"
PASS="${ZY_SSH_PASS:-alpine}"
mkdir -p "$OUT"

SSH_KEY_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  -o PasswordAuthentication=no
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
    ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh -n "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
  fi
}

scp_r() {
  local src="$1" ip="$2" dst="$3"
  if scp "${SSH_KEY_OPTS[@]}" "$src" "root@$ip:$dst" >/dev/null 2>&1; then
    return 0
  fi
  sshpass -p "$PASS" scp "${SSH_PASS_OPTS[@]}" "$src" "root@$ip:$dst"
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

pid_present() {
  awk -v wanted="$1" '$1 == wanted { found=1 } END { print found + 0 }'
}

remote_file() {
  ssh_r "$1" "cat '$2' 2>/dev/null"
}

remote_hash() {
  ssh_r "$1" "if command -v sha256sum >/dev/null 2>&1; then sha256sum '$2'; else shasum -a 256 '$2'; fi" \
    | awk '{print $1}'
}

known_learn_state() {
  local ip="$1" var="$2"
  local id state=""
  for id in ags_17886130846274 ags_17886130889526 ags_17886130933873 ags_17886131005180; do
    if ssh_r "$ip" "test -f '$var/学习数据/$id.txt'" >/dev/null 2>&1; then
      state="${state}${id}=present\n"
    else
      state="${state}${id}=absent\n"
    fi
  done
  printf '%b' "$state"
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5"
  local frozen_fc="$6" frozen_zy="$7" learn_id="$8" out="$OUT/$tag"
  local var target tmp lua run agent ps front profile req backup sha_local sha_remote
  local pre_sb pre_bb pre_fc pre_fc_pid pre_zy run_log run_rc session_body after_ps
  local after_sb after_bb after_fc after_fc_pid after_zy agent_n stop_marker run_record run_rc_value
  local learn_before learn_after start_epoch elapsed=0

  mkdir -p "$out"
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

  printf 'TAG=%s IP=%s SCHEME=%s LEARN_ID=%s\n' "$tag" "$ip" "$scheme" "$learn_id" >"$out/TRANSCRIPT.log"
  ps=$(ssh_r "$ip" 'ps -A -o pid=,comm=,args=') || {
    printf 'SMOKE=FAIL\nREASON=precheck_ps_failed\n' >>"$out/TRANSCRIPT.log"
    return 1
  }
  printf '%s\n' "$ps" >"$out/PRECHECK_PS.log"
  pre_sb=$(printf '%s\n' "$ps" | sb_pid)
  pre_bb=$(printf '%s\n' "$ps" | bb_pid)
  pre_fc=$(printf '%s\n' "$ps" | fc_count)
  pre_fc_pid=$(printf '%s\n' "$ps" | fc_pid)
  pre_zy=$(printf '%s\n' "$ps" | pid_present "$frozen_zy")
  front=$(remote_file "$ip" "$var/.ziyan_front_bid" | tr -d '\r\n')
  printf 'PRECHECK_SB=%s\nPRECHECK_BB=%s\nPRECHECK_FC_PID=%s\nPRECHECK_FC_N=%s\nPRECHECK_ZY_FROZEN_PRESENT=%s\nPRECHECK_FRONT=%s\n' \
    "$pre_sb" "$pre_bb" "$pre_fc_pid" "$pre_fc" "$pre_zy" "$front" >>"$out/TRANSCRIPT.log"
  if [ "$pre_sb" != "$frozen_sb" ] || [ "$pre_bb" != "$frozen_bb" ] || \
     [ "$pre_fc_pid" != "$frozen_fc" ] || [ "$pre_fc" != 1 ] ||
     [ "$pre_zy" != 1 ] || [ "$front" != com.ziyan.ziyan ]; then
    printf 'PRECHECK=FROZEN_OR_FRONT_MISMATCH\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi

  sha_local=$(shasum -a 256 "$ROOT/Agent/Core/agent_runtime.lua" | awk '{print $1}')
  sha_remote=$(remote_hash "$ip" "$target")
  backup="$target.drill-backup.$(date +%Y%m%d%H%M%S)"
  printf 'RUNTIME_SHA_LOCAL=%s\nRUNTIME_SHA_REMOTE_BEFORE=%s\nRUNTIME_BACKUP=%s\n' \
    "$sha_local" "$sha_remote" "$backup" >>"$out/TRANSCRIPT.log"
  if ! ssh_r "$ip" "cp '$target' '$backup'"; then
    printf 'SMOKE=FAIL\nREASON=runtime_backup_failed\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if [ "$sha_remote" != "$sha_local" ]; then
    if ! scp_r "$ROOT/Agent/Core/agent_runtime.lua" "$ip" "$tmp" ||
       ! ssh_r "$ip" "mv '$tmp' '$target'"; then
      printf 'SMOKE=FAIL\nREASON=runtime_upload_failed\n' >>"$out/TRANSCRIPT.log"
      return 1
    fi
    printf 'RUNTIME_UPLOAD=1\n' >>"$out/TRANSCRIPT.log"
  else
    printf 'RUNTIME_UPLOAD=SKIPPED_SHA_MATCH\n' >>"$out/TRANSCRIPT.log"
  fi
  sha_remote=$(remote_hash "$ip" "$target")
  printf 'RUNTIME_SHA_REMOTE_AFTER=%s\n' "$sha_remote" >>"$out/TRANSCRIPT.log"
  if [ "$sha_remote" != "$sha_local" ]; then
    printf 'SMOKE=FAIL\nREASON=runtime_sha_mismatch\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi

  profile=$(remote_file "$ip" "$var/.ziyan_agent_current_profile")
  req=$(remote_file "$ip" "$var/.ziyan_agent_req")
  printf '%s\n' "$profile" >"$out/PROFILE_BEFORE.txt"
  printf '%s\n' "$req" >"$out/REQ_BEFORE.txt"
  if ! printf '%s\n' "$profile" | grep -q '^bundle_id=com\.ziyan\.ziyan$'; then
    printf 'SMOKE=FAIL\nREASON=profile_bundle_mismatch\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'OPEN_APP=SKIPPED_ALREADY_FRONT\n' >>"$out/TRANSCRIPT.log"

  learn_before=$(known_learn_state "$ip" "$var")
  printf '%s\n' "$learn_before" >"$out/LEARN_BEFORE.txt"

  if ! ssh_r "$ip" "printf '%s\\n' '$learn_id' > '$var/.ziyan_drill_learn_id' && printf 'mode=drill\\n' > '$var/.ziyan_agent_req'"; then
    printf 'SMOKE=FAIL\nREASON=drill_request_write_failed\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  printf 'REQ_WRITTEN=mode=drill\nLEARN_ID_WRITTEN=%s\n' "$learn_id" >>"$out/TRANSCRIPT.log"

  run_log="$var/.ziyan_agent_true_drill_run.log"
  run_rc="$var/.ziyan_agent_true_drill_rc"
  start_epoch=$(date +%s)
  ssh_r "$ip" "rm -f '$run_log' '$run_rc' '$var/.ziyan_agent_stop'; ( '$lua' '$run' '$agent'; printf '%s\\n' \$? > '$run_rc' ) > '$run_log' 2>&1 & launch_pid=\$!; printf 'stop=1\\n' > '$var/.ziyan_agent_stop'; chmod 666 '$var/.ziyan_agent_stop' 2>/dev/null; printf 'LAUNCH_PID=%s\\n' \$launch_pid" \
    >"$out/START.log" 2>&1
  cat "$out/START.log" >>"$out/TRANSCRIPT.log"
  printf 'STOP_WRITE=IMMEDIATE_AFTER_BACKGROUND_START\n' >>"$out/TRANSCRIPT.log"

  while [ "$elapsed" -lt 15 ]; do
    sleep 1
    elapsed=$(( $(date +%s) - start_epoch ))
    session_body=$(remote_file "$ip" "$var/.ziyan_agent_session")
    agent_n=$(printf '%s\n' "$(ssh_r "$ip" 'ps -A -o pid=,comm=,args=')" | agent_count)
    printf 'POLL=%ss SESSION=%s REAL_AGENT_LUA_N=%s\n' "$elapsed" \
      "$(printf '%s\n' "$session_body" | sed -n 's/^state=//p' | head -1)" "$agent_n" >>"$out/TRANSCRIPT.log"
    if printf '%s\n' "$session_body" | grep -q '^state=STOPPED$' && [ "$agent_n" = 0 ]; then
      break
    fi
  done

  after_ps=$(ssh_r "$ip" 'ps -A -o pid=,comm=,args=')
  printf '%s\n' "$after_ps" >"$out/AFTER_PS.log"
  after_sb=$(printf '%s\n' "$after_ps" | sb_pid)
  after_bb=$(printf '%s\n' "$after_ps" | bb_pid)
  after_fc=$(printf '%s\n' "$after_ps" | fc_count)
  after_fc_pid=$(printf '%s\n' "$after_ps" | fc_pid)
  after_zy=$(printf '%s\n' "$after_ps" | pid_present "$frozen_zy")
  agent_n=$(printf '%s\n' "$after_ps" | agent_count)
  session_body=$(remote_file "$ip" "$var/.ziyan_agent_session")
  stop_marker=$(ssh_r "$ip" "test -e '$var/.ziyan_agent_stop' && echo PRESENT || echo ABSENT")
  run_record=$(ssh_r "$ip" "grep -h '^STOPPED ' '$var/运行记录/'* 2>/dev/null | tail -1" || true)
  printf '%s\n' "$session_body" >"$out/SESSION_AFTER.txt"
  printf '%s\n' "$run_record" >"$out/RUN_RECORD.txt"
  printf '%s\n' "$(remote_file "$ip" "$run_log" | tail -80)" >"$out/RUN_LOG.txt"
  run_rc_value=$(remote_file "$ip" "$run_rc" | tr -d '\r\n')
  learn_after=$(known_learn_state "$ip" "$var")
  printf '%s\n' "$learn_after" >"$out/LEARN_AFTER.txt"
  printf 'AFTER_SB=%s\nAFTER_BB=%s\nAFTER_FC_PID=%s\nAFTER_FC_N=%s\nAFTER_ZY_FROZEN_PRESENT=%s\nREAL_AGENT_LUA_N=%s\nSTOP_MARKER=%s\nRUN_RC=%s\n' \
    "$after_sb" "$after_bb" "$after_fc_pid" "$after_fc" "$after_zy" "$agent_n" "$stop_marker" "$run_rc_value" >>"$out/TRANSCRIPT.log"

  if [ "$after_sb" = "$frozen_sb" ] && [ "$after_bb" = "$frozen_bb" ] &&
     [ "$after_fc_pid" = "$frozen_fc" ] && [ "$after_fc" = 1 ] &&
     [ "$after_zy" = 1 ] && [ "$agent_n" = 0 ] &&
     [ "$stop_marker" = ABSENT ] && printf '%s\n' "$session_body" | grep -q '^state=STOPPED$' &&
     [ "$run_rc_value" = 0 ] && [ "$learn_before" = "$learn_after" ] &&
     printf '%s\n' "$run_record" | grep -q "mode=drill" &&
     printf '%s\n' "$run_record" | grep -q "learn_id=$learn_id" &&
     printf '%s\n' "$run_record" | grep -q 'stop_reason=agent_stop'; then
    printf 'SMOKE=OK\n' >>"$out/TRANSCRIPT.log"
    return 0
  fi
  printf 'SMOKE=FAIL\nREASON=drill_result_contract_failed\n' >>"$out/TRANSCRIPT.log"
  return 1
}

overall=1
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 ags_17886130846274 || overall=0
if [ "$overall" = 1 ]; then
  run_one 112 192.168.31.112 rootful 79809 79808 98110 92 ags_17886130889526 || overall=0
fi
if [ "$overall" = 1 ]; then
  run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 ags_17886130933873 || overall=0
fi
if [ "$overall" = 1 ]; then
  run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886131005180 || overall=0
fi

{
  printf '# Agent true drill\n\n'
  for tag in 101 112 166 53; do
    if [ -f "$OUT/$tag/TRANSCRIPT.log" ]; then
      printf '.%s: %s\n' "$tag" "$(sed -n 's/^SMOKE=//p' "$OUT/$tag/TRANSCRIPT.log" | tail -1)"
    else
      printf '.%s: NOT_RUN\n' "$tag"
    fi
  done
  printf '\nAGENT_TRUE_DRILL=%s\n' "$([ "$overall" = 1 ] && printf 'PASS_PENDING_HUMAN' || printf 'PARTIAL')"
  printf 'NOT_AGENT_MVP=1\nNO_SBRELOAD=1\n'
} >"$OUT/VERDICT.md"
cat "$OUT/VERDICT.md"
[ "$overall" = 1 ]
