#!/usr/bin/env bash
# P1 Day11：run/stop 100 次 + 音量受控触发 + embed 崩溃恢复。
# 不杀 SB（部署后才 sbreload）、不改 Desktop lua、不碰 .53、不拧匹配器、不新建守护。
# 验：每圈停后 ACTIVE/KEEP/pid/embed=0、FC_N=1；SB pid 不变；崩溃后 framecap 仍在且 10s 内可再跑金标。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
N="${ZY_D11_N:-100}"
VOL_N="${ZY_D11_VOL_N:-5}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P0_DAY11_CYCLE_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=20
          -o ServerAliveCountMax=6)
echo "OUT=$OUT hosts=${HOSTS[*]} N=$N VOL_N=$VOL_N no_pretest no_53 no_matcher no_sbreload" \
  | tee "$OUT/meta.txt"

ts_snap() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" \
    'echo HOST='$1'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$2" 2>&1 || echo SSH_FAIL >>"$2"
}
ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

cat >"$OUT/_p0d11_hold.lua" <<'LUA'
init(1)
keepScreen(true)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d11_out.txt", "a")
  if f then f:write(tostring(s) .. "\n") f:close() end
end
w("GOLD=" .. tostring(getColor(706, 449)))
local x, y = findMultiColorInRegionFuzzy(12688231, "0|0|12688231", 90, 700, 440, 712, 458)
w("FIND=" .. tostring(x) .. "," .. tostring(y))
w("ready")
mSleep(4000)
keepScreen(false)
w("ended")
LUA

cat >"$OUT/_p0d11_boom.lua" <<'LUA'
init(1)
local media = "/var/mobile/Media/ZiYan"
local f = io.open(media .. "/_p0d11_boom.txt", "a")
if f then f:write("boom\n") f:close() end
error("d11_boom")
LUA

cat >"$OUT/_p0d11_again.lua" <<'LUA'
init(1)
keepScreen(false)
local media = "/var/mobile/Media/ZiYan"
local function w(s)
  local f = io.open(media .. "/_p0d11_again.txt", "a")
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
    "$OUT/_p0d11_hold.lua" "$OUT/_p0d11_boom.lua" "$OUT/_p0d11_again.lua" \
    "root@192.168.31.$H:/var/mobile/Media/ZiYan/"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$H" \
    "H=$H N=$N VOL_N=$VOL_N bash -s" >"$OUT/run_${H}.txt" 2>&1 <<'EOS'
