#!/usr/bin/env bash
# 七号开发：真自研对子砚一次比例 HID tap。严格串行，单刀单次入口。
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Agent/Core/agent_runtime.lua"
OUT="$ROOT/tmp_shots/DEV07_AGENT_TRUE_HID_ZIYAN_20260906"
PASS="${ZY_SSH_PASS:-alpine}"
LEARN_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/学习数据"
RECORD_ROOT="/private/var/mobile/Media/ZiYan/Agent游戏/运行记录"

if [ -e "$OUT" ]; then
  printf 'evidence directory already exists: %s\n' "$OUT" >&2
  exit 2
fi
[ -f "$SOURCE" ] || { printf 'runtime source missing: %s\n' "$SOURCE" >&2; exit 2; }
mkdir -p "$OUT"

# 不使用 BatchMode=yes：先公钥，失败后密码回退。
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

copy_from_device() {
  local ip="$1" source="$2" target="$3" log="$4"
  "${SCP_REMOTE[@]}" "root@$ip:$source" "$target" >"$log" 2>&1
}

copy_to_device() {
  local ip="$1" source="$2" target="$3" log="$4"
  "${SCP_REMOTE[@]}" "$source" "root@$ip:$target" >"$log" 2>&1
}

sha256_file_local() {
  openssl dgst -sha256 -r "$1" | awk '{print $1}'
}

# 只在本机解析 ps；远程只执行 ps，不把 SpringBoard 路径字样送进设备 shell。
ps_metrics() {
  local ps_file="$1" out_file="$2" frozen_sb="$3" frozen_bb="$4" frozen_fc="$5" frozen_zy="$6"
  python3 - "$ps_file" "$out_file" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy" <<'PY'
from pathlib import Path
import sys

ps_path, out_path, frozen_sb, frozen_bb, frozen_fc, frozen_zy = sys.argv[1:]
lines = ps_path and Path(ps_path).read_text(errors="replace").splitlines()

def excluded(args):
    return any(x in args for x in ("sh -c", "zsh -c", "bash -s", "grep", "sed"))

def rows_for_suffix(suffix):
    rows = []
    for line in lines:
        text = line.strip()
        if not text:
            continue
        parts = text.split(None, 1)
        if len(parts) != 2:
            continue
        pid, args = parts
        if excluded(args):
            continue
        if args.endswith(suffix):
            rows.append((pid, args))
    return rows

sb = rows_for_suffix("/System/Library/CoreServices/SpringBoard.app/SpringBoard")
bb = rows_for_suffix("backboardd")
fc = rows_for_suffix("ziyan_framecap serve")
zy = []
agent = []
for line in lines:
    text = line.strip()
    parts = text.split(None, 1)
    if len(parts) != 2:
        continue
    pid, args = parts
    if excluded(args):
        continue
    if "ziyadaemond" in args or "ziyan_zydaemond" in args:
        zy.append((pid, args))
    if "lua5.3" in args and "ziyan_agent_run.lua" in args:
        agent.append((pid, args))

def pid(rows):
    return rows[0][0] if rows else ""

def emit(name, value):
    with open(out_path, "a", encoding="utf-8") as f:
        f.write(f"{name}={value}\n")

Path(out_path).write_text("", encoding="utf-8")
emit("SB_PID", pid(sb))
emit("SB_LINE", sb[0][1] if sb else "")
emit("BB_PID", pid(bb))
emit("BB_LINE", bb[0][1] if bb else "")
emit("FC_PID", pid(fc))
emit("FC_N", len(fc))
emit("FC_LINE", fc[0][1] if fc else "")
emit("ZY_PID", pid(zy))
emit("ZY_LINES", " || ".join(f"{p} {a}" for p, a in zy))
emit("REAL_AGENT_LUA_N", len(agent))
emit("REAL_AGENT_LUA_LINES", " || ".join(f"{p} {a}" for p, a in agent))
emit("SB_FROZEN_MATCH", int(pid(sb) == frozen_sb))
emit("BB_FROZEN_MATCH", int(pid(bb) == frozen_bb))
emit("FC_FROZEN_MATCH", int(pid(fc) == frozen_fc))
emit("ZY_FROZEN_PRESENT", int(any(p == frozen_zy for p, _ in zy)))
PY
}

