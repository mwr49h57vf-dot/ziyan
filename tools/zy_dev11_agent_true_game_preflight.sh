#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/DEV11_AGENT_TRUE_GAME_PREFLIGHT_20260906"
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

value() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

run_one() {
  local tag="$1"
  local ip="$2"
  local scheme="$3"
  local frozen_sb="$4"
  local frozen_bb="$5"
  local frozen_fc="$6"
  local frozen_zy="$7"
  local tap_ts="$8"
  local expected_bundle="$9"
  local expected_display="${10}"
  local other_bundle="${11}"
  local out="$OUT/$tag"
  local var
  local failures=()
  local front profile profile_bundle keep stop plist display installed other_known

  mkdir -p "$out"
  if [ "$scheme" = rootless ]; then
    var=/var/jb/usr/lib/ziyan/var
  else
    var=/usr/lib/ziyan/var
  fi
  printf 'TAG=.%s\nIP=%s\nSCHEME=%s\nEXPECTED_BUNDLE=%s\nEXPECTED_DISPLAY=%s\nOTHER_BUNDLE=%s\n' \
    "$tag" "$ip" "$scheme" "$expected_bundle" "$expected_display" "$other_bundle" >"$out/TRANSCRIPT.log"

  if ! connect_device "$ip"; then
    printf 'AUTH=FAIL\nSMOKE=FAIL\nREASON=ssh_connect\n' >>"$out/TRANSCRIPT.log"
    printf 'SMOKE=FAIL\nREASON=ssh_connect\n' >"$out/STATE.txt"
    return 1
  fi
  printf 'AUTH=%s\n' "$AUTH" >>"$out/TRANSCRIPT.log"

  read_remote "$out/ps.txt" 'ps -A -o pid=,args=' || failures+=(ps_read)
  read_remote "$out/front.txt" "cat '$var/.ziyan_front_bid'" || failures+=(front_read)
  read_remote "$out/profile.txt" "cat '$var/.ziyan_agent_current_profile'" || failures+=(profile_read)
  read_remote "$out/flags.txt" "test -e '$var/.ziyan_keep_daemon' && echo KEEP=PRESENT || echo KEEP=ABSENT; test -e '$var/.ziyan_agent_stop' && echo STOP=PRESENT || echo STOP=ABSENT" || failures+=(flags_read)
  read_remote "$out/tap_gate.txt" "test -e '$var/.ziyan_tap_gate' && { echo PRESENT; stat -c '%Y' '$var/.ziyan_tap_gate' 2>/dev/null || stat -f '%m' '$var/.ziyan_tap_gate'; cat '$var/.ziyan_tap_gate'; } || echo ABSENT" || failures+=(tap_gate_read)
  read_remote "$out/tap_meta.txt" "test -e '$var/.ziyan_tap_meta' && { echo PRESENT; stat -c '%Y' '$var/.ziyan_tap_meta' 2>/dev/null || stat -f '%m' '$var/.ziyan_tap_meta'; cat '$var/.ziyan_tap_meta'; } || echo ABSENT" || failures+=(tap_meta_read)
  read_remote "$out/package_paths.txt" "find /var/containers/Bundle/Application /Applications /var/jb/Applications -type f -path '*.app/Info.plist' -print 2>/dev/null | while IFS= read -r p; do grep -a -q -E 'com.xztl.ios|com.ljzbbadao.game' \"\$p\" 2>/dev/null && printf '%s\\n' \"\$p\"; done" || true
  : >"$out/package_records.txt"
  while IFS= read -r plist_path; do
    [ -n "$plist_path" ] || continue
    printf '%s\t' "$plist_path" >>"$out/package_records.txt"
    "${REMOTE[@]}" "base64 '$plist_path' | tr -d '\\n'" </dev/null >>"$out/package_records.txt" 2>>"$out/package_records.txt.stderr" || failures+=(package_read)
    printf '\n' >>"$out/package_records.txt"
  done <"$out/package_paths.txt"
  python3 - "$out/package_records.txt" "$out/packages.txt" <<'PY'
import base64
import plistlib
import sys
from pathlib import Path

records, output = map(Path, sys.argv[1:])
lines = []
for raw in records.read_text(encoding="utf-8", errors="replace").splitlines():
    if "\t" not in raw:
        continue
    path, encoded = raw.split("\t", 1)
    try:
        data = plistlib.loads(base64.b64decode(encoded))
    except Exception:
        continue
    bundle_id = data.get("CFBundleIdentifier", "")
    if bundle_id not in ("com.xztl.ios", "com.ljzbbadao.game"):
        continue
    display = data.get("CFBundleDisplayName") or data.get("CFBundleName") or ""
    lines.append(f"PLIST={path}\tBUNDLE_ID={bundle_id}\tDISPLAY_NAME={display}")
output.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PY
  metric "$out/ps.txt" "$out/metrics.txt" "$frozen_sb" "$frozen_bb" "$frozen_fc" "$frozen_zy"

  front="$(tr -d '\r\n' <"$out/front.txt")"
  profile="$(sed -n 's/^profile_id=//p' "$out/profile.txt" | head -n 1)"
  profile_bundle="$(sed -n 's/^bundle_id=//p' "$out/profile.txt" | head -n 1)"
  keep="$(sed -n 's/^KEEP=//p' "$out/flags.txt" | head -n 1)"
  stop="$(sed -n 's/^STOP=//p' "$out/flags.txt" | head -n 1)"
  plist="$(awk -F '\t' -v bid="$expected_bundle" '$2 == "BUNDLE_ID=" bid { sub(/^PLIST=/, "", $1); print $1; exit }' "$out/packages.txt")"
  display="$(awk -F '\t' -v bid="$expected_bundle" '$2 == "BUNDLE_ID=" bid { sub(/^DISPLAY_NAME=/, "", $3); print $3; exit }' "$out/packages.txt")"
  installed=0
  [ -n "$plist" ] && installed=1 || failures+=(game_missing)
  [ "$display" = "$expected_display" ] || failures+=(display_mismatch)
  other_known=0
  grep -q "BUNDLE_ID=$other_bundle" "$out/packages.txt" && other_known=1 || true

  grep -qx 'com.ziyan.ziyan' "$out/front.txt" || failures+=(front)
  grep -qx 'profile_id=agent_default_observe' "$out/profile.txt" || failures+=(profile_id)
  grep -qx 'bundle_id=com.ziyan.ziyan' "$out/profile.txt" || failures+=(profile_bundle)
  [ "$keep" = ABSENT ] || failures+=(keep)
  [ "$stop" = ABSENT ] || failures+=(stop)
  grep -q '^PRESENT$' "$out/tap_gate.txt" || failures+=(tap_gate_absent)
  grep -q '^PRESENT$' "$out/tap_meta.txt" || failures+=(tap_meta_absent)
  [ "$(sed -n '2p' "$out/tap_gate.txt")" = "$tap_ts" ] || failures+=(tap_gate_ts)
  [ "$(sed -n '2p' "$out/tap_meta.txt")" = "$tap_ts" ] || failures+=(tap_meta_ts)
  [ "$(value "$out/metrics.txt" SB_FROZEN_MATCH)" = 1 ] || failures+=(sb_frozen)
  [ "$(value "$out/metrics.txt" BB_FROZEN_MATCH)" = 1 ] || failures+=(bb_frozen)
  [ "$(value "$out/metrics.txt" FC_FROZEN_MATCH)" = 1 ] || failures+=(fc_frozen)
  [ "$(value "$out/metrics.txt" FC_N)" = 1 ] || failures+=(fc_n)
  [ "$(value "$out/metrics.txt" REAL_AGENT_LUA_N)" = 0 ] || failures+=(real_agent_lua)
  [ "$(value "$out/metrics.txt" ZY_FROZEN_PRESENT)" = 1 ] || failures+=(zy_frozen)

  {
    printf 'TAG=.%s\nAUTH=%s\n' "$tag" "$AUTH"
    printf 'EXPECTED_BUNDLE=%s\nEXPECTED_DISPLAY=%s\nOTHER_BUNDLE=%s\n' "$expected_bundle" "$expected_display" "$other_bundle"
    printf 'PLIST_PATH=%s\nDISPLAY_NAME=%s\nINSTALLED=%s\nOTHER_KNOWN=%s\n' "$plist" "$display" "$installed" "$other_known"
    printf 'SB_PID=%s\nBB_PID=%s\nFC_PID=%s\nFC_N=%s\n' "$(value "$out/metrics.txt" SB_PID)" "$(value "$out/metrics.txt" BB_PID)" "$(value "$out/metrics.txt" FC_PID)" "$(value "$out/metrics.txt" FC_N)"
    printf 'SB_FROZEN_MATCH=%s\nBB_FROZEN_MATCH=%s\nFC_FROZEN_MATCH=%s\nZY_FROZEN_PRESENT=%s\n' "$(value "$out/metrics.txt" SB_FROZEN_MATCH)" "$(value "$out/metrics.txt" BB_FROZEN_MATCH)" "$(value "$out/metrics.txt" FC_FROZEN_MATCH)" "$(value "$out/metrics.txt" ZY_FROZEN_PRESENT)"
    printf 'REAL_AGENT_LUA_N=%s\nKEEP=%s\nSTOP=%s\nFRONT=%s\nPROFILE_ID=%s\nPROFILE_BUNDLE=%s\n' "$(value "$out/metrics.txt" REAL_AGENT_LUA_N)" "$keep" "$stop" "$front" "$profile" "$profile_bundle"
    printf 'TAP_EXPECTED_TS=%s\n' "$tap_ts"
    if [ "${#failures[@]}" -eq 0 ]; then
      printf 'SMOKE=OK\n'
    else
      printf 'SMOKE=FAIL\nREASON=%s\n' "$(IFS=,; printf '%s' "${failures[*]}")"
    fi
  } >"$out/STATE.txt"
  cat "$out/STATE.txt" >>"$out/TRANSCRIPT.log"
  printf '.%s %s\n' "$tag" "$(grep -E '^(PLIST_PATH|DISPLAY_NAME|INSTALLED|OTHER_KNOWN|SMOKE|REASON)=' "$out/STATE.txt" | tr '\n' ' ')"
  [ "${#failures[@]}" -eq 0 ]
}

