#!/usr/bin/env bash
# 八号开发：mode=auto 失败安全门。只证实 no_profile/bundle_mismatch 不触控。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV08_AGENT_TRUE_HID_SAFE_GATE_20260906"
SOURCE="$ROOT/Agent/Core/agent_runtime.lua"
PASS="${ZY_SSH_PASS:-alpine}"
EXPECTED_SHA="a78767ab6a51f3c81786e6d888179d8e01102ca41680ae7842b20ab0061292ae"
LEARN_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/学习数据"
RECORD_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"
REPORT_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/错误报告"

if [ -e "$OUT" ]; then
  printf 'evidence directory already exists: %s\n' "$OUT" >&2
  exit 2
fi
[ -f "$SOURCE" ] || { printf 'runtime source missing: %s\n' "$SOURCE" >&2; exit 2; }
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
  local file="$1" command="$2"
  "${REMOTE[@]}" "$command" </dev/null >"$file" 2>"$file.stderr"
}

copy_to_device() {
  local ip="$1" source="$2" target="$3" log="$4"
  "${SCP_REMOTE[@]}" "$source" "root@$ip:$target" >"$log" 2>&1
}

read_value() {
  tr -d '\r\n' <"$1" 2>/dev/null || true
}

session_value() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

write_transcript() {
  local out="$1"
  shift
  printf '%s\n' "$@" >>"$out/TRANSCRIPT.log"
}

ps_metrics() {
  local ps_file="$1" out_file="$2" frozen_sb="$3" frozen_bb="$4" frozen_fc="$5" frozen_zy="$6"
  python3 - "$ps_file" "$out_file" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy" <<'PY'
from pathlib import Path
import sys

ps_path, out_path, frozen_sb, frozen_bb, frozen_fc, frozen_zy = sys.argv[1:]
lines = Path(ps_path).read_text(errors="replace").splitlines()

def excluded(args):
    return any(token in args for token in ("sh -c", "zsh -c", "bash -s", "grep", "sed"))

def rows_for_suffix(suffix):
    rows = []
    for line in lines:
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, args = parts
        if not excluded(args) and args.endswith(suffix):
            rows.append((pid, args))
    return rows

sb = rows_for_suffix("/System/Library/CoreServices/SpringBoard.app/SpringBoard")
bb = rows_for_suffix("backboardd")
fc = rows_for_suffix("ziyan_framecap serve")
zy = []
agent = []
for line in lines:
    parts = line.strip().split(None, 1)
    if len(parts) != 2:
        continue
    pid, args = parts
    if excluded(args):
        continue
    if "ziyadaemond" in args or "ziyan_zydaemond" in args:
        zy.append((pid, args))
    if "lua5.3" in args and "ziyan_agent_run.lua" in args:
        agent.append((pid, args))

def first_pid(rows):
    return rows[0][0] if rows else ""

rows = {
    "SB_PID": first_pid(sb),
    "SB_LINE": sb[0][1] if sb else "",
    "BB_PID": first_pid(bb),
    "BB_LINE": bb[0][1] if bb else "",
    "FC_PID": first_pid(fc),
    "FC_N": str(len(fc)),
    "FC_LINE": fc[0][1] if fc else "",
    "ZY_LINES": " || ".join(f"{pid} {args}" for pid, args in zy),
    "REAL_AGENT_LUA_N": str(len(agent)),
    "REAL_AGENT_LUA_LINES": " || ".join(f"{pid} {args}" for pid, args in agent),
    "SB_FROZEN_MATCH": str(int(first_pid(sb) == frozen_sb)),
    "BB_FROZEN_MATCH": str(int(first_pid(bb) == frozen_bb)),
    "FC_FROZEN_MATCH": str(int(first_pid(fc) == frozen_fc)),
    "ZY_FROZEN_PRESENT": str(int(any(pid == frozen_zy for pid, _ in zy))),
}
Path(out_path).write_text(
    "".join(f"{key}={value}\n" for key, value in rows.items()),
    encoding="utf-8",
)
PY
}

capture_marker() {
  local var="$1" dir="$2" name="$3" path
  path="$var/.ziyan_$name"
  mkdir -p "$dir"
  "${REMOTE[@]}" "if test -e '$path'; then printf 'PRESENT\n'; stat -c '%Y' '$path'; else printf 'ABSENT\n'; fi" \
    </dev/null >"$dir/${name}.state" 2>"$dir/${name}.state.stderr" || return 1
  if [ "$(head -n 1 "$dir/${name}.state")" = PRESENT ]; then
    remote_to_file "$dir/${name}.body" "cat '$path'" || return 1
  else
    : >"$dir/${name}.body"
  fi
}

