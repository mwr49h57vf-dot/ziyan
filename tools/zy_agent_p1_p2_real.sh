#!/usr/bin/env bash
# A0/P1/P2 four-phone gate. No sbreload. No user ios7/ios8p.
set -euo pipefail
if [ "${1:-}" != "--agent-p1-p2-real" ]; then
  echo "only allowed: $0 --agent-p1-p2-real" >&2
  exit 78
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="${ZY_EVIDENCE_DIR:-$ROOT/tmp_shots/AGENT_P1_P2_REAL_LEARN_FIX_${STAMP}}"
PASS="${ZY_SSH_PASS:-alpine}"
mkdir -p "$OUT"
echo "OUT=$OUT"
DEB_RF=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-38*_iphoneos-arm.deb 2>/dev/null | head -1)
DEB_RL=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-38*_iphoneos-arm64.deb 2>/dev/null | head -1)
echo "DEB_RF=$DEB_RF" | tee "$OUT/debs.txt"
echo "DEB_RL=$DEB_RL" | tee -a "$OUT/debs.txt"
SSH_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=8)
ssh_r() {
  local ip="$1"; shift
  if ssh "${SSH_OPTS[@]}" "root@$ip" "$@"; then return 0; fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "root@$ip" "$@"
}
scp_to() {
  local src="$1" ip="$2" dst="$3"
  if scp -o BatchMode=yes -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 "$src" "root@$ip:$dst" 2>/dev/null; then
    return 0
  fi
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 "$src" "root@$ip:$dst"
}
var_dir() { [ "$1" = rootless ] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var; }

install_one() {
  local tag="$1" scheme="$2" ip="$3" deb="$4" V D
  V=$(var_dir "$scheme"); D="$OUT/$tag"; mkdir -p "$D"
  ssh_r "$ip" "V=$V bash -s" >"$D/pre_state.txt" 2>&1 <<'EOS' || true
set +e
echo -n 'SAVE_SEL='
sed -n '/<key>selectedPath<\/key>/{n;s/.*<string>//;s/<\/string>.*//;p;}' "$V/.ziyan_state.plist" 2>/dev/null | head -1
EOS
  scp_to "$deb" "$ip" /tmp/ziyan.deb
  ssh_r "$ip" "dpkg -i /tmp/ziyan.deb; echo DPKG_RC=\$?; echo installed=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')" \
    >"$D/install.txt" 2>&1 || true
}

observe_one() {
  local tag="$1" scheme="$2" ip="$3" V D
  V=$(var_dir "$scheme"); D="$OUT/$tag"
  ssh_r "$ip" "V=$V bash -s" >"$D/startup_30s.txt" 2>&1 <<'EOS' || true
set +e
pid_of() { LINE=$(ps -axo pid=,args= | grep "$1" | grep -v grep | head -1); set -- $LINE; echo "$1"; }
SB0=$(pid_of '[S]pringBoard.app/SpringBoard')
BB0=$(pid_of '[b]ackboardd')
echo PRE_SB=$SB0 PRE_BB=$BB0
echo '--- CRASH_BEFORE ---'
ls -lt /var/mobile/Library/Logs/CrashReporter/ZiYan* 2>/dev/null | head -3
rm -f "$V/.ziyan_app_user_closed" "$V/.ziyan_agent_session" "$V/.ziyan_agent_stop"
for i in 1 2 3; do
  Z=$(pid_of '[Z]iYan.app/ZiYan'); [ -n "$Z" ] || break; kill "$Z" 2>/dev/null; sleep 1
done
rm -f "$V/.ziyan_app_user_closed"
[ -e "$V/.ziyan_project_active" ] || { date +%s >"$V/.ziyan_project_active"; chmod 666 "$V/.ziyan_project_active"; }
printf '1\n' >"$V/.ziyan_unlock_req"; chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null || true
for i in 1 2 3 4 5 6; do
  REP=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null)
  echo "unlock t=$i rep=$REP"
  echo "$REP" | grep -qi ok && break
  sleep 2