overall=1
reasons=()
run_one 101 192.168.31.101 rootful 87863 87862 47853 96 1788633746 com.xztl.ios '血战屠龙' com.ljzbbadao.game || { overall=0; reasons+=(.101); }
run_one 112 192.168.31.112 rootful 79809 79808 98110 92 1788633753 com.xztl.ios '血战屠龙' com.ljzbbadao.game || { overall=0; reasons+=(.112); }
run_one 166 192.168.31.166 rootful 25025 25024 52622 82626 1788633761 com.xztl.ios '血战屠龙' com.ljzbbadao.game || { overall=0; reasons+=(.166); }
run_one 53 192.168.31.53 rootless 46408 74318 49176 93705 1788634174 com.ljzbbadao.game '龙界争霸-拔刀传奇' com.xztl.ios || { overall=0; reasons+=(.53); }

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
    rows.append((tag, values.get("SMOKE", "NOT_RUN"), values.get("REASON", "none"), values.get("INSTALLED", "0"), values.get("DISPLAY_NAME", "")))

all_ok = overall and all(smoke == "OK" for _, smoke, _, _, _ in rows)
lines = [
    "# 十一号开发：P2 分机游戏预检",
    "",
    "这是十一号开发 P2 分机预检，不是十二号打开游戏；不是点开始；不是让 `.53` 装 `com.xztl.ios`；不是 `AGENT_MVP_4PHONE_PASS`；不是 G0；未 sbreload。",
    "严格串行 `.101 -> .112 -> .166 -> .53`；只读采集；未启动该 App；未读账号、密码、登录页原文。",
    "分机游戏是设计：`.101/.112/.166` 期望 `com.xztl.ios`/血战屠龙；`.53` 期望 `com.ljzbbadao.game`/龙界争霸-拔刀传奇。",
    "",
]
lines.extend(f"- .{tag}: SMOKE={smoke}; INSTALLED={installed}; DISPLAY_NAME={display}; REASON={reason}" for tag, smoke, reason, installed, display in rows)
lines.append("")
if all_ok:
    lines.extend(["AGENT_TRUE_GAME_PREFLIGHT=PASS_PENDING_HUMAN", "MATRIX=.101/.112/.166=com.xztl.ios;.53=com.ljzbbadao.game"])