capture_state() {
  local var="$1" dir="$2" label="$3" frozen_sb="$4" frozen_bb="$5" frozen_fc="$6" frozen_zy="$7"
  mkdir -p "$dir"
  remote_to_file "$dir/profile.txt" "cat '$var/.ziyan_agent_current_profile'" || true
  remote_to_file "$dir/session.txt" "cat '$var/.ziyan_agent_session'" || true
  remote_to_file "$dir/front.txt" "cat '$var/.ziyan_front_bid'" || true
  remote_to_file "$dir/req.txt" "cat '$var/.ziyan_agent_req'" || true
  remote_to_file "$dir/hooks.txt" "cat '$var/.ziyan_hooks'" || true
  remote_to_file "$dir/learn_ls.txt" "find '$LEARN_ROOT' -maxdepth 1 -type f -print | sort" || true
  remote_to_file "$dir/record_ls.txt" "find '$RECORD_ROOT' -maxdepth 1 -type f -print | sort" || true
  remote_to_file "$dir/ps.txt" 'ps -A -o pid=,args=' || true
  ps_metrics "$dir/ps.txt" "$dir/METRICS.txt" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"

  local front profile bundle state
  front="$(read_value "$dir/front.txt")"
  profile="$(session_value "$dir/profile.txt" profile_id)"
  bundle="$(session_value "$dir/profile.txt" bundle_id)"
  state="$(session_value "$dir/session.txt" state)"
  {
    printf '%s_FRONT=%s\n' "$label" "$front"
    printf '%s_PROFILE_ID=%s\n' "$label" "$profile"
    printf '%s_BUNDLE_ID=%s\n' "$label" "$bundle"
    printf '%s_SESSION_STATE=%s\n' "$label" "$state"
    while IFS= read -r line; do printf '%s_%s\n' "$label" "$line"; done <"$dir/METRICS.txt"
  } >"$dir/STATE.txt"
}

new_files() {
  comm -13 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2")
}

check_marker_unchanged() {
  local baseline="$1" after="$2" name="$3"
  cmp -s "$baseline/${name}.state" "$after/${name}.state" &&
    cmp -s "$baseline/${name}.body" "$after/${name}.body"
}

