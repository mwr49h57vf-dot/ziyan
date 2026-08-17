#!/usr/bin/env bash
# P1 Day12：debug-10-2 现包 30 分钟 embed 找色长稳。
# 不杀 SB、不改 Desktop lua、不碰 .53、不拧匹配器、不开 180m、不新建守护、不跑 Gate C Home。
# 验：窗内 session 保持 running、FC_N=1、SB_CHG=0、color_req=0、keep 显式；
#     停后 ACTIVE/KEEP/pid/embed=0；唤醒后再中金标 12688231。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
MIN="${ZY_D12_MIN:-30}"
SEC=$((MIN * 60))
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY12_30M_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=20
          -o ServerAliveCountMax=8)
echo "OUT=$OUT MIN=$MIN hosts=${HOSTS[*]} pkg=debug-10-2 no_pretest no_53 no_home no_180m no_matcher" \
  | tee "$OUT/meta.txt"

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}
ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

cat >"$OUT/_p0d12_loop.lua" <<'LUA'
init(1)
keepScreen(true)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d12_beat.txt", "w")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
local n, hit = 0, 0
while true do
  local g = getColor(706, 449)
  local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
  n = n + 1
  if tonumber(x) and x >= 0 then hit = hit + 1 end
  w(string.format("n=%d hit=%d GOLD=%s FIND=%s,%s", n, hit, tostring(g), tostring(x), tostring(y)))
  mSleep(400)
end
LUA

cat >"$OUT/_p0d12_again.lua" <<'LUA'
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d12_again.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("done")
LUA

run_one() {
  local H="$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "$OUT/_p0d12_loop.lua" "$OUT/_p0d12_again.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$H" \
    "H=$H SEC=$SEC MIN=$MIN bash -s" >"$OUT/run_${H}.txt" 2>&1 <<'EOS'
set +e
V=/usr/lib/ziyan/var
M=/var/mobile/Media/ZiYan
APP=com.xztl.ios
echo VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo MIN=$MIN SEC=$SEC
fc_n() { ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9'; }
sb_pid() {
  ps -axo pid=,args= 2>/dev/null | while read -r pid args; do
    case "$args" in */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo "$pid"; return;; esac
  done
}
fc_pid() {
  ps -axo pid=,args= 2>/dev/null | while read -r pid args; do
    case "$args" in *ziyan_framecap\ serve*) echo "$pid"; return;; esac
  done
}
fc_rss() {
  local p r
  p=$(fc_pid)
  [ -n "$p" ] && r=$(ps -p "$p" -o rss= 2>/dev/null | tr -d ' ')
  echo "${r:-0}"
}

echo SB_PID0=$(sb_pid)
echo FC_PID0=$(fc_pid)
echo FC_N0=$(fc_n)

printf '%s\n' "$APP" >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null
echo 1 >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
echo 1 >"$V/.ziyan_force_recap"
i=0
while [ $i -lt 40 ]; do
  ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
  echo "$ST" | grep -q 'lease_state=active' && echo "$ST" | grep -q 'frame_provider=8' && break
  echo 1 >"$V/.ziyan_force_recap"
  i=$((i+1)); sleep 0.5
done
rm -f "$V/.ziyan_open_app" "$V/.ziyan_unlock_req"
echo WAKE_I=$i

chmod 666 "$M/_p0d12_loop.lua" "$M/_p0d12_again.lua"
: >"$M/_p0d12_beat.txt"
chmod 666 "$M/_p0d12_beat.txt"
rm -f "$V/.ziyan_stop" "$V/.ziyan_kill_scripts" "$V/.ziyan_stop_ack" \
  "$V/.ziyan_embed_go" "$V/.ziyan_path_stats"
printf 'path=%s/_p0d12_loop.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d12_loop.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on"
rm -f "$V/.ziyan_user_stopped"
printf 'nonce=d12_%s\nrequest_id=d12_%s\nsession_id=d12_%s\n' "$$" "$$" "$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_embed_go"

w=0
while [ $w -lt 80 ]; do
  grep -q 'GOLD=' "$M/_p0d12_beat.txt" 2>/dev/null && break
  w=$((w+1)); sleep 0.25
done
echo START_WAIT=$w
echo START_BEAT=$(tr '\n' ' ' <"$M/_p0d12_beat.txt")
echo KEEP_DURING=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo SESS0=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)