new_ids() {
  local before="$1" after="$2"
  comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after") |
    sed -n 's/^\(ags_[A-Za-z0-9_]*\.txt\)$/\1/p' | sed 's/\.txt$//'
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5" frozen_fc="$6" frozen_zy="$7"
  local out="$OUT/${tag#.}" var runtime run_cmd ps_pre ps_post metrics_pre metrics_post
  local front profile bundle req_before session_before learn_before records_before
  local learn_after records_after record_id run_rc run_seconds start_s end_s
  local source_sha remote_sha failures=() record_path

  mkdir -p "$out"
  : >"$out/TRANSCRIPT.log"
  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
    runtime=/var/jb/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
    run_cmd='DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua /var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua'
  else
    var=/usr/lib/ziyan/var
    runtime=/usr/lib/ziyan/lib/lua/agent/Core/agent_runtime.lua
    run_cmd='/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua /usr/lib/ziyan/lib/lua/ziyan_agent_run.lua'
  fi

  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nPRECHECK=FAIL\nREASON=SSH_CONNECT\nSMOKE=FAIL\n' >"$out/STATE.txt"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  remote_to_file "$out/PS_PRE.txt" 'ps -A -o pid=,args=' || failures+=(ps_pre)
  remote_to_file "$out/HOOKS_PRE.txt" "cat '$var/.ziyan_hooks'" || failures+=(hooks_read)
  remote_to_file "$out/FRONT_PRE.txt" "cat '$var/.ziyan_front_bid'" || failures+=(front_read)
  remote_to_file "$out/SESSION_PRE.txt" "cat '$var/.ziyan_agent_session'" || true
  remote_to_file "$out/PROFILE_PRE.txt" "cat '$var/.ziyan_agent_current_profile'" || failures+=(profile_read)
  remote_to_file "$out/REQ_PRE.txt" "cat '$var/.ziyan_agent_req'" || true
  remote_to_file "$out/UI_LEARN_PRE.txt" "cat '$var/.ziyan_ui_learn.json' 2>/dev/null" || true
  remote_to_file "$out/UI_GAMEPLAY_PRE.txt" "cat '$var/.ziyan_ui_gameplay.json' 2>/dev/null" || true
  remote_to_file "$out/LEARN_PRE.txt" "ls -1 '$LEARN_ROOT' 2>/dev/null" || failures+=(learn_ls_pre)
  remote_to_file "$out/RECORDS_PRE.txt" "ls -1 '$RECORD_ROOT' 2>/dev/null" || failures+=(records_ls_pre)
  ps_metrics "$out/PS_PRE.txt" "$out/METRICS_PRE.txt" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"

  front="$(tr -d '\r\n' <"$out/FRONT_PRE.txt" 2>/dev/null)"
  profile="$(sed -n 's/^profile_id=//p' "$out/PROFILE_PRE.txt" | head -1)"
  bundle="$(sed -n 's/^bundle_id=//p' "$out/PROFILE_PRE.txt" | head -1)"
  req_before="$(tr '\n' ';' <"$out/REQ_PRE.txt" 2>/dev/null)"
  session_before="$(tr '\n' ';' <"$out/SESSION_PRE.txt" 2>/dev/null)"
  {
    printf 'PRE_FRONT=%s\nPRE_PROFILE_ID=%s\nPRE_BUNDLE=%s\nPRE_REQ=%s\nPRE_SESSION=%s\n' "$front" "$profile" "$bundle" "$req_before" "$session_before"
    cat "$out/METRICS_PRE.txt"
  } >>"$out/TRANSCRIPT.log"

  [ "$(sed -n 's/^SB_FROZEN_MATCH=//p' "$out/METRICS_PRE.txt")" = 1 ] || failures+=(sb_frozen)
  [ "$(sed -n 's/^BB_FROZEN_MATCH=//p' "$out/METRICS_PRE.txt")" = 1 ] || failures+=(bb_frozen)
  [ "$(sed -n 's/^FC_FROZEN_MATCH=//p' "$out/METRICS_PRE.txt")" = 1 ] || failures+=(fc_frozen)
  [ "$(sed -n 's/^FC_N=//p' "$out/METRICS_PRE.txt")" = 1 ] || failures+=(fc_n)
  [ "$(sed -n 's/^ZY_FROZEN_PRESENT=//p' "$out/METRICS_PRE.txt")" = 1 ] || failures+=(zy_frozen)
  [ "$(sed -n 's/^REAL_AGENT_LUA_N=//p' "$out/METRICS_PRE.txt")" = 0 ] || failures+=(real_agent_lua_pre)
  [ "$front" = com.ziyan.ziyan ] || failures+=(front_not_ziyan)
  [ "$profile" = agent_default_observe ] || failures+=(profile_changed)
  [ "$bundle" = com.ziyan.ziyan ] || failures+=(profile_bundle)

  # 先备份设备原 runtime 到本机证据，再仅覆盖这一文件。
  if ! copy_from_device "$ip" "$runtime" "$out/agent_runtime.before.lua" "$out/scp_backup.log"; then
    failures+=(backup_failed)
  fi
  source_sha="$(sha256_file_local "$SOURCE")"
  remote_to_file "$out/SHA_PRE.txt" "sha256sum '$runtime'" || failures+=(sha_pre)
  {
    printf 'SOURCE_SHA256=%s\n' "$source_sha"
    cat "$out/SHA_PRE.txt"
  } >>"$out/TRANSCRIPT.log"

  if [ "${#failures[@]}" -ne 0 ]; then
    printf 'PRECHECK=FAIL\nREASON=%s\nSMOKE=FAIL\n' "$(IFS=,; echo "${failures[*]}")" >>"$out/TRANSCRIPT.log"
    printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; echo "${failures[*]}")" >"$out/STATE.txt"
    return 1
  fi
  printf 'PRECHECK=OK\n' >>"$out/TRANSCRIPT.log"

  if ! copy_to_device "$ip" "$SOURCE" "$runtime" "$out/scp_deploy.log"; then
    printf 'DEPLOY=FAIL\nSMOKE=FAIL\n' >>"$out/TRANSCRIPT.log"
    printf 'SMOKE=FAIL\nREASON=deploy_failed\n' >"$out/STATE.txt"
    return 1
  fi
  remote_to_file "$out/SHA_POST_DEPLOY.txt" "sha256sum '$runtime'" || failures+=(sha_post_deploy)
  remote_sha="$(awk 'NF {print $1; exit}' "$out/SHA_POST_DEPLOY.txt")"
  [ "$remote_sha" = "$source_sha" ] || failures+=(sha_mismatch)
  printf 'DEPLOY_SHA256=%s\nDEPLOY=OK\n' "$remote_sha" >>"$out/TRANSCRIPT.log"
  if [ "${#failures[@]}" -ne 0 ]; then
    printf 'DEPLOY=FAIL\nREASON=%s\nSMOKE=FAIL\n' "$(IFS=,; echo "${failures[*]}")" >>"$out/TRANSCRIPT.log"
    printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; echo "${failures[*]}")" >"$out/STATE.txt"
    return 1
  fi

  # 只写 mode=auto；不碰 profile、学习文件或任何 UI 控制文件。
  remote_to_file "$out/REQ_WRITE.txt" "printf 'mode=auto\\n' > '$var/.ziyan_agent_req'" || failures+=(req_write)
  remote_to_file "$out/REQ_RUN.txt" "cat '$var/.ziyan_agent_req'" || failures+=(req_read)
  cmp -s <(printf 'mode=auto\n') "$out/REQ_RUN.txt" || failures+=(req_not_exact)
  printf 'REQ_EXACT=mode=auto\n' >>"$out/TRANSCRIPT.log"
  if [ "${#failures[@]}" -ne 0 ]; then
    printf 'REQ=FAIL\nREASON=%s\nSMOKE=FAIL\n' "$(IFS=,; echo "${failures[*]}")" >>"$out/TRANSCRIPT.log"
    printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; echo "${failures[*]}")" >"$out/STATE.txt"
    return 1
  fi

  start_s="$(date +%s)"
  run_rc=0
  remote_to_file "$out/RUN_STDOUT.txt" "$run_cmd" || run_rc=$?
  end_s="$(date +%s)"
  run_seconds=$((end_s - start_s))
  printf 'RUN_RC=%s\nRUN_SECONDS=%s\n' "$run_rc" "$run_seconds" >>"$out/TRANSCRIPT.log"
  [ "$run_rc" = 0 ] || failures+=(run_rc)
  [ "$run_seconds" -le 15 ] || failures+=(run_too_long)

  remote_to_file "$out/SESSION_POST.txt" "cat '$var/.ziyan_agent_session'" || failures+=(session_post_read)
  remote_to_file "$out/FRONT_POST.txt" "cat '$var/.ziyan_front_bid'" || failures+=(front_post_read)
  remote_to_file "$out/PROFILE_POST.txt" "cat '$var/.ziyan_agent_current_profile'" || failures+=(profile_post_read)
  remote_to_file "$out/REQ_POST.txt" "cat '$var/.ziyan_agent_req'" || failures+=(req_post_read)
  remote_to_file "$out/UI_LEARN_POST.txt" "cat '$var/.ziyan_ui_learn.json' 2>/dev/null" || true
  remote_to_file "$out/UI_GAMEPLAY_POST.txt" "cat '$var/.ziyan_ui_gameplay.json' 2>/dev/null" || true
  remote_to_file "$out/LEARN_POST.txt" "ls -1 '$LEARN_ROOT' 2>/dev/null" || failures+=(learn_ls_post)
  remote_to_file "$out/RECORDS_POST.txt" "ls -1 '$RECORD_ROOT' 2>/dev/null" || failures+=(records_ls_post)
  remote_to_file "$out/PS_POST.txt" 'ps -A -o pid=,args=' || failures+=(ps_post)
  ps_metrics "$out/PS_POST.txt" "$out/METRICS_POST.txt" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"

  learn_before="$out/LEARN_PRE.txt"
  learn_after="$out/LEARN_POST.txt"
  records_before="$out/RECORDS_PRE.txt"
  records_after="$out/RECORDS_POST.txt"
  new_learns=()
  while IFS= read -r item; do
    [ -n "$item" ] && new_learns+=("$item")
  done < <(new_ids "$learn_before" "$learn_after")
  new_records=()
  while IFS= read -r item; do
    [ -n "$item" ] && new_records+=("$item")
  done < <(new_ids "$records_before" "$records_after")
  [ "${#new_learns[@]}" = 0 ] || failures+=(new_learning_file)
  [ "${#new_records[@]}" = 1 ] || failures+=(new_record_count)
  record_id="${new_records[0]:-}"
  if [ -n "$record_id" ]; then
    record_path="$RECORD_ROOT/$record_id.txt"
    remote_to_file "$out/RECORD_NEW.txt" "cat '$record_path'" || failures+=(record_read)
  else
    : >"$out/RECORD_NEW.txt"
  fi

  profile="$(sed -n 's/^profile_id=//p' "$out/PROFILE_POST.txt" | head -1)"
  bundle="$(sed -n 's/^bundle_id=//p' "$out/PROFILE_POST.txt" | head -1)"
  front="$(tr -d '\r\n' <"$out/FRONT_POST.txt" 2>/dev/null)"
  {
    printf 'POST_FRONT=%s\nPOST_PROFILE_ID=%s\nPOST_BUNDLE=%s\n' "$front" "$profile" "$bundle"
    cat "$out/METRICS_POST.txt"
    printf 'NEW_LEARN_N=%s\nNEW_RECORD_N=%s\nNEW_RECORD_ID=%s\n' "${#new_learns[@]}" "${#new_records[@]}" "$record_id"
  } >>"$out/TRANSCRIPT.log"

  [ "$(grep -c '^state=STOPPED$' "$out/SESSION_POST.txt")" = 1 ] || failures+=(session_not_stopped)
  grep -qx 'active=0' "$out/SESSION_POST.txt" || failures+=(session_not_active_zero)
  [ "$front" = com.ziyan.ziyan ] || failures+=(front_post_not_ziyan)
  [ "$profile" = agent_default_observe ] || failures+=(profile_post_changed)
  [ "$bundle" = com.ziyan.ziyan ] || failures+=(profile_post_bundle)
  grep -qx 'mode=auto' "$out/REQ_POST.txt" || failures+=(req_post_changed)
  [ "$(sed -n 's/^SB_FROZEN_MATCH=//p' "$out/METRICS_POST.txt")" = 1 ] || failures+=(sb_post_frozen)
  [ "$(sed -n 's/^BB_FROZEN_MATCH=//p' "$out/METRICS_POST.txt")" = 1 ] || failures+=(bb_post_frozen)
  [ "$(sed -n 's/^FC_FROZEN_MATCH=//p' "$out/METRICS_POST.txt")" = 1 ] || failures+=(fc_post_frozen)
  [ "$(sed -n 's/^FC_N=//p' "$out/METRICS_POST.txt")" = 1 ] || failures+=(fc_post_n)
  [ "$(sed -n 's/^ZY_FROZEN_PRESENT=//p' "$out/METRICS_POST.txt")" = 1 ] || failures+=(zy_post_frozen)
  [ "$(sed -n 's/^REAL_AGENT_LUA_N=//p' "$out/METRICS_POST.txt")" = 0 ] || failures+=(real_agent_lua_post)
  if grep -qi 'started' "$out/UI_LEARN_POST.txt"; then failures+=(ui_learn_started); fi
  if grep -qi 'started' "$out/UI_GAMEPLAY_POST.txt"; then failures+=(ui_gameplay_started); fi

  if [ -n "$record_id" ]; then
    for required in \
      'mode=auto' 'front_bid=com.ziyan.ziyan' 'observed=' 'identified=' \
      'verified=' 'tapped=1' 'tap_rx=0.50' 'tap_ry=0.08' \
      'stop_reason=auto_hid_ziyan_done'; do
      grep -qF "$required" "$out/RECORD_NEW.txt" || failures+=(record_missing_${required%%=*})
    done
    for forbidden in 'auto_cycle_done' 'mode=safe_action' 'auto_delegate_app' 'mode=learn' 'mode=drill'; do
      grep -qF "$forbidden" "$out/RECORD_NEW.txt" && failures+=(record_forbidden_${forbidden%%=*})
    done
  else
    failures+=(record_missing)
  fi
  grep -qF 'mode=auto' "$out/RUN_STDOUT.txt" 2>/dev/null && true

  if [ "${#failures[@]}" -eq 0 ]; then
    printf 'SMOKE=OK\nRUN_RC=0\nNEW_RECORD_ID=%s\n' "$record_id" >"$out/STATE.txt"
    printf 'SMOKE=OK\n' >>"$out/TRANSCRIPT.log"
    return 0
  fi
  printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; echo "${failures[*]}")" >"$out/STATE.txt"
  printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; echo "${failures[*]}")" >>"$out/TRANSCRIPT.log"
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

