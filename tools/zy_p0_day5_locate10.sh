#!/usr/bin/env bash
# P0 Day5：10 分钟定位窗。不装包、不杀 SB、不改 Desktop lua、不碰 .53。
# 四类：帧老化 / 锁等待 / 匹配耗时 / 前台错位。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SEC="${ZY_P0_LOCATE_SEC:-600}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY5_LOCATE10_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=20
          -o ServerAliveCountMax=6)
echo "OUT=$OUT SEC=$SEC hosts=${HOSTS[*]} no_deploy no_pretest no_53" | tee "$OUT/meta.txt"

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}
ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

cat >"$OUT/_p0d5_locate.lua" <<LUA
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d5_beat.txt", "a")
  if f then f:write(tostring(s) .. "\\n") f:close() end
end
local n, hit, miss, t0 = 0, 0, 0, os.time()
while os.time() - t0 < $SEC do
  local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
  n = n + 1
  if tonumber(x) and x >= 0 then hit = hit + 1 else miss = miss + 1 end
  if n % 25 == 0 then
    w(string.format("n=%d hit=%d miss=%d t=%d", n, hit, miss, os.time() - t0))
  end
  mSleep(400)
end
w(string.format("done n=%d hit=%d miss=%d", n, hit, miss))
LUA

run_one() {
  local H="$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$OUT/_p0d5_locate.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d5_locate.lua"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$H" \
    "H=$H SEC=$SEC bash -s" >"$OUT/run_${H}.txt" 2>&1 <<'EOS'
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
SB0=$(sb_pid); echo SB0=$SB0
echo FC_N0=$(fc_n)

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
wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null | sed -n 's/^\(lease_state\|frame_seq\|frame_provider\|front_bid\|shm_bid\)=/\1=/p'

rm -f "$M/_p0d5_beat.txt" "$V/.ziyan_path_stats" "$V/.ziyan_find_shm_log" \
  "$V/.ziyan_find_timing_log" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_off" "$V/.ziyan_kill_scripts" "$V/.ziyan_no_auto_keep"
echo 1 >"$V/.ziyan_no_auto_keep"
chmod 666 "$V/.ziyan_no_auto_keep"
: >"$M/_p0d5_beat.txt"
chmod 666 "$M/_p0d5_locate.lua" "$M/_p0d5_beat.txt"
printf 'path=%s/_p0d5_locate.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d5_locate.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
echo "nonce=p0d5_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"

: >"$M/_p0d5_sample.tsv"
echo -e "t\tlease\tseq\tage\tpv\tfront\tshm\tkeep\tfc_n\tsb" >>"$M/_p0d5_sample.tsv"
end=$(( $(date +%s) + SEC + 15 ))
SB_CHG=0
FC_N_MAX=0
AGE_GE2K=0
BID_MIS=0
SAMP=0
while [ "$(date +%s)" -lt "$end" ]; do
  grep -q '^done ' "$M/_p0d5_beat.txt" 2>/dev/null && break
  ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
  LE=$(echo "$ST" | sed -n 's/^lease_state=//p' | head -1)
  SEQ=$(echo "$ST" | sed -n 's/^frame_seq=//p' | head -1)
  AGE=$(echo "$ST" | sed -n 's/^frame_age_ms=//p' | head -1)
  PV=$(echo "$ST" | sed -n 's/^frame_provider=//p' | head -1)
  FR=$(echo "$ST" | sed -n 's/^front_bid=//p' | head -1)
  SH=$(echo "$ST" | sed -n 's/^shm_bid=//p' | head -1)
  KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
  FCN=$(fc_n); [ -n "$FCN" ] || FCN=0
  [ "$FCN" -gt "$FC_N_MAX" ] 2>/dev/null && FC_N_MAX=$FCN
  SB=$(sb_pid)
  if [ -n "$SB0" ] && [ -n "$SB" ] && [ "$SB" != "$SB0" ]; then
    SB_CHG=$((SB_CHG+1)); SB0=$SB
  fi
  echo -e "$(date +%s)\t${LE:--}\t${SEQ:--}\t${AGE:--}\t${PV:--}\t${FR:--}\t${SH:--}\t$KEEP\t$FCN\t${SB:--}" >>"$M/_p0d5_sample.tsv"
  SAMP=$((SAMP+1))
  case "$AGE" in ''|*[!0-9-]*) ;; *) [ "$AGE" -ge 2000 ] 2>/dev/null && AGE_GE2K=$((AGE_GE2K+1)) ;; esac
  [ -n "$FR" ] && [ -n "$SH" ] && [ "$FR" != "$SH" ] && BID_MIS=$((BID_MIS+1))
  sleep 2
done

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts"
sleep 2
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" \
  "$V/.ziyan_embed_script" "$V/.ziyan_active"
sleep 1
echo BEAT=$(tr '\n' ' ' <"$M/_p0d5_beat.txt" | tail -c 240)
echo LAST_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find")
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 260)
echo KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo FC_N_AFTER=$(fc_n)
echo SB_CHG=$SB_CHG
echo FC_N_MAX=$FC_N_MAX
echo SAMP=$SAMP
echo AGE_GE2K=$AGE_GE2K
echo BID_MIS=$BID_MIS
echo RELAY_LOG=$(grep -c 'relay_timeout\|relay_sb_fail' "$V/.ziyan_framecap_log" 2>/dev/null)
echo UICREATE_LOG=$(grep -c 'uicreate\|UICreate' "$V/.ziyan_framecap_log" 2>/dev/null)
echo END=$(date +%s)
EOS
}

