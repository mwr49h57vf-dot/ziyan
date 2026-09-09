#!/usr/bin/env bash
# 一号开发补跑后的证据补采：只读，不再次运行入口。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV01_RETRY_AGENT_TRUE_LEARN_20260905"
PASS="${ZY_SSH_PASS:-alpine}"
LEARN_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/学习数据"
RECORD_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"

SSH_KEY_OPTS=(
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=12
)
SSH_PASS_OPTS=(
  -o PreferredAuthentications=password -o PubkeyAuthentication=no
  -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=12
)

REMOTE=()
AUTH=""
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
  local file="$1" command="$2"
  "${REMOTE[@]}" "$command" </dev/null >"$file" 2>"$file.stderr"
}
clean_ps_args() {
  case "$1" in *"sh -c"*|*"zsh -c"*|*"bash -s"*|*grep*|*sed*) return 1;; esac
}
pid_for_args_ending() {
  local file="$1" suffix="$2" line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; [ -n "$line" ] || continue
    pid="${line%% *}"; args="${line#"$pid"}"; args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    [[ "$args" == *"$suffix" ]] && { printf '%s\n' "$pid"; return; }
  done <"$file"
}
count_for_args_ending() {
  local file="$1" suffix="$2" line pid args n=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; [ -n "$line" ] || continue
    pid="${line%% *}"; args="${line#"$pid"}"; args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    [[ "$args" == *"$suffix" ]] && n=$((n + 1))
  done <"$file"
  printf '%s\n' "$n"
}
pid_for_zydaemon() {
  local file="$1" line pid args
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; [ -n "$line" ] || continue
    pid="${line%% *}"; args="${line#"$pid"}"; args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    case "$args" in *ziyadaemond*|*ziyan_zydaemond*) printf '%s\n' "$pid"; return;; esac
  done <"$file"
}
real_agent_lua_n() {
  local file="$1" line pid args n=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; [ -n "$line" ] || continue
    pid="${line%% *}"; args="${line#"$pid"}"; args="${args#"${args%%[![:space:]]*}"}"
    clean_ps_args "$args" || continue
    [[ "$args" == *lua5.3* && "$args" == *ziyan_agent_run.lua* ]] && n=$((n + 1))
  done <"$file"
  printf '%s\n' "$n"
}
new_id() {
  comm -13 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2") |
    sed -n 's/^ags_\([A-Za-z0-9_]*\)\.txt$/ags_\1/p' | head -n 1
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" sb0="$4" bb0="$5" fc0="$6" zy0="$7"
  local var out id ps sb bb fc fc_n zy agent_n front bundle profile
  [ "$scheme" = rootless ] && var=/var/jb/usr/lib/ziyan/var || var=/usr/lib/ziyan/var
  out="$OUT/$tag"
  id="$(new_id "$out/learn_before_ls.txt" "$out/learn_after_ls.txt")"
  mkdir -p "$out"
  connect_device "$ip" || {
    printf 'POSTCHECK=FAIL\nREASON=SSH_CONNECT\n' >>"$out/TRANSCRIPT.log"
    return 1
  }
  printf 'POST_AUTH=%s\nPOST_LEARN_ID=%s\n' "$AUTH" "$id" >>"$out/TRANSCRIPT.log"
  remote_to_file "$out/ziyan_agent_session.postcheck.txt" "cat '$var/.ziyan_agent_session'"
  remote_to_file "$out/ziyan_front_bid.postcheck.txt" "cat '$var/.ziyan_front_bid'"
  remote_to_file "$out/ziyan_agent_current_profile.postcheck.txt" "cat '$var/.ziyan_agent_current_profile'"
  remote_to_file "$out/learn_${id}.txt" "cat '$LEARN_ROOT/$id.txt'"
  remote_to_file "$out/record_${id}.txt" "cat '$RECORD_ROOT/$id.txt'"
  remote_to_file "$out/ps_POSTCHECK.txt" 'ps -A -o pid=,args='
  ps="$out/ps_POSTCHECK.txt"
  sb="$(pid_for_args_ending "$ps" '/System/Library/CoreServices/SpringBoard.app/SpringBoard')"
  bb="$(pid_for_args_ending "$ps" 'backboardd')"
  fc="$(pid_for_args_ending "$ps" 'ziyan_framecap serve')"
  fc_n="$(count_for_args_ending "$ps" 'ziyan_framecap serve')"
  zy="$(pid_for_zydaemon "$ps")"
  agent_n="$(real_agent_lua_n "$ps")"
  front="$(tr -d '\r\n' <"$out/ziyan_front_bid.postcheck.txt")"
  bundle="$(sed -n 's/^bundle_id=//p' "$out/ziyan_agent_current_profile.postcheck.txt" | head -n 1)"
  profile="$(sed -n 's/^profile_id=//p' "$out/ziyan_agent_current_profile.postcheck.txt" | head -n 1)"
  {
    printf 'POST_SB_PID=%s\nPOST_BB_PID=%s\nPOST_FC_PID=%s\nPOST_FC_N=%s\n' "$sb" "$bb" "$fc" "$fc_n"
    printf 'POST_ZY_PID=%s\nPOST_REAL_AGENT_LUA_N=%s\n' "$zy" "$agent_n"
    printf 'POST_FRONT=%s\nPOST_BUNDLE=%s\nPOST_PROFILE_ID=%s\n' "$front" "$bundle" "$profile"
    printf 'POST_FROZEN_MATCH=%s\n' "$([[ "$sb" = "$sb0" && "$bb" = "$bb0" && "$fc" = "$fc0" && "$zy" = "$zy0" ]] && printf 1 || printf 0)"
    printf 'POST_SESSION_STOPPED=%s\n' "$(grep -qx 'state=STOPPED' "$out/ziyan_agent_session.postcheck.txt" && printf 1 || printf 0)"
    printf 'POST_ACTIVE_0=%s\n' "$(grep -qx 'active=0' "$out/ziyan_agent_session.postcheck.txt" && printf 1 || printf 0)"
    printf 'POST_LEARN_FIELDS=%s\n' "$(grep -Eq '^front_bid=com.ziyan.ziyan$' "$out/learn_${id}.txt" &&
      grep -Eq '^frame_seq=[1-9][0-9]*$' "$out/learn_${id}.txt" &&
      grep -Eq '^bundle_id=com.ziyan.ziyan$' "$out/learn_${id}.txt" &&
      grep -Eq '^profile_id=.+$' "$out/learn_${id}.txt" &&
      grep -Eq '^ts=[0-9]+$' "$out/learn_${id}.txt" && printf 1 || printf 0)"
    printf 'POST_RECORD_MODE_LEARN=%s\n' "$(grep -q 'STOPPED .*mode=learn' "$out/record_${id}.txt" && printf 1 || printf 0)"
    printf 'POST_DELEGATE_SEEN=%s\n' "$(grep -Eq 'learn_delegate_app|learn_owned_by_app' "$out/learn_${id}.txt" "$out/record_${id}.txt" "$out/run.stdout.txt" && printf 1 || printf 0)"
  } >>"$out/TRANSCRIPT.log"
  if [ "$sb" = "$sb0" ] && [ "$bb" = "$bb0" ] && [ "$fc" = "$fc0" ] &&
     [ "$fc_n" = 1 ] && [ "$zy" = "$zy0" ] && [ "$agent_n" = 0 ] &&
     [ "$front" = com.ziyan.ziyan ] && [ "$bundle" = com.ziyan.ziyan ] &&
     grep -qx 'state=STOPPED' "$out/ziyan_agent_session.postcheck.txt" &&
     grep -qx 'active=0' "$out/ziyan_agent_session.postcheck.txt" &&
     grep -Eq '^front_bid=com.ziyan.ziyan$' "$out/learn_${id}.txt" &&
     grep -Eq '^frame_seq=[1-9][0-9]*$' "$out/learn_${id}.txt" &&
     grep -Eq '^bundle_id=com.ziyan.ziyan$' "$out/learn_${id}.txt" &&
     grep -Eq '^profile_id=.+$' "$out/learn_${id}.txt" &&
     grep -Eq '^ts=[0-9]+$' "$out/learn_${id}.txt" &&
     grep -q 'STOPPED .*mode=learn' "$out/record_${id}.txt"; then
    printf 'POSTCHECK=OK\nSMOKE=OK\n' >>"$out/TRANSCRIPT.log"
    return 0
  fi
  printf 'POSTCHECK=FAIL\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
  return 1
}

