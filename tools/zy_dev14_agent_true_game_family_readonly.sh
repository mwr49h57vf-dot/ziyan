#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV14_AGENT_TRUE_GAME_FAMILY_20260906"
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

tap_gate_ok() {
  local file="$1" expected_ts="$2" expected_x="$3" expected_y="$4" expected_front="$5"
  grep -q '^PRESENT$' "$file" &&
    [ "$(sed -n '2p' "$file")" = "$expected_ts" ] &&
    grep -q "ts=${expected_ts} x=${expected_x} y=${expected_y} .*front=${expected_front}" "$file"
}

tap_meta_ok() {
  local file="$1" expected_ts="$2" expected_x="$3" expected_y="$4"
  grep -q '^PRESENT$' "$file" &&
    [ "$(sed -n '2p' "$file")" = "$expected_ts" ] &&
    grep -Eq "xy=${expected_x},${expected_y}([[:space:]]|$)" "$file"
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" frozen_sb="$4" frozen_bb="$5" frozen_fc="$6"
  local frozen_zy="$7" tap_ts="$8" expected_bundle="$9" expected_display="${10}"
  local out="$OUT/$tag" var expected_x expected_y failures=()
  local front profile profile_bundle keep stop open_state tmp_state

  mkdir -p "$out"
  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
    expected_x=621.0
    expected_y=176.64
  else
    var=/usr/lib/ziyan/var
    expected_x=320.0
    expected_y=90.88
  fi

  printf 'TAG=.%s\nIP=%s\nSCHEME=%s\nEXPECTED_BUNDLE=%s\nEXPECTED_DISPLAY=%s\n' \
    "$tag" "$ip" "$scheme" "$expected_bundle" "$expected_display" >"$out/TRANSCRIPT.log"

  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nSMOKE=FAIL\nREASON=ssh_connect\n' >>"$out/TRANSCRIPT.log"
    printf 'SMOKE=FAIL\nREASON=ssh_connect\n' >"$out/STATE.txt"
    printf '.%s SMOKE=FAIL REASON=ssh_connect\n' "$tag"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  read_remote "$out/ps.txt" 'ps -A -o pid=,args=' || failures+=(ps_read)
  read_remote "$out/front.txt" "cat '$var/.ziyan_front_bid'" || failures+=(front_read)
  read_remote "$out/profile.txt" "cat '$var/.ziyan_agent_current_profile'" || failures+=(profile_read)
  read_remote "$out/flags.txt" "test -e '$var/.ziyan_keep_daemon' && echo KEEP=PRESENT || echo KEEP=ABSENT; test -e '$var/.ziyan_agent_stop' && echo STOP=PRESENT || echo STOP=ABSENT" || failures+=(flags_read)
  read_remote "$out/tap_gate.txt" "test -e '$var/.ziyan_tap_gate' && { echo PRESENT; stat -c '%Y' '$var/.ziyan_tap_gate' 2>/dev/null || stat -f '%m' '$var/.ziyan_tap_gate'; cat '$var/.ziyan_tap_gate'; } || echo ABSENT" || failures+=(tap_gate_read)
  read_remote "$out/tap_meta.txt" "test -e '$var/.ziyan_tap_meta' && { echo PRESENT; stat -c '%Y' '$var/.ziyan_tap_meta' 2>/dev/null || stat -f '%m' '$var/.ziyan_tap_meta'; cat '$var/.ziyan_tap_meta'; } || echo ABSENT" || failures+=(tap_meta_read)
  read_remote "$out/open_app.txt" "test -e '$var/.ziyan_open_app' && { echo PRESENT; cat '$var/.ziyan_open_app'; } || echo ABSENT" || failures+=(open_app_read)
  read_remote "$out/dev13_tmp.txt" "test -e /tmp/dev13_game_tap.lua && echo PRESENT || echo ABSENT" || failures+=(dev13_tmp_read)
  read_remote "$out/session.txt" "cat '$var/.ziyan_agent_session' 2>/dev/null || echo ABSENT" || failures+=(session_read)
  metric "$out/ps.txt" "$out/metrics.txt" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"

  front="$(tr -d '\r\n' <"$out/front.txt")"
  profile="$(sed -n 's/^profile_id=//p' "$out/profile.txt" | head -n 1)"
  profile_bundle="$(sed -n 's/^bundle_id=//p' "$out/profile.txt" | head -n 1)"
  keep="$(sed -n 's/^KEEP=//p' "$out/flags.txt" | head -n 1)"
  stop="$(sed -n 's/^STOP=//p' "$out/flags.txt" | head -n 1)"
  open_state="$(sed -n '1p' "$out/open_app.txt")"
  tmp_state="$(sed -n '1p' "$out/dev13_tmp.txt")"

  [ "$front" = "$expected_bundle" ] || failures+=(front_left_game)
  [ "$profile" = agent_default_observe ] || failures+=(profile_id)
  [ "$profile_bundle" = com.ziyan.ziyan ] || failures+=(profile_bundle)
  [ "$keep" = ABSENT ] || failures+=(keep_present)
  [ "$stop" = ABSENT ] || failures+=(stop_present)
  [ "$open_state" = ABSENT ] || failures+=(open_app_present)
  [ "$tmp_state" = ABSENT ] || failures+=(dev13_tmp_present)
  [ "$(value "$out/metrics.txt" SB_FROZEN_MATCH)" = 1 ] || failures+=(sb_frozen)
  [ "$(value "$out/metrics.txt" BB_FROZEN_MATCH)" = 1 ] || failures+=(bb_frozen)
  [ "$(value "$out/metrics.txt" FC_FROZEN_MATCH)" = 1 ] || failures+=(fc_frozen)
  [ "$(value "$out/metrics.txt" FC_N)" = 1 ] || failures+=(fc_n)
  [ "$(value "$out/metrics.txt" REAL_AGENT_LUA_N)" = 0 ] || failures+=(real_agent_lua)
  [ "$(value "$out/metrics.txt" ZY_FROZEN_PRESENT)" = 1 ] || failures+=(zy_frozen)
  tap_gate_ok "$out/tap_gate.txt" "$tap_ts" "$expected_x" "$expected_y" "$expected_bundle" || failures+=(tap_gate_changed)
  if [ "$scheme" = rootless ]; then
    tap_meta_ok "$out/tap_meta.txt" "$tap_ts" "$expected_x" "176.6" || failures+=(tap_meta_changed)
  else
    tap_meta_ok "$out/tap_meta.txt" "$tap_ts" "$expected_x" "90.9" || failures+=(tap_meta_changed)
  fi

  {
    printf 'TAG=.%s\nAUTH=%s\nEXPECTED_BUNDLE=%s\nEXPECTED_DISPLAY=%s\n' "$tag" "$AUTH" "$expected_bundle" "$expected_display"
    printf 'FRONT=%s\nPROFILE=%s/%s\nKEEP=%s\nSTOP=%s\nOPEN_APP=%s\nDEV13_TMP=%s\nSESSION=' \
      "$front" "$profile" "$profile_bundle" "$keep" "$stop" "$open_state" "$tmp_state"
    tr '\r\n' ' ' <"$out/session.txt"
    printf '\n'
    printf 'SB=%s\nBB=%s\nFC=%s\nFC_N=%s\nREAL_AGENT_LUA_N=%s\nRUN_LUA_N=%s\nZY_FROZEN_PRESENT=%s\n' \
      "$(value "$out/metrics.txt" SB_PID)" "$(value "$out/metrics.txt" BB_PID)" \
      "$(value "$out/metrics.txt" FC_PID)" "$(value "$out/metrics.txt" FC_N)" \
      "$(value "$out/metrics.txt" REAL_AGENT_LUA_N)" "$(value "$out/metrics.txt" RUN_LUA_N)" \
      "$(value "$out/metrics.txt" ZY_FROZEN_PRESENT)"
    printf 'TAP_GATE_TS=%s\nTAP_META_TS=%s\n' \
      "$(sed -n '2p' "$out/tap_gate.txt")" "$(sed -n '2p' "$out/tap_meta.txt")"
    if [ "${#failures[@]}" -eq 0 ]; then
      printf 'SMOKE=OK\nCLASS=READONLY_RESIDUAL\n'
    else
      printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; printf '%s' "${failures[*]}")"
    fi
  } >"$out/STATE.txt"
  cat "$out/STATE.txt" >>"$out/TRANSCRIPT.log"
  printf '.%s %s\n' "$tag" "$(grep -E '^(SMOKE|CLASS|REASON|FRONT|PROFILE|SB|BB|FC|FC_N|REAL_AGENT_LUA_N|OPEN_APP|DEV13_TMP)=' "$out/STATE.txt" | tr '\n' ' ')"
  [ "${#failures[@]}" -eq 0 ]
}