set +e
V=/usr/lib/ziyan/var
M=/var/mobile/Media/ZiYan
APP=com.xztl.ios
echo VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo N=$N VOL_N=$VOL_N
fc_n() { ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9'; }
lua_n() { ps -axo args= 2>/dev/null | grep -E 'ziyan_run\.lua|lua5\.3 .*/ZiYan/' | grep -vc grep | tr -dc '0-9'; }
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

wake_game() {
  printf '%s\n' "$APP" >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  echo 1 >"$V/.ziyan_unlock_req"
  chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
  echo 1 >"$V/.ziyan_force_recap"
  local j=0
  while [ $j -lt 30 ]; do
    ST=$(wget -qO- -T 2 http://127.0.0.1:50005/status 2>/dev/null)
    echo "$ST" | grep -q 'lease_state=active' && echo "$ST" | grep -q 'frame_provider=8' && break
    echo 1 >"$V/.ziyan_force_recap"
    j=$((j+1)); sleep 0.4
  done
  rm -f "$V/.ziyan_open_app" "$V/.ziyan_unlock_req"
  echo "$j"
}

chmod 666 "$M/_p0d11_hold.lua" "$M/_p0d11_boom.lua" "$M/_p0d11_again.lua"

start_embed() {
  local script="$1" rid="$2" outf="$3"
  # 先写新 intent，再清 user_stopped。反之 zydaemon 会按旧 path=hold 复活。
  rm -f "$V/.ziyan_stop" "$V/.ziyan_kill_scripts" \
    "$V/.ziyan_stop_ack" "$V/.ziyan_embed_go" "$V/.ziyan_embed_crash"
  : >"$outf"
  chmod 666 "$outf"
  printf 'path=%s\nstop=0\n' "$script" >"$V/.ziyan_run_intent"
  printf '%s\n' "$script" >"$V/.ziyan_embed_script"
  echo 1 >"$V/.ziyan_embed_on"
  chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on"
  rm -f "$V/.ziyan_user_stopped"
  printf 'nonce=%s\nrequest_id=%s\nsession_id=%s\n' "$rid" "$rid" "$rid" >"$V/.ziyan_embed_go"
  chmod 666 "$V/.ziyan_embed_go"
}

start_vol() {
  local script="$1" outf="$2"
  rm -f "$V/.ziyan_stop" "$V/.ziyan_kill_scripts" \
    "$V/.ziyan_stop_ack" "$V/.ziyan_embed_go" "$V/.ziyan_menu_run_trig"
  : >"$outf"
  chmod 666 "$outf"
  printf 'path=%s\nstop=0\n' "$script" >"$V/.ziyan_run_intent"
  chmod 666 "$V/.ziyan_run_intent"
  rm -f "$V/.ziyan_user_stopped"
  printf '%s\n' "$script" >"$V/.ziyan_menu_run_trig"
  chmod 666 "$V/.ziyan_menu_run_trig"
}

do_stop() {
  local rid="$1"
  rm -f "$V/.ziyan_stop_ack"
  printf 'path=\nstop=1\n' >"$V/.ziyan_run_intent"
  chmod 666 "$V/.ziyan_run_intent"
  echo 1 >"$V/.ziyan_user_stopped"
  chmod 666 "$V/.ziyan_user_stopped"
  printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
  chmod 666 "$V/.ziyan_kill_scripts"
  local s=0
  while [ $s -lt 50 ]; do
    if [ -n "$rid" ] && grep -q "request_id=$rid" "$V/.ziyan_stop_ack" 2>/dev/null && \
       grep -q '^state=idle' "$V/.ziyan_stop_ack" 2>/dev/null; then
      break
    fi
    if [ -z "$rid" ] && grep -q '^state=idle' "$V/.ziyan_stop_ack" 2>/dev/null; then
      break
    fi
    s=$((s+1)); sleep 0.1
  done
  echo "$s"
}

assert_idle() {
  local keep=0 pidf=0 emb=0
  [ -f "$V/.ziyan_keep_daemon" ] && keep=1
  [ -f "$V/.ziyan_lua_run.pid" ] && pidf=1
  [ -f "$V/.ziyan_embed_alive" ] && emb=1
  echo "keep=$keep pid=$pidf emb=$emb fc=$(fc_n) lua=$(lua_n)"
}

FAILS=""
OK=0
VOL_OK=0
# 暖机一圈不计入 100（首圈 prewarm/lease 常 >4s）
start_embed "$M/_p0d11_hold.lua" "d11warm_$$" "$M/_p0d11_out.txt"
w=0
while [ $w -lt 80 ]; do
  grep -q '^ready$' "$M/_p0d11_out.txt" 2>/dev/null && break
  w=$((w+1)); sleep 0.1
done
echo WARM_WAIT=$w OUT=$(tr '\n' ' ' <"$M/_p0d11_out.txt")
do_stop "d11warm_$$" >/dev/null
sleep 0.3

i=1
while [ $i -le "$N" ]; do
  RID="d11_${i}_$$"
  : >"$M/_p0d11_out.txt"
  chmod 666 "$M/_p0d11_out.txt"
  start_embed "$M/_p0d11_hold.lua" "$RID" "$M/_p0d11_out.txt"
  w=0
  while [ $w -lt 80 ]; do
    grep -q '^ready$' "$M/_p0d11_out.txt" 2>/dev/null && break
    w=$((w+1)); sleep 0.1
  done
  if ! grep -q '^ready$' "$M/_p0d11_out.txt" 2>/dev/null; then
    FAILS="${FAILS} RUN${i}"
    echo CYCLE_$i=FAIL_START wait=$w out=$(tr '\n' ' ' <"$M/_p0d11_out.txt")
    do_stop "$RID" >/dev/null
    i=$((i+1))
    continue
  fi
  sw=$(do_stop "$RID")
  sleep 0.2
  ST=$(assert_idle)
  ACK=$(tr '\n' ' ' <"$V/.ziyan_stop_ack" 2>/dev/null)
  SESS=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
  FC=$(fc_n)
  bad=""
  echo "$ACK" | grep -q 'active=1' && bad="${bad}ACTIVE "
  echo "$ACK" | grep -q 'keep_after=1' && bad="${bad}KEEPACK "
  echo "$ST" | grep -q 'keep=1' && bad="${bad}KEEP "
  echo "$ST" | grep -q 'pid=1' && bad="${bad}PID "
  echo "$ST" | grep -q 'emb=1' && bad="${bad}EMB "
  echo "$SESS" | grep -q 'state=running' && bad="${bad}SESS "
  [ "$FC" = "1" ] || bad="${bad}FC=$FC "
  if [ -n "$bad" ]; then
    FAILS="${FAILS} STOP${i}:${bad}"
    echo CYCLE_$i=FAIL_STOP wait=$sw $ST ack=$ACK sess=$SESS
  else
    OK=$((OK+1))
    echo CYCLE_$i=OK wait=$w stop=$sw $ST
  fi
  i=$((i+1))
done
echo CYCLE_OK=$OK
echo CYCLE_N=$N
echo CYCLE_FAILS=$FAILS

echo VOL_WAKE=$(wake_game)
sleep 1
v=1
while [ $v -le "$VOL_N" ]; do
  : >"$M/_p0d11_out.txt"
  chmod 666 "$M/_p0d11_out.txt"
  start_vol "$M/_p0d11_hold.lua" "$M/_p0d11_out.txt"
  w=0
  while [ $w -lt 60 ]; do
    grep -q '^ready$' "$M/_p0d11_out.txt" 2>/dev/null && break
    w=$((w+1)); sleep 0.2
  done
  if ! grep -q '^ready$' "$M/_p0d11_out.txt" 2>/dev/null; then
    echo VOL_$v=FAIL_START wait=$w
    do_stop >/dev/null
    v=$((v+1))
    continue
  fi
  sw=$(do_stop)
  sleep 0.2
  ST=$(assert_idle)
  FC=$(fc_n)
  if echo "$ST" | grep -q 'keep=0' && echo "$ST" | grep -q 'pid=0' && echo "$ST" | grep -q 'emb=0' && [ "$FC" = "1" ]; then
    VOL_OK=$((VOL_OK+1))
    echo VOL_$v=OK wait=$w stop=$sw $ST
  else
    echo VOL_$v=FAIL $ST fc=$FC
  fi
  v=$((v+1))
done
echo VOL_OK=$VOL_OK
echo VOL_N=$VOL_N

rm -f "$M/_p0d11_boom.txt" "$V/.ziyan_embed_crash"
: >"$M/_p0d11_boom.txt"
chmod 666 "$M/_p0d11_boom.txt"
start_embed "$M/_p0d11_boom.lua" "d11boom_$$" "$M/_p0d11_boom.txt"
b=0
while [ $b -lt 40 ]; do
  [ -s "$V/.ziyan_embed_crash" ] && break
  grep -q '^boom$' "$M/_p0d11_boom.txt" 2>/dev/null && [ ! -f "$V/.ziyan_embed_alive" ] && break
  b=$((b+1)); sleep 0.1
done
sleep 2
BOOM_N=$(grep -c '^boom$' "$M/_p0d11_boom.txt" 2>/dev/null | tr -dc '0-9')
echo CRASH_WAIT=$b
echo CRASH_ACK=$(tr '\n' ' ' <"$V/.ziyan_embed_crash" 2>/dev/null)
echo CRASH_BOOM_N=${BOOM_N:-0}
echo CRASH_KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo CRASH_PIDFILE=$(test -f "$V/.ziyan_lua_run.pid" && echo 1 || echo 0)
echo CRASH_EMBED=$(test -f "$V/.ziyan_embed_alive" && echo 1 || echo 0)
echo CRASH_SESS=$(tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null)
echo CRASH_FC=$(fc_n)
echo CRASH_FC_PID=$(fc_pid)
echo HEALTH_CRASH=$(wget -qO- -T 2 http://127.0.0.1:50005/health 2>/dev/null | tr '\n' ' ')

echo AGAIN_WAKE=$(wake_game)
rm -f "$M/_p0d11_again.txt" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_kill_scripts" "$V/.ziyan_embed_go"
: >"$M/_p0d11_again.txt"
chmod 666 "$M/_p0d11_again.txt"
CRASH_T0=$(date +%s)
start_embed "$M/_p0d11_again.lua" "d11again_$$" "$M/_p0d11_again.txt"
aw=0
while [ $aw -lt 80 ]; do
  grep -q '^done$' "$M/_p0d11_again.txt" 2>/dev/null && break
  aw=$((aw+1)); sleep 0.25
done
CRASH_T1=$(date +%s)
echo AGAIN_WAIT=$aw
echo AGAIN_OUT=$(tr '\n' ' ' <"$M/_p0d11_again.txt")
echo RECOVER_SEC=$((CRASH_T1 - CRASH_T0))
echo 1 >"$V/.ziyan_user_stopped"
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_embed_go"

echo SB_PID1=$(sb_pid)
echo FC_PID1=$(fc_pid)
echo FC_N_FINAL=$(fc_n)
echo HEALTH_FINAL=$(wget -qO- -T 2 http://127.0.0.1:50005/health 2>/dev/null | tr '\n' ' ')
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null | tail -c 220)
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

python3 - "$OUT" "$N" "$VOL_N" "${HOSTS[@]}" <<'PY' | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
import os, re, sys
out = sys.argv[1]
n = int(sys.argv[2])
vol_n = int(sys.argv[3])
hosts = sys.argv[4:]
print("# P1 Day11 run/stop cycle + crash recover")
print("out=%s hosts=%s N=%d VOL_N=%d" % (out, " ".join(hosts), n, vol_n))
print()
print("| host | ver | cycle | vol | crash | recover gold | SB_CHG | FC | verdict |")
print("|---|---|---|---|---|---|---|---|---|")

def field(t, k):
    m = re.search(r"^%s=(.*)$" % re.escape(k), t, re.M)
    return (m.group(1).strip() if m else "")

rows = []
for h in hosts:
    t = open(os.path.join(out, "run_%s.txt" % h), errors="replace").read() if os.path.isfile(os.path.join(out, "run_%s.txt" % h)) else ""
    ver = field(t, "VER")
    ok = field(t, "CYCLE_OK").split()[0] if field(t, "CYCLE_OK") else ""
    fails = field(t, "CYCLE_FAILS")
    vok = field(t, "VOL_OK")
    crash = field(t, "CRASH_ACK")
    boom = field(t, "CRASH_BOOM_N")
    again = field(t, "AGAIN_OUT")
    rec = field(t, "RECOVER_SEC")
    sb0 = field(t, "SB_PID0")
    sb1 = field(t, "SB_PID1")
    fc0 = field(t, "FC_N0")
    fcf = field(t, "FC_N_FINAL")
    fcc = field(t, "CRASH_FC")
    keepc = field(t, "CRASH_KEEP")
    pidc = field(t, "CRASH_PIDFILE")
    embc = field(t, "CRASH_EMBED")
    sessc = field(t, "CRASH_SESS")
    healthc = field(t, "HEALTH_CRASH")
    healthf = field(t, "HEALTH_FINAL")
    stats = field(t, "STATS")
    cr = re.search(r"via_color_req_find=(\d+)", stats)
    crn = int(cr.group(1)) if cr else -1
    ag = re.search(r"GOLD=(-?\d+)", again)
    af = re.search(r"FIND=(-?\d+),(-?\d+)", again)
    agv = int(ag.group(1)) if ag else None
    axy = (int(af.group(1)), int(af.group(2))) if af else (None, None)
    fail = []
    try:
        if int(ok or "0") < n:
            fail.append("CYCLE_%s/%s" % (ok or "0", n))
    except ValueError:
        fail.append("CYCLE")
    if fails.strip():
        fail.append("FAILS")
    try:
        if int(vok or "0") < vol_n:
            fail.append("VOL_%s/%s" % (vok or "0", vol_n))
    except ValueError:
        fail.append("VOL")
    # ziyan_run 对业务 error() 走 pcall+os.exit，不一定写 embed_crash。
    # 合同：boom 只出现一次、会话落地、framecap 仍在、10s 内可再跑。
    try:
        if int(boom or "0") != 1:
            fail.append("REVIVE_LOOP")
    except ValueError:
        fail.append("REVIVE_LOOP")
    if keepc not in ("0",) or pidc not in ("0",) or embc not in ("0",):
        fail.append("CRASH_STICKY")
    if "state=running" in sessc or "hold.lua" in sessc:
        fail.append("CRASH_SESS")
    if fcc not in ("1",) or fcf not in ("1",) or fc0 not in ("1",):
        fail.append("FC")
    if "ok=1" not in healthc or "ok=1" not in healthf:
        fail.append("HEALTH")
    if agv != 12688231 or axy[0] is None or axy[0] < 0:
        fail.append("GOLD_AGAIN")
    try:
        if int(rec or "99") > 10:
            fail.append("RECOVER_%ss" % rec)
    except ValueError:
        fail.append("RECOVER")
    if not sb0 or not sb1 or sb0 != sb1:
        fail.append("SB_CHG")
    if crn > 0:
        fail.append("COLOR_REQ")
    label = "PASS" if not fail else "FAIL:" + ",".join(fail)
    rows.append(label)
    print("| .%s | %s | %s/%s | %s/%s | %s | %s/%s %ss | %s→%s | %s/%s | %s |" % (
        h, ver, ok or "?", n, vok or "?", vol_n,
        "crash" if ("ZY_E_RUNNER_CRASHED" in crash or boom == "1") else "noack",
        agv, axy, rec or "?",
        sb0 or "?", sb1 or "?", fcc or "?", fcf or "?", label))
print()
print("Day11 is run/stop x%s + vol x%s + crash recover. Not 3h. No surpass claim. .53 not deployed." % (n, vol_n))
open(os.path.join(out, "CLASS.txt"), "w").write("\n".join(rows) + "\n")
PY
echo "OUT=$OUT"
