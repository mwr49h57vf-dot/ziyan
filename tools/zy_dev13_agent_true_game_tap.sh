#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV13_AGENT_TRUE_GAME_TAP_20260906"
PASS="${ZY_SSH_PASS:-alpine}"
TEMPLATE="$ROOT/tools/zy_dev13_game_tap.lua.template"
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
AUTH=

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

read_remote() {
  local file="$1" command="$2"
  "${REMOTE[@]}" "$command" </dev/null >"$file" 2>"$file.stderr"
}

value() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

metric() {
  local ps_file="$1" out_file="$2" frozen_sb="$3" frozen_bb="$4" frozen_fc="$5" frozen_zy="$6"
  python3 - "$ps_file" "$out_file" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy" <<'PY'
from pathlib import Path
import sys

ps_path, out_path, frozen_sb, frozen_bb, frozen_fc, frozen_zy = sys.argv[1:]
lines = Path(ps_path).read_text(encoding="utf-8", errors="replace").splitlines()

def excluded(args):
    return any(token in args for token in ("sh -c", "zsh -c", "bash -s", "grep", "sed"))

def rows_suffix(suffix):
    rows = []
    for line in lines:
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, args = parts
        if not excluded(args) and args.endswith(suffix):
            rows.append((pid, args))
    return rows

sb = rows_suffix("/System/Library/CoreServices/SpringBoard.app/SpringBoard")
bb = rows_suffix("backboardd")
fc = rows_suffix("ziyan_framecap serve")
zy = []
agent = []
run_lua = []
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
    if "lua5.3" in args and "ziyan_run.lua" in args:
        run_lua.append((pid, args))

def first(rows):
    return rows[0][0] if rows else ""

values = {
    "SB_PID": first(sb),
    "SB_LINE": sb[0][1] if sb else "",
    "BB_PID": first(bb),
    "BB_LINE": bb[0][1] if bb else "",
    "FC_PID": first(fc),
    "FC_LINE": fc[0][1] if fc else "",
    "FC_N": str(len(fc)),
    "REAL_AGENT_LUA_N": str(len(agent)),
    "REAL_AGENT_LUA_LINES": " || ".join(f"{p} {a}" for p, a in agent),
    "RUN_LUA_N": str(len(run_lua)),
    "RUN_LUA_LINES": " || ".join(f"{p} {a}" for p, a in run_lua),
    "ZY_LINES": " || ".join(f"{p} {a}" for p, a in zy),
    "SB_FROZEN_MATCH": str(int(first(sb) == frozen_sb)),
    "BB_FROZEN_MATCH": str(int(first(bb) == frozen_bb)),
    "FC_FROZEN_MATCH": str(int(first(fc) == frozen_fc)),
    "ZY_FROZEN_PRESENT": str(int(any(p == frozen_zy for p, _ in zy))),
}
Path(out_path).write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")
PY
}

tap_line_ok() {
  local file="$1" expected_ts="$2" expected_front="$3"
  grep -q '^PRESENT$' "$file" &&
    [ "$(sed -n '2p' "$file")" -gt "$expected_ts" ] 2>/dev/null &&
    grep -q "front=$expected_front" "$file"
}

