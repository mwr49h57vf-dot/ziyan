#!/usr/bin/env bash
# P0 Day7：第一周完成条件复核。不装包、不杀 SB、不改 Desktop lua、不碰 .53、不拧匹配器。
# 窗内：持续 relay_timeout/relay_sb_fail、反复 UICreate、seq 停滞、业务期秒级 age、卡屏（脚本在跑但找不到且 seq 不走）。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SEC="${ZY_P0_DAY7_SEC:-300}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY7_WEEK1_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=20
          -o ServerAliveCountMax=6)
echo "OUT=$OUT SEC=$SEC hosts=${HOSTS[*]} no_deploy no_pretest no_53 no_matcher" | tee "$OUT/meta.txt"

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}
ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

cat >"$OUT/_p0d7_week1.lua" <<LUA
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d7_beat.txt", "a")
  if f then f:write(tostring(s) .. "\\n") f:close() end
end
local n, hit, miss, t0 = 0, 0, 0, os.time()
while os.time() - t0 < $SEC do
  local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
  n = n + 1
  if tonumber(x) and x >= 0 then hit = hit + 1 else miss = miss + 1 end
  if n % 20 == 0 then
    w(string.format("n=%d hit=%d miss=%d t=%d", n, hit, miss, os.time() - t0))
  end
  mSleep(400)
end
w(string.format("done n=%d hit=%d miss=%d", n, hit, miss))
LUA

run_one() {
  local H="$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$OUT/_p0d7_week1.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d7_week1.lua"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$H" \
    "H=$H SEC=$SEC bash -s" >"$OUT/run_${H}.txt" 2>&1 <<'EOS'
set +e
V=/usr/lib/ziyan/var
M=/var/mobile/Media/ZiYan
APP=com.xztl.ios
LOG="$V/.ziyan_framecap_log"
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

LOGSZ0=0
[ -f "$LOG" ] && LOGSZ0=$(wc -c <"$LOG" | tr -dc '0-9')
echo LOGSZ0=$LOGSZ0

rm -f "$M/_p0d7_beat.txt" "$V/.ziyan_path_stats" "$V/.ziyan_find_shm_log" \
  "$V/.ziyan_find_timing_log" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_off" "$V/.ziyan_kill_scripts" "$V/.ziyan_no_auto_keep"
echo 1 >"$V/.ziyan_no_auto_keep"
chmod 666 "$V/.ziyan_no_auto_keep"
: >"$M/_p0d7_beat.txt"
chmod 666 "$M/_p0d7_week1.lua" "$M/_p0d7_beat.txt"
printf 'path=%s/_p0d7_week1.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d7_week1.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
echo "nonce=p0d7_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"

: >"$M/_p0d7_sample.tsv"
echo -e "t\tlease\tseq\tage\tpv\tfront\tshm\tkeep\tfc_n\tsb" >>"$M/_p0d7_sample.tsv"
end=$(( $(date +%s) + SEC + 15 ))
SB_CHG=0
FC_N_MAX=0
AGE_GE2K=0
BID_MIS=0
SAMP=0
PREV_SEQ=
STALL_S=0
STALL_EVENTS=0
STALL_MAX=0
AGE_STREAK=0
AGE_STREAK_MAX=0
SEQ0=
SEQ_LAST=
while [ "$(date +%s)" -lt "$end" ]; do
  grep -q '^done ' "$M/_p0d7_beat.txt" 2>/dev/null && break
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
  echo -e "$(date +%s)\t${LE:--}\t${SEQ:--}\t${AGE:--}\t${PV:--}\t${FR:--}\t${SH:--}\t$KEEP\t$FCN\t${SB:--}" >>"$M/_p0d7_sample.tsv"
  SAMP=$((SAMP+1))
  [ -z "$SEQ0" ] && SEQ0=$SEQ
  SEQ_LAST=$SEQ
  case "$AGE" in ''|*[!0-9-]*) ;; *) [ "$AGE" -ge 2000 ] 2>/dev/null && AGE_GE2K=$((AGE_GE2K+1)) ;; esac
  [ -n "$FR" ] && [ -n "$SH" ] && [ "$FR" != "$SH" ] && BID_MIS=$((BID_MIS+1))
  if echo "$LE" | grep -q active && [ "$PV" = 8 ]; then
    if [ -n "$PREV_SEQ" ] && [ "$SEQ" = "$PREV_SEQ" ]; then
      STALL_S=$((STALL_S+2))
    else
      if [ "$STALL_S" -ge 6 ]; then STALL_EVENTS=$((STALL_EVENTS+1)); fi
      [ "$STALL_S" -gt "$STALL_MAX" ] && STALL_MAX=$STALL_S
      STALL_S=0
    fi
    PREV_SEQ=$SEQ
  else
    if [ "$STALL_S" -ge 6 ]; then STALL_EVENTS=$((STALL_EVENTS+1)); fi
    [ "$STALL_S" -gt "$STALL_MAX" ] && STALL_MAX=$STALL_S
    STALL_S=0
    PREV_SEQ=
  fi
  case "$AGE" in
    ''|*[!0-9-]*) AGE_STREAK=0 ;;
    *)
      if [ "$AGE" -ge 2000 ] 2>/dev/null; then
        AGE_STREAK=$((AGE_STREAK+1))
        [ "$AGE_STREAK" -gt "$AGE_STREAK_MAX" ] && AGE_STREAK_MAX=$AGE_STREAK
      else
        AGE_STREAK=0
      fi
      ;;
  esac
  sleep 2
