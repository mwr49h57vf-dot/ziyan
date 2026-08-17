#!/usr/bin/env bash
# Chapter 27 P1-P4 four-phone gate. No sbreload.
set -euo pipefail
if [ "${1:-}" != "--agent-learn-self-iter" ]; then
  echo "only allowed: $0 --agent-learn-self-iter" >&2
  exit 78
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$ROOT/tmp_shots/AGENT_LEARN_AND_SELF_ITERATION_${STAMP}"
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
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
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
  ssh_r "$ip" "V=$V bash -s" >"$D/learning_confirm_cancel.txt" 2>&1 <<'EOS' || true
set +e
cmd() { printf '%s\n' "$1" >"$V/.ziyan_ui_cmd"; chmod 666 "$V/.ziyan_ui_cmd" 2>/dev/null || true; sleep 3; }
SAVE=$(sed -n '/<key>selectedPath<\/key>/{n;s/.*<string>//;s/<\/string>.*//;p;}' "$V/.ziyan_state.plist" 2>/dev/null | head -1)
echo SAVE_SEL=$SAVE
cmd open_agent
cmd agent_probe
echo '--- AGENT_PAGE ---'
cat "$V/.ziyan_ui_agent_page.json" 2>/dev/null; echo
cmd learn_cancel
echo '--- LEARN_CANCEL ---'
cat "$V/.ziyan_ui_learn.json" 2>/dev/null; echo
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cmd learn_start
echo '--- LEARN_START ---'
cat "$V/.ziyan_ui_learn.json" 2>/dev/null; echo
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
echo GO_HOME=$([ -f "$V/.ziyan_go_home" ] && echo 1 || echo 0)
cmd $'learn_lock\tcom.ownbook.notes\tsimNote'
echo '--- LEARN_LOCK ---'
cat "$V/.ziyan_ui_agent_session.json" 2>/dev/null; echo
cmd $'learn_tap\t120\t240'
cmd $'learn_tap\t160\t280'
echo '--- AFTER_TAPS ---'
cat "$V/.ziyan_ui_agent_session.json" 2>/dev/null; echo
cmd learn_vol
echo '--- AFTER_VOL ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cat "$V/.ziyan_agent_gen_progress" 2>/dev/null; echo
echo '--- GEN_FILES ---'
ls -lt /private/var/mobile/Media/ZiYan/*学习草稿* 2>/dev/null | head -6
ls -lt /private/var/mobile/Media/ZiYan/Agent游戏/学习数据 2>/dev/null | head -6
ls -lt /private/var/mobile/Media/ZiYan/Agent游戏/运行记录 2>/dev/null | head -6
cmd script_list_probe
echo '--- SCRIPT_LIST ---'
cat "$V/.ziyan_ui_script_list.json" 2>/dev/null; echo
NOWSEL=$(sed -n '/<key>selectedPath<\/key>/{n;s/.*<string>//;s/<\/string>.*//;p;}' "$V/.ziyan_state.plist" 2>/dev/null | head -1)
echo NOW_SEL=$NOWSEL
echo SEL_PRESERVED=$([ "$SAVE" = "$NOWSEL" ] && echo 1 || echo 0)
cmd picker_cancel
echo '--- PICKER_CANCEL ---'
cat "$V/.ziyan_ui_app_picker.json" 2>/dev/null; echo
cmd picker_confirm_first
echo '--- PICKER_CONFIRM ---'
cat "$V/.ziyan_ui_app_picker.json" 2>/dev/null; echo
cmd ai_explore
echo '--- AI_EXPLORE ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cmd learn_vol
echo '--- AI_STOP ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cat "$V/.ziyan_agent_gen_progress" 2>/dev/null; echo
ls -lt /private/var/mobile/Media/ZiYan/*自研草稿* 2>/dev/null | head -6
cmd version_probe
echo '--- VERSION ---'
cat "$V/.ziyan_ui_version.json" 2>/dev/null; echo
cmd ai_iterate
echo '--- ITERATE ---'
cat "$V/.ziyan_agent_session" 2>/dev/null; echo
cmd learn_vol
echo '--- ITERATE_STOP ---'
cat "$V/.ziyan_ui_version.json" 2>/dev/null; echo
ls -lt /private/var/mobile/Media/ZiYan/*自研草稿* 2>/dev/null | head -8
echo USER_LUA_INTACT=$([ -f /private/var/mobile/Media/ZiYan/ios8p.lua -o -f /private/var/mobile/Media/ZiYan/lua/ios7.lua ] && echo 1 || echo 0)
EOS
  cp -f "$D/learning_confirm_cancel.txt" "$D/learning_lock_target.txt"
  cp -f "$D/learning_confirm_cancel.txt" "$D/learning_stop_cleanup.txt"
  cp -f "$D/learning_confirm_cancel.txt" "$D/generation_progress.txt"
  cp -f "$D/learning_confirm_cancel.txt" "$D/generated_script_probe.txt"
  cp -f "$D/learning_confirm_cancel.txt" "$D/ai_picker_confirm.txt"
  cp -f "$D/learning_confirm_cancel.txt" "$D/ai_stop_cleanup.txt"
  cp -f "$D/learning_confirm_cancel.txt" "$D/version_store_probe.txt"
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
# 10min / 30s = 20 samples
i=0
while [ "$i" -lt 20 ]; do
  i=$((i+1))
  SB=$(pid_of '[S]pringBoard.app/SpringBoard')
  BB=$(pid_of '[b]ackboardd')
  FC=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' ')
  echo "m=$i SB=$SB BB=$BB FC_N=$FC"
  sleep 30
done
SB1=$(pid_of '[S]pringBoard.app/SpringBoard')
BB1=$(pid_of '[b]ackboardd')
echo POST_SB=$SB1 POST_BB=$BB1
echo SB_STABLE=$([ -n "$SB0" ] && [ "$SB0" = "$SB1" ] && echo 1 || echo 0)
echo BB_STABLE=$([ -n "$BB0" ] && [ "$BB0" = "$BB1" ] && echo 1 || echo 0)
FC=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' ')
echo FC_N=$FC
EOS
}

restore_one() {
  local tag="$1" scheme="$2" ip="$3" V want
  V=$(var_dir "$scheme")
  want=$(sed -n 's/^SAVE_SEL=//p' "$OUT/$tag/pre_state.txt" 2>/dev/null | head -1)
  case "$want" in
    *_cursor_run_smoke.lua|*_zy_page_entry_selftest.lua|*ziyan_agent_run.lua) want="" ;;
  esac
  ssh_r "$ip" "V=$V WANT='$want' bash -s" >>"$OUT/$tag/generated_script_probe.txt" 2>&1 <<'EOS' || true
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
printf 'stop=1\nstate=idle\nreason=agent_learn_gate_done\n' >"$V/.ziyan_run_intent"
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
echo "== ui p1-p4 =="
ui_one 53 rootless 192.168.31.53 &
ui_one 101 rootful 192.168.31.101 &
ui_one 112 rootful 192.168.31.112 &
ui_one 166 rootful 192.168.31.166 &
wait
if [ "${ZY_SKIP_LONG_STABLE:-0}" = "1" ]; then
  echo "== skip 10min (ZY_SKIP_LONG_STABLE=1); copy short pid/fc =="
  for tag in 53 101 112 166; do
    if [ -f "$OUT/$tag/startup_30s.txt" ]; then
      {
        echo "SHORT_STABLE_FROM=startup_30s"
        grep -E '^(PRE_|POST_|SB_STABLE|BB_STABLE|FC_N=)' "$OUT/$tag/startup_30s.txt" || true
      } >"$OUT/$tag/pid_fc_stability.txt"
    fi
  done
else
  echo "== 10min stability =="
  stable_one 53 rootless 192.168.31.53 &
  stable_one 101 rootful 192.168.31.101 &
  stable_one 112 rootful 192.168.31.112 &
  stable_one 166 rootful 192.168.31.166 &
  wait
fi
echo "== restore =="
restore_one 53 rootless 192.168.31.53 &
restore_one 101 rootful 192.168.31.101 &
restore_one 112 rootful 192.168.31.112 &
restore_one 166 rootful 192.168.31.166 &
wait
echo OUT="$OUT"
echo ALL_PHONES_DONE