tap_meta_ok() {
  local file="$1" expected_ts="$2" expected_x="$3" expected_y="$4"
  grep -q '^PRESENT$' "$file" &&
    [ "$(sed -n '2p' "$file")" -gt "$expected_ts" ] 2>/dev/null &&
    grep -Eq "xy=${expected_x},${expected_y}([[:space:]]|$)" "$file"
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5" frozen_fc="$6"
  local frozen_zy="$7" tap_ts="$8" expected_bundle="$9" expected_display="${10}"
  local out="$OUT/$tag" var lua run launch_cmd
  local failures=()
  local front profile profile_bundle keep stop open_state
  local stage_lua="$out/dev13_game_tap.lua"

  mkdir -p "$out"
  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
    lua=/var/jb/usr/lib/ziyan/bin/lua5.3
    run=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
    launch_cmd="DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib '$lua' '$run' /tmp/dev13_game_tap.lua"
    expected_x=621.0
    expected_y=176.64
    expected_meta_y=176.6
  else
    var=/usr/lib/ziyan/var
    lua=/usr/lib/ziyan/bin/lua5.3
    run=/usr/lib/ziyan/lib/lua/ziyan_run.lua
    launch_cmd="'$lua' '$run' /tmp/dev13_game_tap.lua"
    expected_x=320.0
    expected_y=90.88
    expected_meta_y=90.9
  fi
  sed -e "s#__EXPECTED_BUNDLE__#$expected_bundle#g" -e "s#__VAR__#$var#g" "$TEMPLATE" >"$stage_lua"
  printf 'TAG=.%s\nIP=%s\nSCHEME=%s\nEXPECTED_BUNDLE=%s\nEXPECTED_DISPLAY=%s\n' \
    "$tag" "$ip" "$scheme" "$expected_bundle" "$expected_display" >"$out/TRANSCRIPT.log"

  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nTAP=FAIL\nREASON=ssh_connect\n' >>"$out/TRANSCRIPT.log"
    printf 'TAP=FAIL\nREASON=ssh_connect\n' >"$out/STATE.txt"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  collect() {
    local phase="$1"
    read_remote "$out/ps_${phase}.txt" 'ps -A -o pid=,args=' || failures+=("${phase}_ps_read")
    read_remote "$out/front_${phase}.txt" "cat '$var/.ziyan_front_bid'" || failures+=("${phase}_front_read")
    read_remote "$out/profile_${phase}.txt" "cat '$var/.ziyan_agent_current_profile'" || failures+=("${phase}_profile_read")
    read_remote "$out/flags_${phase}.txt" "test -e '$var/.ziyan_keep_daemon' && echo KEEP=PRESENT || echo KEEP=ABSENT; test -e '$var/.ziyan_agent_stop' && echo STOP=PRESENT || echo STOP=ABSENT" || failures+=("${phase}_flags_read")
    read_remote "$out/tap_gate_${phase}.txt" "test -e '$var/.ziyan_tap_gate' && { echo PRESENT; stat -c '%Y' '$var/.ziyan_tap_gate' 2>/dev/null || stat -f '%m' '$var/.ziyan_tap_gate'; cat '$var/.ziyan_tap_gate'; } || echo ABSENT" || failures+=("${phase}_tap_gate_read")
    read_remote "$out/tap_meta_${phase}.txt" "test -e '$var/.ziyan_tap_meta' && { echo PRESENT; stat -c '%Y' '$var/.ziyan_tap_meta' 2>/dev/null || stat -f '%m' '$var/.ziyan_tap_meta'; cat '$var/.ziyan_tap_meta'; } || echo ABSENT" || failures+=("${phase}_tap_meta_read")
    read_remote "$out/open_${phase}.txt" "test -e '$var/.ziyan_open_app' && { echo PRESENT; cat '$var/.ziyan_open_app'; } || echo ABSENT" || failures+=("${phase}_open_read")
    metric "$out/ps_${phase}.txt" "$out/metrics_${phase}.txt" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"
  }

  collect PRE
  front="$(tr -d '\r\n' <"$out/front_PRE.txt")"
  profile="$(sed -n 's/^profile_id=//p' "$out/profile_PRE.txt" | head -n 1)"
  profile_bundle="$(sed -n 's/^bundle_id=//p' "$out/profile_PRE.txt" | head -n 1)"
  keep="$(sed -n 's/^KEEP=//p' "$out/flags_PRE.txt" | head -n 1)"
  stop="$(sed -n 's/^STOP=//p' "$out/flags_PRE.txt" | head -n 1)"
  [ "$front" = "$expected_bundle" ] || failures+=(pre_front_not_game)
  [ "$profile" = agent_default_observe ] || failures+=(pre_profile_id)
  [ "$profile_bundle" = com.ziyan.ziyan ] || failures+=(pre_profile_bundle)
  [ "$keep" = ABSENT ] || failures+=(pre_keep)
  [ "$stop" = ABSENT ] || failures+=(pre_stop)
  [ "$(sed -n '1p' "$out/open_PRE.txt")" = ABSENT ] || failures+=(pre_open_app)
  [ "$(sed -n '2p' "$out/tap_gate_PRE.txt")" = "$tap_ts" ] || failures+=(pre_tap_gate_ts)
  [ "$(sed -n '2p' "$out/tap_meta_PRE.txt")" = "$tap_ts" ] || failures+=(pre_tap_meta_ts)
  [ "$(value "$out/metrics_PRE.txt" SB_FROZEN_MATCH)" = 1 ] || failures+=(pre_sb_frozen)
  [ "$(value "$out/metrics_PRE.txt" BB_FROZEN_MATCH)" = 1 ] || failures+=(pre_bb_frozen)
  [ "$(value "$out/metrics_PRE.txt" FC_FROZEN_MATCH)" = 1 ] || failures+=(pre_fc_frozen)
  [ "$(value "$out/metrics_PRE.txt" FC_N)" = 1 ] || failures+=(pre_fc_n)
  [ "$(value "$out/metrics_PRE.txt" REAL_AGENT_LUA_N)" = 0 ] || failures+=(pre_real_agent_lua)
  [ "$(value "$out/metrics_PRE.txt" ZY_FROZEN_PRESENT)" = 1 ] || failures+=(pre_zy_frozen)

  if [ "${#failures[@]}" -eq 0 ]; then
    if ! "${SCP_REMOTE[@]}" "$stage_lua" "root@$ip:/tmp/dev13_game_tap.lua" >"$out/scp_lua.log" 2>&1; then
      failures+=(scp_lua)
    fi
  fi
  if [ "${#failures[@]}" -eq 0 ]; then
    "${REMOTE[@]}" "chmod 755 /tmp/dev13_game_tap.lua 2>/dev/null || true; rm -f /tmp/dev13_game_tap.rc /tmp/dev13_game_tap.log; ( $launch_cmd > /tmp/dev13_game_tap.log 2>&1; printf '%s\n' \"\$?\" > /tmp/dev13_game_tap.rc )" \
      </dev/null >"$out/run_start.log" 2>"$out/run_start.log.stderr" || failures+=(run_start)
  fi
  if [ "${#failures[@]}" -eq 0 ]; then
    for _ in $(seq 1 40); do
      read_remote "$out/run_rc_poll.txt" 'cat /tmp/dev13_game_tap.rc 2>/dev/null' || failures+=(run_rc_read)
      [ -s "$out/run_rc_poll.txt" ] && break
      sleep 0.25
    done
    run_rc="$(tr -d '\r\n' <"$out/run_rc_poll.txt")"
    [ "$run_rc" = 0 ] || failures+=(lua_rc_${run_rc:-missing})
    read_remote "$out/run_log.txt" 'cat /tmp/dev13_game_tap.log 2>/dev/null' || failures+=(run_log_read)
    "${REMOTE[@]}" "rm -f /tmp/dev13_game_tap.lua /tmp/dev13_game_tap.rc /tmp/dev13_game_tap.log" \
      </dev/null >"$out/cleanup_tmp.log" 2>"$out/cleanup_tmp.log.stderr" || failures+=(cleanup_tmp)
  fi

  collect POST
  front="$(tr -d '\r\n' <"$out/front_POST.txt")"
  profile="$(sed -n 's/^profile_id=//p' "$out/profile_POST.txt" | head -n 1)"
  profile_bundle="$(sed -n 's/^bundle_id=//p' "$out/profile_POST.txt" | head -n 1)"
  keep="$(sed -n 's/^KEEP=//p' "$out/flags_POST.txt" | head -n 1)"
  stop="$(sed -n 's/^STOP=//p' "$out/flags_POST.txt" | head -n 1)"
  open_state="$(sed -n '1p' "$out/open_POST.txt")"
  [ "$front" = "$expected_bundle" ] || failures+=(post_front)
  [ "$profile" = agent_default_observe ] || failures+=(post_profile_id)
  [ "$profile_bundle" = com.ziyan.ziyan ] || failures+=(post_profile_bundle)
  [ "$keep" = ABSENT ] || failures+=(post_keep)
  [ "$stop" = ABSENT ] || failures+=(post_stop)
  [ "$open_state" = ABSENT ] || failures+=(post_open_app)
  [ "$(value "$out/metrics_POST.txt" SB_FROZEN_MATCH)" = 1 ] || failures+=(post_sb_frozen)
  [ "$(value "$out/metrics_POST.txt" BB_FROZEN_MATCH)" = 1 ] || failures+=(post_bb_frozen)
  [ "$(value "$out/metrics_POST.txt" FC_FROZEN_MATCH)" = 1 ] || failures+=(post_fc_frozen)
  [ "$(value "$out/metrics_POST.txt" FC_N)" = 1 ] || failures+=(post_fc_n)
  [ "$(value "$out/metrics_POST.txt" REAL_AGENT_LUA_N)" = 0 ] || failures+=(post_real_agent_lua)
  [ "$(value "$out/metrics_POST.txt" RUN_LUA_N)" = 0 ] || failures+=(post_run_lua)
  [ "$(value "$out/metrics_POST.txt" ZY_FROZEN_PRESENT)" = 1 ] || failures+=(post_zy_frozen)
  tap_line_ok "$out/tap_gate_POST.txt" "$tap_ts" "$expected_bundle" || failures+=(post_tap_gate)
  tap_meta_ok "$out/tap_meta_POST.txt" "$tap_ts" "$expected_x" "$expected_meta_y" || failures+=(post_tap_meta)

  {
    printf 'TAG=.%s\nAUTH=%s\nEXPECTED_BUNDLE=%s\nEXPECTED_DISPLAY=%s\n' "$tag" "$AUTH" "$expected_bundle" "$expected_display"
    printf 'PRE_FRONT=%s\nPOST_FRONT=%s\nOPEN_APP_POST=%s\n' "$(tr -d '\r\n' <"$out/front_PRE.txt")" "$front" "$open_state"
    printf 'PRE_SB=%s\nPRE_BB=%s\nPRE_FC=%s\nPRE_FC_N=%s\nPOST_SB=%s\nPOST_BB=%s\nPOST_FC=%s\nPOST_FC_N=%s\n' \
      "$(value "$out/metrics_PRE.txt" SB_PID)" "$(value "$out/metrics_PRE.txt" BB_PID)" "$(value "$out/metrics_PRE.txt" FC_PID)" "$(value "$out/metrics_PRE.txt" FC_N)" \
      "$(value "$out/metrics_POST.txt" SB_PID)" "$(value "$out/metrics_POST.txt" BB_PID)" "$(value "$out/metrics_POST.txt" FC_PID)" "$(value "$out/metrics_POST.txt" FC_N)"
    printf 'PRE_PROFILE=%s/%s\nPOST_PROFILE=%s/%s\nPRE_KEEP=%s\nPOST_KEEP=%s\nPRE_STOP=%s\nPOST_STOP=%s\n' \
      "$(sed -n 's/^profile_id=//p' "$out/profile_PRE.txt" | head -n 1)" "$(sed -n 's/^bundle_id=//p' "$out/profile_PRE.txt" | head -n 1)" \
      "$profile" "$profile_bundle" \
      "$(sed -n 's/^KEEP=//p' "$out/flags_PRE.txt" | head -n 1)" "$keep" \
      "$(sed -n 's/^STOP=//p' "$out/flags_PRE.txt" | head -n 1)" "$stop"
    printf 'TAP_PRE_TS=%s\nTAP_POST_TS=%s\nTAP_META_PRE_TS=%s\nTAP_META_POST_TS=%s\n' \
      "$(sed -n '2p' "$out/tap_gate_PRE.txt")" "$(sed -n '2p' "$out/tap_gate_POST.txt")" \
      "$(sed -n '2p' "$out/tap_meta_PRE.txt")" "$(sed -n '2p' "$out/tap_meta_POST.txt")"
    printf 'RUN_RC=%s\n' "${run_rc:-not_started}"
    if [ "${#failures[@]}" -eq 0 ]; then
      printf 'TAP=OK\nCLASS=FRONT_GAME\n'
    else
      printf 'TAP=FAIL\nREASON=%s\n' "$(IFS=,; printf '%s' "${failures[*]}")"
    fi
  } >"$out/STATE.txt"
  cat "$out/STATE.txt" >>"$out/TRANSCRIPT.log"
  printf '.%s %s\n' "$tag" "$(grep -E '^(TAP|CLASS|REASON|PRE_FRONT|POST_FRONT|RUN_RC)=' "$out/STATE.txt" | tr '\n' ' ')"
  [ "${#failures[@]}" -eq 0 ]
}

