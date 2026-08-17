#!/usr/bin/env bash
# Retest only: clear user_closed, unlock, foreground 30s, page-entry smoke.
# No dpkg, no sbreload, no killall SpringBoard.
set -euo pipefail
if [ "${1:-}" != "--retest" ]; then
  echo "only allowed: $0 --retest" >&2
  exit 78
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/APP_STARTUP_AND_NORMAL_RUN_FIX_20260816"
PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=8)
SSH_PASS_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
               -o ConnectTimeout=8 -o PreferredAuthentications=password
               -o PubkeyAuthentication=no)
ssh_r() {
  local ip="$1"; shift
  if ssh "${SSH_OPTS[@]}" "root@$ip" "$@"; then return 0; fi
  sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
}
var_dir() { [ "$1" = rootless ] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var; }

run_one() {
  local tag="$1" scheme="$2" ip="$3"
  local V D
  V=$(var_dir "$scheme")
  D="$OUT/$tag"
  mkdir -p "$D"
  echo "== RETEST2 .$tag =="
  ssh_r "$ip" "V=$V bash -s" >"$D/startup_30s.txt" 2>&1 <<'EOS' || true
set +e
pid_of() {
  LINE=$(ps -axo pid=,args= | grep "$1" | grep -v grep | head -1)
  set -- $LINE
  echo "$1"
}
echo CLOCK=$(date '+%Y-%m-%d %H:%M:%S')
SB0=$(pid_of '[S]pringBoard.app/SpringBoard')
BB0=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | grep -v grep | head -1)
set -- $BB0
BB0=$1
echo PRE_SB=$SB0 PRE_BB=$BB0
echo '--- CRASH_BEFORE ---'
ls -lt /var/mobile/Library/Logs/CrashReporter/ZiYan* 2>/dev/null | head -5
echo USER_CLOSED_BEFORE=$([ -f "$V/.ziyan_app_user_closed" ] && echo 1 || echo 0)
echo VOL_DISARM_BEFORE=$([ -f "$V/.ziyan_vol_disarmed" ] && echo 1 || echo 0)
# Cursor IPC leftovers only. Do not touch user Lua.
rm -f "$V/.ziyan_app_user_closed" "$V/.ziyan_vol_disarmed" \
      "$V/.ziyan_ui_agent_card.json" "$V/.ziyan_unlock_rep" \
      "$V/.ziyan_go_home" "$V/.ziyan_page_bg_req" \
      "$V/.ziyan_open_app" "$V/.ziyan_open_app.taking"
# Stop leftover ZiYan.app only (not SB / framecap / zydaemon).
for i in 1 2 3; do
  ZLINE=$(ps -axo pid=,args= | grep '[Z]iYan.app/ZiYan' | grep -v grep | head -1)
  set -- $ZLINE
  [ -n "$1" ] || break
  echo KILL_OLD_APP pid=$1
  kill "$1" 2>/dev/null
  sleep 1
done
[ -e "$V/.ziyan_project_active" ] || { date +%s >"$V/.ziyan_project_active"; chmod 666 "$V/.ziyan_project_active"; }
printf '1\n' >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req"
for i in 1 2 3 4 5 6 7 8 9 10; do
  REP=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null)
  echo "unlock t=$i rep=$REP"
  echo "$REP" | grep -qi ok && break
  sleep 2
done
printf 'com.ziyan.ziyan\n' >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app"
front_ok=0
z0=""
alive=0
for i in $(seq 1 25); do
  ZLINE=$(ps -axo pid=,etime=,args= | grep '[Z]iYan.app/ZiYan' | grep -v grep | head -1)
  set -- $ZLINE
  ZPID=$1
  ZET=$2
  FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
  SB=$(pid_of '[S]pringBoard.app/SpringBoard')
  BBL=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | grep -v grep | head -1)
  set -- $BBL
  BB=$1
  echo "t=${i}s ZPID=${ZPID:-none} et=${ZET:-} FRONT=$FG SB=$SB BB=$BB"
  echo "$FG" | grep -q com.ziyan.ziyan && front_ok=1
  if [ -n "$ZPID" ] && [ "$front_ok" = 1 ]; then
    if [ -z "$z0" ]; then z0=$ZPID; fi
    if [ "$ZPID" = "$z0" ]; then
      alive=$((alive+1))
    else
      echo ZPID_CHANGED old=$z0 new=$ZPID
      z0=$ZPID
      alive=1
    fi
  fi
  if [ "$front_ok" = 1 ] && [ "$alive" -ge 15 ]; then
    echo HOLD_OK alive=${alive}s ZPID=$ZPID FRONT=$FG
    break
  fi
  if [ "$i" = 8 ] && [ "$front_ok" = 0 ]; then
    rm -f "$V/.ziyan_app_user_closed" "$V/.ziyan_vol_disarmed"
    printf 'com.ziyan.ziyan\n' >"$V/.ziyan_open_app"
    chmod 666 "$V/.ziyan_open_app"
    echo REOPEN
  fi
  sleep 2