done
printf 'com.ziyan.ziyan\n' >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app"
front_ok=0; z0=""; alive=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
  Z=$(pid_of '[Z]iYan.app/ZiYan')
  FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
  echo "t=${i}s ZPID=${Z:-none} FRONT=$FG"
  echo "$FG" | grep -q com.ziyan.ziyan && front_ok=1
  if [ -n "$Z" ] && [ "$front_ok" = 1 ]; then
    [ -z "$z0" ] && z0=$Z
    if [ "$Z" = "$z0" ]; then alive=$((alive+1)); else z0=$Z; alive=1; fi
  fi
  [ "$front_ok" = 1 ] && [ "$alive" -ge 15 ] && { echo HOLD_OK ZPID=$Z; break; }
  if [ "$i" = 6 ] && [ "$front_ok" = 0 ]; then
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
echo SB_STABLE=$([ -n "$SB0" ] && [ "$SB0" = "$SB1" ] && echo 1 || echo 0)
echo BB_STABLE=$([ -n "$BB0" ] && [ "$BB0" = "$BB1" ] && echo 1 || echo 0)
FC=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' ')
echo FC_N=$FC
EOS
}

ui_one() {
  local tag="$1" scheme="$2" ip="$3" V D
  V=$(var_dir "$scheme"); D="$OUT/$tag"
  ssh_r "$ip" "V=$V bash -s" >"$D/session_convergence.txt" 2>&1 <<'EOS' || true
set +e
cmd() { printf '%s\n' "$1" >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd" 2>/dev/null || true; sleep 3; }
pid_of() { LINE=$(ps -axo pid=,args= | grep "$1" | grep -v grep | head -1); set -- $LINE; echo "$1"; }
SAVE=$(sed -n '/<key>selectedPath<\/key>/{n;s/.*<string>//;s/<\/string>.*//;p;}' "$V/.ziyan_state.plist" 2>/dev/null | head -1)
echo SAVE_SEL=$SAVE
echo '--- CONVERGE_BEFORE ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cmd open_agent
cmd agent_probe
echo '--- AGENT_PAGE ---'
cat "$V/.ziyan_ui_agent_page.json" 2>/dev/null; echo
cmd learn_cancel
echo '--- LEARN_CANCEL ---'
cat "$V/.ziyan_ui_learn.json" 2>/dev/null; echo
cat "$V/.ziyan_agent_session" 2>/dev/null; echo

# ch.27: learn_start first → WAITING_LOCK → then open target → lock
printf 'synthetic_test\n' >"$V/.ziyan_agent_learn_source"; chmod 666 "$V/.ziyan_agent_learn_source"
cmd learn_start
echo '--- LEARN_START ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
echo FRONT_AFTER_START=$(tr -d '\r\n' < "$V/.ziyan_front_bid")

# kill leftover notes so AppTouch filter can load on next launch (no sbreload)
for i in 1 2; do
  N=$(pid_of 'ownbook.notes'); [ -n "$N" ] && kill "$N" 2>/dev/null
  sleep 1
done
rm -f "$V/.ziyan_app_user_closed"
printf 'com.ownbook.notes\n' >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app"
notes_ok=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
  FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
  ST=$(tr '\n' ' ' < "$V/.ziyan_agent_session" 2>/dev/null)
  echo "notes_lock_wait t=$i FRONT=$FG $ST"
  echo "$FG" | grep -q com.ownbook.notes && notes_ok=1
  echo "$ST" | grep -q 'state=LEARNING' && echo "$FG" | grep -q com.ownbook.notes && break
  sleep 2
done
echo NOTES_FRONT=$notes_ok
echo '--- AFTER_LOCK ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cat "$V/.ziyan_agent_learn_active" 2>/dev/null; echo
echo INJECT_TRACE=
grep -E 'AppTouch|ownbook' "$V/.ziyan_inject_trace" 2>/dev/null | tail -8

# keep notes front, then existing HID tap; fallback prefer_app_touch once
if ! echo "$(tr -d '\r\n' < "$V/.ziyan_front_bid")" | grep -q com.ownbook.notes; then
  rm -f "$V/.ziyan_app_user_closed"
  printf 'com.ownbook.notes\n' >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app"
  sleep 3
fi
printf 'synthetic_test\n' >"$V/.ziyan_agent_learn_source"; chmod 666 "$V/.ziyan_agent_learn_source"
printf 'tap\n1\n120\n240\nlearn_synth_%s\n' "$$" >"$V/.ziyan_touch_req"
chmod 666 "$V/.ziyan_touch_req" 2>/dev/null || true
sleep 3
if [ ! -s "$V/.ziyan_agent_learn_bridge.jsonl" ]; then
  echo FALLBACK_PREFER_APP_TOUCH=1
  printf '1\n' >"$V/.ziyan_prefer_app_touch"; chmod 666 "$V/.ziyan_prefer_app_touch"
  printf 'tap\n1\n140\n260\nlearn_synth2_%s\n' "$$" >"$V/.ziyan_touch_req"
  chmod 666 "$V/.ziyan_touch_req" 2>/dev/null || true
  sleep 3
  rm -f "$V/.ziyan_prefer_app_touch"
fi
echo '--- BRIDGE ---'
echo FRONT=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
cat "$V/.ziyan_agent_learn_bridge.jsonl" 2>/dev/null; echo
cat "$V/.ziyan_ui_agent_session.json" 2>/dev/null; echo
sleep 2
cmd learn_vol
echo '--- AFTER_SYNTH_VOL ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cat "$V/.ziyan_agent_gen_progress" 2>/dev/null; echo
SID=$(sed -n 's/^session_id=//p' "$V/.ziyan_agent_session" 2>/dev/null | head -1)
echo SID=$SID
ls -lt /private/var/mobile/Media/ZiYan/Agent游戏/会话 2>/dev/null | head -8
if [ -n "$SID" ]; then
  echo '--- OBS ---'
  cat "/private/var/mobile/Media/ZiYan/Agent游戏/会话/$SID/观察.jsonl" 2>/dev/null | tail -5
  echo '--- PLAN ---'
  cat "/private/var/mobile/Media/ZiYan/Agent游戏/会话/$SID/计划候选.json" 2>/dev/null
  echo '--- VERDICT ---'
  cat "/private/var/mobile/Media/ZiYan/Agent游戏/会话/$SID/审核结论.json" 2>/dev/null
  echo '--- REPORT ---'
  cat "/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/${SID}_学习报告.txt" 2>/dev/null
fi
ls -lt /private/var/mobile/Media/ZiYan/*学习草稿* 2>/dev/null | head -8
echo '--- QUARANTINE ---'
ls -lt /private/var/mobile/Media/ZiYan/SimNote_自研草稿* 2>/dev/null | head -8

# Paused-safe path: start → lock notes → wait past lock grace → leave target
cmd learn_start
sleep 2
rm -f "$V/.ziyan_app_user_closed"
printf 'com.ownbook.notes\n' >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app"
for i in 1 2 3 4 5 6 7 8; do
  echo "$i $(tr '\n' ' ' < "$V/.ziyan_agent_session" 2>/dev/null)"
  grep -q 'state=LEARNING' "$V/.ziyan_agent_session" 2>/dev/null && break
  sleep 2
done
echo '--- LEARNING_BEFORE_PAUSE ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
sleep 3
printf 'com.apple.springboard\n' >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app"
printf '1\n' >"$V/.ziyan_go_home"; chmod 666 "$V/.ziyan_go_home"
for i in 1 2 3 4 5 6 7 8; do
  echo "pause_wait $i $(tr '\n' ' ' < "$V/.ziyan_agent_session" 2>/dev/null)"
  grep -q 'state=PAUSED_SAFE' "$V/.ziyan_agent_session" 2>/dev/null && break
  sleep 2
done
echo '--- PAUSED ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cmd learn_vol
echo '--- PAUSED_VOL ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cat "$V/.ziyan_agent_gen_progress" 2>/dev/null; echo
SID2=$(sed -n 's/^session_id=//p' "$V/.ziyan_agent_session" 2>/dev/null | head -1)
echo SID2=$SID2
if [ -n "$SID2" ]; then
  cat "/private/var/mobile/Media/ZiYan/Agent游戏/会话/$SID2/审核结论.json" 2>/dev/null
  cat "/private/var/mobile/Media/ZiYan/Agent游戏/运行记录/${SID2}_学习报告.txt" 2>/dev/null
fi
cmd script_list_probe
echo '--- SCRIPT_LIST ---'
cat "$V/.ziyan_ui_script_list.json" 2>/dev/null; echo
NOWSEL=$(sed -n '/<key>selectedPath<\/key>/{n;s/.*<string>//;s/<\/string>.*//;p;}' "$V/.ziyan_state.plist" 2>/dev/null | head -1)
echo NOW_SEL=$NOWSEL
echo SEL_PRESERVED=$([ "$SAVE" = "$NOWSEL" ] && echo 1 || echo 0)
echo USER_LUA_INTACT=$([ -f /private/var/mobile/Media/ZiYan/ios8p.lua -o -f /private/var/mobile/Media/ZiYan/lua/ios7.lua ] && echo 1 || echo 0)
echo '--- FINAL_SESSION ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
FC=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' ')
echo FC_N=$FC
EOS
  cp -f "$D/session_convergence.txt" "$D/synthetic_target_front.txt"
  cp -f "$D/session_convergence.txt" "$D/input_bridge_event.txt"
  cp -f "$D/session_convergence.txt" "$D/observation_packet.txt"
  cp -f "$D/session_convergence.txt" "$D/plan_candidate.txt"
  cp -f "$D/session_convergence.txt" "$D/verdict_packet.txt"
  cp -f "$D/session_convergence.txt" "$D/learn_success_generation.txt"
  cp -f "$D/session_convergence.txt" "$D/learn_insufficient_generation.txt"
  cp -f "$D/session_convergence.txt" "$D/paused_safe_volume_generate.txt"
  cp -f "$D/session_convergence.txt" "$D/script_list_and_selected_path.txt"
}