all_ok=1
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 || all_ok=0
if [ "$all_ok" = 1 ]; then run_one 112 192.168.31.112 rootful 79809 79808 98110 92 || all_ok=0; fi
if [ "$all_ok" = 1 ]; then run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 || all_ok=0; fi
if [ "$all_ok" = 1 ]; then run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 || all_ok=0; fi

{
  printf '# 一号开发补：真学习最小切片四机补跑\n\n'
  printf '这是**一号开发补跑**，不是八十六只读汇总；不是真自研，不是真演练。\n\n'
  printf '四台已各运行一次入口；本次只补采运行后证据，未再次运行入口，未 sbreload、未 dpkg、未改 profile、未操作游戏。\n\n'
  for tag in 101 112 166 53; do
    printf '## .%s\n\n' "$tag"
    grep -E '^(AUTH|POST_|SMOKE|REASON)=' "$OUT/$tag/TRANSCRIPT.log" || true
    printf '\n'
  done
  printf 'NOT_AGENT_MVP_4PHONE_PASS=1\nNOT_G0=1\nNO_SBRELOAD_EXECUTED=1\n'
  if [ "$all_ok" = 1 ]; then
    printf 'AGENT_TRUE_LEARN=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_TRUE_LEARN=PARTIAL_PENDING_HUMAN\n'
  fi
} >"$OUT/VERDICT.md"

python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "一号开发补：真学习最小切片四机补跑" \
  --last-command "四机入口各运行一次后，bash tools/zy_dev01_retry_agent_true_learn_postcheck.sh 只读补采" \
  --result "$([ "$all_ok" = 1 ] && printf '四机运行后证据均通过；每台学习文件字段、mode=learn、STOPPED、冻结与 FC_N=1 已核验；未再次运行入口；未 sbreload；等待人工最终审核。' || printf '运行后证据补采未全通过；未再次运行入口；未 sbreload；等待人工最终审核。')" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV01_RETRY_AGENT_TRUE_LEARN_20260905/VERDICT.md；四机 TRANSCRIPT.log；各机学习文件、运行记录、session 与 POSTCHECK ps" \
  --latest-verdict "$([ "$all_ok" = 1 ] && printf 'AGENT_TRUE_LEARN=PASS_PENDING_HUMAN' || printf 'AGENT_TRUE_LEARN=PARTIAL_PENDING_HUMAN')" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "本刀未改包" \
  --device-state "严格串行；入口各运行一次；补采仅只读；冻结不匹配即停止后续设备；未 sbreload" \
  --running-processes "SpringBoard args 仅完整路径结尾；FC_N 仅 ziyan_framecap serve 结尾；真实 agent lua 同时含 lua5.3 与 ziyan_agent_run.lua" \
  --cleanup-status "四台入口均已 STOPPED；补采未改设备；未 sbreload/ldrestart/killall/dpkg；停手等待人工最终审核"
printf '%s\n' "$OUT/VERDICT.md"
