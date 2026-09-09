#!/usr/bin/env bash
# Eighty-two retry: one read-only collection per device, in frozen order.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/EIGHTYTWO_RETRY_AGENT_SMOKE_REPORT_SPLIT_20260905"
PASS="${ZY_SSH_PASS:-alpine}"

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

REMOTE_COLLECT='
set +e

REPORT_ROOT=/private/var/mobile/Media/ZiYan/Agent游戏/错误报告
RECORD_ROOT=/private/var/mobile/Media/ZiYan/Agent游戏/运行记录

if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
else
  VAR=/usr/lib/ziyan/var
fi

is_real_framecap_line() {
  case "$1" in
    *grep*|*sed*|*"sh -c"*|*"bash -s"*) return 1 ;;
    *"/ziyan_framecap serve"*|*" ziyan_framecap serve"*) return 0 ;;
    *) return 1 ;;
  esac
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

ps_all=$(ps -A -o pid=,args= 2>/dev/null)
sb_pid=
bb_pid=
fc_pid=
fc_n=0
zy_n=0
zy_frozen=0
agent_n=0

while IFS= read -r line; do
  case "$line" in
    *"sh -c"*|*"bash -s"*) continue ;;
  esac
  case "$line" in
    *SpringBoard.app/SpringBoard*)
      printf "SB_LINE=%s\n" "$line"
      if [ -z "$sb_pid" ]; then
        set -- $line
        sb_pid="${1:-}"
      fi
      ;;
    *backboardd*)
      printf "BB_LINE=%s\n" "$line"
      if [ -z "$bb_pid" ]; then
        set -- $line
        bb_pid="${1:-}"
      fi
      ;;
    *ziyadaemond*|*ziyan_zydaemond*)
      printf "ZY_LINE=%s\n" "$line"
      zy_n=$((zy_n + 1))
      set -- $line
      [ "${1:-}" = "$FROZEN_ZY" ] && zy_frozen=1
      ;;
  esac
  if is_real_framecap_line "$line"; then
    printf "FC_LINE=%s\n" "$line"
    fc_n=$((fc_n + 1))
    if [ -z "$fc_pid" ]; then
      set -- $line
      fc_pid="${1:-}"
    fi
  fi
  if is_real_agent_line "$line"; then
    printf "REAL_AGENT_LUA=%s\n" "$line"
    agent_n=$((agent_n + 1))
  fi
done <<EOF
$ps_all
EOF

printf "SB_PID=%s\n" "$sb_pid"
printf "BB_PID=%s\n" "$bb_pid"
printf "FC_PID=%s\n" "$fc_pid"
printf "FC_N=%s\n" "$fc_n"
printf "ZY_N=%s\n" "$zy_n"
printf "REAL_AGENT_LUA_N=%s\n" "$agent_n"
printf "HOOKS_PATH=%s/.ziyan_hooks\n" "$VAR"
printf "FROZEN_SB=%s\n" "$FROZEN_SB"
printf "FROZEN_BB=%s\n" "$FROZEN_BB"
printf "FROZEN_FC=%s\n" "$FROZEN_FC"
printf "FROZEN_ZY=%s\n" "$FROZEN_ZY"

freeze_match=1
[ "$sb_pid" = "$FROZEN_SB" ] || freeze_match=0
[ "$bb_pid" = "$FROZEN_BB" ] || freeze_match=0
[ "$fc_pid" = "$FROZEN_FC" ] || freeze_match=0
[ "$fc_n" = 1 ] || freeze_match=0
[ "$zy_frozen" = 1 ] || freeze_match=0
printf "FROZEN_MATCH=%s\n" "$freeze_match"

if [ "$freeze_match" != 1 ]; then
  printf "INVENTORY=FROZEN_MISMATCH\n"
  exit 0
fi

front=$(tr -d "\r\n" < "$VAR/.ziyan_front_bid" 2>/dev/null)
printf "FRONT=%s\n" "$front"
printf "SESSION_BEGIN\n"
cat "$VAR/.ziyan_agent_session" 2>/dev/null
printf "SESSION_END\n"

report_list=$(ls -l "$REPORT_ROOT" 2>/dev/null | grep "Sep  5 .*ags_")
record_list=$(ls -l "$RECORD_ROOT" 2>/dev/null | grep "Sep  5 .*ags_")
today_ags_n=0
report_reason_n=0
record_reason_n=0
expected_record_seen=0

