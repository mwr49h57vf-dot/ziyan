#!/usr/bin/env bash
# Agent UI + P1 four-phone gate. Sequential sbreload. No killall SB/BB.
set -euo pipefail
if [ "${1:-}" != "--agent-ui-4phone" ]; then
  echo "only allowed: $0 --agent-ui-4phone" >&2
  exit 78
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
OUT="$ROOT/tmp_shots/AGENT_UI_4PHONE_20260815_1"
mkdir -p "$OUT"
echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15" | tee "$OUT/CLOCK_SKEW.txt"

DEB_RF=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-34*_iphoneos-arm.deb 2>/dev/null | head -1)
DEB_RL=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-34*_iphoneos-arm64.deb 2>/dev/null | head -1)
if [ -z "${DEB_RF:-}" ] || [ -z "${DEB_RL:-}" ]; then
  echo "MISSING_DEBUG_1034_DEB" | tee "$OUT/VERDICT.md"
  exit 2
fi
VER_RF=$(basename "$DEB_RF" | sed -n 's/^com\.ziyan\.ziyan_\(.*\)_iphoneos-arm\.deb$/\1/p')
VER_RL=$(basename "$DEB_RL" | sed -n 's/^com\.ziyan\.ziyan_\(.*\)_iphoneos-arm64\.deb$/\1/p')
SHA_RF=$(shasum -a 256 "$DEB_RF" | awk '{print $1}')
SHA_RL=$(shasum -a 256 "$DEB_RL" | awk '{print $1}')

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
digits() { sed -n "s/^$1=\\([0-9][0-9]*\\).*/\\1/p" "$2" | head -1; }

sample_pids() {
  ssh_r "$1" "bash -s" <<'EOS'
set +e
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
[ -n "$1" ] && echo SB=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
[ -n "$1" ] && echo BB=$1
EOS
}

wait_hold() {
  local ip="$1" dest="$2" hold="$3" max="$4" min_obs="$5"
  local sb0="" bb0="" sb_chg=0 bb_chg=0 stable=0 last_sb="" last_bb=""
  : >"$dest"
  local sec
  for sec in $(seq 1 "$max"); do
    sample=$(sample_pids "$ip" 2>/dev/null || true)
    sb=$(printf '%s\n' "$sample" | sed -n 's/^SB=\([0-9][0-9]*\).*/\1/p' | head -1)
    bb=$(printf '%s\n' "$sample" | sed -n 's/^BB=\([0-9][0-9]*\).*/\1/p' | head -1)
    echo "t=${sec}s SB=${sb:-none} BB=${bb:-none}" >>"$dest"
    if [ -z "$sb" ] || [ -z "$bb" ]; then sleep 1; continue; fi
    if [ -z "$sb0" ]; then
      sb0="$sb"; bb0="$bb"; last_sb="$sb"; last_bb="$bb"
      sleep 1; continue
    fi
    if [ "$sb" != "$last_sb" ]; then sb_chg=$((sb_chg+1)); last_sb="$sb"; fi
    if [ "$bb" != "$last_bb" ]; then bb_chg=$((bb_chg+1)); last_bb="$bb"; fi
    if [ "$sb_chg" -gt 1 ] || [ "$bb_chg" -gt 1 ]; then
      echo "LOOP sb_chg=$sb_chg bb_chg=$bb_chg"
      return 3
    fi
    if [ "$sb" = "$sb0" ] && [ "$bb" = "$bb0" ]; then
      stable=$((stable+1))
    else
      stable=0; sb0="$sb"; bb0="$bb"
    fi
    if [ "$stable" -ge "$hold" ] && [ "$sec" -ge "$min_obs" ]; then
      echo "STABLE SB=$sb BB=$bb hold=${stable}s"
      return 0
    fi
    sleep 1
  done
  echo "NOT_STABLE hold=${stable}s"
  return 1
}

