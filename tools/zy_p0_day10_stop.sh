#!/usr/bin/env bash
# P1 Day10：停止合同。不杀 SB（部署后才 sbreload）、不改 Desktop lua、不碰 .53、不拧匹配器。
# 验：stop 后 ACTIVE=0 KEEP=0 无 pidfile/embed/僵尸、FC_N=1、抬指/藏 toast 请求已消费、可再跑金标。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY10_STOP_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=20
          -o ServerAliveCountMax=6)
echo "OUT=$OUT hosts=${HOSTS[*]} no_pretest no_53 no_matcher" | tee "$OUT/meta.txt"

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}
ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

cat >"$OUT/_p0d10_hold.lua" <<'LUA'
init(1)
keepScreen(true)
toast("d10", 2)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d10_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
if type(touchDown) == "function" then
  touchDown(1, 200, 200)
  w("DOWN=1")
end
w("ready")
mSleep(8000)
if type(touchUp) == "function" then
  touchUp(1, 200, 200)
end
keepScreen(false)
w("ended")
LUA

cat >"$OUT/_p0d10_again.lua" <<'LUA'
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d10_again.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("done")
LUA

run_one() {
  local H="$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$OUT/_p0d10_hold.lua" "$OUT/_p0d10_again.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$H" \
    "H=$H bash -s" >"$OUT/run_${H}.txt" 2>&1 <<'EOS'
set +e
V=/usr/lib/ziyan/var
M=/var/mobile/Media/ZiYan
APP=com.xztl.ios
RID="d10_$$_$(date +%s)"
echo VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo RID=$RID
fc_n() { ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9'; }
lua_n() { ps -axo args= 2>/dev/null | grep -E 'ziyan_run\.lua|lua5\.3 .*/ZiYan/' | grep -vc grep | tr -dc '0-9'; }
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

rm -f "$M/_p0d10_out.txt" "$M/_p0d10_again.txt" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_off" "$V/.ziyan_kill_scripts" "$V/.ziyan_run_ack" \
  "$V/.ziyan_ready_ack" "$V/.ziyan_stop_ack" "$V/.ziyan_embed_ack" \
  "$V/.ziyan_stop_cleanup" "$V/.ziyan_stop_cleanup_ack"
: >"$M/_p0d10_out.txt"
chmod 666 "$M/_p0d10_hold.lua" "$M/_p0d10_again.lua" "$M/_p0d10_out.txt"
printf 'path=%s/_p0d10_hold.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d10_hold.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
printf 'nonce=%s\nrequest_id=%s\nsession_id=%s\n' "$RID" "$RID" "$RID" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"

n=0
while [ $n -lt 40 ]; do
  grep -q '^ready$' "$M/_p0d10_out.txt" 2>/dev/null && break
  n=$((n+1)); sleep 0.25
done
echo HOLD_WAIT=$n
echo HOLD_OUT=$(tr '\n' ' ' <"$M/_p0d10_out.txt")
echo KEEP_DURING=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo PIDFILE_DURING=$(test -f "$V/.ziyan_lua_run.pid" && echo 1 || echo 0)

echo 1 >"$V/.ziyan_user_stopped"
chmod 666 "$V/.ziyan_user_stopped"
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts"
s=0
while [ $s -lt 40 ]; do
  grep -q '^state=idle' "$V/.ziyan_stop_ack" 2>/dev/null && break
  s=$((s+1)); sleep 0.1
done
echo STOP_ACK_WAIT=$s
echo STOP_ACK=$(tr '\n' ' ' <"$V/.ziyan_stop_ack" 2>/dev/null)
c=0
while [ $c -lt 20 ]; do
  grep -q '^touch_lift=1' "$V/.ziyan_stop_cleanup_ack" 2>/dev/null && break
  c=$((c+1)); sleep 0.1
done
echo CLEANUP_WAIT=$c
echo CLEANUP_ACK=$(tr '\n' ' ' <"$V/.ziyan_stop_cleanup_ack" 2>/dev/null)
sleep 1
echo KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo PIDFILE_AFTER=$(test -f "$V/.ziyan_lua_run.pid" && echo 1 || echo 0)
echo EMBED_AFTER=$(test -f "$V/.ziyan_embed_alive" && echo 1 || echo 0)
echo SESSION_AFTER=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
echo LUA_N_AFTER=$(lua_n)
echo FC_N_AFTER=$(fc_n)
echo HEALTH_AFTER=$(wget -qO- -T 2 http://127.0.0.1:50005/health 2>/dev/null | tr '\n' ' ')
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 220)

rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_go" "$V/.ziyan_run_intent"
: >"$M/_p0d10_again.txt"
chmod 666 "$M/_p0d10_again.txt"
RID2="d10b_$$_$(date +%s)"
printf 'path=%s/_p0d10_again.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d10_again.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
printf 'nonce=%s\nrequest_id=%s\nsession_id=%s\n' "$RID2" "$RID2" "$RID2" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"
a=0
while [ $a -lt 40 ]; do
  grep -q '^done$' "$M/_p0d10_again.txt" 2>/dev/null && break
  a=$((a+1)); sleep 0.25
done
echo AGAIN_WAIT=$a
echo AGAIN_OUT=$(tr '\n' ' ' <"$M/_p0d10_again.txt")
echo 1 >"$V/.ziyan_user_stopped"
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_embed_go" \
  "$V/.ziyan_embed_script" "$V/.ziyan_run_intent"
echo KEEP_FINAL=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo FC_N_FINAL=$(fc_n)
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
print("# P1 Day10 stop contract")
print("out=%s hosts=%s" % (out, " ".join(hosts)))
print()
print("| host | ver | stop active/keep | pid/embed/lua | cleanup | again gold | FC_N | verdict |")
print("|---|---|---|---|---|---|---|---|")

def field(t, k):
    m = re.search(r"^%s=(.*)$" % re.escape(k), t, re.M)
    return (m.group(1).strip() if m else "")

rows = []
for h in hosts:
    t = open(os.path.join(out, "run_%s.txt" % h), errors="replace").read() if os.path.isfile(os.path.join(out, "run_%s.txt" % h)) else ""
    ver = field(t, "VER")
    stop = field(t, "STOP_ACK")
    keep = field(t, "KEEP_AFTER")
    pid = field(t, "PIDFILE_AFTER")
    emb = field(t, "EMBED_AFTER")
    lua = field(t, "LUA_N_AFTER")
    sess = field(t, "SESSION_AFTER")
    cup = field(t, "CLEANUP_ACK")
    again = field(t, "AGAIN_OUT")
    fc = field(t, "FC_N_AFTER")
    fcf = field(t, "FC_N_FINAL")
    hold = field(t, "HOLD_OUT")
    stats = field(t, "STATS")
    cr = re.search(r"via_color_req_find=(\d+)", stats)
    crn = int(cr.group(1)) if cr else -1
    g = re.search(r"GOLD=(-?\d+)", hold)
    f = re.search(r"FIND=(-?\d+),(-?\d+)", hold)
    goldv = int(g.group(1)) if g else None
    xy = (int(f.group(1)), int(f.group(2))) if f else (None, None)
    ag = re.search(r"GOLD=(-?\d+)", again)
    af = re.search(r"FIND=(-?\d+),(-?\d+)", again)
    agv = int(ag.group(1)) if ag else None
    axy = (int(af.group(1)), int(af.group(2))) if af else (None, None)
    fail = []
    if "state=idle" not in stop:
        fail.append("NO_STOP_ACK")
    if "active=1" in stop or "keep_after=1" in stop:
        fail.append("STOP_ACTIVE")
    if "state=running" in sess:
        fail.append("SESS_RUN")
    if keep not in ("0",):
        fail.append("KEEP_AFTER")
    if pid not in ("0",):
        fail.append("PIDFILE")
    if emb not in ("0",):
        fail.append("EMBED")
    if lua not in ("0", "", "00"):
        # lua_n may be empty if grep none → tr -dc leaves ""
        try:
            if int(lua or "0") > 0:
                fail.append("ZOMBIE")
        except ValueError:
            fail.append("ZOMBIE")
    if "touch_lift=1" not in cup or "toast_hide=1" not in cup:
        fail.append("CLEANUP")
    if goldv != 12688231 or xy[0] is None or xy[0] < 0:
        fail.append("GOLD_HOLD")
    if agv != 12688231 or axy[0] is None or axy[0] < 0:
        fail.append("GOLD_AGAIN")
    if fc not in ("1",) or fcf not in ("1",):
        fail.append("FC")
    if crn > 0:
        fail.append("COLOR_REQ")
    if "ok=1" not in field(t, "HEALTH_AFTER"):
        fail.append("HEALTH")
    label = "PASS" if not fail else "FAIL:" + ",".join(fail)
    rows.append(label)
    print("| .%s | %s | %s/%s | %s/%s/%s | %s | %s/%s | %s/%s | %s |" % (
        h, ver, "active=0" if "active=1" not in stop else "active=1", keep,
        pid, emb, lua or "0",
        "ok" if "touch_lift=1" in cup else cup[:24],
        agv, axy, fc, fcf, label))
print()
print("Day10 is the stop contract, not 100x (Day11). No surpass claim. .53 not deployed.")
open(os.path.join(out, "CLASS.txt"), "w").write("\n".join(rows) + "\n")
PY
echo "OUT=$OUT"
