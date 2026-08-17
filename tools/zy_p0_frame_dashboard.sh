#!/usr/bin/env bash
# P0 Day1：同字段帧仪表盘。只读现包，不装包、不杀 SB、不改 Desktop lua。
# 默认 .101/.112/.166；.53 已恢复进验收集，传入即可只读，不部署。
# 用法：bash tools/zy_p0_frame_dashboard.sh [53 101 112 166]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 53|101|112|166) ;; *) echo "refuse host=$h (ZiYan accept: 53 101 112 166; TS observe only)"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DASHBOARD_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
echo "OUT=$OUT hosts=${HOSTS[*]} no_deploy no_pretest no_desktop_lua" | tee "$OUT/meta.txt"

ssh_one() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" "$2"
}

snap_one() {
  local H="$1" PHASE="$2"
  ssh_one "$H" "H='$H' PHASE='$PHASE' bash -s" <<'R'
set +e
if [ -d /var/jb/usr/lib/ziyan/var ]; then
  V=/var/jb/usr/lib/ziyan/var
else
  V=/usr/lib/ziyan/var
fi
echo PHASE=$PHASE
echo VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo FRONT_FILE=$(tr -d '\r\n' <"$V/.ziyan_front_bid")
echo KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0)
echo PIN=$(test -f "$V/.ziyan_resident_pin" && echo 1 || echo 0)
echo FC_N=$(ps -axo args= | grep '[z]iyan_framecap serve' | grep -v grep | wc -l | tr -dc '0-9')
ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
if [ -n "$ST" ]; then
  echo "$ST" | sed -n 's/^\(frame_seq\|frame_age_ms\|frame_provider\|frame_status\|front_bid\|shm_bid\|lease_state\|session\|resident_writer_waits\|resident_readers\|wants_run\)=/\1=/p'
else
  echo STATUS=missing
fi
echo LEASE_FILE=$(tr '\n' ' ' <"$V/.ziyan_lease_state" 2>/dev/null | head -c 160)
echo LAST_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find" 2>/dev/null | tail -c 240)
echo FIND_TIMING=$(tr '\n' ' ' <"$V/.ziyan_find_timing" 2>/dev/null | tail -c 200)
echo CONTRACT=$(tr '\n' ' ' <"$V/.ziyan_find_contract" 2>/dev/null | tail -c 200)
R
}

gold_one() {
  local H="$1"
  ssh_one "$H" 'bash -s' <<'R'
set +e
if [ -d /var/jb/usr/lib/ziyan/var ]; then
  V=/var/jb/usr/lib/ziyan/var
else
  V=/usr/lib/ziyan/var
fi
n=p0g_$$
rm -f "$V/.ziyan_color_rep"
printf 'getColor\n706\n449\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
i=0
while [ $i -lt 40 ]; do
  [ -f "$V/.ziyan_color_rep" ] && grep -q "$n" "$V/.ziyan_color_rep" 2>/dev/null && break
  i=$((i+1)); sleep 0.1
done
echo GOLD=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null)
R
}

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}

ts_snap 171 "$OUT/ts171.txt" &
ts_snap 149 "$OUT/ts149.txt" &
wait || true

if [ "${ZY_P0_PROBE_53:-0}" = 1 ]; then
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" root@192.168.31.53 \
    'echo VER53=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n "s/^Version: //p"); echo FRONT53=$(tr -d "\r\n" </var/jb/usr/lib/ziyan/var/.ziyan_front_bid 2>/dev/null)' \
    >"$OUT/probe_53.txt" 2>&1 || echo "53_UNREACHABLE" >"$OUT/probe_53.txt"
fi

for H in "${HOSTS[@]}"; do
  snap_one "$H" now >"$OUT/snap_${H}_now.txt" 2>&1
  gold_one "$H" >>"$OUT/snap_${H}_now.txt" 2>&1
done

{
  echo "# P0 frame dashboard"
  echo "stamp=$STAMP hosts=${HOSTS[*]}"
  echo
  echo "| host | ver | front | shm | seq | age_ms | provider | lease | keep | FC_N | gold |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|"
  for H in "${HOSTS[@]}"; do
    f="$OUT/snap_${H}_now.txt"
    echo "| .$H | $(sed -n 's/^VER=//p' "$f" | head -1) | $(sed -n 's/^front_bid=//p' "$f" | head -1) | $(sed -n 's/^shm_bid=//p' "$f" | head -1) | $(sed -n 's/^frame_seq=//p' "$f" | head -1) | $(sed -n 's/^frame_age_ms=//p' "$f" | head -1) | $(sed -n 's/^frame_provider=//p' "$f" | head -1) | $(sed -n 's/^lease_state=//p' "$f" | head -1) | $(sed -n 's/^KEEP=//p' "$f" | head -1) | $(sed -n 's/^FC_N=//p' "$f" | head -1) | $(sed -n 's/^GOLD=//p' "$f" | head -1) |"
  done
  echo
  echo "No surpass claim. Not Z2. .53 is back in the accept set."
} | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
echo "OUT=$OUT"