for H in "${HOSTS[@]}"; do
  run_one "$H" &
done
wait

for H in "${HOSTS[@]}"; do
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d5_sample.tsv" \
    "$OUT/sample_${H}.tsv" 2>/dev/null || true
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/usr/lib/ziyan/var/.ziyan_find_shm_log" \
    "$OUT/find_shm_${H}.log" 2>/dev/null || true
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/usr/lib/ziyan/var/.ziyan_find_timing_log" \
    "$OUT/find_timing_${H}.log" 2>/dev/null || true
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d5_beat.txt" \
    "$OUT/beat_${H}.txt" 2>/dev/null || true
done

ts_snap 171 "$OUT/ts171_end.txt" &
ts_snap 149 "$OUT/ts149_end.txt" &
wait || true

python3 - "$OUT" "${HOSTS[@]}" <<'PY' | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
import os, re, sys, statistics
out = sys.argv[1]
hosts = sys.argv[2:]
rows = []
print("# P0 Day5 10min locate")
print("out=%s hosts=%s" % (out, " ".join(hosts)))
print()
print("| host | n/hit | age p50/p95/max | lock p95 | match p95 | age>=2s | bid_mis | SB_CHG | FC_N | class |")
print("|---|---|---|---|---|---|---|---|---|---|")
for h in hosts:
    run = open(os.path.join(out, "run_%s.txt" % h), errors="replace").read()
    beat = ""
    bp = os.path.join(out, "beat_%s.txt" % h)
    if os.path.isfile(bp):
        beat = open(bp, errors="replace").read()
    done = re.search(r"done n=(\d+) hit=(\d+) miss=(\d+)", beat) or re.search(r"done n=(\d+) hit=(\d+) miss=(\d+)", run)
    n = hit = miss = -1
    if done:
        n, hit, miss = int(done.group(1)), int(done.group(2)), int(done.group(3))
    ages, locks, matches = [], [], []
    shm = os.path.join(out, "find_shm_%s.log" % h)
    if os.path.isfile(shm):
        for line in open(shm, errors="replace"):
            m = re.search(r"age_ms=(-?\d+)", line)
            if m:
                a = int(m.group(1))
                if a >= 0:
                    ages.append(a)
    tlog = os.path.join(out, "find_timing_%s.log" % h)
    if os.path.isfile(tlog):
        for line in open(tlog, errors="replace"):
            m = re.search(r"lock_wait_ms=([\d.]+).*pixel_match_ms=([\d.]+)", line)
            if m:
                locks.append(float(m.group(1)))
                matches.append(float(m.group(2)))
    samp = os.path.join(out, "sample_%s.tsv" % h)
    samp_ages = []
    if os.path.isfile(samp):
        for i, line in enumerate(open(samp, errors="replace")):
            if i == 0:
                continue
            p = line.strip().split("\t")
            if len(p) >= 4:
                try:
                    a = int(p[3])
                    if a >= 0:
                        samp_ages.append(a)
                except ValueError:
                    pass
    use_ages = ages or samp_ages
    def pct(xs, p):
        if not xs:
            return -1
        xs = sorted(xs)
        k = int(round((p/100.0)*(len(xs)-1)))
        return xs[k]
    age_p50, age_p95, age_max = pct(use_ages, 50), pct(use_ages, 95), (max(use_ages) if use_ages else -1)
    lock_p95 = pct(locks, 95)
    match_p95 = pct(matches, 95)
    age_ge2k = int(re.search(r"AGE_GE2K=(\d+)", run).group(1)) if re.search(r"AGE_GE2K=(\d+)", run) else -1
    bid_mis = int(re.search(r"BID_MIS=(\d+)", run).group(1)) if re.search(r"BID_MIS=(\d+)", run) else -1
    sb = re.search(r"SB_CHG=(\d+)", run)
    fc = re.search(r"FC_N_MAX=(\d+)", run)
    sb_chg = int(sb.group(1)) if sb else -1
    fc_max = int(fc.group(1)) if fc else -1
    cr = re.search(r"via_color_req_find=(\d+)", run)
    crn = int(cr.group(1)) if cr else -1
    cls = []
    if use_ages and age_p95 >= 2000:
        cls.append("AGE")
    if locks and lock_p95 >= 50:
        cls.append("LOCK")
    if matches and match_p95 >= 50:
        cls.append("MATCH")
    if bid_mis > 0:
        cls.append("BID")
    if sb_chg > 0:
        cls.append("SB")
    if fc_max > 1:
        cls.append("FC")
    if crn > 0:
        cls.append("COLOR_REQ")
    if n > 0 and hit * 100 < n * 80:
        cls.append("HIT_LOW")
    label = ",".join(cls) if cls else "none"
    print("| .%s | %s/%s | %s/%s/%s | %s | %s | %s | %s | %s | %s | %s |" % (
        h, n, hit, age_p50, age_p95, age_max, lock_p95, match_p95,
        age_ge2k, bid_mis, sb_chg, fc_max, label))
    rows.append(label)
print()
print("class_rule: AGE=age_p95>=2000 LOCK=lock_p95>=50 MATCH=match_p95>=50 BID=front!=shm HIT_LOW=hit<80%")
print("No product change. No surpass claim. .53 not deployed.")
open(os.path.join(out, "CLASS.txt"), "w").write("\n".join(rows) + "\n")
PY

{
  echo
  echo "raw runs: $OUT/run_*.txt"
} | tee -a "$OUT/REPORT.md"
echo "OUT=$OUT"