python3 - "$OUT" "$all_ok" "${reasons[*]:-}" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
all_ok = sys.argv[2] == "1"
reasons = sys.argv[3]
rows = []
for tag in ("101", "112", "166", "53"):
    state = out / tag / "STATE.txt"
    if not state.exists():
        rows.append((tag, "NOT_RUN", "prior_device_not_clean"))
        continue
    text = state.read_text(errors="replace")
    smoke = "OK" if "SMOKE=OK" in text else "FAIL"
    reason = next((x.split("=", 1)[1] for x in text.splitlines() if x.startswith("REASON=")), "none")
    rows.append((tag, smoke, reason))

lines = [
    "# 七号开发：真自研对子砚点一次比例死区",
    "",
    "这是七号开发，502 后重贴，不是八号；不是六号续。",
    "本刀只覆盖 mode=auto 的一次真 HID tap：rx=0.50、ry=0.08。",
    "不是 AGENT_MVP_4PHONE_PASS；不是 G0；未 sbreload；未点游戏。",
    "",
]
lines.extend(f"- .{tag}: SMOKE={smoke} REASON={reason}" for tag, smoke, reason in rows)
lines.extend([
    "",
    "AGENT_TRUE_HID_ZIYAN=" + ("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN"),
])
if not all_ok:
    lines.append("REASON=" + (reasons or "device_or_contract_failure"))