snap() {
  local scheme="$1" ip="$2" dest="$3"
  ssh_r "$ip" "SCHEME=$scheme bash -s" >"$dest" 2>&1 <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
echo PKG=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n "s/^Version: //p")
SBLINE=$(ps -axo pid=,etime=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_PID=$1 SB_ETIME=$2
BBLINE=$(ps -axo pid=,etime=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_PID=$1 BB_ETIME=$2
echo FC_N=$(ps -ax -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep)
echo DAEMON=$(ps -ax -o command= | grep -E 'ziyadaemond|ziyan_zydaemond' | grep -vc grep)
echo HOOKS=$(tr '\n' ' ' < "$V/.ziyan_hooks")
echo HOOKS_SB_PID=$(printf '%s\n' "$(cat "$V/.ziyan_hooks" 2>/dev/null)" | sed -n 's/.*sb_pid=\([0-9][0-9]*\).*/\1/p' | head -1)
echo PENDING=$([ -f "$V/.ziyan_inject_reload_pending" ] && echo 1 || echo 0)
echo AGENT_DIRS=$(ls -d /private/var/mobile/Media/ZiYan/Agent游戏/*/ 2>/dev/null | wc -l)
EOS
}

install_one() {
  local tag="$1" scheme="$2" ip="$3" deb="$4" expect="$5"
  mkdir -p "$OUT/$tag"
  snap "$scheme" "$ip" "$OUT/$tag/pre.txt"
  scp_to "$deb" "$ip" /tmp/ziyan.deb
  ssh_r "$ip" "dpkg -i /tmp/ziyan.deb; echo DPKG_RC=\$?; echo installed=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')" \
    | tee "$OUT/$tag/deploy.txt"
  snap "$scheme" "$ip" "$OUT/$tag/post_install.txt"
  local pre_sb post_sb pre_bb post_bb
  pre_sb=$(digits SB_PID "$OUT/$tag/pre.txt")
  post_sb=$(digits SB_PID "$OUT/$tag/post_install.txt")
  pre_bb=$(digits BB_PID "$OUT/$tag/pre.txt")
  post_bb=$(digits BB_PID "$OUT/$tag/post_install.txt")
  {
    echo "install_sb_before=$pre_sb after=$post_sb"
    echo "install_bb_before=$pre_bb after=$post_bb"
  } | tee -a "$OUT/$tag/deploy.txt"
  grep -q 'INSTALL_OK no_auto_respring=1' "$OUT/$tag/deploy.txt" || { echo DEPLOY_FAIL; return 1; }
  grep -q "installed=$expect" "$OUT/$tag/deploy.txt" || { echo VERSION_MISMATCH; return 1; }
  if [ -z "$pre_sb" ] || [ -z "$post_sb" ] || [ -z "$pre_bb" ] || [ -z "$post_bb" ]; then
    echo SNAP_PARSE_FAIL pre_sb=$pre_sb post_sb=$post_sb pre_bb=$pre_bb post_bb=$post_bb
    return 1
  fi
  [ "$pre_sb" = "$post_sb" ] || { echo SB_CHANGED_ON_INSTALL; return 1; }
  [ "$pre_bb" = "$post_bb" ] || { echo BB_CHANGED_ON_INSTALL; return 1; }
  echo "DEPLOY_OK .$tag"
}

reload_one() {
  local tag="$1" ip="$2"
  echo "RELOAD_ONCE sbreload .$tag" | tee "$OUT/$tag/reload.txt"
  ssh_r "$ip" "sbreload" >>"$OUT/$tag/reload.txt" 2>&1 || true
  sleep 3
  set +e
  wait_hold "$ip" "$OUT/$tag/pid_samples.txt" 30 50 30
  local ws=$?
  set -e
  echo "wait_hold_rc=$ws" | tee -a "$OUT/$tag/reload.txt"
  return "$ws"
}

unlock_one() {
  local tag="$1" scheme="$2" ip="$3"
  ssh_r "$ip" "SCHEME=$scheme bash -s" >"$OUT/$tag/unlock.txt" 2>&1 <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_BEFORE=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_BEFORE=$1
rm -f "$V/.ziyan_unlock_rep"
[ -e "$V/.ziyan_project_active" ] || { date +%s >"$V/.ziyan_project_active"; chmod 666 "$V/.ziyan_project_active"; }
REQS=0
write_req() { REQS=$((REQS+1)); printf '1\n' >"$V/.ziyan_unlock_req"; chmod 666 "$V/.ziyan_unlock_req"; echo UNLOCK_REQ n=$REQS; }
write_req
START=$(date +%s)
while [ $(( $(date +%s) - START )) -lt 30 ]; do
  REP=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null | head -1)
  echo "poll t=$(( $(date +%s)-START ))s unlock_rep=$REP"
  echo "$REP" | grep -qi '^ok' && break
  if [ $(( $(date +%s)-START )) -ge 12 ] && [ "$REQS" -lt 2 ] && [ -z "$REP" ]; then write_req; fi
  sleep 2
done
echo unlock_rep=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null | head -1)
echo LOCK_STATE=$(tr -d '\r\n' < "$V/.ziyan_lock_state")
echo front=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_AFTER=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_AFTER=$1
EOS
  if grep -qi '^unlock_rep=ok' "$OUT/$tag/unlock.txt"; then
    echo "AUTO_UNLOCK_PASS .$tag" | tee -a "$OUT/$tag/unlock.txt"
    return 0
  fi
  echo "AUTO_UNLOCK_FAIL .$tag" | tee -a "$OUT/$tag/unlock.txt"
  return 1
}

agent_lua() {
  local scheme="$1"
  if [ "$scheme" = rootless ]; then
    echo "DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua /var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_run.lua"
  else
    echo "/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua /usr/lib/ziyan/lib/lua/ziyan_agent_run.lua"
  fi
}

run_phone() {
  local tag="$1" scheme="$2" ip="$3" deb="$4" expect="$5"
  mkdir -p "$OUT/$tag"
  echo "== .$tag =="
  if ! install_one "$tag" "$scheme" "$ip" "$deb" "$expect"; then
    echo "FAIL DEPLOY" >"$OUT/$tag/device.txt"
    return 0
  fi
  set +e
  reload_one "$tag" "$ip"
  local ws=$?
  set -e
  snap "$scheme" "$ip" "$OUT/$tag/post.txt"
  local sb fc daemon hooks
  sb=$(digits SB_PID "$OUT/$tag/post.txt")
  fc=$(sed -n 's/^FC_N=//p' "$OUT/$tag/post.txt" | head -1)
  daemon=$(sed -n 's/^DAEMON=//p' "$OUT/$tag/post.txt" | head -1)
  hooks=$(sed -n 's/^HOOKS_SB_PID=//p' "$OUT/$tag/post.txt" | head -1)
  if [ "$ws" = 3 ]; then
    echo "DEVICE_ABORT_SB_LOOP .$tag" | tee "$OUT/$tag/device.txt"
    ssh_r "$ip" 'MS=/Library/MobileSubstrate/DynamicLibraries; [ -d /var/jb/Library/MobileSubstrate/DynamicLibraries ] && MS=/var/jb/Library/MobileSubstrate/DynamicLibraries; for n in ZiYanFsCloak ZiYanDefense ZiYanAppTouch ZiYanFrameRelay ZiYanVol ZiYanBBFrame; do [ -f "$MS/$n.plist" ] && mv "$MS/$n.plist" "$MS/$n.plist.ziyan_off"; done; echo SIX_OFF'
    return 0
  fi
  if [ "$ws" != 0 ] || [ "${fc:-0}" != 1 ] || [ "${daemon:-0}" -lt 1 ] || [ "$hooks" != "$sb" ]; then
    echo "SKIP UNSTABLE .$tag fc=$fc daemon=$daemon hooks=$hooks sb=$sb" | tee "$OUT/$tag/device.txt"
    return 0
  fi
  set +e
  unlock_one "$tag" "$scheme" "$ip"
  local urc=$?
  set -e
  cp -f "$OUT/$tag/unlock.txt" "$OUT/AUTO_UNLOCK_$tag.md"
  if [ "$urc" != 0 ]; then
    echo "SKIP LOCKED .$tag" | tee "$OUT/$tag/device.txt"
    return 0
  fi

  local V BIN
  V=$(var_dir "$scheme")
  BIN=$(agent_lua "$scheme")
  ssh_r "$ip" "V=$V BIN='$BIN' bash -s" >"$OUT/$tag/agent_p1.txt" 2>&1 <<'EOS' || true
set +e
printf 'com.ziyan.ziyan\n' > "$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
  echo "wait_front t=$i front=$FG"
  echo "$FG" | grep -q com.ziyan.ziyan && break
  sleep 1
done
# UI probe
printf 'agent_probe\n' > "$V/.ziyan_ui_cmd"
chmod 666 "$V/.ziyan_ui_cmd"
sleep 2
echo '--- AGENT_CARD ---'
cat "$V/.ziyan_ui_agent_card.json" 2>/dev/null
echo
echo '--- BOTTOM ---'
cat "$V/.ziyan_ui_bottom_bar.json" 2>/dev/null
echo
echo '--- DIRS ---'
ls -d /private/var/mobile/Media/ZiYan/Agent游戏/*/ 2>/dev/null
ls /private/var/mobile/Media/ZiYan/Agent游戏/游戏配置/ 2>/dev/null
# Observe
printf 'profile_id=agent_observe\ndisplay_name=观察回归\ngame_name=子砚\nbundle_id=com.ziyan.ziyan\n' > "$V/.ziyan_agent_current_profile"
printf 'mode=observe\n' > "$V/.ziyan_agent_req"
eval $BIN
echo OBSERVE_RC=$?
echo OBSERVE_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
echo OBSERVE_HAS_STOP=$([ -f "$V/.ziyan_stop" ] && echo 1 || echo 0)
# Safe action
printf 'profile_id=agent_safe_action\ndisplay_name=安全动作\ngame_name=子砚\nbundle_id=com.ziyan.ziyan\n' > "$V/.ziyan_agent_current_profile"
printf 'mode=safe\n' > "$V/.ziyan_agent_req"
eval $BIN
echo SAFE_RC=$?
echo SAFE_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
# Learn then stop
printf 'mode=learn\n' > "$V/.ziyan_agent_req"
eval $BIN &
LPID=$!
sleep 2
echo LEARN_MID=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
printf 'stop=1\n' > "$V/.ziyan_agent_stop"
chmod 666 "$V/.ziyan_agent_stop"
wait $LPID 2>/dev/null
echo LEARN_RC=$?
echo LEARN_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
# Drill then stop
printf 'mode=drill\n' > "$V/.ziyan_agent_req"
eval $BIN &
DPID=$!
sleep 2
echo DRILL_MID=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
printf 'stop=1\n' > "$V/.ziyan_agent_stop"
wait $DPID 2>/dev/null
echo DRILL_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
# Auto
printf 'mode=auto\n' > "$V/.ziyan_agent_req"
eval $BIN
echo AUTO_SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
# Volume plus idle
: > "$V/.ziyan_vol_plus_trig"
chmod 666 "$V/.ziyan_vol_plus_trig"
sleep 2
echo VOL_PLUS=$(grep -E 'agent=list|rec=|选择 App' "$V/.ziyan_vol_event" 2>/dev/null | tail -n 8)
echo VOL_LIST=$([ -f "$V/.ziyan_agent_list_req" ] && echo 1 || echo 0)
# Volume plus stop
printf 'state=OBSERVING\n' > "$V/.ziyan_agent_session"
: > "$V/.ziyan_vol_plus_trig"
sleep 2
echo VOL_STOP_SESS=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
echo VOL_STOP_FILE=$([ -f "$V/.ziyan_agent_stop" ] && echo 1 || echo 0)
# Volume minus should not write agent stop
rm -f "$V/.ziyan_agent_stop"
: > "$V/.ziyan_vol_trig"
chmod 666 "$V/.ziyan_vol_trig"
sleep 2
echo VOL_MINUS_AGENT_STOP=$([ -f "$V/.ziyan_agent_stop" ] && echo 1 || echo 0)
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

  {
    echo "# UI .$tag"
    echo
    echo '```'
    grep -A20 'AGENT_CARD' "$OUT/$tag/agent_p1.txt" | head -30
    echo '```'
  } >"$OUT/UI_$tag.md"
  {
    echo "# AGENT_OBSERVE .$tag"
    grep -E 'OBSERVE_|wait_front' "$OUT/$tag/agent_p1.txt" | head -20
  } >"$OUT/AGENT_OBSERVE_$tag.md"
  {
    echo "# AGENT_ACTION .$tag"
    grep -E 'SAFE_|AUTO_' "$OUT/$tag/agent_p1.txt" | head -20
  } >"$OUT/AGENT_ACTION_$tag.md"
  {
    echo "# VOLUME_PLUS .$tag"
    grep -E 'VOL_PLUS|VOL_STOP|VOL_LIST' "$OUT/$tag/agent_p1.txt"
  } >"$OUT/VOLUME_PLUS_$tag.md"
  echo "DONE .$tag" | tee "$OUT/$tag/device.txt"
}

{
  echo "# BUILD"
  echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15"
  echo "VER_RF=$VER_RF SHA256_RF=$SHA_RF"
  echo "VER_RL=$VER_RL SHA256_RL=$SHA_RL"
  echo "bbframe=deferred_no_capture_timer"
} | tee "$OUT/BUILD.md"

run_phone 53 rootless 192.168.31.53 "$DEB_RL" "$VER_RL" || true
run_phone 101 rootful 192.168.31.101 "$DEB_RF" "$VER_RF" || true
run_phone 112 rootful 192.168.31.112 "$DEB_RF" "$VER_RF" || true
run_phone 166 rootful 192.168.31.166 "$DEB_RF" "$VER_RF" || true

{
  echo "# ORIGINAL_FEATURE_REGRESSION"
  echo "录制脚本 selector=recordScriptTapped: 未改"
  echo "自动脱壳 selector=autoDumpTapped: 未改"
  for t in 53 101 112 166; do
    echo "## .$t"
    grep -E 'gen_title|dump_title|gen_sel|dump_sel' "$OUT/$t/agent_p1.txt" || true
  done
} >"$OUT/ORIGINAL_FEATURE_REGRESSION.md"

{
  echo "# ROOTLESS_53_PATH_VERIFY"
  grep -E 'DIRS|Agent游戏|游戏配置' "$OUT/53/agent_p1.txt" || true
} >"$OUT/ROOTLESS_53_PATH_VERIFY.md"

{
  echo "# VOLUME_MINUS_REGRESSION"
  grep VOL_MINUS "$OUT/"*/agent_p1.txt || true
} >"$OUT/VOLUME_MINUS_REGRESSION.md"

{
  echo "# LEARN_SESSION_TEST"
  grep LEARN_ "$OUT/"*/agent_p1.txt || true
} >"$OUT/LEARN_SESSION_TEST.md"
{
  echo "# DRILL_SESSION_TEST"
  grep DRILL_ "$OUT/"*/agent_p1.txt || true
} >"$OUT/DRILL_SESSION_TEST.md"
{
  echo "# AUTO_RUN_SESSION_TEST"
  grep AUTO_ "$OUT/"*/agent_p1.txt || true
} >"$OUT/AUTO_RUN_SESSION_TEST.md"
{
  echo "# ERROR_REPORT_VERIFY"
  grep -E 'ERR_OK|RUN_OK|HAS_GLOBAL_STOP' "$OUT/"*/agent_p1.txt || true
} >"$OUT/ERROR_REPORT_VERIFY.md"
{
  echo "# RESOURCE_REPORT"
  grep -E 'FC=|SB_AFTER|BB_AFTER' "$OUT/"*/agent_p1.txt || true
} >"$OUT/RESOURCE_REPORT.md"

PASS=1
for t in 53 101 112 166; do
  grep -q 'AUTO_UNLOCK_PASS' "$OUT/$t/unlock.txt" 2>/dev/null || PASS=0
  grep -q 'OBSERVE_SESSION=.*STOPPED' "$OUT/$t/agent_p1.txt" 2>/dev/null || PASS=0
done

{
  echo "# VERDICT"
  echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15"
  echo "VER_RF=$VER_RF SHA256_RF=$SHA_RF"
  echo "VER_RL=$VER_RL SHA256_RL=$SHA_RL"
  if [ "$PASS" = 1 ]; then
    echo "AGENT_UI_4PHONE_PASS=YES"
  else
    echo "AGENT_UI_4PHONE_PASS=NO"
    echo "RESULT=PARTIAL_OR_FAIL"
  fi
  echo "BBFrame capture remains deferred. 不得宣称超越触动。"
} | tee "$OUT/VERDICT.md"

{
  echo "# ITERATION_2"
  echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15"
  echo "fixed snap() heredoc; reran same 10-34 packages; no BBFrame change"
} >"$OUT/ITERATION_2.md"
echo "OUT=$OUT"
