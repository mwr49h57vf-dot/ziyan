#!/usr/bin/env bash
# P0/P1 Day8：session ACK。不杀 SB（部署后才 sbreload）、不改 Desktop lua、不碰 .53、不拧匹配器。
# 验：run_ack accepted + ids；ready_ack 出现（fresh 可 0）；金标仍中；user stop → stop_ack idle keep_after=0。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY8_SESSION_ACK_${STAMP}"
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

cat >"$OUT/_p0d8_ack.lua" <<'LUA'
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d8_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("done")
LUA

run_one() {
  local H="$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$OUT/_p0d8_ack.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d8_ack.lua"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$H" \
    "H=$H bash -s" >"$OUT/run_${H}.txt" 2>&1 <<'EOS'
set +e
V=/usr/lib/ziyan/var
M=/var/mobile/Media/ZiYan
APP=com.xztl.ios
RID="d8_$$_$(date +%s)"
echo VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo RID=$RID
fc_n() { ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9'; }
echo FC_N0=$(fc_n)

printf '%s\n' "$APP" >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null
echo 1 >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
echo 1 >"$V/.ziyan_force_recap"
echo force=1 >"$V/.ziyan_frame_req"
i=0
while [ $i -lt 40 ]; do
  ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
  LE=$(echo "$ST" | sed -n 's/^lease_state=//p' | head -1)
  PV=$(echo "$ST" | sed -n 's/^frame_provider=//p' | head -1)
  echo "$LE" | grep -q active && [ "$PV" = 8 ] && break
  echo 1 >"$V/.ziyan_force_recap"
  i=$((i+1)); sleep 0.5
done
rm -f "$V/.ziyan_open_app" "$V/.ziyan_unlock_req"
echo WAKE_I=$i
echo STATUS0=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null | tr '\n' ' ' | sed -n 's/.*\(session_id=[^ ]*\).*\(request_id=[^ ]*\).*\(lease_state=[^ ]*\).*/\1 \2 \3/p')

rm -f "$M/_p0d8_out.txt" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_off" "$V/.ziyan_kill_scripts" "$V/.ziyan_run_ack" \
  "$V/.ziyan_ready_ack" "$V/.ziyan_stop_ack" "$V/.ziyan_embed_ack"
echo 1 >"$V/.ziyan_no_auto_keep"
chmod 666 "$V/.ziyan_no_auto_keep"
: >"$M/_p0d8_out.txt"
chmod 666 "$M/_p0d8_ack.lua" "$M/_p0d8_out.txt"
printf 'path=%s/_p0d8_ack.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d8_ack.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
printf 'nonce=%s\nrequest_id=%s\nsession_id=%s\n' "$RID" "$RID" "$RID" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"

j=0
while [ $j -lt 40 ]; do
  grep -q '^accepted=1' "$V/.ziyan_run_ack" 2>/dev/null && break
  grep -q '^ok=1' "$V/.ziyan_embed_ack" 2>/dev/null && break
  j=$((j+1)); sleep 0.1
done
echo RUN_ACK_WAIT=$j
echo RUN_ACK=$(tr '\n' ' ' <"$V/.ziyan_run_ack" 2>/dev/null)
echo EMBED_ACK=$(tr '\n' ' ' <"$V/.ziyan_embed_ack" 2>/dev/null)

k=0
while [ $k -lt 80 ]; do
  grep -q '^accepted=' "$V/.ziyan_ready_ack" 2>/dev/null && break
  k=$((k+1)); sleep 0.1
done
echo READY_ACK_WAIT=$k
echo READY_ACK=$(tr '\n' ' ' <"$V/.ziyan_ready_ack" 2>/dev/null)
echo SESSION=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
echo STATUS1=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null | tr '\n' ' ')

n=0
while [ $n -lt 40 ]; do
  grep -q '^done$' "$M/_p0d8_out.txt" 2>/dev/null && break
  n=$((n+1)); sleep 0.25
done
echo GOLD_WAIT=$n
echo GOLD_OUT=$(tr '\n' ' ' <"$M/_p0d8_out.txt")
echo LAST_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find")
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 220)

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
sleep 1
echo KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo FC_N_AFTER=$(fc_n)
echo SESSION_AFTER=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_run_intent" \
  "$V/.ziyan_embed_go" "$V/.ziyan_embed_script"
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
print("# P0 Day8 session ACK")
print("out=%s hosts=%s" % (out, " ".join(hosts)))
print()
print("| host | ver | run_ack | ready | gold/find | stop keep_after | cr_find | FC_N | verdict |")
print("|---|---|---|---|---|---|---|---|---|")

def field(t, k):
    m = re.search(r"^%s=(.*)$" % re.escape(k), t, re.M)
    return (m.group(1).strip() if m else "")

rows = []
for h in hosts:
    t = open(os.path.join(out, "run_%s.txt" % h), errors="replace").read() if os.path.isfile(os.path.join(out, "run_%s.txt" % h)) else ""
    rid = field(t, "RID")
    run = field(t, "RUN_ACK")
    ready = field(t, "READY_ACK")
    gold = field(t, "GOLD_OUT")
    stop = field(t, "STOP_ACK")
    keep = field(t, "KEEP_AFTER")
    fc = field(t, "FC_N_AFTER")
    ver = field(t, "VER")
    stats = field(t, "STATS")
    cr = re.search(r"via_color_req_find=(\d+)", stats)
    crn = int(cr.group(1)) if cr else -1
    g = re.search(r"GOLD=(-?\d+)", gold)
    f = re.search(r"FIND=(-?\d+),(-?\d+)", gold)
    goldv = int(g.group(1)) if g else None
    xy = (int(f.group(1)), int(f.group(2))) if f else (None, None)
    fail = []
    if "accepted=1" not in run and "ok=1" not in field(t, "EMBED_ACK"):
        fail.append("NO_RUN_ACK")
    if rid and rid not in run and rid not in field(t, "EMBED_ACK"):
        fail.append("RID_MISMATCH")
    if "accepted=" not in ready:
        fail.append("NO_READY_ACK")
    if goldv != 12688231 or xy[0] is None or xy[0] < 0:
        fail.append("GOLD_MISS")
    if "state=idle" not in stop:
        fail.append("NO_STOP_ACK")
    if rid and rid not in stop:
        fail.append("STOP_RID")
    if "ZY_E_STOP_TIMEOUT" in stop:
        fail.append("STOP_TIMEOUT")
    if keep not in ("0",):
        fail.append("KEEP_AFTER")
    if fc not in ("1",):
        fail.append("FC")
    if crn > 0:
        fail.append("COLOR_REQ")
    label = "PASS" if not fail else "FAIL:" + ",".join(fail)
    rows.append(label)
    print("| .%s | %s | %s | %s | %s/%s | %s/%s | %s | %s | %s |" % (
        h, ver, run[:40], ready[:40], goldv, xy, stop[:30], keep, crn, fc, label))
print()
print("fresh=0 in ready_ack is WATCH (Day7 start hitch), not FAIL.")
print("No surpass claim. .53 not deployed.")
open(os.path.join(out, "CLASS.txt"), "w").write("\n".join(rows) + "\n")
PY
echo "OUT=$OUT"