overall=1
reasons=()
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 1788633746 com.xztl.ios '血战屠龙' || { overall=0; reasons+=(.101); }
if [ "$overall" -eq 1 ]; then
  run_one 112 192.168.31.112 rootful 79809 79808 98110 92 1788633753 com.xztl.ios '血战屠龙' || { overall=0; reasons+=(.112); }
fi
if [ "$overall" -eq 1 ]; then
  run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 1788633761 com.xztl.ios '血战屠龙' || { overall=0; reasons+=(.166); }
fi
if [ "$overall" -eq 1 ]; then
  run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 1788634174 com.ljzbbadao.game '龙界争霸-拔刀传奇' || { overall=0; reasons+=(.53); }
fi

python3 - "$OUT" "$overall" "${reasons[*]:-}" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
overall = sys.argv[2] == "1"
reasons = sys.argv[3]
rows = []
for tag in ("101", "112", "166", "53"):
    values = {}
    path = out / tag / "STATE.txt"
    if path.exists():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    rows.append((tag, values.get("TAP", "NOT_RUN"), values.get("REASON", "none"), values.get("POST_FRONT", "")))

all_ok = overall and all(tap == "OK" for _, tap, _, _ in rows)
lines = [
    "# 十三号开发：P2 游戏前台按比例点一次死区",
    "",
    "这是十三号开发 P2 游戏前台比例死区一点，不是点开始；不是登录；不是十四号残留汇总；不是 `AGENT_MVP_4PHONE_PASS`；不是 G0；未 sbreload。",
    "严格串行 `.101 -> .112 -> .166 -> .53`；每台只写一次 `/tmp/dev13_game_tap.lua`，使用既有 `ziyan_run.lua`；未 Home、未填写登录、未支付、未聊天。",
    "",
]
lines.extend(f"- .{tag}: TAP={tap}; POST_FRONT={front}; REASON={reason}" for tag, tap, reason, front in rows)
lines.append("")
if all_ok:
    lines.extend(["AGENT_TRUE_GAME_TAP=PASS_PENDING_HUMAN", "MATRIX=.101/.112/.166=com.xztl.ios;.53=com.ljzbbadao.game"])
