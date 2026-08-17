#!/usr/bin/env bash
# Home shell + Agent four-action + real App picker gate. No sbreload.
set -euo pipefail
if [ "${1:-}" != "--home-agent-ui-final" ]; then
  echo "only allowed: $0 --home-agent-ui-final" >&2
  exit 78
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$ROOT/tmp_shots/HOME_AND_AGENT_UI_FINAL_REWORK_${STAMP}"
PASS="${ZY_SSH_PASS:-alpine}"
mkdir -p "$OUT"
echo "OUT=$OUT"
echo "CLOCK_SKEW=workspace_2026-08-16_progress_file_2026-08-15" | tee "$OUT/CLOCK_SKEW.txt"

DEB_RF=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-37*_iphoneos-arm.deb 2>/dev/null | head -1)
DEB_RL=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-37*_iphoneos-arm64.deb 2>/dev/null | head -1)
if [ -z "${DEB_RF:-}" ] || [ -z "${DEB_RL:-}" ]; then
  echo "MISSING_DEBUG_1037_DEB" | tee "$OUT/VERDICT.md"
  exit 2
fi
echo "DEB_RF=$DEB_RF" | tee "$OUT/debs.txt"
echo "DEB_RL=$DEB_RL" | tee -a "$OUT/debs.txt"

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

install_one() {
  local tag="$1" scheme="$2" ip="$3" deb="$4"
  local V D
  V=$(var_dir "$scheme")
  D="$OUT/$tag"
  mkdir -p "$D"
  ssh_r "$ip" "V=$V bash -s" >"$D/pre_state.txt" 2>&1 <<'EOS' || true
set +e
pid_of() { LINE=$(ps -axo pid=,args= | grep "$1" | grep -v grep | head -1); set -- $LINE; echo "$1"; }
echo PRE_SB=$(pid_of '[S]pringBoard.app/SpringBoard')
echo PRE_BB=$(pid_of '[b]ackboardd')
echo '--- STATE ---'
cat "$V/.ziyan_state.plist" 2>/dev/null | head -40
echo
echo -n 'SAVE_SEL='
sed -n '/<key>selectedPath<\/key>/{n;s/.*<string>//;s/<\/string>.*//;p;}' "$V/.ziyan_state.plist" 2>/dev/null | head -1
EOS
  scp_to "$deb" "$ip" /tmp/ziyan.deb
  ssh_r "$ip" "dpkg -i /tmp/ziyan.deb; echo DPKG_RC=\$?; echo installed=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')" \
    >"$D/install.txt" 2>&1 || true
}

observe_one() {
  local tag="$1" scheme="$2" ip="$3"
  local V D
  V=$(var_dir "$scheme")
  D="$OUT/$tag"
  ssh_r "$ip" "V=$V bash -s" >"$D/startup_30s.txt" 2>&1 <<'EOS' || true
set +e
pid_of() { LINE=$(ps -axo pid=,args= | grep "$1" | grep -v grep | head -1); set -- $LINE; echo "$1"; }
echo CLOCK=$(date '+%Y-%m-%d %H:%M:%S')
SB0=$(pid_of '[S]pringBoard.app/SpringBoard')
BB0=$(pid_of '[b]ackboardd')
echo PRE_SB=$SB0 PRE_BB=$BB0
echo '--- CRASH_BEFORE ---'
ls -lt /var/mobile/Library/Logs/CrashReporter/ZiYan* 2>/dev/null | head -3
rm -f "$V/.ziyan_app_user_closed" "$V/.ziyan_vol_disarmed" \
      "$V/.ziyan_unlock_rep" "$V/.ziyan_go_home" "$V/.ziyan_open_app" \
      "$V/.ziyan_agent_current_profile" "$V/.ziyan_agent_session" \
      "$V/.ziyan_agent_stop" "$V/.ziyan_agent_list_req"
for i in 1 2 3; do
  ZLINE=$(ps -axo pid=,args= | grep '[Z]iYan.app/ZiYan' | grep -v grep | head -1)
  ZPID=$(echo "$ZLINE" | awk '{print $1}')
  [ -n "$ZPID" ] || break
  kill "$ZPID" 2>/dev/null
  sleep 1
done
rm -f "$V/.ziyan_app_user_closed"
[ -e "$V/.ziyan_project_active" ] || { date +%s >"$V/.ziyan_project_active"; chmod 666 "$V/.ziyan_project_active"; }
printf '1\n' >"$V/.ziyan_unlock_req"; chmod 666 "$V/.ziyan_unlock_req"
for i in 1 2 3 4 5 6 7 8; do
  REP=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null)
  echo "unlock t=$i rep=$REP"
  echo "$REP" | grep -qi ok && break
  sleep 2