done
if [ "$STALL_S" -ge 6 ]; then STALL_EVENTS=$((STALL_EVENTS+1)); fi
[ "$STALL_S" -gt "$STALL_MAX" ] && STALL_MAX=$STALL_S

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts"
sleep 2
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" \
  "$V/.ziyan_embed_script" "$V/.ziyan_active"
sleep 1

: >"$M/_p0d7_winlog.txt"
if [ -f "$LOG" ]; then
  LOGSZ1=$(wc -c <"$LOG" | tr -dc '0-9')
  echo LOGSZ1=$LOGSZ1
  if [ -n "$LOGSZ0" ] && [ -n "$LOGSZ1" ] && [ "$LOGSZ1" -gt "$LOGSZ0" ]; then
    tail -c +"$((LOGSZ0 + 1))" "$LOG" | tail -c 65536 >"$M/_p0d7_winlog.txt"
  fi
fi
chmod 666 "$M/_p0d7_winlog.txt" 2>/dev/null
echo WIN_RELAY=$(grep -cE 'relay_timeout|relay_sb_fail' "$M/_p0d7_winlog.txt" 2>/dev/null | tr -dc '0-9')
echo WIN_UICREATE=$(grep -cE 'uicreate|UICreate' "$M/_p0d7_winlog.txt" 2>/dev/null | tr -dc '0-9')
echo WIN_BLACK=$(grep -cE 'black_backoff|write_black' "$M/_p0d7_winlog.txt" 2>/dev/null | tr -dc '0-9')
echo BEAT=$(tr '\n' ' ' <"$M/_p0d7_beat.txt" | tail -c 240)
echo LAST_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find")
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 260)
echo KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo FC_N_AFTER=$(fc_n)
echo SB_CHG=$SB_CHG
echo FC_N_MAX=$FC_N_MAX
echo SAMP=$SAMP
echo AGE_GE2K=$AGE_GE2K
echo BID_MIS=$BID_MIS
echo SEQ0=$SEQ0 SEQ_LAST=$SEQ_LAST
echo STALL_EVENTS=$STALL_EVENTS STALL_MAX=$STALL_MAX
echo AGE_STREAK_MAX=$AGE_STREAK_MAX
echo END=$(date +%s)
EOS
}

for H in "${HOSTS[@]}"; do
  run_one "$H" &
done
wait

for H in "${HOSTS[@]}"; do
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d7_sample.tsv" \
    "$OUT/sample_${H}.tsv" 2>/dev/null || true
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d7_beat.txt" \
    "$OUT/beat_${H}.txt" 2>/dev/null || true
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d7_winlog.txt" \
    "$OUT/winlog_${H}.txt" 2>/dev/null || true
done

ts_snap 171 "$OUT/ts171_end.txt" &
ts_snap 149 "$OUT/ts149_end.txt" &
wait || true

python3 - "$OUT" "${HOSTS[@]}" <<'PY' | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
import os, re, sys
out = sys.argv[1]
hosts = sys.argv[2:]
print("# P0 Day7 week-1 completion")
print("out=%s hosts=%s" % (out, " ".join(hosts)))
print("no_deploy no_pretest no_53 no_matcher")
print()
print("| host | n/hit | age p50/p95/max | age>=2s streak | stall ev/max_s | seq0->last | win relay/ui/black | SB/FC/cr | class |")
print("|---|---|---|---|---|---|---|---|---|")

def field(txt, key):
    m = re.search(r"(?:^|\s)%s=(\S+)" % re.escape(key), txt)
    return m.group(1) if m else ""

def pct(xs, p):
    if not xs:
        return -1
    xs = sorted(xs)
    k = int(round((p/100.0)*(len(xs)-1)))
    return xs[k]

