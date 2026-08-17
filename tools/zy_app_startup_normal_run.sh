#!/usr/bin/env bash
# App startup + normal run gate. No sbreload, no killall SpringBoard.
set -euo pipefail
if [ "${1:-}" != "--app-startup-normal-run" ]; then
  echo "only allowed: $0 --app-startup-normal-run" >&2
  exit 78
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/APP_STARTUP_AND_NORMAL_RUN_FIX_20260816"
PASS="${ZY_SSH_PASS:-alpine}"
mkdir -p "$OUT"
DEB_RF=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-35*_iphoneos-arm.deb 2>/dev/null | head -1)
DEB_RL=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-35*_iphoneos-arm64.deb 2>/dev/null | head -1)
SSH_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=8)
SSH_PASS_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
               -o ConnectTimeout=8 -o PreferredAuthentications=password
               -o PubkeyAuthentication=no)
ssh_r() {
  local ip="$1"; shift
  if ssh "${SSH_OPTS[@]}" "root@$ip" "$@" 2>/dev/null; then return 0; fi
  sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
}
scp_to() {
  local src="$1" ip="$2" dst="$3"
  if scp -o BatchMode=yes -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 "$src" "root@$ip:$dst" 2>/dev/null; then
    return 0
  fi
  sshpass -p "$PASS" scp "${SSH_PASS_OPTS[@]}" "$src" "root@$ip:$dst"
}
var_dir() { [ "$1" = rootless ] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var; }

# .112 stale evidence before install
ssh_r 192.168.31.112 'V=/usr/lib/ziyan/var; echo INTENT; cat $V/.ziyan_run_intent 2>/dev/null; echo ---LOG_TAIL---; grep -E "revive_skip missing|stale_intent|page_entry_selftest" $V/.ziyan_zydaemon_log 2>/dev/null | tail -20; echo ---PS---; ps -ax -o pid=,pcpu=,args= | grep -E "[z]iyan_zydaemond|[z]iyadaemond" | head' \
  >"$OUT/112_stale_intent_before.txt" 2>&1 || true