lines.extend([
    "NOT_AGENT_MVP=1",
    "NOT_G0=1",
    "UNFINISHED=1",
    "NEXT_ACTION=等待人工最终审核",
])
(out / "VERDICT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print((out / "VERDICT.md").read_text(), end="")
PY

python3 tools/ziyan_codex_checkpoint.py write \
  --stage "七号开发：真自研对子砚点一次比例死区" \
  --last-command "bash tools/zy_dev07_agent_true_hid_ziyan.sh；严格串行 .101 -> .112 -> .166 -> .53" \
  --result "见 DEV07 VERDICT；本刀只做 mode=auto 真 HID 一次 tap，是否四机全绿以证据为准" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV07_AGENT_TRUE_HID_ZIYAN_20260906/VERDICT.md；四机 PRE/POST/METRICS/RECORD_NEW/TRANSCRIPT" \
  --latest-verdict "$(tr '\n' ';' < "$OUT/VERDICT.md")" \
  --package-version "本刀未安装、重建或改包" \
  --package-sha256 "仅 scp agent_runtime.lua；四机 sha256sum 见证据" \
  --device-state "依 DEV07 四机 STATE/TRANSCRIPT；严格串行，未 sbreload" \
  --running-processes "依 DEV07 四机 POST METRICS：冻结 SB/BB/FC/zy、FC_N、真实 agent lua 见证据" \
  --cleanup-status "每台入口单次；停后 session/active、UI 标记、运行记录见证据；未开八号" \
  >/dev/null

exit "$((1 - all_ok))"
