#!/usr/bin/env bash
# R6: .53/.112 page-order regression + .101/.166 per-module inject bisection.
# Isolated: one phone fail never stops the others.
# Default (no flag): exit 78, no SSH, no respring.
set -euo pipefail

if [ "${1:-}" != "--agent-mvp-4phone" ]; then
  echo "BLOCKED_AGENT_MVP_REQUIRED" >&2
  echo "only allowed: $0 --agent-mvp-4phone" >&2
  exit 78
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
OUT="${ROOT}/tmp_shots/AGENT_MVP_4PHONE_20260815_1"
mkdir -p "$OUT" "$OUT/INJECT_TRACE_101" "$OUT/INJECT_TRACE_166" \
  "$OUT/AGENT_CORE_SB_RECOVERY_101" "$OUT/AGENT_CORE_SB_RECOVERY_166"
echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15" | tee "$OUT/CLOCK_SKEW.txt"

START_EPOCH=$(date +%s)
DEADLINE=$((START_EPOCH + 5400))
SAFE_LUA="$ROOT/layout/private/var/mobile/Media/ZiYan/_zy_page_entry_selftest.lua"
if [ ! -f "$SAFE_LUA" ]; then
  mkdir -p "$(dirname "$SAFE_LUA")"
  cat >"$SAFE_LUA" <<'LUA'
-- Safe page-entry selftest. Not a user business script.
function main()
  toast("page_entry_selftest", 1)
  mSleep(300)
end
LUA
fi
MODULES=(ZiYanFsCloak ZiYanDefense ZiYanAppTouch ZiYanFrameRelay ZiYanVol ZiYanBBFrame)

DEB_RF=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-31*_iphoneos-arm.deb 2>/dev/null | head -1)
DEB_RL=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-31*_iphoneos-arm64.deb 2>/dev/null | head -1)
if [ -z "${DEB_RF:-}" ] || [ -z "${DEB_RL:-}" ]; then
  echo "MISSING_DEBUG_1031_DEB" | tee "$OUT/VERDICT.md"
  exit 2
fi
VER_RF=$(basename "$DEB_RF" | sed -n 's/^com\.ziyan\.ziyan_\(.*\)_iphoneos-arm\.deb$/\1/p')
VER_RL=$(basename "$DEB_RL" | sed -n 's/^com\.ziyan\.ziyan_\(.*\)_iphoneos-arm64\.deb$/\1/p')
SHA_RF=$(shasum -a 256 "$DEB_RF" | awk '{print $1}')
SHA_RL=$(shasum -a 256 "$DEB_RL" | awk '{print $1}')

SSH_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=8 -o ServerAliveInterval=4 -o ServerAliveCountMax=2)
SSH_PASS_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
               -o ConnectTimeout=8 -o PreferredAuthentications=password
               -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
               -o ServerAliveInterval=4 -o ServerAliveCountMax=2)

past_deadline() { [ "$(date +%s)" -ge "$DEADLINE" ]; }

ssh_r() {
  local ip="$1"; shift
  if past_deadline; then echo "DEADLINE_SKIP $ip" >&2; return 124; fi
  if ssh "${SSH_OPTS[@]}" "root@$ip" "$@" 2>/dev/null; then return 0; fi
  sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
}

scp_to() {
  local src="$1" ip="$2" dst="$3"
  if past_deadline; then return 124; fi
  if scp -o BatchMode=yes -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 "$src" "root@$ip:$dst" 2>/dev/null; then
    return 0
  fi
  sshpass -p "$PASS" scp "${SSH_PASS_OPTS[@]}" "$src" "root@$ip:$dst"
}

digits() { sed -n "s/^$1=\\([0-9][0-9]*\\).*/\\1/p" "$2" | head -1; }

ms_dir() {
  if [ "$1" = rootless ]; then echo /var/jb/Library/MobileSubstrate/DynamicLibraries
  else echo /Library/MobileSubstrate/DynamicLibraries
  fi
}
var_dir() {
  if [ "$1" = rootless ]; then echo /var/jb/usr/lib/ziyan/var
  else echo /usr/lib/ziyan/var
  fi
}

sample_pids() {
  local ip="$1"
  ssh_r "$ip" "bash -s" <<'EOS'
set +e
SBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
[ -n "$1" ] && echo SB=$1
BBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
[ -n "$1" ] && echo BB=$1
EOS
}

