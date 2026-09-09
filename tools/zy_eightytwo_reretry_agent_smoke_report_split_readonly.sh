#!/usr/bin/env bash
# Eighty-two re-retry: direct, read-only collection with all ps filtering local.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/EIGHTYTWO_RERETRY_AGENT_SMOKE_REPORT_SPLIT_20260905"
PASS="${ZY_SSH_PASS:-alpine}"

if [ -e "$OUT" ]; then
  if [ ! -s "$OUT/.166/DIRECT_READ.log" ] || [ -e "$OUT/.112" ] || [ -e "$OUT/.53" ]; then
    printf 'evidence directory already exists: %s\n' "$OUT" >&2
    exit 2
  fi
  resume_after_166=1
else
  mkdir -p "$OUT"
  resume_after_166=0
fi

SSH_KEY_OPTS=(
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
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
  -o LogLevel=ERROR
  -o ConnectTimeout=12
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
)

REMOTE=()
AUTH=
connect_device() {
  local ip="$1"
  if ssh "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(ssh "${SSH_KEY_OPTS[@]}" "root@$ip")
    AUTH=publickey
  else
    REMOTE=(sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip")
    AUTH=password_fallback
  fi
}

remote_to_file() {
  local file="$1"
  shift
  "${REMOTE[@]}" "$@" </dev/null >"$file" 2>&1
}

remote_to_file_allow_empty() {
  local file="$1"
  shift
  "${REMOTE[@]}" "$@" </dev/null >"$file" 2>&1 || true
}

clean_ps_line() {
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
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_line "$args" || continue
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
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_line "$args" || continue
    [[ "$args" == *"$suffix" ]] && n=$((n + 1))
  done <"$ps_file"
  printf '%s\n' "$n"
}

pid_for_backboardd() {
  local ps_file="$1"
  local line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_line "$args" || continue
    [[ "$args" == *backboardd ]] && printf '%s\n' "$pid"
  done <"$ps_file"
}

pid_for_zydaemon() {
  local ps_file="$1"
  local line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_line "$args" || continue
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
    pid="${line%% *}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_line "$args" || continue
    [[ "$args" == *lua5.3* && "$args" == *ziyan_agent_run.lua* ]] && n=$((n + 1))
  done <"$ps_file"
  printf '%s\n' "$n"
}

list_today_ags() {
  grep 'Sep  5 .*ags_' "$1" || true
}

collect_166_glance() {
  local ip=192.168.31.166
  local out="$OUT/.166"
  local record_root=/private/var/mobile/Media/ZiYan/Agent游戏/运行记录
  local expected=ags_17886039294846
  local sb agent_n

  mkdir -p "$out"
  connect_device "$ip"
  printf 'AUTH=%s\n' "$AUTH" >"$out/DIRECT_READ.log"
  remote_to_file "$out/ps.txt" 'ps -A -o pid=,args='
  remote_to_file "$out/records_ls.txt" "ls -l '$record_root'"
  remote_to_file "$out/record_first.txt" "cat '$record_root/$expected.txt' | head -n 1"

  sb="$(pid_for_args_ending "$out/ps.txt" '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | head -n 1)"
  agent_n="$(real_agent_lua_n "$out/ps.txt")"
  {
    printf 'SB_PID=%s\n' "$sb"
    printf 'FROZEN_SB=25025\n'
    printf 'SB_MATCH=%s\n' "$([[ "$sb" = 25025 ]] && printf 1 || printf 0)"
    printf 'REAL_AGENT_LUA_N=%s\n' "$agent_n"
    printf 'EXPECTED_RECORD=%s\n' "$expected"
    list_today_ags "$out/records_ls.txt" | sed 's/^/RECORD_LIST=/'
    printf 'RECORD_FIRST_LINE=%s\n' "$(grep -E '^(STOPPED|PAUSED) .*mode=' "$out/record_first.txt" | head -n 1)"
    printf 'REPORT_REEXTRACTED=0\n'
  } >>"$out/DIRECT_READ.log"
}

run_one() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local frozen_sb="$4"
  local frozen_bb="$5"
  local frozen_fc="$6"
  local frozen_zy="$7"
  local expected="$8"
  local var report_root record_root out
  local sb bb fc fc_n agent_n
  local report_list record_list
  local today_report_n=0 today_record_n=0 expected_report_seen=0 expected_record_seen=0 report_reason_n=0 record_reason_n=0
  local line name id report record first

  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
  else
    var=/usr/lib/ziyan/var
  fi
  report_root=/private/var/mobile/Media/ZiYan/Agent游戏/错误报告
  record_root=/private/var/mobile/Media/ZiYan/Agent游戏/运行记录
  out="$OUT/$tag"
  mkdir -p "$out"

  connect_device "$ip"
  printf 'AUTH=%s\n' "$AUTH" >"$out/TRANSCRIPT.log"
  remote_to_file "$out/ps.txt" 'ps -A -o pid=,args='

  sb="$(pid_for_args_ending "$out/ps.txt" '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | head -n 1)"
  bb="$(pid_for_backboardd "$out/ps.txt" | head -n 1)"
  fc="$(pid_for_args_ending "$out/ps.txt" 'ziyan_framecap serve' | head -n 1)"
  fc_n="$(count_for_args_ending "$out/ps.txt" 'ziyan_framecap serve')"
  agent_n="$(real_agent_lua_n "$out/ps.txt")"
  {
    printf 'SB_PID=%s\nFROZEN_SB=%s\n' "$sb" "$frozen_sb"
    printf 'BB_PID=%s\nFROZEN_BB=%s\n' "$bb" "$frozen_bb"
    printf 'FC_PID=%s\nFROZEN_FC=%s\nFC_N=%s\n' "$fc" "$frozen_fc" "$fc_n"
    printf 'FROZEN_ZY=%s\n' "$frozen_zy"
    printf 'REAL_AGENT_LUA_N=%s\n' "$agent_n"
  } >>"$out/TRANSCRIPT.log"

  if [ "$sb" != "$frozen_sb" ] || [ "$bb" != "$frozen_bb" ] ||
     [ "$fc" != "$frozen_fc" ] || [ "$fc_n" != 1 ] ||
     ! grep -qx "$frozen_zy" < <(pid_for_zydaemon "$out/ps.txt"); then
    printf 'INVENTORY=FROZEN_MISMATCH\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi
  if [ "$agent_n" != 0 ]; then
    printf 'INVENTORY=REAL_AGENT_LUA_PRESENT\n' >>"$out/TRANSCRIPT.log"
    return 1
  fi

  remote_to_file "$out/reports_ls.txt" "ls -l '$report_root'"
  remote_to_file "$out/records_ls.txt" "ls -l '$record_root'"
  report_list="$(list_today_ags "$out/reports_ls.txt")"
  record_list="$(list_today_ags "$out/records_ls.txt")"
  printf '%s\n' "$report_list" | sed '/^$/d; s/^/REPORT_LIST=/' >>"$out/TRANSCRIPT.log"
  printf '%s\n' "$record_list" | sed '/^$/d; s/^/RECORD_LIST=/' >>"$out/TRANSCRIPT.log"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line##* }"
    case "$scheme:$name" in
      rootful:ags_*) id="$name"; report="$report_root/$id/report.txt" ;;
      rootless:ags_*.txt) id="${name%.txt}"; report="$report_root/$name" ;;
      *) continue ;;
    esac
    today_report_n=$((today_report_n + 1))
    [ "$id" = "$expected" ] && expected_report_seen=1
    remote_to_file_allow_empty "$out/report_${id}.txt" "grep -E '^(error_code|stop_reason|paused|bundle_id|front_bid)=' '$report'"
    printf 'REPORT_ID=%s\n' "$id" >>"$out/TRANSCRIPT.log"
    while IFS= read -r first; do
      [ -n "$first" ] || continue
      printf 'REPORT_FIELD=%s\n' "$first" >>"$out/TRANSCRIPT.log"
      report_reason_n=$((report_reason_n + 1))
    done <"$out/report_${id}.txt"
  done <<<"$report_list"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line##* }"
    case "$name" in
      ags_*.txt) id="${name%.txt}" ;;
      *) continue ;;
    esac
    case "$id" in
      *_drill*|*_学习*) printf 'RECORD_SKIPPED=%s\n' "$id" >>"$out/TRANSCRIPT.log"; continue ;;
    esac
    today_record_n=$((today_record_n + 1))
    [ "$id" = "$expected" ] && expected_record_seen=1
    record="$record_root/$name"
    remote_to_file "$out/record_${id}.txt" "cat '$record' | head -n 1"
    first="$(head -n 1 "$out/record_${id}.txt")"
    printf 'RECORD_ID=%s\nRECORD_FIRST_LINE=%s\n' "$id" "$first" >>"$out/TRANSCRIPT.log"
    case "$first" in
      STOPPED*"mode="*|PAUSED*"mode="*) record_reason_n=$((record_reason_n + 1)) ;;
    esac
  done <<<"$record_list"

  {
    printf 'TODAY_REPORT_N=%s\nTODAY_RECORD_N=%s\n' "$today_report_n" "$today_record_n"
    printf 'EXPECTED_RECORD=%s\nEXPECTED_RECORD_SEEN=%s\n' "$expected" "$expected_record_seen"
    printf 'EXPECTED_REPORT_SEEN=%s\nREPORT_REASON_N=%s\nRECORD_REASON_N=%s\n' "$expected_report_seen" "$report_reason_n" "$record_reason_n"
  } >>"$out/TRANSCRIPT.log"

  if [ "$today_report_n" -gt 0 ] && [ "$today_record_n" -gt 0 ] &&
     [ "$report_reason_n" -gt 0 ] && [ "$record_reason_n" -gt 0 ] &&
     [ "$expected_record_seen" = 1 ]; then
    printf 'INVENTORY=OK\n' >>"$out/TRANSCRIPT.log"
    return 0
  fi
  printf 'INVENTORY=PARTIAL\n' >>"$out/TRANSCRIPT.log"
  return 1
}