: >"$V/.ziyan_e4_resource.tsv"
echo -e "t\tfc_n\tfc_rss\tsb_rss\tkeep" >>"$V/.ziyan_e4_resource.tsv"
SB_CHG=0
FC_N_MAX=$(fc_n)
IDLE_HIT=0
SB0=$(sb_pid)
end=$(( $(date +%s) + SEC ))
echo RUN_BEGIN=$(date +%s)
while [ "$(date +%s)" -lt "$end" ]; do
  FCN=$(fc_n); [ -n "$FCN" ] || FCN=0
  [ "$FCN" -gt "$FC_N_MAX" ] 2>/dev/null && FC_N_MAX=$FCN
  SB=$(sb_pid)
  if [ -n "$SB0" ] && [ -n "$SB" ] && [ "$SB" != "$SB0" ]; then
    SB_CHG=$((SB_CHG+1))
    echo SB_RING from=$SB0 to=$SB
    SB0=$SB
  fi
  SESS=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
  echo "$SESS" | grep -q 'state=running' || IDLE_HIT=$((IDLE_HIT+1))
  KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
  SB_RSS=$(ps -p "$(sb_pid)" -o rss= 2>/dev/null | tr -d ' ')
  echo -e "$(date +%s)\t$FCN\t$(fc_rss)\t${SB_RSS:-0}\t$KEEP" >>"$V/.ziyan_e4_resource.tsv"
  echo SAMPLE t=$(date +%s) beat=$(tr '\n' ' ' <"$M/_p0d12_beat.txt") sess=$(echo "$SESS" | sed 's/.*state=/state=/') fc=$FCN keep=$KEEP
  sleep 20
done
echo RUN_END=$(date +%s)
echo BEAT_END=$(tr '\n' ' ' <"$M/_p0d12_beat.txt")
echo SESS_END=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
echo IDLE_HIT=$IDLE_HIT
echo SB_CHG=$SB_CHG
echo FC_N_MAX=$FC_N_MAX
echo KEEP_PEAK=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)

rm -f "$V/.ziyan_stop_ack"
printf 'path=\nstop=1\n' >"$V/.ziyan_run_intent"
echo 1 >"$V/.ziyan_user_stopped"
chmod 666 "$V/.ziyan_user_stopped" "$V/.ziyan_run_intent"
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts"
s=0
while [ $s -lt 50 ]; do
  grep -q '^state=idle' "$V/.ziyan_stop_ack" 2>/dev/null && break
  s=$((s+1)); sleep 0.1
done
echo STOP_WAIT=$s
echo STOP_ACK=$(tr '\n' ' ' <"$V/.ziyan_stop_ack" 2>/dev/null)
sleep 0.5
echo KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo PIDFILE_AFTER=$(test -f "$V/.ziyan_lua_run.pid" && echo 1 || echo 0)
echo EMBED_AFTER=$(test -f "$V/.ziyan_embed_alive" && echo 1 || echo 0)
echo SESS_AFTER=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
echo FC_N_AFTER=$(fc_n)
echo HEALTH_AFTER=$(wget -qO- -T 2 http://127.0.0.1:50005/health 2>/dev/null | tr '\n' ' ')
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 280)

printf '%s\n' "$APP" >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null
echo 1 >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
echo 1 >"$V/.ziyan_force_recap"
j=0
while [ $j -lt 30 ]; do
  ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
  echo "$ST" | grep -q 'lease_state=active' && echo "$ST" | grep -q 'frame_provider=8' && break
  echo 1 >"$V/.ziyan_force_recap"
  j=$((j+1)); sleep 0.4
done
rm -f "$V/.ziyan_open_app" "$V/.ziyan_unlock_req"
echo AGAIN_WAKE=$j
: >"$M/_p0d12_again.txt"
chmod 666 "$M/_p0d12_again.txt"
printf 'path=%s/_p0d12_again.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d12_again.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on"
rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop" "$V/.ziyan_kill_scripts"
printf 'nonce=d12b_%s\nrequest_id=d12b_%s\nsession_id=d12b_%s\n' "$$" "$$" "$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_embed_go"
a=0
while [ $a -lt 80 ]; do
  grep -q '^done$' "$M/_p0d12_again.txt" 2>/dev/null && break
  a=$((a+1)); sleep 0.25
done
echo AGAIN_WAIT=$a
echo AGAIN_OUT=$(tr '\n' ' ' <"$M/_p0d12_again.txt")
echo 1 >"$V/.ziyan_user_stopped"
printf 'path=\nstop=1\n' >"$V/.ziyan_run_intent"
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_embed_go"
echo SB_PID1=$(sb_pid)
echo FC_PID1=$(fc_pid)
echo FC_N_FINAL=$(fc_n)
echo KEEP_FINAL=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo END=$(date +%s)
EOS
}

for H in "${HOSTS[@]}"; do
  run_one "$H" &
done
echo "waiting ${MIN}min…"
wait

ts_snap 171 "$OUT/ts171_end.txt" &
ts_snap 149 "$OUT/ts149_end.txt" &
wait || true

for H in "${HOSTS[@]}"; do
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/usr/lib/ziyan/var/.ziyan_e4_resource.tsv" \
    "$OUT/rss_${H}.tsv" 2>/dev/null || true
done