run_case() {
  local case_name="$1" expected_reason="$2" profile_mode="$3"
  local ip="$4" scheme="$5" var="$6" lua="$7" run="$8" agent="$9"
  local frozen_sb="${10}" frozen_bb="${11}" frozen_fc="${12}" frozen_zy="${13}"
  local out="$CASE_OUT/$case_name"
  local profile_path="$var/.ziyan_agent_current_profile"
  local req="$var/.ziyan_agent_req"
  local run_cmd run_rc=0 post_sid report new_learns new_records tapped_records=0 case_ok=1 record

  mkdir -p "$out"
  capture_state "$var" "$out/pre" PRE "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"
  capture_marker "$var" "$out/pre" tap_gate || case_ok=0
  capture_marker "$var" "$out/pre" tap_meta || case_ok=0

  if [ "$profile_mode" = empty ]; then
    "${REMOTE[@]}" ": > '$profile_path'; printf 'mode=auto\n' > '$req'; chmod 666 '$profile_path' '$req' 2>/dev/null" \
      >"$out/mutate.log" 2>&1 || case_ok=0
  else
    "${REMOTE[@]}" "printf '%s\n' 'profile_id=agent_wrong_bundle' 'bundle_id=com.apple.Preferences' 'display_name=WrongBundle' 'game_name=ZiYan' > '$profile_path'; printf 'mode=auto\n' > '$req'; chmod 666 '$profile_path' '$req' 2>/dev/null" \
      >"$out/mutate.log" 2>&1 || case_ok=0
  fi
  capture_state "$var" "$out/armed" ARMED "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"

  if [ "$scheme" = rootless ]; then
    run_cmd="DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib '$lua' '$run' '$agent'"
  else
    run_cmd="'$lua' '$run' '$agent'"
  fi
  remote_to_file "$out/run.stdout.txt" "$run_cmd" || run_rc=$?

  capture_state "$var" "$out/post" POST "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"
  capture_marker "$var" "$out/post" tap_gate || case_ok=0
  capture_marker "$var" "$out/post" tap_meta || case_ok=0
  post_sid="$(session_value "$out/post/session.txt" session_id)"
  if [ -n "$post_sid" ]; then
    report="$REPORT_ROOT/$post_sid.txt"
    remote_to_file "$out/report.txt" "cat '$report'" || true
  else
    : >"$out/report.txt"
  fi
  new_files "$out/pre/learn_ls.txt" "$out/post/learn_ls.txt" >"$out/new_learning_files.txt"
  new_files "$out/pre/record_ls.txt" "$out/post/record_ls.txt" >"$out/new_record_files.txt"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    remote_to_file "$out/record_$(basename "$record")" "cat '$record'" || case_ok=0
    grep -qF 'tapped=1' "$out/record_$(basename "$record")" && tapped_records=$((tapped_records + 1))
  done <"$out/new_record_files.txt"
  new_learns="$(wc -l <"$out/new_learning_files.txt" | tr -d ' ')"
  new_records="$(wc -l <"$out/new_record_files.txt" | tr -d ' ')"

  grep -qx 'state=PAUSED_SAFE' "$out/post/session.txt" || case_ok=0
  grep -qx 'error_code=PAUSED_SAFE' "$out/report.txt" || case_ok=0
  grep -qx "stop_reason=$expected_reason" "$out/report.txt" || case_ok=0
  grep -qx "paused=$expected_reason" "$out/report.txt" || case_ok=0
  [ "$run_rc" = 0 ] || case_ok=0
  [ "$new_learns" = 0 ] || case_ok=0
  [ "$tapped_records" = 0 ] || case_ok=0
  check_marker_unchanged "$PRE_MARKERS" "$out/post" tap_gate || case_ok=0
  check_marker_unchanged "$PRE_MARKERS" "$out/post" tap_meta || case_ok=0
  grep -q '^POST_FRONT=com.ziyan.ziyan$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_FC_N=1$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_REAL_AGENT_LUA_N=0$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_SB_FROZEN_MATCH=1$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_BB_FROZEN_MATCH=1$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_FC_FROZEN_MATCH=1$' "$out/post/STATE.txt" || case_ok=0
  grep -q '^POST_ZY_FROZEN_PRESENT=1$' "$out/post/STATE.txt" || case_ok=0
  grep -qx 'mode=auto' "$out/post/req.txt" || case_ok=0
  if [ "$profile_mode" = empty ]; then
    [ ! -s "$out/post/profile.txt" ] || case_ok=0
  else
    grep -qx 'profile_id=agent_wrong_bundle' "$out/post/profile.txt" || case_ok=0
    grep -qx 'bundle_id=com.apple.Preferences' "$out/post/profile.txt" || case_ok=0
  fi

  {
    printf 'CASE=%s\n' "$([ "$case_ok" = 1 ] && printf OK || printf FAIL)"
    printf 'EXPECTED_REASON=%s\nRUN_RC=%s\n' "$expected_reason" "$run_rc"
    printf 'NEW_LEARNING_FILES=%s\nNEW_RECORD_FILES=%s\nNEW_TAPPED_RECORDS=%s\n' \
      "$new_learns" "$new_records" "$tapped_records"
    printf 'TAP_GATE_UNCHANGED=%s\n' "$(check_marker_unchanged "$PRE_MARKERS" "$out/post" tap_gate && printf 1 || printf 0)"
    printf 'TAP_META_UNCHANGED=%s\n' "$(check_marker_unchanged "$PRE_MARKERS" "$out/post" tap_meta && printf 1 || printf 0)"
  } >"$out/STATE.txt"
  [ "$case_ok" = 1 ]
}