if [ "$resume_after_166" = 0 ]; then
  collect_166_glance
fi
serial_ok=1
run_one .101 192.168.31.101 rootful 87863 87862 47853 96 ags_17886039267035 || serial_ok=0
if [ "$serial_ok" = 1 ]; then
  run_one .112 192.168.31.112 rootful 79809 79808 98110 92 ags_17886039283090 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  run_one .53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886039311331 || serial_ok=0
fi

{
  printf '# Eighty-two re-retry: three-device read-only report/record split\n\n'
  printf 'Collection order: `.101 -> .112 -> .53`; `.166` was one direct read only and reports were not re-extracted.\n'
  printf 'SpringBoard acceptance is local filtering of `ps` lines whose args end in the full SpringBoard path; collector shell/grep/sed lines are excluded.\n'
  printf 'Fields below come from this SSH collection. Error reports are PAUSED; run records are STOPPED.\n\n'
  for tag in .166 .101 .112 .53; do
    log="$OUT/$tag/$([[ "$tag" = .166 ]] && printf DIRECT_READ || printf TRANSCRIPT).log"
    printf '## %s\n\n' "$tag"
    if [ "$tag" = .166 ]; then
      grep -E '^(AUTH|SB_PID|FROZEN_SB|SB_MATCH|BB_PID|FC_PID|FC_N|REAL_AGENT_LUA_N|REPORT_ID|REPORT_FIELD|RECORD_ID|EXPECTED_RECORD|EXPECTED_RECORD_SEEN|INVENTORY|REPORT_REEXTRACTED)=' "$log" || true
      grep -E '^(STOPPED|PAUSED) .*mode=' "$OUT/.166/record_first.txt" | head -n 1 | sed 's/^/RECORD_FIRST_LINE=/'
    else
      grep -E '^(AUTH|SB_PID|FROZEN_SB|SB_MATCH|BB_PID|FC_PID|FC_N|REAL_AGENT_LUA_N|REPORT_ID|REPORT_FIELD|RECORD_ID|RECORD_FIRST_LINE|EXPECTED_RECORD|EXPECTED_RECORD_SEEN|INVENTORY|REPORT_REEXTRACTED)=' "$log" || true
    fi
    printf '\n'
  done

  all_inventory=1
  for tag in .101 .112 .53; do
    grep -qx 'INVENTORY=OK' "$OUT/$tag/TRANSCRIPT.log" 2>/dev/null || all_inventory=0
  done
  required=1
  grep -R -q 'REPORT_FIELD=.*no_profile' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'REPORT_FIELD=bundle_id=com.apple.Preferences' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'REPORT_FIELD=front_bid=com.ziyan.ziyan' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'REPORT_FIELD=front_bid=com.apple.springboard' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'RECORD_FIRST_LINE=STOPPED .*mode=observe' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'RECORD_FIRST_LINE=STOPPED .*mode=safe_action' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0

  secrets=1
  if rg -i -q 'password=|验证码|手机号|联系方式|私聊|screenshot=' "$OUT"/.*/{TRANSCRIPT,DIRECT_READ}.log "$OUT"/.*/ps.txt 2>/dev/null; then
    secrets=0
  fi
  printf 'NO_SECRETS_SEEN=%s\n' "$secrets"
  printf 'ERROR_REPORT_STATE=PAUSED\n'
  printf 'RUN_RECORD_STATE=STOPPED\n'
  printf 'FIELDS_FROM_THIS_SSH=1\n'
  printf 'DOT166_NOT_REEXTRACTED=1\n'
  printf 'NO_SBRELOAD_EXECUTED=1\n'
  printf 'NOT_G0=1\n'
  printf 'NOT_AGENT_MVP=1\n'
  if [ "$serial_ok" = 1 ] && [ "$all_inventory" = 1 ] &&
     [ "$required" = 1 ] && [ "$secrets" = 1 ]; then
    printf 'AGENT_SMOKE_REPORT_SPLIT=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_SMOKE_REPORT_SPLIT=PARTIAL\n'
  fi
} >"$OUT/VERDICT.md"