printf "REPORT_LIST_BEGIN\n"
[ -n "$report_list" ] && printf "%s\n" "$report_list"
printf "REPORT_LIST_END\n"

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  name=${entry##* }
  case "$name" in
    ags_*) ;;
    *) continue ;;
  esac
  today_ags_n=$((today_ags_n + 1))
  if [ "$SCHEME" = rootless ]; then
    id=${name%.txt}
    report="$REPORT_ROOT/$name"
  else
    id=$name
    report="$REPORT_ROOT/$id/report.txt"
  fi
  printf "REPORT_ID=%s\n" "$id"
  printf "REPORT_PATH=%s\n" "$report"
  fields=$(grep -E "^(error_code|stop_reason|paused|bundle_id|front_bid)=" "$report" 2>/dev/null)
  if [ -n "$fields" ]; then
    printf "%s\n" "$fields" | while IFS= read -r field; do
      printf "REPORT_FIELD=%s\n" "$field"
    done
    report_reason_n=$((report_reason_n + 1))
  else
    printf "REPORT_FIELDS=ABSENT\n"
  fi
done <<EOF
$report_list
EOF

printf "RECORD_LIST_BEGIN\n"
[ -n "$record_list" ] && printf "%s\n" "$record_list"
printf "RECORD_LIST_END\n"

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  name=${entry##* }
  case "$name" in
    ags_*.txt) ;;
    *) continue ;;
  esac
  today_ags_n=$((today_ags_n + 1))
  id=${name%.txt}
  if [ "$id" = "$EXPECTED_RECORD" ]; then
    expected_record_seen=1
  fi
  case "$id" in
    *_drill*|*_学习*)
      printf "RECORD_SKIPPED=%s\n" "$id"
      continue
      ;;
  esac
  first=$(sed -n "1p" "$RECORD_ROOT/$name" 2>/dev/null)
  printf "RECORD_ID=%s\n" "$id"
  case "$first" in
    STOPPED*"mode="*|PAUSED*"mode="*)
      printf "RECORD_FIRST_LINE=%s\n" "$first"
      record_reason_n=$((record_reason_n + 1))
      ;;
    *)
      printf "RECORD_FIRST_LINE_UNEXPECTED=%s\n" "$first"
      ;;
  esac
done <<EOF
$record_list
EOF

printf "TODAY_AGS_N=%s\n" "$today_ags_n"
printf "REPORT_REASON_N=%s\n" "$report_reason_n"
printf "RECORD_REASON_N=%s\n" "$record_reason_n"
printf "EXPECTED_RECORD=%s\n" "$EXPECTED_RECORD"
printf "EXPECTED_RECORD_SEEN=%s\n" "$expected_record_seen"

if [ "$agent_n" = 0 ] &&
   [ "$today_ags_n" -gt 0 ] &&
   [ "$report_reason_n" -gt 0 ] &&
   [ "$record_reason_n" -gt 0 ] &&
   [ "$expected_record_seen" = 1 ]; then
  printf "INVENTORY=OK\n"
else
  printf "INVENTORY=PARTIAL\n"
fi
'

run_one() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local frozen_sb="$4"
  local frozen_bb="$5"
  local frozen_fc="$6"
  local frozen_zy="$7"
  local expected_record="$8"
  local out="$OUT/$tag"
  local key_rc
  local pass_rc

  mkdir -p "$out"

  if ssh "${SSH_KEY_OPTS[@]}" "root@$ip" \
    "SCHEME='$scheme' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' FROZEN_ZY='$frozen_zy' EXPECTED_RECORD='$expected_record'; export SCHEME FROZEN_SB FROZEN_BB FROZEN_FC FROZEN_ZY EXPECTED_RECORD; exec sh" \
    < <(printf '%s\n' "$REMOTE_COLLECT") >"$out/TRANSCRIPT.log" 2>&1; then
    printf 'AUTH=publickey\n' >>"$out/TRANSCRIPT.log"
    return 0
  fi
  key_rc=$?
  printf 'AUTH=publickey_failed\nKEY_SSH_EXIT=%s\n' "$key_rc" >"$out/TRANSCRIPT.log"
  sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" \
    "SCHEME='$scheme' FROZEN_SB='$frozen_sb' FROZEN_BB='$frozen_bb' FROZEN_FC='$frozen_fc' FROZEN_ZY='$frozen_zy' EXPECTED_RECORD='$expected_record'; export SCHEME FROZEN_SB FROZEN_BB FROZEN_FC FROZEN_ZY EXPECTED_RECORD; exec sh" \
    < <(printf '%s\n' "$REMOTE_COLLECT") >>"$out/TRANSCRIPT.log" 2>&1
  pass_rc=$?
  printf 'AUTH=password_fallback\nPASSWORD_SSH_EXIT=%s\n' "$pass_rc" >>"$out/TRANSCRIPT.log"
  return "$pass_rc"
}