python3 - "$OUT" "$MIN" "/Users/mac/Desktop/ZiYan_副本/tools/zy_rss_slope_analyze.py" "${HOSTS[@]}" <<'PY' | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
import os, re, sys, subprocess
out = sys.argv[1]
mins = int(sys.argv[2])
ols = sys.argv[3]
hosts = sys.argv[4:]
print("# P1 Day12 30min lifecycle hold")
print("out=%s hosts=%s min=%d pkg=debug-10-2" % (out, " ".join(hosts), mins))
print()
print("| host | ver | beat n/hit | idle_hit | SB_CHG | FC | keep_after | again gold | verdict |")
print("|---|---|---|---|---|---|---|---|---|")

def field(t, k):
    m = re.search(r"^%s=(.*)$" % re.escape(k), t, re.M)
    return (m.group(1).strip() if m else "")

rows = []
for h in hosts:
    t = open(os.path.join(out, "run_%s.txt" % h), errors="replace").read() if os.path.isfile(os.path.join(out, "run_%s.txt" % h)) else ""
    ver = field(t, "VER")
    beat = field(t, "BEAT_END")
    idle = field(t, "IDLE_HIT")
    sb = field(t, "SB_CHG")
    fcm = field(t, "FC_N_MAX")
    fca = field(t, "FC_N_AFTER")
    fcf = field(t, "FC_N_FINAL")
    keepa = field(t, "KEEP_AFTER")
    pid = field(t, "PIDFILE_AFTER")
    emb = field(t, "EMBED_AFTER")
    sess = field(t, "SESS_AFTER")
    stop = field(t, "STOP_ACK")
    again = field(t, "AGAIN_OUT")
    startb = field(t, "START_BEAT")
    stats = field(t, "STATS")
    health = field(t, "HEALTH_AFTER")
    sb0 = field(t, "SB_PID0")
    sb1 = field(t, "SB_PID1")
    keepd = field(t, "KEEP_DURING")
    cr = re.search(r"via_color_req_find=(\d+)", stats)
    em = re.search(r"via_embed_find=(\d+)", stats)
    crn = int(cr.group(1)) if cr else -1
    emn = int(em.group(1)) if em else -1
    bn = re.search(r"n=(\d+)", beat)
    bh = re.search(r"hit=(\d+)", beat)
    bg = re.search(r"GOLD=(-?\d+)", beat)
    n = int(bn.group(1)) if bn else 0
    hit = int(bh.group(1)) if bh else 0
    gold = int(bg.group(1)) if bg else None
    ag = re.search(r"GOLD=(-?\d+)", again)
    af = re.search(r"FIND=(-?\d+),(-?\d+)", again)
    agv = int(ag.group(1)) if ag else None
    axy = (int(af.group(1)), int(af.group(2))) if af else (None, None)
    fail = []
    if "GOLD=" not in startb:
        fail.append("NO_START")
    if n < max(10, mins * 20):
        fail.append("BEAT_LOW")
    if gold != 12688231:
        fail.append("GOLD_RUN")
    if hit < max(5, n // 4):
        fail.append("HIT_LOW")
    try:
        if int(idle or "99") > 2:
            fail.append("IDLE_%s" % idle)
    except ValueError:
        fail.append("IDLE")
    if sb not in ("0",):
        fail.append("SB_CHG")
    if fcm not in ("1",) or fca not in ("1",) or fcf not in ("1",):
        fail.append("FC")
    if keepd not in ("1",):
        fail.append("KEEP_OFF")
    if keepa not in ("0",) or pid not in ("0",) or emb not in ("0",):
        fail.append("STOP_STICKY")
    if "state=running" in sess:
        fail.append("SESS_RUN")
    if "active=1" in stop or "keep_after=1" in stop:
        fail.append("STOP_ACK")
    if crn > 0:
        fail.append("COLOR_REQ")
    if emn <= 10:
        fail.append("EMBED_LOW")
    if "ok=1" not in health:
        fail.append("HEALTH")
    if agv != 12688231 or axy[0] is None or axy[0] < 0:
        fail.append("GOLD_AGAIN")
    if not sb0 or not sb1 or sb0 != sb1:
        fail.append("SB_PID")
    label = "PASS" if not fail else "FAIL:" + ",".join(fail)
    rows.append(label)
    print("| .%s | %s | %s/%s | %s | %s | %s/%s/%s | %s | %s/%s | %s |" % (
        h, ver, n, hit, idle or "?", sb or "?", fcm, fca, fcf, keepa or "?",
        agv, axy, label))
print()
print("## OLS")
for h in hosts:
    tsv = os.path.join(out, "rss_%s.tsv" % h)
    if os.path.isfile(tsv) and os.path.getsize(tsv) > 20:
        r = subprocess.run(["python3", ols, tsv], capture_output=True, text=True)
        print("### .%s" % h)
        print((r.stdout or r.stderr or "analyze_fail").strip())
    else:
        print("OLS .%s tsv_missing" % h)
print()
print("Day12 is 30min lifecycle on debug-10-2. Not 3h. Not four phones. No Home. No surpass claim.")
open(os.path.join(out, "CLASS.txt"), "w").write("\n".join(rows) + "\n")
PY
echo "OUT=$OUT"