done
printf 'com.ziyan.ziyan\n' >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app"
front_ok=0; z0=""; alive=0
for i in $(seq 1 25); do
  ZLINE=$(ps -axo pid=,etime=,args= | grep '[Z]iYan.app/ZiYan' | grep -v grep | head -1)
  ZPID=$(echo "$ZLINE" | awk '{print $1}')
  FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
  echo "t=${i}s ZPID=${ZPID:-none} FRONT=$FG"
  echo "$FG" | grep -q com.ziyan.ziyan && front_ok=1
  if [ -n "$ZPID" ] && [ "$front_ok" = 1 ]; then
    [ -z "$z0" ] && z0=$ZPID
    if [ "$ZPID" = "$z0" ]; then alive=$((alive+1)); else z0=$ZPID; alive=1; fi
  fi
  [ "$front_ok" = 1 ] && [ "$alive" -ge 15 ] && { echo HOLD_OK ZPID=$ZPID; break; }
  if [ "$i" = 8 ] && [ "$front_ok" = 0 ]; then
    rm -f "$V/.ziyan_app_user_closed"
    printf 'com.ziyan.ziyan\n' >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app"
  fi
  sleep 2
done
echo ALIVE_TICKS=$alive FRONT_OK=$front_ok
echo '--- CRASH_AFTER ---'
ls -lt /var/mobile/Library/Logs/CrashReporter/ZiYan* 2>/dev/null | head -3
SB1=$(pid_of '[S]pringBoard.app/SpringBoard')
BB1=$(pid_of '[b]ackboardd')
echo POST_SB=$SB1 POST_BB=$BB1
echo SB_STABLE=$([ "$SB0" = "$SB1" ] && echo 1 || echo 0)
echo BB_STABLE=$([ "$BB0" = "$BB1" ] && echo 1 || echo 0)
EOS
  cp -f "$D/startup_30s.txt" "$D/pid_stability.txt"
}

ui_one() {
  local tag="$1" scheme="$2" ip="$3"
  local V D
  V=$(var_dir "$scheme")
  D="$OUT/$tag"
  ssh_r "$ip" "V=$V TAG=$tag bash -s" >"$D/home_layout_probe.txt" 2>&1 <<'EOS' || true
set +e
rm -f "$V/.ziyan_ui_script_list.json" "$V/.ziyan_ui_home.json" \
      "$V/.ziyan_ui_agent_page.json" "$V/.ziyan_ui_app_picker.json" \
      "$V/.ziyan_agent_current_profile" "$V/.ziyan_agent_session"
printf 'home_probe\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
printf 'script_list_probe\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo '--- HOME ---'
cat "$V/.ziyan_ui_home.json" 2>/dev/null; echo
echo '--- SCRIPT_LIST ---'
cat "$V/.ziyan_ui_script_list.json" 2>/dev/null; echo
if [ "$TAG" = 53 ]; then
  printf 'select_basename\tios8p.lua\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
  sleep 2
  printf 'script_list_probe\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
  sleep 2
  echo '--- AFTER_SELECT ---'
  cat "$V/.ziyan_ui_script_list.json" 2>/dev/null; echo
fi
printf 'open_agent\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
printf 'agent_probe\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo '--- AGENT_PAGE ---'
cat "$V/.ziyan_ui_agent_page.json" 2>/dev/null; echo
printf 'picker_cancel\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo '--- PICKER_CANCEL ---'
cat "$V/.ziyan_ui_app_picker.json" 2>/dev/null; echo
echo '--- TARGET_AFTER_CANCEL ---'
cat "$V/.ziyan_agent_current_profile" 2>/dev/null; echo
echo SESSION_AFTER_CANCEL=$(cat "$V/.ziyan_agent_session" 2>/dev/null)
printf 'picker_confirm_first\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo '--- PICKER_CONFIRM ---'
cat "$V/.ziyan_ui_app_picker.json" 2>/dev/null; echo
echo '--- TARGET_AFTER_CONFIRM ---'
cat "$V/.ziyan_agent_current_profile" 2>/dev/null; echo
printf 'pop_home\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
printf 'script_list_probe\n' >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo '--- AFTER_POP_HOME ---'
cat "$V/.ziyan_ui_home.json" 2>/dev/null; echo
cat "$V/.ziyan_ui_script_list.json" 2>/dev/null; echo
EOS
  cp -f "$D/home_layout_probe.txt" "$D/script_list_probe.txt"
  cp -f "$D/home_layout_probe.txt" "$D/agent_page_probe.txt"
  cp -f "$D/home_layout_probe.txt" "$D/app_picker_confirm.txt"
  ssh_r "$ip" "V=$V bash -s" >"$D/volume_contract.txt" 2>&1 <<'EOS' || true
set +e
: > "$V/.ziyan_vol_event"
chmod 666 "$V/.ziyan_vol_event"
rm -f "$V/.ziyan_agent_stop" "$V/.ziyan_agent_list_req"
printf '1\n' >"$V/.ziyan_vol_trig"; chmod 666 "$V/.ziyan_vol_trig"
sleep 2
echo '--- AFTER_VOL_DOWN ---'
grep -E 'VolumeDown|agent=' "$V/.ziyan_vol_event" | tail -10
echo HAS_AGENT_ON_DOWN=$(grep -c 'agent=' "$V/.ziyan_vol_event" || true)
echo HAS_REC_TOAST=$(grep -cE '开始录制|录制已|录制结束' "$V/.ziyan_vol_event" || true)
printf 'state=LEARNING\nactive=1\n' >"$V/.ziyan_agent_session"
chmod 666 "$V/.ziyan_agent_session"
printf '1\n' >"$V/.ziyan_vol_plus_trig"; chmod 666 "$V/.ziyan_vol_plus_trig"
sleep 2
echo '--- AFTER_VOL_UP_AGENT ---'
cat "$V/.ziyan_agent_stop" 2>/dev/null
grep -E 'agent=stop|VolumeUp|rec=' "$V/.ziyan_vol_event" | tail -8
rm -f "$V/.ziyan_agent_session" "$V/.ziyan_agent_stop"
printf '1\n' >"$V/.ziyan_vol_plus_trig"; chmod 666 "$V/.ziyan_vol_plus_trig"
sleep 2
echo '--- AFTER_VOL_UP_IDLE ---'
cat "$V/.ziyan_agent_list_req" 2>/dev/null
grep -E 'agent=list|VolumeUp|rec=' "$V/.ziyan_vol_event" | tail -8
echo LIST_REQ=$([ -f "$V/.ziyan_agent_list_req" ] && echo 1 || echo consumed_or_absent)
echo HAS_REC_TOAST2=$(grep -cE '开始录制|录制已|录制结束' "$V/.ziyan_vol_event" || true)
EOS
}