stable_one() {
  local tag="$1" scheme="$2" ip="$3" V D
  V=$(var_dir "$scheme"); D="$OUT/$tag"
  ssh_r "$ip" "V=$V bash -s" >"$D/pid_fc_stability.txt" 2>&1 <<'EOS' || true
set +e
pid_of() { LINE=$(ps -axo pid=,args= | grep "$1" | grep -v grep | head -1); set -- $LINE; echo "$1"; }
SB0=$(pid_of '[S]pringBoard.app/SpringBoard')
BB0=$(pid_of '[b]ackboardd')
echo PRE_SB=$SB0 PRE_BB=$BB0
echo SHORT_FROM_STARTUP
grep -E '^(PRE_|POST_|SB_STABLE|BB_STABLE|FC_N=)' /dev/null
SB1=$(pid_of '[S]pringBoard.app/SpringBoard')
BB1=$(pid_of '[b]ackboardd')
echo POST_SB=$SB1 POST_BB=$BB1
echo SB_STABLE=$([ -n "$SB0" ] && [ "$SB0" = "$SB1" ] && echo 1 || echo 0)
echo BB_STABLE=$([ -n "$BB0" ] && [ "$BB0" = "$BB1" ] && echo 1 || echo 0)
FC=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' ')
echo FC_N=$FC
echo NOTE=10min_only_if_p1p2_pass
EOS
}

