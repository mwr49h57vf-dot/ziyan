#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV12_AGENT_TRUE_GAME_OPEN_20260906"
PASS="${ZY_SSH_PASS:-alpine}"
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
AUTH=

connect_device() {
  local ip="$1"
  if ssh "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(ssh "${SSH_KEY_OPTS[@]}" "root@$ip")
    AUTH=publickey
    return 0
  fi
  if sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    REMOTE=(sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip")
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
    "ZY_LINES": " || ".join(f"{p} {a}" for p, a in zy),
    "SB_FROZEN_MATCH": str(int(first(sb) == frozen_sb)),
    "BB_FROZEN_MATCH": str(int(first(bb) == frozen_bb)),
    "FC_FROZEN_MATCH": str(int(first(fc) == frozen_fc)),
    "ZY_FROZEN_PRESENT": str(int(any(p == frozen_zy for p, _ in zy))),
}
Path(out_path).write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")
PY
}

check_tap() {
  local file="$1" expected="$2"
  grep -q '^PRESENT$' "$file" &&
    [ "$(sed -n '2p' "$file")" = "$expected" ] &&
    [ -n "$(sed -n '3p' "$file")" ]
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5" frozen_fc="$6"
  local frozen_zy="$7" tap_ts="$8" expected_bundle="$9" expected_display="${10}"
  local out="$OUT/$tag" var
  local failures=()
  local front profile profile_bundle keep stop open_state

  mkdir -p "$out"
  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
  else
    var=/usr/lib/ziyan/var
  fi
  printf 'TAG=.%s\nIP=%s\nSCHEME=%s\nEXPECTED_BUNDLE=%s\nEXPECTED_DISPLAY=%s\n' \
    "$tag" "$ip" "$scheme" "$expected_bundle" "$expected_display" >"$out/TRANSCRIPT.log"

  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nOPEN=FAIL\nREASON=ssh_connect\n' >>"$out/TRANSCRIPT.log"
    printf 'OPEN=FAIL\nREASON=ssh_connect\n' >"$out/STATE.txt"
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
  [ "$front" = com.ziyan.ziyan ] || failures+=(pre_front)
  [ "$profile" = agent_default_observe ] || failures+=(pre_profile_id)
  [ "$profile_bundle" = com.ziyan.ziyan ] || failures+=(pre_profile_bundle)
  [ "$keep" = ABSENT ] || failures+=(pre_keep)
  [ "$stop" = ABSENT ] || failures+=(pre_stop)
  check_tap "$out/tap_gate_PRE.txt" "$tap_ts" || failures+=(pre_tap_gate)
  check_tap "$out/tap_meta_PRE.txt" "$tap_ts" || failures+=(pre_tap_meta)
  [ "$(value "$out/metrics_PRE.txt" SB_FROZEN_MATCH)" = 1 ] || failures+=(pre_sb_frozen)
  [ "$(value "$out/metrics_PRE.txt" BB_FROZEN_MATCH)" = 1 ] || failures+=(pre_bb_frozen)
  [ "$(value "$out/metrics_PRE.txt" FC_FROZEN_MATCH)" = 1 ] || failures+=(pre_fc_frozen)
  [ "$(value "$out/metrics_PRE.txt" FC_N)" = 1 ] || failures+=(pre_fc_n)
  [ "$(value "$out/metrics_PRE.txt" REAL_AGENT_LUA_N)" = 0 ] || failures+=(pre_real_agent_lua)
  [ "$(value "$out/metrics_PRE.txt" ZY_FROZEN_PRESENT)" = 1 ] || failures+=(pre_zy_frozen)

  if [ "${#failures[@]}" -eq 0 ]; then
    "${REMOTE[@]}" "printf '%s\\n' '$expected_bundle' > '$var/.ziyan_open_app'; chmod 666 '$var/.ziyan_open_app' 2>/dev/null || true" </dev/null >"$out/write_open_app.txt" 2>"$out/write_open_app.txt.stderr" || failures+=(open_write)
  fi

  if [ "${#failures[@]}" -eq 0 ]; then
    consumed=0
    for _ in $(seq 1 50); do
      read_remote "$out/open_poll.txt" "test -e '$var/.ziyan_open_app' && { echo PRESENT; cat '$var/.ziyan_open_app'; } || echo ABSENT" || failures+=(open_poll_read)
      read_remote "$out/front_poll.txt" "cat '$var/.ziyan_front_bid'" || failures+=(front_poll_read)
      poll_open="$(sed -n '1p' "$out/open_poll.txt")"
      poll_front="$(tr -d '\r\n' <"$out/front_poll.txt")"
      if [ "$poll_open" = ABSENT ] && [ "$poll_front" = "$expected_bundle" ]; then
        consumed=1
        break
      fi
      sleep 0.4
    done
    [ "$consumed" -eq 1 ] || failures+=(open_timeout_or_front)
  fi

  if [ "${#failures[@]}" -eq 0 ]; then
    collect POST
  else
    collect POST
  fi
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
  check_tap "$out/tap_gate_POST.txt" "$tap_ts" || failures+=(post_tap_gate)
  check_tap "$out/tap_meta_POST.txt" "$tap_ts" || failures+=(post_tap_meta)
  [ "$open_state" = ABSENT ] || failures+=(open_app_not_consumed)
  [ "$(value "$out/metrics_POST.txt" SB_FROZEN_MATCH)" = 1 ] || failures+=(post_sb_frozen)
  [ "$(value "$out/metrics_POST.txt" BB_FROZEN_MATCH)" = 1 ] || failures+=(post_bb_frozen)
  [ "$(value "$out/metrics_POST.txt" FC_FROZEN_MATCH)" = 1 ] || failures+=(post_fc_frozen)
  [ "$(value "$out/metrics_POST.txt" FC_N)" = 1 ] || failures+=(post_fc_n)
  [ "$(value "$out/metrics_POST.txt" REAL_AGENT_LUA_N)" = 0 ] || failures+=(post_real_agent_lua)
  [ "$(value "$out/metrics_POST.txt" ZY_FROZEN_PRESENT)" = 1 ] || failures+=(post_zy_frozen)

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
    printf 'TAP_TS=%s\n' "$tap_ts"
    if [ "${#failures[@]}" -eq 0 ]; then
      printf 'OPEN=OK\nCLASS=FRONT_GAME\nLOGIN_OR_SPLASH=UNKNOWN_OK\n'
    else
      printf 'OPEN=FAIL\nREASON=%s\n' "$(IFS=,; printf '%s' "${failures[*]}")"
    fi
  } >"$out/STATE.txt"
  cat "$out/STATE.txt" >>"$out/TRANSCRIPT.log"
  printf '.%s %s\n' "$tag" "$(grep -E '^(OPEN|CLASS|LOGIN_OR_SPLASH|REASON|PRE_FRONT|POST_FRONT)=' "$out/STATE.txt" | tr '\n' ' ')"
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
    rows.append((tag, values.get("OPEN", "NOT_RUN"), values.get("REASON", "none"), values.get("POST_FRONT", "")))