restore_one() {
  local tag="$1" scheme="$2" ip="$3"
  local V want
  V=$(var_dir "$scheme")
  want=$(sed -n 's/^SAVE_SEL=//p' "$OUT/$tag/pre_state.txt" 2>/dev/null | head -1)
  case "$want" in
    *_cursor_run_smoke.lua|*_zy_page_entry_selftest.lua|*ziyan_agent_run.lua) want="" ;;
  esac
  ssh_r "$ip" "V=$V WANT='$want' bash -s" >>"$OUT/$tag/script_list_probe.txt" 2>&1 <<'EOS' || true
set +e
if [ -n "$WANT" ] && [ -f "$WANT" ]; then
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>selectedPath</key>' \
    "<string>$WANT</string></dict></plist>" >"$V/.ziyan_state.plist"
  echo RESTORED_SEL=$WANT
else
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>selectedPath</key><string></string></dict></plist>' \
    >"$V/.ziyan_state.plist"
  echo RESTORED_EMPTY
fi
chmod 666 "$V/.ziyan_state.plist"
rm -f /private/var/mobile/Media/ZiYan/_cursor_run_smoke.lua \
      "$V/.ziyan_page_selftest_req"
printf 'stop=1\nstate=idle\nreason=home_agent_ui_final_done\n' >"$V/.ziyan_run_intent"
chmod 666 "$V/.ziyan_run_intent"
echo CLEANED
EOS
}

echo "== parallel install =="
install_one 53 rootless 192.168.31.53 "$DEB_RL" &
p53=$!
install_one 101 rootful 192.168.31.101 "$DEB_RF" &
p101=$!
install_one 112 rootful 192.168.31.112 "$DEB_RF" &
p112=$!
install_one 166 rootful 192.168.31.166 "$DEB_RF" &
p166=$!
wait $p53 $p101 $p112 $p166

echo "== parallel observe =="
observe_one 53 rootless 192.168.31.53 &
o53=$!
observe_one 101 rootful 192.168.31.101 &
o101=$!
observe_one 112 rootful 192.168.31.112 &
o112=$!
observe_one 166 rootful 192.168.31.166 &
o166=$!
wait $o53 $o101 $o112 $o166

echo "== parallel ui+volume =="
ui_one 53 rootless 192.168.31.53 &
u53=$!
ui_one 101 rootful 192.168.31.101 &
u101=$!
ui_one 112 rootful 192.168.31.112 &
u112=$!
ui_one 166 rootful 192.168.31.166 &
u166=$!
wait $u53 $u101 $u112 $u166

echo "== parallel restore =="
restore_one 53 rootless 192.168.31.53 &
restore_one 101 rootful 192.168.31.101 &
restore_one 112 rootful 192.168.31.112 &
restore_one 166 rootful 192.168.31.166 &
wait

cp -f "$OUT/53/script_list_probe.txt" "$OUT/53_ios8p_visibility.txt"
echo OUT="$OUT"
echo ALL_PHONES_DONE