overall=1
reasons=()
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 1788698375 com.xztl.ios '血战屠龙' || { overall=0; reasons+=(.101); }
run_one 112 192.168.31.112 rootful 79809 79808 98110 92 1788698390 com.xztl.ios '血战屠龙' || { overall=0; reasons+=(.112); }
run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 1788698406 com.xztl.ios '血战屠龙' || { overall=0; reasons+=(.166); }
run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 1788698418 com.ljzbbadao.game '龙界争霸-拔刀传奇' || { overall=0; reasons+=(.53); }

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
    rows.append((tag, values.get("SMOKE", "NOT_RUN"), values.get("REASON", "none"), values.get("FRONT", "")))

all_ok = overall and all(smoke == "OK" for _, smoke, _, _ in rows)
lines = [
    "# 十四号开发：P2 只读残留 + 汇总家族",
    "",
    "这是十四号开发 P2 只读残留+家族汇总，不是十三号重做；不是点开始；不是登录；不是 `AGENT_MVP_4PHONE_PASS`；不是 G0；未 sbreload。",
    "本刀严格串行 `.101 -> .112 -> .166 -> .53`，只读冻结进程、残留标记、前台、profile、十三号 tap 记录、open_app 与 `/tmp/dev13_game_tap.lua`。",
    "session 可能仍为 `PAUSED_SAFE` 只记；本刀未写、未跑任何游戏脚本。进游戏方向从下一主题起只许 `init(1)`；本刀没有脚本。",
    "",
]
lines.extend(f"- .{tag}: SMOKE={smoke}; FRONT={front}; REASON={reason}" for tag, smoke, reason, front in rows)
lines.append("")
if all_ok:
    lines.extend([
        "AGENT_TRUE_GAME_FAMILY=PASS_PENDING_HUMAN",
        "MATRIX=.101/.112/.166=com.xztl.ios;.53=com.ljzbbadao.game",
    ])
else:
    lines.extend([
        "AGENT_TRUE_GAME_FAMILY=PARTIAL_PENDING_HUMAN",
        "REASON=" + (reasons or ";".join(f".{tag}:{reason}" for tag, smoke, reason, _ in rows if smoke != "OK")),
    ])
lines.extend([
    "",
    "人审 PASS 路径：十一号分机预检、十二号打开分机游戏、十三号游戏前台比例死区一点；缺一项即 PARTIAL。",
    "不要把本刀读成点开始、登录、G0 或 MVP；不要 invent 十五号。做完本家族也不是 agent 开发完。",
    "NEXT_ACTION=等待人工最终审核",
])
(out / "VERDICT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
(out / "OVERALL.txt").write_text(("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN") + "\n", encoding="utf-8")
print((out / "VERDICT.md").read_text(encoding="utf-8"), end="")
PY