done
echo ALIVE_TICKS=$alive LAST_Z=$z0 FRONT_OK=$front_ok
echo '--- CRASH_AFTER ---'
ls -lt /var/mobile/Library/Logs/CrashReporter/ZiYan* 2>/dev/null | head -5
printf 'agent_probe\n' >"$V/.ziyan_ui_cmd"
chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo '--- CARD ---'
cat "$V/.ziyan_ui_agent_card.json" 2>/dev/null
echo
echo CARD_MTIME=$(ls -l "$V/.ziyan_ui_agent_card.json" 2>/dev/null)
echo '--- BOTTOM ---'
cat "$V/.ziyan_ui_bottom_bar.json" 2>/dev/null
echo
SB1=$(pid_of '[S]pringBoard.app/SpringBoard')
BBL=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | grep -v grep | head -1)
set -- $BBL
BB1=$1
echo POST_SB=$SB1 POST_BB=$BB1
echo SB_STABLE=$([ "$SB0" = "$SB1" ] && echo 1 || echo 0)
echo BB_STABLE=$([ "$BB0" = "$BB1" ] && echo 1 || echo 0)
EOS
  cp -f "$D/startup_30s.txt" "$D/pid_stability.txt"
  {
    echo '=== from startup_30s ==='
    grep -E 'CRASH_|HOLD_OK|ALIVE_|FRONT_OK|ZPID_CHANGED|scene-create' "$D/startup_30s.txt" || true
  } >"$D/crash_before_after.txt"
  {
    echo '=== CARD ==='
    awk '/--- CARD ---/,/--- BOTTOM ---/' "$D/startup_30s.txt" || true
    echo '=== BOTTOM ==='
    awk '/--- BOTTOM ---/,/POST_SB=/' "$D/startup_30s.txt" || true
  } >"$D/ui_probe.txt"
  ssh_r "$ip" "V=$V bash -s" >"$D/normal_run_smoke.txt" 2>&1 <<'EOS' || true
set +e
SMOKE=/private/var/mobile/Media/ZiYan/_cursor_run_smoke.lua
OUTF=/private/var/mobile/Media/ZiYan/ZYCV/tmp/_cursor_run_smoke_out.txt
mkdir -p /private/var/mobile/Media/ZiYan/ZYCV/tmp
cat >"$SMOKE" <<'LUA'
function main()
  local p = "/private/var/mobile/Media/ZiYan/ZYCV/tmp/_cursor_run_smoke_out.txt"
  local f = io.open(p, "w")
  if f then
    f:write("cursor_smoke_ok\n")
    f:close()
  end
end
LUA
chmod 644 "$SMOKE"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>selectedPath</key>' \
  "<string>$SMOKE</string></dict></plist>" >"$V/.ziyan_state.plist"
chmod 666 "$V/.ziyan_state.plist"
: > "$V/.ziyan_minimize_log"
chmod 666 "$V/.ziyan_minimize_log"
rm -f "$V/.ziyan_embed_ack" "$OUTF" "$V/.ziyan_page_selftest_req" "$V/.ziyan_page_selftest_rep"
# Keep App front for page-entry. Do not run user scripts.
FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
echo PRE_SMOKE_FRONT=$FG
if ! echo "$FG" | grep -q com.ziyan.ziyan; then
  rm -f "$V/.ziyan_app_user_closed" "$V/.ziyan_vol_disarmed"
  printf 'com.ziyan.ziyan\n' >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
    echo "reopen t=$i front=$FG"
    echo "$FG" | grep -q com.ziyan.ziyan && break
    sleep 1
  done
fi
printf 'nonce=startup_retest2_%s\n' "$$" >"$V/.ziyan_page_selftest_req"
chmod 666 "$V/.ziyan_page_selftest_req"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  sleep 1
  echo poll_$i
  [ -f "$OUTF" ] && echo HAS_SMOKE_OUT && break
  grep -E 'run_ok |page_entry |SIGTERM|FBS terminate|embed_|PAGE_SELFTEST|accepted' "$V/.ziyan_minimize_log" 2>/dev/null | tail -8
done
echo '--- MINLOG ---'
cat "$V/.ziyan_minimize_log" 2>/dev/null | tail -80
echo '--- ACK ---'
cat "$V/.ziyan_embed_ack" 2>/dev/null
echo '--- REP ---'
cat "$V/.ziyan_page_selftest_rep" 2>/dev/null
echo '--- SMOKE ---'
cat "$OUTF" 2>/dev/null
echo '--- SESSION ---'
cat "$V/.ziyan_session" 2>/dev/null
echo '--- FRONT_END ---'
echo FRONT=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
rm -f "$SMOKE" "$OUTF" "$V/.ziyan_page_selftest_req"
printf 'stop=1\nstate=idle\nreason=cursor_smoke_done\n' >"$V/.ziyan_run_intent"
chmod 666 "$V/.ziyan_run_intent"
echo CLEANED
EOS
}

run_one 53 rootless 192.168.31.53
run_one 101 rootful 192.168.31.101
run_one 112 rootful 192.168.31.112
run_one 166 rootful 192.168.31.166

ssh_r 192.168.31.112 'bash -s' >"$OUT/112_stale_intent_fix.txt" 2>&1 <<'EOS' || true
set +e
V=/usr/lib/ziyan/var
echo CLOCK=$(date '+%Y-%m-%d %H:%M:%S')
echo '--- INTENT ---'
cat "$V/.ziyan_run_intent"
echo
echo '--- BEFORE_20S ---'
grep -n 'revive_skip missing\|stale_intent_missing' "$V/.ziyan_zydaemon_log" | tail -15
C0=$(wc -l < "$V/.ziyan_zydaemon_log")
echo LOG_LINES=$C0
sleep 20
C1=$(wc -l < "$V/.ziyan_zydaemon_log")
echo '--- AFTER_20S ---'
echo LOG_LINES=$C1 DELTA=$((C1-C0))
grep -n 'revive_skip missing\|stale_intent_missing' "$V/.ziyan_zydaemon_log" | tail -15
echo NEW_REVIVE=$(awk -v t="$(date +%s)" 'BEGIN{} /revive_skip missing/ {c++} END{print c+0}' "$V/.ziyan_zydaemon_log")
echo '--- DAEMON ---'
ps -axo pid=,etime=,pcpu=,args= | grep '[z]iyan_zydaemond' | grep -v grep
EOS
echo RETEST_DONE