restore_profile() {
  local ip="$1" var="$2" out="$3"
  copy_to_device "$ip" "$PROFILE_BACKUP" "$var/.ziyan_agent_current_profile" "$out/restore.log" ||
    return 1
  remote_to_file "$out/profile.restored.txt" "cat '$var/.ziyan_agent_current_profile'" || return 1
  cmp -s "$PROFILE_BACKUP" "$out/profile.restored.txt"
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5" frozen_fc="$6" frozen_zy="$7"
  local out="$OUT/${tag#.}" var lua run agent runtime remote_sha source_sha
  local ok=1
  mkdir -p "$out"
  : >"$out/TRANSCRIPT.log"

  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
    lua=/var/jb/usr/lib/ziyan/bin/lua5.3
    run=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
    agent=/var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
    runtime=/var/jb/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
  else
    var=/usr/lib/ziyan/var
    lua=/usr/lib/ziyan/bin/lua5.3
    run=/usr/lib/ziyan/lib/lua/ziyan_run.lua
    agent=/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua
    runtime=/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
  fi
  if ! connect_device "$ip"; then
    printf 'SMOKE=FAIL\nREASON=SSH_CONNECT\n' >"$out/STATE.txt"
    return 1
  fi
  write_transcript "$out" "AUTH=$AUTH"

  source_sha="$(openssl dgst -sha256 -r "$SOURCE" | awk '{print $1}')"
  remote_to_file "$out/runtime.sha256.txt" "sha256sum '$runtime'" || ok=0
  remote_sha="$(awk 'NF {print $1; exit}' "$out/runtime.sha256.txt")"
  printf 'SOURCE_SHA256=%s\nREMOTE_SHA256=%s\n' "$source_sha" "$remote_sha" >>"$out/TRANSCRIPT.log"

  capture_state "$var" "$out/pre" PRE "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"
  capture_marker "$var" "$out/pre_markers" tap_gate || ok=0
  capture_marker "$var" "$out/pre_markers" tap_meta || ok=0
  PROFILE_BACKUP="$out/profile_backup.txt"
  cp "$out/pre/profile.txt" "$PROFILE_BACKUP"
  PRE_MARKERS="$out/pre_markers"
  CASE_OUT="$out"

  if [ "$source_sha" != "$EXPECTED_SHA" ] || [ "$remote_sha" != "$EXPECTED_SHA" ] ||
     ! grep -qx 'profile_id=agent_default_observe' "$PROFILE_BACKUP" ||
     ! grep -qx 'bundle_id=com.ziyan.ziyan' "$PROFILE_BACKUP" ||
     ! grep -q '^PRE_FRONT=com.ziyan.ziyan$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_FC_N=1$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_REAL_AGENT_LUA_N=0$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_SB_FROZEN_MATCH=1$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_BB_FROZEN_MATCH=1$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_FC_FROZEN_MATCH=1$' "$out/pre/STATE.txt" ||
     ! grep -q '^PRE_ZY_FROZEN_PRESENT=1$' "$out/pre/STATE.txt"; then
    ok=0
    write_transcript "$out" "PRECHECK=FAIL"
  else
    write_transcript "$out" "PRECHECK=OK"
  fi

  if [ "$ok" = 1 ]; then
    run_case no_profile no_profile empty "$ip" "$scheme" "$var" "$lua" "$run" "$agent" \
      "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy" || ok=0
    if ! restore_profile "$ip" "$var" "$out/no_profile"; then
      ok=0
      write_transcript "$out" "RESTORE_AFTER_NO_PROFILE=FAIL"
    else
      write_transcript "$out" "RESTORE_AFTER_NO_PROFILE=OK"
    fi
  fi

  if [ "$ok" = 1 ]; then
    capture_state "$var" "$out/between" BETWEEN "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"
    cmp -s "$PROFILE_BACKUP" "$out/between/profile.txt" ||
      ok=0
    grep -q '^BETWEEN_REAL_AGENT_LUA_N=0$' "$out/between/STATE.txt" ||
      ok=0
    grep -q '^BETWEEN_SB_FROZEN_MATCH=1$' "$out/between/STATE.txt" ||
      ok=0
  fi

  if [ "$ok" = 1 ]; then
    run_case wrong_bundle bundle_mismatch wrong "$ip" "$scheme" "$var" "$lua" "$run" "$agent" \
      "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy" || ok=0
    if ! restore_profile "$ip" "$var" "$out/wrong_bundle"; then
      ok=0
      write_transcript "$out" "RESTORE_AFTER_WRONG_BUNDLE=FAIL"
    else
      write_transcript "$out" "RESTORE_AFTER_WRONG_BUNDLE=OK"
    fi
  fi

  capture_state "$var" "$out/final" FINAL "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"
  cmp -s "$PROFILE_BACKUP" "$out/final/profile.txt" || ok=0
  grep -q '^FINAL_PROFILE_ID=agent_default_observe$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_BUNDLE_ID=com.ziyan.ziyan$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_FRONT=com.ziyan.ziyan$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_FC_N=1$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_REAL_AGENT_LUA_N=0$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_SB_FROZEN_MATCH=1$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_BB_FROZEN_MATCH=1$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_FC_FROZEN_MATCH=1$' "$out/final/STATE.txt" || ok=0
  grep -q '^FINAL_ZY_FROZEN_PRESENT=1$' "$out/final/STATE.txt" || ok=0

  if [ "$ok" = 1 ]; then
    write_transcript "$out" "SMOKE=OK"
    printf 'SMOKE=OK\n' >"$out/STATE.txt"
    return 0
  fi
  write_transcript "$out" "SMOKE=FAIL"
  printf 'SMOKE=FAIL\nREASON=see_TRANSCRIPT_and_case_STATE\n' >"$out/STATE.txt"
  return 1
}