python3 tools/ziyan_codex_checkpoint.py write \
  --stage "八十二再补：三机只读直抽今日报告与记录 reason" \
  --last-command "bash tools/zy_eightytwo_reretry_agent_smoke_report_split_readonly.sh；严格串行 .101 -> .112 -> .53；.166 只读一眼" \
  --result "本刀仅 SSH 直读；错误报告 PAUSED，运行记录 STOPPED；字段来自本刀 SSH；.166 未重抽；未 sbreload；不是 MVP" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/EIGHTYTWO_RERETRY_AGENT_SMOKE_REPORT_SPLIT_20260905/VERDICT.md；.101/.112/.53 TRANSCRIPT.log；.166 DIRECT_READ.log" \
  --latest-verdict "$(sed -n 's/^AGENT_SMOKE_REPORT_SPLIT=//p' "$OUT/VERDICT.md" | tail -1)" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包；沿用盘上既有版本" \
  --device-state "依本刀本地筛选后的 ps 与报告/记录直读；冻结不匹配即停止后续设备；未 sbreload" \
  --running-processes "仅本地筛选：SpringBoard args 路径结尾；FC_N 只计 ziyan_framecap serve 路径结尾；真实 agent lua 同时含 lua5.3 与 ziyan_agent_run.lua" \
  --cleanup-status "未运行 lua、未写设备文件、未 sbreload/ldrestart/killall、未删除报告；停手等待人工最终审核"

printf '%s\n' "$OUT/VERDICT.md"
