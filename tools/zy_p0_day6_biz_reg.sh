#!/usr/bin/env bash
# P0 Day6：短业务回归。不装包、不杀 SB、不改 Desktop lua、不碰 .53、不拧匹配器。
# 路径：游戏金标 → 显式 keep 金标 → 关 keep → Home 不得扫冻帧 → 回游戏再中 → 停后清理。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY6_BIZREG_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=20
          -o ServerAliveCountMax=6)
echo "OUT=$OUT hosts=${HOSTS[*]} no_deploy no_pretest no_53 no_matcher" | tee "$OUT/meta.txt"

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}
ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

cat >"$OUT/_p0d6_live.lua" <<'LUA'
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d6_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("done")
LUA

cat >"$OUT/_p0d6_keep.lua" <<'LUA'
init(1)
keepScreen(true)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d6_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("done")
LUA

cat >"$OUT/_p0d6_keepoff.lua" <<'LUA'
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d6_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("KEEP_OFF=1")
w("done")
LUA

cat >"$OUT/_p0d6_home.lua" <<'LUA'
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d6_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("done")
LUA
cp "$OUT/_p0d6_live.lua" "$OUT/_p0d6_back.lua"

run_one() {
  local H="$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "$OUT/_p0d6_live.lua" "$OUT/_p0d6_keep.lua" "$OUT/_p0d6_keepoff.lua" \
    "$OUT/_p0d6_home.lua" "$OUT/_p0d6_back.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$H" \
    "H=$H bash -s" >"$OUT/run_${H}.txt" 2>&1 <<'EOS'
set +e
V=/usr/lib/ziyan/var
M=/var/mobile/Media/ZiYan
APP=com.xztl.ios
echo VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo START=$(date +%s)
sb_pid() {
  ps -axo pid=,args= 2>/dev/null | while read -r pid args; do
    case "$args" in */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo "$pid"; break ;; esac
  done
}
fc_n() { ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9'; }
front() { tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null; }
status_bits() {
  wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null \
    | sed -n 's/^\(lease_state\|frame_seq\|frame_age_ms\|frame_provider\|front_bid\|shm_bid\)=/\1=/p'
}
SB0=$(sb_pid); echo SB0=$SB0
echo FC_N0=$(fc_n)

wake_game() {
  printf '%s\n' "$APP" >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  echo 1 >"$V/.ziyan_force_recap"
  echo force=1 >"$V/.ziyan_frame_req"
  echo 1 >"$V/.ziyan_snap_http_want"
  i=0
  while [ $i -lt 40 ]; do
    ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
    LE=$(echo "$ST" | sed -n 's/^lease_state=//p' | head -1)
    PV=$(echo "$ST" | sed -n 's/^frame_provider=//p' | head -1)
    echo "$LE" | grep -q active && [ "$PV" = 8 ] && break
    echo 1 >"$V/.ziyan_force_recap"
    i=$((i+1)); sleep 0.5
  done
  rm -f "$V/.ziyan_open_app"
  wget -qO /dev/null -T 3 http://127.0.0.1:50005/snapshot >/dev/null 2>&1 || true
  echo WAKE_I=$i
  status_bits
}

embed_run() {
  local name="$1"
  rm -f "$M/_p0d6_out.txt"
  : >"$M/_p0d6_out.txt"
  chmod 666 "$M/_p0d6_${name}.lua" "$M/_p0d6_out.txt"
  printf 'path=%s/_p0d6_%s.lua\nstop=0\n' "$M" "$name" >"$V/.ziyan_run_intent"
  printf '%s/_p0d6_%s.lua\n' "$M" "$name" >"$V/.ziyan_embed_script"
  echo 1 >"$V/.ziyan_embed_on"
  echo "nonce=p0d6_${name}_$$" >"$V/.ziyan_embed_go"
  chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"
  j=0
  while [ $j -lt 40 ]; do
    grep -q '^done$' "$M/_p0d6_out.txt" 2>/dev/null && break
    j=$((j+1)); sleep 0.25
  done
  echo PHASE_${name}_WAIT=$j
  echo PHASE_${name}_OUT=$(tr '\n' ' ' <"$M/_p0d6_out.txt")
  echo PHASE_${name}_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find")
  echo PHASE_${name}_TIMING=$(tr '\n' ' ' <"$V/.ziyan_find_timing" 2>/dev/null | tail -c 220)
  echo PHASE_${name}_KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
  echo PHASE_${name}_FRONT=$(front)
  status_bits | sed "s/^/PHASE_${name}_/"
}

rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop" "$V/.ziyan_embed_off" \
  "$V/.ziyan_kill_scripts" "$V/.ziyan_path_stats" "$V/.ziyan_no_auto_keep"
echo 1 >"$V/.ziyan_no_auto_keep"
chmod 666 "$V/.ziyan_no_auto_keep"

echo '== LIVE =='
wake_game
embed_run live

echo '== KEEP =='
embed_run keep

echo '== KEEPOFF =='
embed_run keepoff

echo '== HOME =='
rm -f "$V/.ziyan_open_app"
printf '1\n' >"$V/.ziyan_go_home"
chmod 666 "$V/.ziyan_go_home" 2>/dev/null
i=0; HOK=0
while [ $i -lt 80 ]; do
  f=$(front)
  echo "$f" | grep -qi springboard && { HOK=1; break; }
  i=$((i+1)); sleep 0.05
done
rm -f "$V/.ziyan_go_home"
echo HOME_OK=$HOK HOME_WAIT=$i FRONT_H=$(front)
sleep 1
echo 1 >"$V/.ziyan_frame_req"
status_bits | sed 's/^/HOME_/'
embed_run home

echo '== BACK =='
wake_game
embed_run back

echo '== STOP =='
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts"
sleep 2
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" \
  "$V/.ziyan_embed_script" "$V/.ziyan_active"
sleep 1
SB1=$(sb_pid)
echo KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo FC_N_AFTER=$(fc_n)
echo SB1=$SB1
if [ -n "$SB0" ] && [ -n "$SB1" ] && [ "$SB0" != "$SB1" ]; then echo SB_CHG=1; else echo SB_CHG=0; fi
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 280)
echo END=$(date +%s)
EOS
}