all_ok=1
reasons=()
run_one .101 192.168.31.101 rootful 87863 87862 47853 96 || { all_ok=0; reasons+=(.101); }
if [ "$all_ok" = 1 ]; then
  run_one .112 192.168.31.112 rootful 79809 79808 98110 92 || { all_ok=0; reasons+=(.112); }
fi
if [ "$all_ok" = 1 ]; then
  run_one .166 192.168.31.166 rootful 25025 25024 52622 82626 || { all_ok=0; reasons+=(.166); }
fi
if [ "$all_ok" = 1 ]; then
  run_one .53 192.168.31.53 rootless 46408 74318 49176 93705 || { all_ok=0; reasons+=(.53); }
fi

{
  printf '# 八号开发：HID 安全门\n\n'
  printf '这是八号开发，不是九号；不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload。\n'
  printf '本刀只运行 mode=auto 的 no_profile 与 bundle_mismatch 失败路径；没有 Home、设置、游戏或七号成功 HID。\n\n'
  for tag in 101 112 166 53; do
    printf '## .%s\n\n' "$tag"
    if [ -f "$OUT/$tag/TRANSCRIPT.log" ]; then
      grep -E '^(AUTH|SOURCE_SHA256|REMOTE_SHA256|PRECHECK|RESTORE_|SMOKE)=' "$OUT/$tag/TRANSCRIPT.log" || true
      grep -hE '^(CASE|EXPECTED_REASON|RUN_RC|NEW_LEARNING_FILES|NEW_RECORD_FILES|NEW_TAPPED_RECORDS|TAP_GATE_UNCHANGED|TAP_META_UNCHANGED)=' \
        "$OUT/$tag"/no_profile/STATE.txt "$OUT/$tag"/wrong_bundle/STATE.txt 2>/dev/null || true
    else
      printf 'SMOKE=NOT_RUN\n'
    fi
    printf '\n'
  done
  if [ "$all_ok" = 1 ]; then
    printf 'AGENT_TRUE_HID_SAFE_GATE=PASS_PENDING_HUMAN\n'
  else
    printf 'AGENT_TRUE_HID_SAFE_GATE=PARTIAL_PENDING_HUMAN\n'
    printf 'REASON=%s\n' "${reasons[*]:-device_or_contract_failure}"
  fi
  printf 'NOT_AGENT_MVP_4PHONE_PASS=1\nNOT_G0=1\nNO_SBRELOAD_EXECUTED=1\n'
} >"$OUT/VERDICT.md"

python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "八号开发：HID 安全门；空 profile 与错 bundle 必须 PAUSED_SAFE 且 tap=0" \
  --last-command "bash tools/zy_dev08_agent_true_hid_safe_gate.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "$([ "$all_ok" = 1 ] && printf '四机 no_profile/bundle_mismatch 均 PAUSED_SAFE，tap gate/meta 未更新、无新学习文件和 tapped=1 记录，profile 已恢复。' || printf '八号安全门未四机全通过；已停止后续设备；profile 恢复与失败证据见本刀目录。')" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV08_AGENT_TRUE_HID_SAFE_GATE_20260906/VERDICT.md；四机 PRE/POST、marker 原文与 mtime、session/error report、目录清单与 ps 原文" \
  --latest-verdict "$(tr '\n' ';' < "$OUT/VERDICT.md")" \
  --package-version "本刀未安装、重建、改包或 scp runtime" \
  --package-sha256 "仓库与四机 runtime sha256sum 均要求 a78767ab6a51f3c81786e6d888179d8e01102ca41680ae7842b20ab0061292ae" \
  --device-state "严格串行；每台两次 mode=auto 失败入口；未 Home/设置/游戏/七号成功 HID；未 sbreload" \
  --running-processes "SpringBoard/FC 仅本机按 args 结尾筛选；真实 agent lua 按 lua5.3 + ziyan_agent_run.lua 同时筛选；冻结 zy 存在即可" \
  --cleanup-status "每步 PAUSED_SAFE 后无真实 agent lua；profile 恢复 agent_default_observe/com.ziyan.ziyan；unfinished=true，等待人工最终审核" \
  >/dev/null

cat "$OUT/VERDICT.md"
exit "$([ "$all_ok" = 1 ] && printf 0 || printf 1)"