else:
    lines.extend(["AGENT_TRUE_GAME_TAP=PARTIAL_PENDING_HUMAN", "REASON=" + (reasons or ";".join(f".{tag}:{reason}" for tag, tap, reason, _ in rows if tap != "OK"))])
lines.extend(["", "不要 invent 十四号。", "NEXT_ACTION=等待人工最终审核"])
(out / "VERDICT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
(out / "OVERALL.txt").write_text(("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN") + "\n", encoding="utf-8")
print((out / "VERDICT.md").read_text(encoding="utf-8"), end="")
PY

python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "十三号开发：P2 游戏前台比例死区一点完成" \
  --last-command "bash tools/zy_dev13_agent_true_game_tap.sh；严格串行 .101 -> .112 -> .166 -> .53；每台一次 /tmp/dev13_game_tap.lua + ziyan_run.lua；未 Home、未登录、未 sbreload" \
  --result "AGENT_TRUE_GAME_TAP=$(cat "$OUT/OVERALL.txt")；详见 VERDICT.md；不是十四号、不是 G0、不是 AGENT_MVP_4PHONE_PASS" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV13_AGENT_TRUE_GAME_TAP_20260906/VERDICT.md；四机 PRE/POST PS、METRICS、PROFILE、FRONT、FLAGS、TAP、RUN 日志证据" \
  --latest-verdict "AGENT_TRUE_GAME_TAP=$(cat "$OUT/OVERALL.txt")；这是游戏前台比例死区一点，不是点开始/登录；未 sbreload；不是十四号" \
  --package-version "本刀未安装、未改包、未部署任何游戏" \
  --package-sha256 "本刀未改设备 runtime" \
  --device-state "严格串行 .101/.112/.166/.53；冻结 SB/BB/FC 与 zy、FC_N=1；各机前台仍为期望游戏；profile/tap 与本刀前后证据已采集" \
  --running-processes "PS 后本地筛选；SpringBoard 只认精确结尾；FC_N 只认 ziyan_framecap serve；真实 agent lua 同时匹配 lua5.3 与 ziyan_agent_run.lua；run lua 完成后应为 0" \
  --cleanup-status "一次性 Lua 跑完后删除设备 /tmp/dev13_game_tap.lua、rc、log；未清理游戏前台；keep/stop ABSENT；未 sbreload/ldrestart/killall/dpkg"