for H in "${HOSTS[@]}"; do
  run_one "$H" &
done
wait

ts_snap 171 "$OUT/ts171_end.txt" &
ts_snap 149 "$OUT/ts149_end.txt" &
wait || true

python3 - "$OUT" "${HOSTS[@]}" <<'PY' | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
import os, re, sys
out = sys.argv[1]
hosts = sys.argv[2:]
print("# P0 Day6 short business regression")
print("out=%s hosts=%s" % (out, " ".join(hosts)))
print("no_deploy no_pretest no_53 no_matcher no_ios7")
print()
print("| host | live gold/find | keep gold/find/keep | home gold/find/front | back gold/find | KEEP_AFTER | SB_CHG | FC_N | cr_find | verdict |")
print("|---|---|---|---|---|---|---|---|---|---|")

def field(txt, key):
    m = re.search(r"^%s=(.*)$" % re.escape(key), txt, re.M)
    return (m.group(1).strip() if m else "")

def gold_find(blob):
    g = re.search(r"GOLD=(-?\d+)", blob or "")
    f = re.search(r"FIND=(-?\d+),(-?\d+)", blob or "")
    gold = int(g.group(1)) if g else None
    xy = (int(f.group(1)), int(f.group(2))) if f else (None, None)
    return gold, xy

def hit(xy):
    return xy[0] is not None and xy[0] >= 0 and xy[1] is not None and xy[1] >= 0

rows = []
for h in hosts:
    p = os.path.join(out, "run_%s.txt" % h)
    t = open(p, errors="replace").read() if os.path.isfile(p) else ""
    live_g, live_xy = gold_find(field(t, "PHASE_live_OUT"))
    keep_g, keep_xy = gold_find(field(t, "PHASE_keep_OUT"))
    keep_find = field(t, "PHASE_keep_FIND")
    km = re.search(r"keep=(\d+)", keep_find)
    keep_on = km.group(1) if km else field(t, "PHASE_keep_KEEP")
    home_g, home_xy = gold_find(field(t, "PHASE_home_OUT"))
    home_front = field(t, "PHASE_home_FRONT") or field(t, "FRONT_H")
    home_ok = field(t, "HOME_OK")
    # last PHASE_live_OUT after BACK overwrites; parse both occurrences
    back_g, back_xy = gold_find(field(t, "PHASE_back_OUT"))
    keep_after = field(t, "KEEP_AFTER")
    sb = field(t, "SB_CHG")
    fc = field(t, "FC_N_AFTER")
    stats = field(t, "STATS")
    cr = re.search(r"via_color_req_find=(\d+)", stats)
    crn = int(cr.group(1)) if cr else -1
    fail = []
    if live_g != 12688231 or not hit(live_xy):
        fail.append("LIVE_MISS")
    if keep_g != 12688231 or not hit(keep_xy):
        fail.append("KEEP_MISS")
    if keep_on != "1":
        fail.append("KEEP_NOT_ON")
    frozen = (home_g == 12688231 and hit(home_xy))
    if frozen:
        fail.append("FROZEN_HOME")
    if home_ok != "1" and "springboard" not in (home_front or "").lower():
        fail.append("HOME_FRONT")
    if back_g != 12688231 or not hit(back_xy):
        fail.append("BACK_MISS")
    if keep_after != "0":
        fail.append("KEEP_AFTER")
    if sb == "1":
        fail.append("SB")
    if fc not in ("1",):
        fail.append("FC")
    if crn > 0:
        fail.append("COLOR_REQ")
    label = "PASS" if not fail else "FAIL:" + ",".join(fail)
    rows.append(label)
    print("| .%s | %s/%s | %s/%s/%s | %s/%s/%s | %s/%s | %s | %s | %s | %s | %s |" % (
        h, live_g, live_xy, keep_g, keep_xy, keep_on,
        home_g, home_xy, (home_front or "-")[:24],
        back_g, back_xy, keep_after, sb, fc, crn, label))
print()
print("PASS = live+keep gold 12688231 and hit; last_find keep=1 during keep (file may clear when short embed exits); Home not gold+hit; back gold+hit; KEEP_AFTER=0; SB_CHG=0; FC_N=1; via_color_req_find=0")
print("No product change this knife unless FAIL. No surpass claim. .53 not deployed.")
open(os.path.join(out, "CLASS.txt"), "w").write("\n".join(rows) + "\n")
PY
echo "OUT=$OUT"