else:
    lines.extend(["AGENT_TRUE_GAME_PREFLIGHT=PARTIAL_PENDING_HUMAN", "REASON=" + (reasons or ";".join(f".{tag}:{reason}" for tag, smoke, reason, _, _ in rows if smoke != "OK"))])
lines.extend(["", "不要 invent 十二号。", "NEXT_ACTION=等待人工最终审核"])
(out / "VERDICT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
(out / "OVERALL.txt").write_text(("PASS_PENDING_HUMAN" if all_ok else "PARTIAL_PENDING_HUMAN") + "\n", encoding="utf-8")
print((out / "VERDICT.md").read_text(encoding="utf-8"), end="")
PY

python3 "$ROOT/tools/ziyan_codex_checkpoint.py" write \
  --stage "十一号开发：P2 分机游戏只读预检完成" \
  --last-command "bash tools/zy_dev11_agent_true_game_preflight.sh；严格串行 .101 -> .112 -> .166 -> .53；未启动 App、未 open、未 tap、未 sbreload" \
  --result "AGENT_TRUE_GAME_PREFLIGHT=$(cat "$OUT/OVERALL.txt")；详见 VERDICT.md；不是十二号、不是 G0、不是 AGENT_MVP_4PHONE_PASS" \
  --next-action "等待人工最终审核" \
  --evidence "tmp_shots/DEV11_AGENT_TRUE_GAME_PREFLIGHT_20260906/VERDICT.md；四机 STATE、PS、METRICS、PROFILE、FRONT、FLAGS、TAP、Info.plist 只读证据" \
  --latest-verdict "AGENT_TRUE_GAME_PREFLIGHT=$(cat "$OUT/OVERALL.txt")；分机游戏设计保留；未启动 App；未 open/tap；未 sbreload" \
  --package-version "本刀未安装、未改包、未部署任何游戏" \
  --package-sha256 "本刀未改设备 runtime" \
  --device-state "严格串行 .101/.112/.166/.53；冻结 SB/BB/FC 与 zy、FC_N=1、front/profile/marker 核验；本机期望 bundle 与 display 名核验" \
  --running-processes "PS 后本地筛选；SpringBoard 只认精确结尾；FC_N 只认 ziyan_framecap serve；真实 agent lua 同时匹配 lua5.3 与 ziyan_agent_run.lua" \
  --cleanup-status "keep/stop ABSENT；未执行 Lua、未 open/tap、未 sbreload/ldrestart/killall/dpkg；停手等待人工最终审核"
