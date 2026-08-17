#!/usr/bin/env bash
# Agent P1 retest only. No dpkg, no sbreload.
set -euo pipefail
if [ "${1:-}" != "--agent-p1-retest" ]; then
  echo "only allowed: $0 --agent-p1-retest" >&2
  exit 78
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/AGENT_UI_4PHONE_20260815_1"
PASS="${ZY_SSH_PASS:-alpine}"
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
var_dir() { [ "$1" = rootless ] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var; }
agent_lua() {
  if [ "$1" = rootless ]; then
    echo "DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua /var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua"
  else
    echo "/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua /usr/lib/ziyan/lib/lua/ziyan_agent_run.lua"
  fi
}

run_one() {
  local tag="$1" scheme="$2" ip="$3"
  local V BIN
  V=$(var_dir "$scheme")
  BIN=$(agent_lua "$scheme")
  echo "== RETEST .$tag =="
  ssh_r "$ip" "V=$V BIN='$BIN' bash -s" >"$OUT/$tag/agent_p1_retest.txt" 2>&1 <<'EOS' || true
set +e
printf 'com.ziyan.ziyan\n' > "$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
  echo "wait_front t=$i front=$FG"
  echo "$FG" | grep -q com.ziyan.ziyan && break
  sleep 1
done
echo ACK_SEQ=$(sed -n 's/^seq=//p' "$V/.ziyan_frame_ack" | head -1)
echo LEASE=$(tr '\n' ' ' < "$V/.ziyan_lease_state")
printf 'profile_id=agent_observe\ndisplay_name=观察回归\ngame_name=子砚\nbundle_id=com.ziyan.ziyan\n' > "$V/.ziyan_agent_current_profile"
printf 'mode=observe\n' > "$V/.ziyan_agent_req"
eval $BIN
echo OBSERVE_RC=$?
echo OBSERVE_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
echo OBSERVE_HAS_STOP=$([ -f "$V/.ziyan_stop" ] && echo 1 || echo 0)
printf 'profile_id=agent_safe_action\ndisplay_name=安全动作\ngame_name=子砚\nbundle_id=com.ziyan.ziyan\n' > "$V/.ziyan_agent_current_profile"
printf 'mode=safe\n' > "$V/.ziyan_agent_req"
eval $BIN
echo SAFE_RC=$?
echo SAFE_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
printf 'mode=learn\n' > "$V/.ziyan_agent_req"
eval $BIN &
LPID=$!
sleep 2
echo LEARN_MID=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
printf 'stop=1\n' > "$V/.ziyan_agent_stop"
chmod 666 "$V/.ziyan_agent_stop"
wait $LPID 2>/dev/null
echo LEARN_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
printf 'mode=drill\n' > "$V/.ziyan_agent_req"
eval $BIN &
DPID=$!
sleep 2
echo DRILL_MID=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
printf 'stop=1\n' > "$V/.ziyan_agent_stop"
wait $DPID 2>/dev/null
echo DRILL_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
printf 'mode=auto\n' > "$V/.ziyan_agent_req"
eval $BIN
echo AUTO_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
echo FC=$(ps -ax -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep)
echo RUN_OK=$(ls /private/var/mobile/Media/ZiYan/Agent游戏/运行记录/ 2>/dev/null | wc -l)
echo ERR_OK=$(ls /private/var/mobile/Media/ZiYan/Agent游戏/错误报告/ 2>/dev/null | wc -l)
echo HAS_GLOBAL_STOP=$([ -f "$V/.ziyan_stop" ] && echo 1 || echo 0)
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_AFTER=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_AFTER=$1
EOS
  echo "RETEST_DONE .$tag"
}

run_one 53 rootless 192.168.31.53
run_one 101 rootful 192.168.31.101
run_one 112 rootful 192.168.31.112
run_one 166 rootful 192.168.31.166
echo RETEST_ALL_DONE