rows = []
for h in hosts:
    runp = os.path.join(out, "run_%s.txt" % h)
    t = open(runp, errors="replace").read() if os.path.isfile(runp) else ""
    beat = ""
    bp = os.path.join(out, "beat_%s.txt" % h)
    if os.path.isfile(bp):
        beat = open(bp, errors="replace").read()
    done = re.search(r"done n=(\d+) hit=(\d+) miss=(\d+)", beat) or re.search(r"done n=(\d+) hit=(\d+) miss=(\d+)", t)
    n = hit = miss = -1
    if done:
        n, hit, miss = int(done.group(1)), int(done.group(2)), int(done.group(3))
    ages = []
    sp = os.path.join(out, "sample_%s.tsv" % h)
    if os.path.isfile(sp):
        for i, line in enumerate(open(sp, errors="replace")):
            if i == 0:
                continue
            p = line.strip().split("\t")
            if len(p) >= 4:
                try:
                    a = int(p[3])
                    if a >= 0:
                        ages.append(a)
                except ValueError:
                    pass
    age_p50, age_p95, age_max = pct(ages, 50), pct(ages, 95), (max(ages) if ages else -1)
    age_ge2k = field(t, "AGE_GE2K") or "-1"
    streak = field(t, "AGE_STREAK_MAX") or "0"
    stall_ev = field(t, "STALL_EVENTS") or "0"
    stall_max = field(t, "STALL_MAX") or "0"
    seq0 = field(t, "SEQ0")
    seql = field(t, "SEQ_LAST")
    wr = int(field(t, "WIN_RELAY") or "0" or 0)
    wu = int(field(t, "WIN_UICREATE") or "0" or 0)
    wb = int(field(t, "WIN_BLACK") or "0" or 0)
    try:
        wr = int(re.search(r"WIN_RELAY=(\d+)", t).group(1)) if re.search(r"WIN_RELAY=(\d+)", t) else 0
        wu = int(re.search(r"WIN_UICREATE=(\d+)", t).group(1)) if re.search(r"WIN_UICREATE=(\d+)", t) else 0
        wb = int(re.search(r"WIN_BLACK=(\d+)", t).group(1)) if re.search(r"WIN_BLACK=(\d+)", t) else 0
    except Exception:
        pass
    sb = field(t, "SB_CHG")
    fc = field(t, "FC_N_MAX") or field(t, "FC_N_AFTER")
    stats = re.search(r"^STATS=(.*)$", t, re.M)
    crn = -1
    if stats:
        m = re.search(r"via_color_req_find=(\d+)", stats.group(1))
        if m:
            crn = int(m.group(1))
    last = re.search(r"^LAST_FIND=(.*)$", t, re.M)
    last_s = last.group(1) if last else ""
    last_hit = "class=hit" in last_s
    fail = []
    if wr > 0:
        fail.append("RELAY")
    if wu >= 5:
        fail.append("UICREATE_LOOP")
    if wb >= 3:
        fail.append("BLACK")
    try:
        if int(stall_ev) >= 3 or int(stall_max) >= 10:
            fail.append("SEQ_STALL")
    except ValueError:
        pass
    # AGE_SUSTAINED: p95>=2000, or 3 consecutive *active* samples age>=2000.
    # reacquiring + high age is the diagnostic path, not silent stale scan.
    act_streak = act_max = 0
    if os.path.isfile(sp):
        for i, line in enumerate(open(sp, errors="replace")):
            if i == 0:
                continue
            p = line.strip().split("\t")
            if len(p) < 4:
                continue
            le = p[1]
            try:
                a = int(p[3])
            except ValueError:
                continue
            if le == "active" and a >= 2000:
                act_streak += 1
                act_max = max(act_max, act_streak)
            else:
                act_streak = 0
    try:
        if (ages and age_p95 >= 2000) or act_max >= 3:
            fail.append("AGE_SUSTAINED")
    except ValueError:
        pass
    if n > 0 and hit * 100 < n * 80:
        fail.append("HIT_LOW")
    if n > 0 and hit * 100 < n * 80 and "SEQ_STALL" in fail:
        fail.append("STUCK")
    if sb not in ("0",):
        fail.append("SB")
    if fc not in ("1",):
        fail.append("FC")
    if crn > 0:
        fail.append("COLOR_REQ")
    keep = field(t, "KEEP_AFTER")
    if keep not in ("0",):
        fail.append("KEEP_AFTER")
    if n > 0 and not last_hit:
        fail.append("LAST_MISS")
    label = "PASS" if not fail else "FAIL:" + ",".join(fail)
    rows.append(label)
    print("| .%s | %s/%s | %s/%s/%s | %s/%s | %s/%s | %s->%s | %s/%s/%s | %s/%s/%s | %s |" % (
        h, n, hit, age_p50, age_p95, age_max, age_ge2k, streak,
        stall_ev, stall_max, seq0, seql, wr, wu, wb, sb, fc, crn, label))
print()
print("FAIL if: window relay>0; UICreate>=5; black>=3; seq stall events>=3 or max>=10s; age p95>=2000 or streak>=3 samples; hit<80%; last find not hit; SB/FC/color_req/keep.")
print("Needles of age>=2s without streak are not AGE_SUSTAINED. Whole-file UICreate grep is not used.")
print("No product change unless FAIL. No surpass claim. .53 not deployed. Day5 10min + this window = week-1 locate evidence.")
open(os.path.join(out, "CLASS.txt"), "w").write("\n".join(rows) + "\n")
PY
echo "OUT=$OUT"