run_phone() {
  local tag="$1" scheme="$2" ip="$3" deb="$4"
  local V D
  V=$(var_dir "$scheme")
  D="$OUT/$tag"
  mkdir -p "$D"
  echo "== .$tag =="
  ssh_r "$ip" "V=$V bash -s" >"$D/pid_stability.txt" 2>&1 <<'EOS' || true
set +e
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE; echo PRE_SB=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE; echo PRE_BB=$1
echo PRE_PKG=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')
echo PRE_CRASH=$(ls -lt /var/mobile/Library/Logs/CrashReporter/ZiYan* 2>/dev/null | head -5)
EOS
  scp_to "$deb" "$ip" /tmp/ziyan.deb
  ssh_r "$ip" "dpkg -i /tmp/ziyan.deb; echo DPKG_RC=\$?; echo installed=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')" \
    | tee "$D/install.txt"
  # cursor-only leftover cleanup + restart zydaemon only (not SB)
  ssh_r "$ip" "V=$V bash -s" >>"$D/install.txt" 2>&1 <<'EOS' || true
set +e
# do not delete user lua
INTENT=$(cat "$V/.ziyan_run_intent" 2>/dev/null)
echo "$INTENT" | grep -E '_zy_page_entry_selftest|_cursor_run_smoke' >/dev/null 2>&1 && {
  printf 'stop=1\nstate=idle\nreason=cursor_smoke_cleanup\n' >"$V/.ziyan_run_intent"
  chmod 666 "$V/.ziyan_run_intent"
  echo CLEANED_CURSOR_INTENT
}
rm -f /private/var/mobile/Media/ZiYan/_cursor_run_smoke.lua \
      /private/var/mobile/Media/ZiYan/ZYCV/tmp/_cursor_run_smoke_out.txt \
      "$V/.ziyan_agent_stop" 2>/dev/null
# restart zydaemon script only
for p in $(ps -ax -o pid=,args= | grep -E '[z]iyan_zydaemond|[z]iyadaemond.sh' | awk '{print $1}'); do
  kill "$p" 2>/dev/null || true
  echo KILLED_ZYDAEMON_PID=$p
done
sleep 1
echo ZYDAEMON_AFTER=$(ps -ax -o pid=,args= | grep -E '[z]iyan_zydaemond|[z]iyadaemond' | grep -v grep | head -2)
EOS
  # open ZiYan
  ssh_r "$ip" "printf 'com.ziyan.ziyan\n' > $V/.ziyan_open_app; chmod 666 $V/.ziyan_open_app"
  : >"$D/startup_30s.txt"
  local alive=1 crash=0 last_pid=""
  local i
  for i in $(seq 1 15); do
    sample=$(ssh_r "$ip" "V=$V bash -s" <<'EOS' || true
set +e
ZLINE=$(ps -axo pid=,args= | grep -E '[Z]iYan.app/ZiYan|[Z]iYan$' | grep -v grep | head -1)
set -- $ZLINE; echo ZPID=$1
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE; echo SB=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE; echo BB=$1
echo FRONT=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
EOS
)
    echo "t=$((i*2))s $sample" | tee -a "$D/startup_30s.txt"
    zpid=$(printf '%s\n' "$sample" | sed -n 's/.*ZPID=\([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -z "$zpid" ]; then
      if [ "$i" -ge 4 ]; then alive=0; crash=1; break; fi
    else
      if [ -n "$last_pid" ] && [ "$last_pid" != "$zpid" ] && [ "$i" -ge 5 ]; then
        crash=1
      fi
      last_pid="$zpid"
    fi
    sleep 2
  done
  ssh_r "$ip" "ls -lt /var/mobile/Library/Logs/CrashReporter/ZiYan* /var/mobile/Library/Logs/CrashReporter/*watchdog* 2>/dev/null | head -8; echo ---; log show --style syslog --last 2m 2>/dev/null | grep -i -E 'scene-create watchdog|ZiYan' | tail -5" \
    >"$D/crash_before_after.txt" 2>&1 || true
  # UI probe
  ssh_r "$ip" "V=$V bash -s" >"$D/ui_probe.txt" 2>&1 <<'EOS' || true
set +e
printf 'agent_probe\n' > "$V/.ziyan_ui_cmd"
chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo CARD
cat "$V/.ziyan_ui_agent_card.json" 2>/dev/null
echo
echo BOTTOM
cat "$V/.ziyan_ui_bottom_bar.json" 2>/dev/null
echo
EOS
  # smoke via real run button path
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
printf 'nonce=startupfix_%s\n' "$$" > "$V/.ziyan_page_selftest_req"
chmod 666 "$V/.ziyan_page_selftest_req"
# keep app front
printf 'com.ziyan.ziyan\n' > "$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 1
  echo "poll_$i"
  grep -E 'run_ok |page_entry |embed_|SIGTERM|FBS terminate|accepted' "$V/.ziyan_minimize_log" 2>/dev/null | tail -8
  [ -f "$OUTF" ] && echo HAS_SMOKE_OUT && break
done
echo '--- MINLOG ---'
cat "$V/.ziyan_minimize_log" 2>/dev/null | tail -40
echo '--- EMBED_ACK ---'
cat "$V/.ziyan_embed_ack" 2>/dev/null
echo '--- SESSION ---'
cat "$V/.ziyan_session" 2>/dev/null
echo '--- SMOKE_OUT ---'
cat "$OUTF" 2>/dev/null
echo '--- INTENT ---'
cat "$V/.ziyan_run_intent" 2>/dev/null
# cleanup smoke only
rm -f "$SMOKE" "$OUTF" "$V/.ziyan_page_selftest_req"
printf 'stop=1\nstate=idle\nreason=cursor_smoke_done\n' > "$V/.ziyan_run_intent"
chmod 666 "$V/.ziyan_run_intent"
echo CLEANED_SMOKE
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE; echo POST_SB=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE; echo POST_BB=$1
EOS
  {
    echo "ALIVE_30S=$alive CRASH_SEEN=$crash LAST_ZPID=$last_pid"
    grep -E 'PRE_SB|PRE_BB|POST_SB|POST_BB' "$D/pid_stability.txt" "$D/normal_run_smoke.txt" || true
  } >>"$D/pid_stability.txt"
}

run_phone 53 rootless 192.168.31.53 "$DEB_RL"
run_phone 101 rootful 192.168.31.101 "$DEB_RF"
run_phone 112 rootful 192.168.31.112 "$DEB_RF"
run_phone 166 rootful 192.168.31.166 "$DEB_RF"

ssh_r 192.168.31.112 'V=/usr/lib/ziyan/var; echo AFTER; cat $V/.ziyan_run_intent; echo ---; grep -E "stale_intent_missing|revive_skip missing" $V/.ziyan_zydaemon_log | tail -15' \
  >"$OUT/112_stale_intent_fix.txt" 2>&1 || true
echo ALL_PHONES_DONE
