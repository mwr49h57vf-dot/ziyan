#!/usr/bin/env bash
# P0 Day4：embed find 只读 resident；active 金标仍中。不装包、不杀 SB、不碰 .53。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY4_RESIDENT_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)
echo "OUT=$OUT hosts=${HOSTS[*]}" | tee "$OUT/meta.txt"
ssh_one() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" "$2"; }

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}
ts_snap 171 "$OUT/ts171.txt" &
ts_snap 149 "$OUT/ts149.txt" &
wait || true

cat >"$OUT/_p0d4_find.lua" <<'LUA'
init(1)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d4_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
local c = getColor(706, 449)
w("GOLD=" .. tostring(c))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("done")
LUA

run_one() {
  local H="$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$OUT/_p0d4_find.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/_p0d4_find.lua"
  ssh_one "$H" 'bash -s' <<'R'
set +e
V=/usr/lib/ziyan/var
M=/var/mobile/Media/ZiYan
echo VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo FC_N=$(ps -axo args= | grep '[z]iyan_framecap serve' | grep -v grep | wc -l | tr -dc '0-9')
printf 'com.xztl.ios\n' >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null
i=0
LEASE=; PV=
while [ $i -lt 50 ]; do
  echo 1 >"$V/.ziyan_force_recap"
  echo force=1 >"$V/.ziyan_frame_req"
  ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
  LEASE=$(echo "$ST" | sed -n 's/^lease_state=//p' | head -1)
  PV=$(echo "$ST" | sed -n 's/^frame_provider=//p' | head -1)
  echo "$LEASE" | grep -q active && [ "$PV" = 8 ] && break
  i=$((i+1)); sleep 0.6
done
rm -f "$V/.ziyan_open_app"
echo WAIT_I=$i
wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null | sed -n 's/^\(lease_state\|frame_seq\|frame_provider\|front_bid\|shm_bid\)=/\1=/p'
n=p0d4a_$$
rm -f "$V/.ziyan_color_rep"
printf 'getColor\n706\n449\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
i=0
while [ $i -lt 40 ]; do
  [ -f "$V/.ziyan_color_rep" ] && grep -q "$n" "$V/.ziyan_color_rep" 2>/dev/null && break
  i=$((i+1)); sleep 0.1
done
echo COLOR_REQ_GOLD=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null)
rm -f "$M/_p0d4_out.txt" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" "$V/.ziyan_embed_off" "$V/.ziyan_kill_scripts" "$V/.ziyan_find_timing" "$V/.ziyan_last_find"
: >"$M/_p0d4_out.txt"
chmod 666 "$M/_p0d4_find.lua" "$M/_p0d4_out.txt"
printf 'path=%s/_p0d4_find.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_p0d4_find.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
echo "nonce=p0d4_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"
j=0
while [ $j -lt 40 ]; do
  grep -q '^done$' "$M/_p0d4_out.txt" 2>/dev/null && break
  j=$((j+1)); sleep 0.25
done
echo EMBED_OUT=$(tr '\n' ' ' <"$M/_p0d4_out.txt")
echo LAST_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find")
echo FIND_TIMING=$(tr '\n' ' ' <"$V/.ziyan_find_timing" | tail -c 220)
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 220)
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" "$V/.ziyan_embed_script"
echo KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo FC_N_AFTER=$(ps -axo args= | grep '[z]iyan_framecap serve' | grep -v grep | wc -l | tr -dc '0-9')
R
}

for H in "${HOSTS[@]}"; do
  run_one "$H" >"$OUT/run_${H}.txt" 2>&1
done

{
  echo "# P0 Day4 resident-only find"
  echo "stamp=$STAMP hosts=${HOSTS[*]}"
  echo
  echo "| host | ver | lease | gold | embed | last_find | timing | FC_N |"
  echo "|---|---|---|---|---|---|---|---|"
  for H in "${HOSTS[@]}"; do
    f="$OUT/run_${H}.txt"
    echo "| .$H | $(sed -n 's/^VER=//p' "$f" | head -1) | $(sed -n 's/^lease_state=//p' "$f" | head -1) | $(sed -n 's/^COLOR_REQ_GOLD=//p' "$f" | head -1) | $(sed -n 's/^EMBED_OUT=//p' "$f" | head -1) | $(sed -n 's/^LAST_FIND=//p' "$f" | head -1) | $(sed -n 's/^FIND_TIMING=//p' "$f" | head -1) | $(sed -n 's/^FC_N_AFTER=//p' "$f" | head -1) |"
  done
  echo
  echo "No surpass claim. Not Z2. .53 not deployed."
} | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
echo "OUT=$OUT"