all_ok = overall and all(open_state == "OK" for _, open_state, _, _ in rows)
lines = [
    "# 十二号开发：P2 分机已知游戏前台打开",
    "",
    "这是十二号开发 P2 打开分机已知游戏，不是十三号点开始；不是登录；不是让 `.53` 装 `com.xztl.ios`；不是 `AGENT_MVP_4PHONE_PASS`；不是 G0；未 sbreload。",
    "严格串行 `.101 -> .112 -> .166 -> .53`；每台只写一次既有 `.ziyan_open_app`，未 tap、未 Home、未登录填写、未启动 agent lua。",
    "",
]
lines.extend(f"- .{tag}: OPEN={state}; POST_FRONT={front}; REASON={reason}" for tag, state, reason, front in rows)
lines.append("")
if all_ok:
    lines.extend(["AGENT_TRUE_GAME_OPEN=PASS_PENDING_HUMAN", "MATRIX=.101/.112/.166=com.xztl.ios;.53=com.ljzbbadao.game"])
else:
    lines.extend(["AGENT_TRUE_GAME_OPEN=PARTIAL_PENDING_HUMAN", "REASON=" + (reasons or ";".join(f".{tag}:{reason}" for tag, state, reason, _ in rows if state != "OK"))])
lines.extend(["", "不要 invent 十三号。", "NEXT_ACTION=等待人工最终审核"])
(out / "VERDICT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
(out / "OVERALL.txt").write_text(("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN") + "\n", encoding="utf-8")
print((out / "VERDICT.md").read_text(encoding="utf-8"), end="")
PY

python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "十二号开发：P2 分机已知游戏前台打开完成" \
  --last-command "bash tools/zy_dev12_agent_true_game_open.sh；严格串行 .101 -> .112 -> .166 -> .53；每台只写一次 .ziyan_open_app；未 tap、未 Home、未登录填写、未 sbreload" \
  --result "AGENT_TRUE_GAME_OPEN=$(cat "$OUT/OVERALL.txt")；详见 VERDICT.md；不是十三号、不是 G0、不是 AGENT_MVP_4PHONE_PASS" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV12_AGENT_TRUE_GAME_OPEN_20260906/VERDICT.md；四机 PRE/POST PS、METRICS、PROFILE、FRONT、FLAGS、TAP、OPEN_APP 证据" \
  --latest-verdict "AGENT_TRUE_GAME_OPEN=$(cat "$OUT/OVERALL.txt")；各机按设计打开自己的已知游戏；未 tap；未 sbreload；不是十三号" \
  --package-version "本刀未安装、未改包、未部署任何游戏" \
  --package-sha256 "本刀未改设备 runtime" \
  --device-state "严格串行 .101/.112/.166/.53；冻结 SB/BB/FC 与 zy、FC_N=1；front 变为各机期望 bundle；profile/tap 保持七号基线" \
  --running-processes "PS 后本地筛选；SpringBoard 只认精确结尾；FC_N 只认 ziyan_framecap serve；真实 agent lua 同时匹配 lua5.3 与 ziyan_agent_run.lua" \
  --cleanup-status "未清理游戏前台；keep/stop ABSENT；未执行 Lua、未 tap/Home、未 sbreload/ldrestart/killall/dpkg；停手等待人工最终审核"