snapshot_remote() {
  local scheme="$1"
  cat <<EOS
set +e
if [ "$scheme" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  MS=/var/jb/Library/MobileSubstrate/DynamicLibraries
else
  VAR=/usr/lib/ziyan/var
  MS=/Library/MobileSubstrate/DynamicLibraries
fi
echo PKG=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p' | head -1)
echo NOW_TS=\$(date +%s)
SBLINE=\$(ps -axo pid=,etime=,args= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- \$SBLINE
echo SB_PID=\$1 SB_ETIME=\$2
BBLINE=\$(ps -axo pid=,etime=,args= 2>/dev/null | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- \$BBLINE
echo BB_PID=\$1 BB_ETIME=\$2
echo -n 'FC_N='; ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' '
echo -n 'DAEMON='; ps -ax -o command= 2>/dev/null | grep -E 'ziyadaemond|ziyan_zydaemond' | grep -vc grep | tr -d ' '
echo FRONT=\$(tr -d '\r\n' < "\$VAR/.ziyan_front_bid" 2>/dev/null)
echo LOCK=\$(tr -d '\r\n' < "\$VAR/.ziyan_display_locked" 2>/dev/null)
echo PENDING=\$([ -f "\$VAR/.ziyan_inject_reload_pending" ] && echo 1 || echo 0)
HOOKS=\$(tr '\n' ' ' < "\$VAR/.ziyan_hooks" 2>/dev/null)
echo HOOKS=\$HOOKS
echo HOOKS_SB_PID=\$(printf '%s\n' "\$HOOKS" | sed -n 's/.*sb_pid=\\([0-9][0-9]*\\).*/\\1/p' | head -1)
for n in ZiYanAppTouch ZiYanBBFrame ZiYanDefense ZiYanFrameRelay ZiYanFsCloak ZiYanVol; do
  if [ -f "\$MS/\$n.plist" ]; then echo PLIST_\$n=on
  elif [ -f "\$MS/\$n.plist.ziyan_off" ]; then echo PLIST_\$n=off
  else echo PLIST_\$n=missing
  fi
done
echo TRACE_TAIL=\$(tail -n 8 "\$VAR/.ziyan_inject_trace" 2>/dev/null | tr '\n' '|')
EOS
}

write_snap() {
  local tag="$1" scheme="$2" ip="$3" dest="$4"
  ssh_r "$ip" "bash -s" < <(snapshot_remote "$scheme") >"$dest" 2>&1 || {
    echo "SSH_FAIL .$tag" | tee -a "$dest"
    return 1
  }
}

set_mod() {
  local scheme="$1" ip="$2" name="$3" on="$4"
  local MS TI
  MS=$(ms_dir "$scheme")
  TI=""
  [ "$scheme" = rootless ] && TI=/var/jb/usr/lib/TweakInject
  ssh_r "$ip" "MS='$MS' TI='$TI' N='$name' ON='$on' bash -s" <<'EOS'
set +e
if [ "$ON" = 1 ]; then
  [ -f "$MS/$N.plist.ziyan_off" ] && mv -f "$MS/$N.plist.ziyan_off" "$MS/$N.plist"
  if [ -n "$TI" ] && [ -f "$TI/$N.plist.ziyan_off" ]; then
    mv -f "$TI/$N.plist.ziyan_off" "$TI/$N.plist"
  fi
  echo SET_ON_$N
else
  [ -f "$MS/$N.plist" ] && mv -f "$MS/$N.plist" "$MS/$N.plist.ziyan_off"
  if [ -n "$TI" ] && [ -f "$TI/$N.plist" ]; then
    mv -f "$TI/$N.plist" "$TI/$N.plist.ziyan_off"
  fi
  echo SET_OFF_$N
fi
EOS
}

disable_all_six() {
  local scheme="$1" ip="$2"
  local n
  for n in "${MODULES[@]}"; do
    set_mod "$scheme" "$ip" "$n" 0 >/dev/null || true
  done
}

apply_kept_plus() {
  local scheme="$1" ip="$2" current="$3"
  shift 3
  local kept=("$@") n
  for n in "${MODULES[@]}"; do
    local want=0
    [ "$n" = "$current" ] && want=1
    local k
    for k in "${kept[@]+"${kept[@]}"}"; do
      [ "$k" = "$n" ] && want=1
    done
    set_mod "$scheme" "$ip" "$n" "$want" >/dev/null || true
  done
}

install_deb() {
  local tag="$1" scheme="$2" ip="$3" deb="$4" expect="$5"
  local dest="$OUT/$tag"
  mkdir -p "$dest"
  write_snap "$tag" "$scheme" "$ip" "$dest/pre.txt" || true
  local pre_sb pre_bb
  pre_sb=$(digits SB_PID "$dest/pre.txt")
  pre_bb=$(digits BB_PID "$dest/pre.txt")
  echo "pre_sb=$pre_sb pre_bb=$pre_bb" | tee "$dest/deploy.txt"
  scp_to "$deb" "$ip" /tmp/ziyan.deb
  ssh_r "$ip" "dpkg -i /tmp/ziyan.deb; echo DPKG_RC=\$?; echo installed=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p' | head -1)" \
    | tee -a "$dest/deploy.txt"
  write_snap "$tag" "$scheme" "$ip" "$dest/post_install.txt" || true
  local post_sb post_bb inst pending
  post_sb=$(digits SB_PID "$dest/post_install.txt")
  post_bb=$(digits BB_PID "$dest/post_install.txt")
  inst=$(sed -n 's/^installed=//p' "$dest/deploy.txt" | tail -1)
  pending=$(sed -n 's/^PENDING=//p' "$dest/post_install.txt" | head -1)
  {
    echo "install_sb_before=$pre_sb after=$post_sb"
    echo "install_bb_before=$pre_bb after=$post_bb"
    echo "pending=$pending"
    echo "expect=$expect got=$inst"
  } | tee -a "$dest/deploy.txt"
  local ok=1
  grep -q 'INSTALL_OK no_auto_respring=1' "$dest/deploy.txt" || {
    echo MISSING_NO_AUTO_RESPRING | tee -a "$dest/deploy.txt"
    ok=0
  }
  [ "$inst" = "$expect" ] || { echo VERSION_MISMATCH | tee -a "$dest/deploy.txt"; ok=0; }
  [ "$pre_sb" = "$post_sb" ] && [ -n "$pre_sb" ] || { echo SB_CHANGED_ON_INSTALL | tee -a "$dest/deploy.txt"; ok=0; }
  [ "$pre_bb" = "$post_bb" ] && [ -n "$pre_bb" ] || { echo BB_CHANGED_ON_INSTALL | tee -a "$dest/deploy.txt"; ok=0; }
  [ "$pending" = 1 ] || { echo MISSING_PENDING | tee -a "$dest/deploy.txt"; ok=0; }
  if [ "$ok" = 1 ]; then
    echo "DEPLOY_OK .$tag" | tee -a "$dest/deploy.txt"
    return 0
  fi
  echo "DEPLOY_FAIL .$tag" | tee -a "$dest/deploy.txt"
  return 1
}

sbreload_once() {
  local tag="$1" ip="$2" note="$3"
  echo "RELOAD_ONCE sbreload .$tag $note" | tee -a "$OUT/$tag/reload.txt"
  ssh_r "$ip" "sbreload" >>"$OUT/$tag/reload.txt" 2>&1 || true
  echo "SBRELOAD_RC=$?" | tee -a "$OUT/$tag/reload.txt"
  sleep 3
}

wait_hold() {
  local tag="$1" ip="$2" dest="$3" hold="$4" max="$5"
  local min_obs="${6:-0}"
  local sb0="" bb0="" sb_chg=0 bb_chg=0 stable=0 last_sb="" last_bb=""
  : >"$dest"
  local sec
  for sec in $(seq 1 "$max"); do
    past_deadline && break
    sample=$(sample_pids "$ip" 2>/dev/null || true)
    sb=$(printf '%s\n' "$sample" | sed -n 's/^SB=\([0-9][0-9]*\).*/\1/p' | head -1)
    bb=$(printf '%s\n' "$sample" | sed -n 's/^BB=\([0-9][0-9]*\).*/\1/p' | head -1)
    echo "t=${sec}s SB=${sb:-none} BB=${bb:-none}" >>"$dest"
    if [ -z "$sb" ] || [ -z "$bb" ]; then
      sleep 1
      continue
    fi
    if [ -z "$sb0" ]; then
      sb0="$sb"; bb0="$bb"; last_sb="$sb"; last_bb="$bb"
      sleep 1
      continue
    fi
    if [ "$sb" != "$last_sb" ]; then sb_chg=$((sb_chg + 1)); last_sb="$sb"; fi
    if [ "$bb" != "$last_bb" ]; then bb_chg=$((bb_chg + 1)); last_bb="$bb"; fi
    if [ "$sb_chg" -gt 1 ] || [ "$bb_chg" -gt 1 ]; then
      echo "LOOP sb_chg=$sb_chg bb_chg=$bb_chg last_sb=$last_sb last_bb=$last_bb"
      return 3
    fi
    if [ "$sb" = "$sb0" ] && [ "$bb" = "$bb0" ]; then
      stable=$((stable + 1))
    else
      stable=0
      sb0="$sb"; bb0="$bb"
    fi
    if [ "$stable" -ge "$hold" ] && [ "$sec" -ge "$min_obs" ]; then
      echo "STABLE SB=$sb BB=$bb hold=${stable}s observed=${sec}s min_obs=$min_obs sb_chg=$sb_chg bb_chg=$bb_chg"
      return 0
    fi
    sleep 1
  done
  echo "NOT_STABLE hold=${stable}s observed=${sec:-0}s min_obs=$min_obs sb_chg=$sb_chg bb_chg=$bb_chg"
  return 1
}

do_unlock() {
  local tag="$1" scheme="$2" ip="$3" dest="$4"
  ssh_r "$ip" "SCHEME=$scheme bash -s" >"$dest" 2>&1 || true
}

# unlock body via stdin from caller? Keep inline like R5.
unlock_phone() {
  local tag="$1" scheme="$2" ip="$3"
  local dest="$OUT/$tag/unlock.txt"
  local before_sb before_bb after_sb after_bb
  write_snap "$tag" "$scheme" "$ip" "$OUT/$tag/unlock_pre.txt" || true
  before_sb=$(digits SB_PID "$OUT/$tag/unlock_pre.txt")
  before_bb=$(digits BB_PID "$OUT/$tag/unlock_pre.txt")
  ssh_r "$ip" "SCHEME=$scheme bash -s" >"$dest" 2>&1 <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
SBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_BEFORE=$1
BBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_BEFORE=$1
HOOKS=$(tr '\n' ' ' < "$V/.ziyan_hooks" 2>/dev/null)
echo HOOKS_SB_PID=$(printf '%s\n' "$HOOKS" | sed -n 's/.*sb_pid=\([0-9][0-9]*\).*/\1/p' | head -1)
echo FRONT_BEFORE=$(tr -d '\r\n' < "$V/.ziyan_front_bid" 2>/dev/null)
rm -f "$V/.ziyan_unlock_rep"
if [ ! -e "$V/.ziyan_project_active" ] && [ ! -e "$V/.ziyan_script_session" ]; then
  date +%s >"$V/.ziyan_project_active"
  chmod 666 "$V/.ziyan_project_active" 2>/dev/null
  echo MARKER_CREATED=1
fi
REQS=0
write_req() {
  REQS=$((REQS + 1))
  printf '1\n' >"$V/.ziyan_unlock_req"
  chmod 666 "$V/.ziyan_unlock_req"
  echo UNLOCK_REQ_WRITTEN n=$REQS
}
write_req
START=$(date +%s)
REP=""
while [ $(( $(date +%s) - START )) -lt 30 ]; do
  REP=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null | head -1)
  echo "poll t=$(( $(date +%s) - START ))s unlock_rep=$REP"
  echo "$REP" | grep -qi '^ok' && break
  if [ $(( $(date +%s) - START )) -ge 12 ] && [ "$REQS" -lt 2 ] && [ -z "$REP" ]; then
    write_req
  fi
  sleep 2
done
echo unlock_req_count=$REQS
echo unlock_rep=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null | head -1)
echo display_locked=$(tr -d '\r\n' < "$V/.ziyan_display_locked" 2>/dev/null)
echo front=$(tr -d '\r\n' < "$V/.ziyan_front_bid" 2>/dev/null)
echo LOCK_STATE=$(tr -d '\r\n' < "$V/.ziyan_lock_state" 2>/dev/null)
SBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_AFTER=$1
BBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_AFTER=$1
echo elapsed_s=$(( $(date +%s) - START ))
EOS
  after_sb=$(sed -n 's/^SB_AFTER=//p' "$dest" | head -1)
  after_bb=$(sed -n 's/^BB_AFTER=//p' "$dest" | head -1)
  local rep lock front reqs
  rep=$(sed -n 's/^unlock_rep=//p' "$dest" | tail -1)
  lock=$(sed -n 's/^LOCK_STATE=//p' "$dest" | tail -1)
  front=$(sed -n 's/^front=//p' "$dest" | tail -1)
  reqs=$(sed -n 's/^unlock_req_count=//p' "$dest" | tail -1)
  local pid_ok=1
  [ -n "$before_sb" ] && [ -n "$after_sb" ] && [ "$before_sb" = "$after_sb" ] || pid_ok=0
  [ -n "$before_bb" ] && [ -n "$after_bb" ] && [ "$before_bb" = "$after_bb" ] || pid_ok=0
  {
    echo "SB_PID_before=$before_sb after=$after_sb"
    echo "BB_PID_before=$before_bb after=$after_bb"
    echo "unlock_req_count=${reqs:-0}"
    echo "unlock_rep=$rep"
    echo "lock_state=$lock"
    echo "front_after=$front"
  } >>"$dest"
  if echo "$rep" | grep -qi '^ok' && { [ "$lock" = 0 ] || [ -z "$lock" ] || echo "$lock" | grep -qiE 'unlock|0'; } \
      && [ "$pid_ok" = 1 ]; then
    echo "AUTO_UNLOCK_PASS .$tag" | tee -a "$dest"
    return 0
  fi
  echo "AUTO_UNLOCK_FAIL .$tag" | tee -a "$dest"
  return 1
}

page_run_one() {
  local tag="$1" scheme="$2" ip="$3"
  local VAR NONCE
  VAR=$(var_dir "$scheme")
  NONCE="pst_${tag}_$(date +%s)_$RANDOM"
  echo "NONCE=$NONCE" | tee "$OUT/$tag/nonce.txt"
  scp_to "$SAFE_LUA" "$ip" /private/var/mobile/Media/ZiYan/_zy_page_entry_selftest.lua || true
  ssh_r "$ip" "VAR=$VAR NONCE=$NONCE bash -s" >"$OUT/$tag/page_run.txt" 2>&1 <<'EOS' || true
set +e
SAFE=/private/var/mobile/Media/ZiYan/_zy_page_entry_selftest.lua
mkdir -p /private/var/mobile/Media/ZiYan/ZYCV/config
printf '%s\n' "$SAFE" > /private/var/mobile/Media/ZiYan/ZYCV/config/select.lua
cat > "$VAR/.ziyan_state.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>selectedPath</key>
<string>/private/var/mobile/Media/ZiYan/_zy_page_entry_selftest.lua</string>
<key>runState</key><integer>0</integer>
<key>runPid</key><integer>0</integer>
</dict></plist>
PLIST
cp -f "$VAR/.ziyan_state.plist" /private/var/mobile/Media/ZiYan/.ziyan_state.plist
chmod 666 "$VAR/.ziyan_state.plist" /private/var/mobile/Media/ZiYan/.ziyan_state.plist 2>/dev/null
: > "$VAR/.ziyan_minimize_log"
: > "$VAR/.ziyan_page_selftest_log"
rm -f "$VAR/.ziyan_app_run_trig" "$VAR/.ziyan_menu_run_trig" \
      "$VAR/.ziyan_page_selftest_req" "$VAR/.ziyan_page_selftest_rep" \
      /private/var/mobile/Media/ZiYan/.ziyan_page_selftest_req
printf 'com.ziyan.ziyan\n' > "$VAR/.ziyan_open_app"
chmod 666 "$VAR/.ziyan_open_app"
echo OPEN_WRITTEN
FRONT_OK=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  FG=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "wait_open t=$i front=$FG"
  if echo "$FG" | grep -q 'com.ziyan.ziyan'; then FRONT_OK=1; break; fi
  sleep 1
done
echo FRONT_OK=$FRONT_OK
if [ "$FRONT_OK" != 1 ]; then
  echo PAGE_FAIL_NOT_FOREGROUND
  echo stop=1 >"$VAR/.ziyan_stop"
  exit 0
fi
printf 'nonce=%s\n' "$NONCE" > "$VAR/.ziyan_page_selftest_req"
chmod 666 "$VAR/.ziyan_page_selftest_req"
cp -f "$VAR/.ziyan_page_selftest_req" /private/var/mobile/Media/ZiYan/.ziyan_page_selftest_req
echo REQ_WRITTEN nonce=$NONCE
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if grep -qE 'run_ok _zy_page_entry_selftest' "$VAR/.ziyan_minimize_log" 2>/dev/null; then
    echo GOT_RUN_OK t=$i
    break
  fi
  sleep 1
done
echo '--- SELFTEST_LOG ---'
cat "$VAR/.ziyan_page_selftest_log" 2>/dev/null
echo
echo '--- MINIMIZE_LOG ---'
cat "$VAR/.ziyan_minimize_log" 2>/dev/null | tail -c 2500
echo
echo '--- ENSURE ---'
cat "$VAR/.ziyan_ensure_framecap_log" 2>/dev/null | tail -c 800
echo
echo '--- VOL ---'
grep -E 'page_entry|volume' "$VAR/.ziyan_vol_event" "$VAR/.ziyan_minimize_log" 2>/dev/null | tail -n 20
echo
echo FRONT_AFTER=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
echo SELECTED=$(tr -d '\r\n' < /private/var/mobile/Media/ZiYan/ZYCV/config/select.lua 2>/dev/null)
echo RUN_PID=$(tr -d '\r\n' < "$VAR/.ziyan_lua_run.pid" 2>/dev/null)
echo SESSION=$(tr '\n' ' ' < "$VAR/.ziyan_session" 2>/dev/null | head -c 160)
echo HAS_RUN_TRIG=$([ -f "$VAR/.ziyan_app_run_trig" ] && echo 1 || echo 0)
echo HAS_MENU_TRIG=$([ -f "$VAR/.ziyan_menu_run_trig" ] && echo 1 || echo 0)
SBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
[ -n "$1" ] && echo SB_AFTER=$1
BBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
[ -n "$1" ] && echo BB_AFTER=$1
rm -f "$VAR/.ziyan_page_selftest_req" /private/var/mobile/Media/ZiYan/.ziyan_page_selftest_req
echo stop=1 >"$VAR/.ziyan_stop"
rm -f "$VAR/.ziyan_app_run_trig"
echo CLEANUP_DONE
EOS
}

judge_page() {
  local tag="$1" base_sb="$2" base_bb="$3"
  local f="$OUT/$tag/page_run.txt" NONCE
  NONCE=$(cat "$OUT/$tag/nonce.txt" 2>/dev/null | sed -n 's/^NONCE=//p')
  local path_ok enter_ok done_ok min_once run_ok already has_trig has_menu vol_page kill_hit
  path_ok=$(awk '/--- SELFTEST_LOG ---/,/--- MINIMIZE_LOG ---/' "$f" | grep -c "PAGE_SELFTEST_RUN_BUTTON_PATH nonce=$NONCE" || true)
  enter_ok=$(awk '/--- SELFTEST_LOG ---/,/--- MINIMIZE_LOG ---/' "$f" | grep -c "PAGE_SELFTEST_ENTER nonce=$NONCE" || true)
  done_ok=$(awk '/--- SELFTEST_LOG ---/,/--- MINIMIZE_LOG ---/' "$f" | grep -c "PAGE_SELFTEST_DONE nonce=$NONCE" || true)
  min_once=$(awk '/--- MINIMIZE_LOG ---/,/--- ENSURE ---/' "$f" | grep -c 'page_entry minimize_once' || true)
  run_ok=$(awk '/--- MINIMIZE_LOG ---/,/--- ENSURE ---/' "$f" \
    | grep -E 'run_ok _zy_page_entry_selftest|run_ok .*selftest' \
    | sed 's/.*run_ok /run_ok /' | sort -u | wc -l | tr -d ' ')
  already=$(grep -c 'already_ready' "$f" || true)
  has_trig=$(sed -n 's/^HAS_RUN_TRIG=//p' "$f" | tail -1)
  has_menu=$(sed -n 's/^HAS_MENU_TRIG=//p' "$f" | tail -1)
  vol_page=$(grep -c 'page_entry.*volume\|entry=volume' "$f" || true)
  kill_hit=$(grep -cE 'SIGTERM ZiYan|terminate ZiYan|SIGKILL ZiYan|minimize FBS terminate' "$f" || true)
  local sb_a bb_a run_pid session_ok pid_ok
  sb_a=$(sed -n 's/^SB_AFTER=\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
  bb_a=$(sed -n 's/^BB_AFTER=\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
  run_pid=$(sed -n 's/^RUN_PID=//p' "$f" | tail -1)
  session_ok=0
  echo "$run_pid" | grep -qE '^[1-9][0-9]*$' && session_ok=1
  grep -q 'GOT_RUN_OK' "$f" && session_ok=1
  grep -qE 'runState=1|running' <<<"$(sed -n 's/^SESSION=//p' "$f")" && session_ok=1
  [ "${run_ok:-0}" -eq 1 ] && session_ok=1
  pid_ok=1
  if [ -n "$base_sb" ] && [ -n "$sb_a" ] && [ "$base_sb" != "$sb_a" ]; then pid_ok=0; fi
  if [ -n "$base_bb" ] && [ -n "$bb_a" ] && [ "$base_bb" != "$bb_a" ]; then pid_ok=0; fi
  {
    echo "nonce=$NONCE"
    echo "enter=$enter_ok path=$path_ok done=$done_ok"
    echo "min_once=$min_once"
    echo "run_ok_unique=$run_ok"
    echo "run_pid=$run_pid session_ok=$session_ok"
    echo "already_ready=$already"
    echo "HAS_RUN_TRIG=${has_trig:-0}"
    echo "HAS_MENU_TRIG=${has_menu:-0}"
    echo "vol_page=$vol_page"
    echo "kill_hit=$kill_hit"
    echo "sb_before=$base_sb sb_after=$sb_a"
    echo "bb_before=$base_bb bb_after=$bb_a"
    echo "pid_ok=$pid_ok"
  } >"$OUT/$tag/page_verdict.txt"
  if [ "${enter_ok:-0}" -ge 1 ] && [ "${path_ok:-0}" -ge 1 ] && [ "${done_ok:-0}" -ge 1 ] \
      && [ "${min_once:-0}" -eq 1 ] && [ "${run_ok:-0}" -eq 1 ] && [ "$session_ok" = 1 ] \
      && [ "${already:-0}" -ge 1 ] && [ "$pid_ok" = 1 ] \
      && [ "${vol_page:-0}" = 0 ] && [ "${kill_hit:-0}" = 0 ] \
      && [ "${has_trig:-0}" != 1 ] && [ "${has_menu:-0}" != 1 ]; then
    echo "PAGE_PASS .$tag" | tee -a "$OUT/$tag/page_verdict.txt"
    echo "PASS" >"$OUT/$tag/device_verdict.txt"
    return 0
  fi
  echo "PAGE_FAIL .$tag" | tee -a "$OUT/$tag/page_verdict.txt"
  echo "FAIL PAGE" >"$OUT/$tag/device_verdict.txt"
  return 1
}

phase2_page() {
  local tag="$1" scheme="$2" ip="$3" deb="$4" expect="$5"
  mkdir -p "$OUT/$tag"
  : >"$OUT/$tag/reload.txt"
  : >"$OUT/$tag/pid_samples.txt"
  : >"$OUT/$tag/unlock.txt"
  : >"$OUT/$tag/page_run.txt"
  echo "== PAGE .$tag =="
  if ! install_deb "$tag" "$scheme" "$ip" "$deb" "$expect"; then
    echo "FAIL DEPLOY" >"$OUT/$tag/device_verdict.txt"
    return 0
  fi
  sbreload_once "$tag" "$ip" "page"
  local ws
  set +e
  wait_hold "$tag" "$ip" "$OUT/$tag/pid_samples.txt" 20 45 20
  ws=$?
  set -e
  echo "wait_hold_rc=$ws" | tee -a "$OUT/$tag/reload.txt"
  if [ "$ws" = 3 ]; then
    echo "DEVICE_ABORT_SB_LOOP .$tag" | tee "$OUT/$tag/status.txt"
    echo "SKIP SB_LOOP" >"$OUT/$tag/device_verdict.txt"
    disable_all_six "$scheme" "$ip"
    return 0
  fi
  write_snap "$tag" "$scheme" "$ip" "$OUT/$tag/post.txt" || true
  local base_sb base_bb fc daemon hooks
  base_sb=$(digits SB_PID "$OUT/$tag/post.txt")
  base_bb=$(digits BB_PID "$OUT/$tag/post.txt")
  fc=$(sed -n 's/^FC_N=//p' "$OUT/$tag/post.txt" | head -1)
  daemon=$(sed -n 's/^DAEMON=//p' "$OUT/$tag/post.txt" | head -1)
  hooks=$(sed -n 's/^HOOKS_SB_PID=//p' "$OUT/$tag/post.txt" | head -1)
  echo "post_sb=$base_sb post_bb=$base_bb fc=$fc daemon=$daemon hooks=$hooks" | tee -a "$OUT/$tag/reload.txt"
  if [ "$ws" != 0 ] || [ "${fc:-0}" != 1 ] || [ "${daemon:-0}" -lt 1 ] || [ "$hooks" != "$base_sb" ]; then
    echo "SKIP UNSTABLE .$tag" | tee "$OUT/$tag/status.txt"
    echo "SKIP UNSTABLE" >"$OUT/$tag/device_verdict.txt"
    return 0
  fi
  set +e
  unlock_phone "$tag" "$scheme" "$ip"
  local urc=$?
  set -e
  if [ "$urc" != 0 ]; then
    echo "LOCKED_SKIP .$tag" | tee "$OUT/$tag/status.txt"
    echo "SKIP LOCKED" >"$OUT/$tag/device_verdict.txt"
    return 0
  fi
  page_run_one "$tag" "$scheme" "$ip"
  judge_page "$tag" "$base_sb" "$base_bb" || true
}

phase3_bisect() {
  local tag="$1" scheme="$2" ip="$3" deb="$4" expect="$5"
  local dest="$OUT/$tag"
  mkdir -p "$dest" "$OUT/INJECT_TRACE_$tag"
  echo "== BISECT .$tag =="
  if ! install_deb "$tag" "$scheme" "$ip" "$deb" "$expect"; then
    echo "FAIL DEPLOY" >"$dest/device_verdict.txt"
    echo "# MODULE MATRIX .$tag" >"$OUT/MODULE_MATRIX_$tag.md"
    echo "DEPLOY_FAIL" >>"$OUT/MODULE_MATRIX_$tag.md"
    return 0
  fi
  echo "DISABLE_ALL_AFTER_INSTALL" | tee -a "$dest/deploy.txt"
  disable_all_six "$scheme" "$ip"
  write_snap "$tag" "$scheme" "$ip" "$dest/after_disable.txt" || true

  local kept=()
  local matrix="$dest/matrix.txt"
  : >"$matrix"
  local mod idx=0
  for mod in "${MODULES[@]}"; do
    idx=$((idx + 1))
    [ "$idx" -gt 6 ] && break
    past_deadline && { echo "DEADLINE_STOP .$tag at $mod" | tee -a "$matrix"; break; }
    local md="$dest/$mod"
    mkdir -p "$md"
    echo "== MODULE .$tag $mod =="
    apply_kept_plus "$scheme" "$ip" "$mod" "${kept[@]+"${kept[@]}"}"
    if [ "$mod" = ZiYanBBFrame ]; then
      ssh_r "$ip" "V='$(var_dir "$scheme")'; echo 1 >\"\$V/.ziyan_bbframe_on\"; chmod 666 \"\$V/.ziyan_bbframe_on\"; echo BBFRAME_ON" \
        >"$md/bbframe_on.txt" 2>&1 || true
    fi
    write_snap "$tag" "$scheme" "$ip" "$md/pre.txt" || true
    ssh_r "$ip" "V='$(var_dir "$scheme")'; : > \"\$V/.ziyan_inject_trace\"; chmod 666 \"\$V/.ziyan_inject_trace\" 2>/dev/null; echo TRACE_RESET" \
      >"$md/trace_reset.txt" 2>&1 || true
    {
      echo "module=$mod"
      echo "kept=${kept[*]:-none}"
      grep -E 'SB_PID|BB_PID|PKG=|FC_N|DAEMON|HOOKS|PLIST_' "$md/pre.txt" || true
    } >"$md/before.txt"
    sbreload_once "$tag" "$ip" "mod=$mod"
    local ws
    set +e
    wait_hold "$tag" "$ip" "$md/pid_samples.txt" 20 55 32
    ws=$?
    set -e
    write_snap "$tag" "$scheme" "$ip" "$md/post.txt" || true
    ssh_r "$ip" "cat '$(var_dir "$scheme")/.ziyan_inject_trace' 2>/dev/null" \
      >"$md/inject_trace.txt" 2>&1 || true
    cp -f "$md/inject_trace.txt" "$OUT/INJECT_TRACE_$tag/${mod}.txt" 2>/dev/null || true
    if [ "$ws" = 0 ]; then
      echo "MODULE_PASS $mod" | tee "$md/verdict.txt" | tee -a "$matrix"
      kept+=("$mod")
    elif [ "$ws" = 3 ]; then
      echo "MODULE_LOOP $mod" | tee "$md/verdict.txt" | tee -a "$matrix"
      set_mod "$scheme" "$ip" "$mod" 0 | tee -a "$md/verdict.txt" || true
      if [ "$mod" = ZiYanBBFrame ]; then
        ssh_r "$ip" "V='$(var_dir "$scheme")'; rm -f \"\$V/.ziyan_bbframe_on\"; echo BBFRAME_ON_REMOVED" \
          >>"$md/verdict.txt" 2>&1 || true
      fi
      echo "WAIT_AFTER_LOOP $mod" | tee -a "$md/verdict.txt"
      set +e
      wait_hold "$tag" "$ip" "$md/settle.txt" 10 40
      set -e
    else
      echo "MODULE_UNSTABLE $mod" | tee "$md/verdict.txt" | tee -a "$matrix"
      set_mod "$scheme" "$ip" "$mod" 0 | tee -a "$md/verdict.txt" || true
    fi
  done
  {
    echo "# MODULE MATRIX .$tag"
    echo
    echo "pkg=$(sed -n 's/^PKG=//p' "$dest/post_install.txt" | head -1)"
    echo "kept_pass=${kept[*]:-none}"
    echo
    cat "$matrix"
  } >"$OUT/MODULE_MATRIX_$tag.md"
  echo "BISECT_DONE" >"$dest/device_verdict.txt"
  cp -R "$dest" "$OUT/AGENT_CORE_SB_RECOVERY_$tag" 2>/dev/null || true
  if printf '%s\n' "${kept[@]+"${kept[@]}"}" | grep -qx ZiYanBBFrame; then
    echo "SB_RECOVERY_PASS .$tag" | tee "$dest/sb_recovery.txt"
  else
    echo "SB_RECOVERY_PARTIAL .$tag bbframe_not_kept" | tee "$dest/sb_recovery.txt"
  fi
}

agent_smoke_one() {
  local tag="$1" scheme="$2" ip="$3"
  local VAR BIN
  VAR=$(var_dir "$scheme")
  if [ "$scheme" = rootless ]; then
    BIN="DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua"
  else
    BIN="/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua"
  fi
  ssh_r "$ip" "VAR=$VAR BIN='$BIN' bash -s" >"$OUT/$tag/agent_smoke.txt" 2>&1 <<'EOS' || true
set +e
printf 'com.ziyan.ziyan\n' > "$VAR/.ziyan_open_app"
chmod 666 "$VAR/.ziyan_open_app"
FRONT_OK=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  FG=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "wait_front t=$i front=$FG"
  echo "$FG" | grep -q 'com.ziyan.ziyan' && FRONT_OK=1 && break
  sleep 1
done
echo FRONT_OK=$FRONT_OK
if [ -f /var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_smoke.lua ]; then
  eval $BIN /var/jb/usr/lib/ziyan/lib/lua/ziyan_agent_smoke.lua
else
  eval $BIN /usr/lib/ziyan/lib/lua/ziyan_agent_smoke.lua
fi
echo SMOKE_RC=$?
echo SESSION=$(tr '\n' ' ' < "$VAR/.ziyan_agent_session" 2>/dev/null)
echo FC=$(ps -ax -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep)
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_AFTER=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_AFTER=$1
echo Z=$(ps -ax -o stat= | grep -c Z || true)
EOS
  local st
  st=$(sed -n 's/^SESSION=//p' "$OUT/$tag/agent_smoke.txt" | tail -1)
  if echo "$st" | grep -q 'state=STOPPED'; then
    echo "AGENT_SMOKE_PASS .$tag" | tee "$OUT/AGENT_SMOKE_$tag.md"
    return 0
  fi
  if echo "$st" | grep -q 'PAUSED_SAFE'; then
    echo "AGENT_SMOKE_PAUSED_SAFE .$tag" | tee "$OUT/AGENT_SMOKE_$tag.md"
    return 0
  fi
  echo "AGENT_SMOKE_FAIL .$tag" | tee "$OUT/AGENT_SMOKE_$tag.md"
  return 1
}

# ---- run ----
{
  echo "# PRECHECK"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "DEB_RF=$DEB_RF"
  echo "DEB_RL=$DEB_RL"
  echo "VER_RF=$VER_RF SHA256_RF=$SHA_RF"
  echo "VER_RL=$VER_RL SHA256_RL=$SHA_RL"
} | tee "$OUT/PRECHECK.md"

# Phase 2: page phones independently
phase2_page 53 rootless 192.168.31.53 "$DEB_RL" "$VER_RL" || true
phase2_page 112 rootful 192.168.31.112 "$DEB_RF" "$VER_RF" || true
for spec in "53 rootless 192.168.31.53" "112 rootful 192.168.31.112"; do
  set -- $spec
  {
    echo "# AUTO_UNLOCK .$1"
    echo
    echo '```'
    cat "$OUT/$1/unlock.txt" 2>/dev/null || echo missing
    echo '```'
  } >"$OUT/AUTO_UNLOCK_$1.md"
  if grep -q 'AUTO_UNLOCK_PASS' "$OUT/$1/unlock.txt" 2>/dev/null \
      && ! grep -qE 'SB_LOOP|UNSTABLE' "$OUT/$1/device_verdict.txt" 2>/dev/null; then
    agent_smoke_one "$1" "$2" "$3" || true
  else
    echo "AGENT_SMOKE_SKIP .$1" | tee "$OUT/AGENT_SMOKE_$1.md"
  fi
done

# Phase 3: module phones independently
phase3_bisect 101 rootful 192.168.31.101 "$DEB_RF" "$VER_RF" || true
phase3_bisect 166 rootful 192.168.31.166 "$DEB_RF" "$VER_RF" || true
for spec in "101 rootful 192.168.31.101" "166 rootful 192.168.31.166"; do
  set -- $spec
  if grep -q SB_RECOVERY_PASS "$OUT/$1/sb_recovery.txt" 2>/dev/null; then
    set +e
    unlock_phone "$1" "$2" "$3"
    set -e
    {
      echo "# AUTO_UNLOCK .$1"
      echo
      echo '```'
      cat "$OUT/$1/unlock.txt" 2>/dev/null || echo missing
      echo '```'
    } >"$OUT/AUTO_UNLOCK_$1.md"
    if grep -q 'AUTO_UNLOCK_PASS' "$OUT/$1/unlock.txt" 2>/dev/null; then
      agent_smoke_one "$1" "$2" "$3" || true
    else
      echo "AGENT_SMOKE_SKIP unlock_fail" | tee "$OUT/AGENT_SMOKE_$1.md"
    fi
  else
    echo "AUTO_UNLOCK_SKIP sb_recovery" >"$OUT/AUTO_UNLOCK_$1.md"
    echo "AGENT_SMOKE_SKIP sb_recovery" | tee "$OUT/AGENT_SMOKE_$1.md"
  fi
done

# Copy page summaries
for tag in 53 112; do
  {
    echo "# PAGE .$tag"
    echo
    echo "deploy:"
    echo '```'
    cat "$OUT/$tag/deploy.txt" 2>/dev/null || echo missing
    echo '```'
    echo
    echo "reload / pid:"
    echo '```'
    cat "$OUT/$tag/reload.txt" 2>/dev/null || true
    echo
    cat "$OUT/$tag/pid_samples.txt" 2>/dev/null || true
    echo '```'
    echo
    echo "page_verdict:"
    echo '```'
    cat "$OUT/$tag/page_verdict.txt" 2>/dev/null || echo missing
    echo '```'
    echo
    echo "device=$(cat "$OUT/$tag/device_verdict.txt" 2>/dev/null || echo unknown)"
  } >"$OUT/PAGE_$tag.md"
done

ELAPSED=$(( $(date +%s) - START_EPOCH ))
{
  echo "# BUILD"
  echo
  echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15"
  echo "actual_date=2026-08-15"
  echo "compile_host_time=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "VER_RF=$VER_RF"
  echo "SHA256_RF=$SHA_RF"
  echo "VER_RL=$VER_RL"
  echo "SHA256_RL=$SHA_RL"
  echo "source_control=0.0.92-8-161-205-C-65.11-98+debug-10-31"
  echo "agent_switch=local_rules_mvp"
  echo "debug_selftest=ZIYAN_PAGE_SELFTEST + ziyan_agent_smoke.lua"
  echo "no_auto_respring=1"
} | tee "$OUT/BUILD.md"

{
  echo "# AGENT_ARCHITECTURE"
  echo
  cat "$ROOT/DOCS/Agent自动游戏MVP说明.md"
} >"$OUT/AGENT_ARCHITECTURE.md"
{
  echo "# AGENT_API"
  echo
  cat "$ROOT/DOCS/Agent函数能力清单.md"
} >"$OUT/AGENT_API.md"

for tag in 101 166; do
  {
    echo "# SB_RECOVERY .$tag"
    echo
    echo '```'
    cat "$OUT/$tag/sb_recovery.txt" 2>/dev/null || echo missing
    echo
    cat "$OUT/$tag/matrix.txt" 2>/dev/null || true
    echo '```'
  } >"$OUT/SB_RECOVERY_$tag.md"
done

{
  echo "# ERROR_REPORT_SAMPLE"
  echo
  echo "Device reports live under /private/var/mobile/Media/ZiYan/Agent游戏/错误报告/"
  echo "Harness copies session lines from AGENT_SMOKE_*.md."
  echo
  for tag in 53 101 112 166; do
    echo "## .$tag"
    echo '```'
    grep -E 'SESSION=|FRONT|SMOKE|state=' "$OUT/$tag/agent_smoke.txt" 2>/dev/null | head -20 || echo none
    echo '```'
  done
} >"$OUT/ERROR_REPORT_SAMPLE.md"

{
  echo "# RESOURCE_REPORT"
  echo
  echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15"
  for tag in 53 101 112 166; do
    echo "## .$tag"
    echo '```'
    grep -E 'FC_N=|DAEMON=|SB_PID=|BB_PID=|PKG=' "$OUT/$tag/post.txt" "$OUT/$tag/post_install.txt" "$OUT/$tag/agent_smoke.txt" 2>/dev/null | head -20 || true
    echo '```'
  done
} >"$OUT/RESOURCE_REPORT.md"

{
  echo "# ITERATION_1"
  echo
  echo "package=debug-10-31"
  echo "hypothesis=BBFrame 25s late_start + no watch poller + 2s/250ms timer; page launch-then-go_home; Agent smoke observe_once"
  echo "source_fix_round=1"
} >"$OUT/ITERATION_1.md"

{
  echo "# CURRENT_STATE"
  echo
  echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15"
  echo "elapsed_s=$ELAPSED"
  for tag in 53 101 112 166; do
    echo "## .$tag"
    echo "device=$(cat "$OUT/$tag/device_verdict.txt" 2>/dev/null || echo missing)"
    echo "unlock=$(grep -E 'AUTO_UNLOCK_' "$OUT/$tag/unlock.txt" 2>/dev/null | tail -1 || echo none)"
    echo "smoke=$(head -1 "$OUT/AGENT_SMOKE_$tag.md" 2>/dev/null || echo none)"
    echo "sb_recovery=$(cat "$OUT/$tag/sb_recovery.txt" 2>/dev/null || echo n/a)"
  done
} >"$OUT/CURRENT_STATE.md"

PASS_ALL=1
for tag in 53 101 112 166; do
  grep -q 'AUTO_UNLOCK_PASS' "$OUT/$tag/unlock.txt" 2>/dev/null || PASS_ALL=0
  grep -q 'AGENT_SMOKE_PASS' "$OUT/AGENT_SMOKE_$tag.md" 2>/dev/null || PASS_ALL=0
done
grep -q 'SB_RECOVERY_PASS' "$OUT/101/sb_recovery.txt" 2>/dev/null || PASS_ALL=0
grep -q 'SB_RECOVERY_PASS' "$OUT/166/sb_recovery.txt" 2>/dev/null || PASS_ALL=0

{
  echo "# VERDICT"
  echo
  echo "CLOCK_SKEW=device_2026-08-16_actual_2026-08-15"
  echo "actual_date=2026-08-15"
  echo "elapsed_s=$ELAPSED"
  echo "VER_RF=$VER_RF SHA256_RF=$SHA_RF"
  echo "VER_RL=$VER_RL SHA256_RL=$SHA_RL"
  echo
  echo "| device | deploy | page/module | unlock | smoke |"
  echo "|---|---|---|---|---|"
  echo "| .53 | $(grep -E 'DEPLOY_' "$OUT/53/deploy.txt" 2>/dev/null | tail -1) | $(tr '\n' ' ' < "$OUT/53/device_verdict.txt" 2>/dev/null) | $(grep AUTO_UNLOCK_ "$OUT/53/unlock.txt" 2>/dev/null | tail -1) | $(head -1 "$OUT/AGENT_SMOKE_53.md" 2>/dev/null) |"
  echo "| .112 | $(grep -E 'DEPLOY_' "$OUT/112/deploy.txt" 2>/dev/null | tail -1) | $(tr '\n' ' ' < "$OUT/112/device_verdict.txt" 2>/dev/null) | $(grep AUTO_UNLOCK_ "$OUT/112/unlock.txt" 2>/dev/null | tail -1) | $(head -1 "$OUT/AGENT_SMOKE_112.md" 2>/dev/null) |"
  echo "| .101 | $(grep -E 'DEPLOY_' "$OUT/101/deploy.txt" 2>/dev/null | tail -1) | $(tr '\n' ' ' < "$OUT/101/sb_recovery.txt" 2>/dev/null) | $(grep AUTO_UNLOCK_ "$OUT/101/unlock.txt" 2>/dev/null | tail -1) | $(head -1 "$OUT/AGENT_SMOKE_101.md" 2>/dev/null) |"
  echo "| .166 | $(grep -E 'DEPLOY_' "$OUT/166/deploy.txt" 2>/dev/null | tail -1) | $(tr '\n' ' ' < "$OUT/166/sb_recovery.txt" 2>/dev/null) | $(grep AUTO_UNLOCK_ "$OUT/166/unlock.txt" 2>/dev/null | tail -1) | $(head -1 "$OUT/AGENT_SMOKE_166.md" 2>/dev/null) |"
  echo
  if [ "$PASS_ALL" = 1 ]; then
    echo "AGENT_MVP_4PHONE_PASS=YES"
  else
    echo "AGENT_MVP_4PHONE_PASS=NO"
    echo "RESULT=PARTIAL_OR_BLOCKED"
  fi
  echo
  echo "Four results are independent. Closing inject is not PASS."
  echo "不得宣称完全兼容或超越触动。"
} | tee "$OUT/VERDICT.md"

{
  echo "# NEXT_AGENT_PHASE"
  echo
  if [ "$PASS_ALL" = 1 ]; then
    echo "Next: real GameProfile on one non-sensitive title, still PAUSED_SAFE on login/pay."
  else
    echo "Next: keep .53/.112 evidence; if .101/.166 SB_LOOP remains, stop guessing after 2 same-root-cause rounds and write BLOCKED_ROOT_CAUSE."
    echo "Do not claim four-phone Agent complete."
  fi
  echo "不得宣称完全兼容或超越触动。"
} >"$OUT/NEXT_AGENT_PHASE.md"

echo "OUT=$OUT"
echo "elapsed_s=$ELAPSED"
echo "AGENT_MVP_4PHONE_PASS=$([ "$PASS_ALL" = 1 ] && echo YES || echo NO)"