restore_one() {
  local tag="$1" scheme="$2" ip="$3" V want
  V=$(var_dir "$scheme")
  want=$(sed -n 's/^SAVE_SEL=//p' "$OUT/$tag/pre_state.txt" 2>/dev/null | head -1)
  case "$want" in
    *_cursor_run_smoke.lua|*_zy_page_entry_selftest.lua|*ziyan_agent_run.lua) want="" ;;
  esac
  ssh_r "$ip" "V=$V WANT='$want' bash -s" >>"$OUT/$tag/script_list_and_selected_path.txt" 2>&1 <<'EOS' || true
set +e
if [ -n "$WANT" ] && [ -f "$WANT" ]; then
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>selectedPath</key>' \
    "<string>$WANT</string></dict></plist>" >"$V/.ziyan_state.plist"
  echo RESTORED_SEL=$WANT
else
  echo RESTORED_KEEP
fi
chmod 666 "$V/.ziyan_state.plist" 2>/dev/null || true
printf 'stop=1\nstate=idle\nreason=agent_p1p2_gate_done\n' >"$V/.ziyan_run_intent"
echo CLEANED
EOS
}

echo "== install =="
install_one 53 rootless 192.168.31.53 "$DEB_RL" &
install_one 101 rootful 192.168.31.101 "$DEB_RF" &
install_one 112 rootful 192.168.31.112 "$DEB_RF" &
install_one 166 rootful 192.168.31.166 "$DEB_RF" &
wait
echo "== startup =="
observe_one 53 rootless 192.168.31.53 &
observe_one 101 rootful 192.168.31.101 &
observe_one 112 rootful 192.168.31.112 &
observe_one 166 rootful 192.168.31.166 &
wait
echo "== p1 p2 =="
ui_one 53 rootless 192.168.31.53 &
ui_one 101 rootful 192.168.31.101 &
ui_one 112 rootful 192.168.31.112 &
ui_one 166 rootful 192.168.31.166 &
wait
echo "== short pid/fc =="
stable_one 53 rootless 192.168.31.53 &
stable_one 101 rootful 192.168.31.101 &
stable_one 112 rootful 192.168.31.112 &
stable_one 166 rootful 192.168.31.166 &
wait
echo "== restore =="
restore_one 53 rootless 192.168.31.53 &
restore_one 101 rootful 192.168.31.101 &
restore_one 112 rootful 192.168.31.112 &
restore_one 166 rootful 192.168.31.166 &
wait
echo OUT="$OUT"
echo ALL_PHONES_DONE