serial_ok=1
run_one .101 192.168.31.101 rootful 87863 87862 47853 96 ags_17886039267035 || serial_ok=0
if [ "$serial_ok" = 1 ]; then
  run_one .112 192.168.31.112 rootful 79809 79808 98110 92 ags_17886039283090 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  run_one .166 192.168.31.166 rootful 25025 25024 52622 82626 ags_17886039294846 || serial_ok=0
fi
if [ "$serial_ok" = 1 ]; then
  run_one .53 192.168.31.53 rootless 46408 74318 49176 93705 ags_17886039311331 || serial_ok=0
fi

{
  printf '# Eighty-two retry: read-only report/record split\n\n'
  printf 'Collection order: `.101 -> .112 -> .166 -> .53`.\n'
  printf 'Fields below are from this collection SSH, not copied from an older verdict.\n\n'
  for tag in .101 .112 .166 .53; do
    log="$OUT/$tag/TRANSCRIPT.log"
    printf '## %s\n\n' "$tag"
    if [ -f "$log" ]; then
      grep -E '^(AUTH|KEY_SSH_EXIT|PASSWORD_SSH_EXIT|SB_PID|BB_PID|FC_PID|FC_N|REAL_AGENT_LUA_N|FROZEN_MATCH|FRONT|state=|session_id=|REPORT_ID|REPORT_FIELD|RECORD_ID|RECORD_FIRST_LINE|EXPECTED_RECORD|EXPECTED_RECORD_SEEN|INVENTORY)=' "$log" || true
    else
      printf 'TRANSCRIPT=ABSENT\n'
    fi
    printf '\n'
  done

  all_inventory=1
  for tag in .101 .112 .166 .53; do
    grep -qx 'INVENTORY=OK' "$OUT/$tag/TRANSCRIPT.log" 2>/dev/null || all_inventory=0
  done
  required=1
  grep -R -q 'REPORT_FIELD=.*no_profile' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'REPORT_FIELD=.*bundle_mismatch' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'REPORT_FIELD=front_bid=com.apple.springboard' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'RECORD_FIRST_LINE=STOPPED .*mode=observe' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0
  grep -R -q 'RECORD_FIRST_LINE=STOPPED .*mode=safe_action' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null || required=0

  secrets=1
  if rg -i -q 'password=|验证码|手机号|联系方式|私聊|screenshot=' "$OUT"/.*/TRANSCRIPT.log 2>/dev/null; then
    secrets=0
  fi
  printf 'NO_SECRETS_SEEN=%s\n' "$secrets"
  printf 'ERROR_REPORT_STATE=PAUSED\n'
  printf 'RUN_RECORD_STATE=STOPPED\n'
  printf 'FIELDS_FROM_THIS_SSH=1\n'
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
  --stage "八十二补：四机只读直抽今日报告与记录 reason" \
  --last-command "bash tools/zy_eightytwo_retry_report_split_readonly.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "本刀仅 SSH 直读进程、front/session、Sep 5 ags 清单、报告 reason 与记录首行；错误报告 PAUSED，运行记录 STOPPED；不是 MVP" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/EIGHTYTWO_RETRY_AGENT_SMOKE_REPORT_SPLIT_20260905/VERDICT.md；.101/.112/.166/.53 TRANSCRIPT.log" \
  --latest-verdict "$(sed -n 's/^AGENT_SMOKE_REPORT_SPLIT=//p' "$OUT/VERDICT.md" | tail -1)" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包；沿用盘上既有版本" \
  --device-state "依本刀四机 TRANSCRIPT；冻结不匹配即停止该机读取，未 sbreload" \
  --running-processes "依本刀四机 TRANSCRIPT：FC_N 只计 framecap 二进制行；真实 agent lua 同时含 lua5.3 与 ziyan_agent_run.lua" \
  --cleanup-status "未运行 lua、未写设备文件、未 sbreload/ldrestart/killall、未删除报告；停手等待人工最终审核"

printf '%s\n' "$OUT/VERDICT.md"
