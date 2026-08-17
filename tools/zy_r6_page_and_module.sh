#!/usr/bin/env bash
# R6: .53/.112 page-order regression + .101/.166 per-module inject bisection.
# Isolated: one phone fail never stops the others.
# Default (no flag): exit 78, no SSH, no respring.
set -euo pipefail

if [ "${1:-}" != "--r6-page-and-module" ]; then
  echo "BLOCKED_R6_REQUIRED" >&2
  echo "only allowed: $0 --r6-page-and-module" >&2
  exit 78
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/R6_PAGE_ORDER_AND_MODULE_BISECTION_${STAMP}"
mkdir -p "$OUT" "$OUT/INJECT_TRACE_101" "$OUT/INJECT_TRACE_166"
echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"

START_EPOCH=$(date +%s)
DEADLINE=$((START_EPOCH + 1500))
SAFE_LUA="$ROOT/layout/private/var/mobile/Media/ZiYan/_zy_page_entry_selftest.lua"
MODULES=(ZiYanFsCloak ZiYanDefense ZiYanAppTouch ZiYanFrameRelay ZiYanVol ZiYanBBFrame)

DEB_RF=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-30*_iphoneos-arm.deb 2>/dev/null | head -1)
DEB_RL=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-30*_iphoneos-arm64.deb 2>/dev/null | head -1)
if [ -z "${DEB_RF:-}" ] || [ -z "${DEB_RL:-}" ]; then
  echo "MISSING_DEBUG_1030_DEB" | tee "$OUT/VERDICT.md"
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
    if [ "$stable" -ge "$hold" ]; then
      echo "STABLE SB=$sb BB=$bb hold=${stable}s sb_chg=$sb_chg bb_chg=$bb_chg"
      return 0
    fi
    sleep 1
  done
  echo "NOT_STABLE hold=${stable}s sb_chg=$sb_chg bb_chg=$bb_chg"
  return 1
}

do_unlock() {
  local tag="$1" scheme="$2" ip="$3" dest="$4"
  ssh_r "$ip" "SCHEME=$scheme bash -s" >"$dest" 2>&1 || true
}

# unlock body via stdin from caller? Keep inline like R5.
unlock_phone() {
  local tag="$1" scheme="$2" ip="$3"
  ssh_r "$ip" "SCHEME=$scheme bash -s" >"$OUT/$tag/unlock.txt" 2>&1 <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
if [ ! -e "$V/.ziyan_project_active" ] && [ ! -e "$V/.ziyan_script_session" ]; then
  date +%s >"$V/.ziyan_project_active"
  chmod 666 "$V/.ziyan_project_active" 2>/dev/null
  echo MARKER_CREATED=1
fi
printf '1\n' >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req"
echo UNLOCK_REQ_WRITTEN
sleep 2
echo unlock_status=$(tr -d '\r\n' < "$V/.ziyan_unlock_rep" 2>/dev/null)
echo display_locked=$(tr -d '\r\n' < "$V/.ziyan_display_locked" 2>/dev/null)
echo front=$(tr -d '\r\n' < "$V/.ziyan_front_bid" 2>/dev/null)
echo LOCK_STATE=$(tr -d '\r\n' < "$V/.ziyan_lock_state" 2>/dev/null)
EOS
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
  wait_hold "$tag" "$ip" "$OUT/$tag/pid_samples.txt" 20 45
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
  if [ "$ws" != 0 ] || [ "${fc:-0}" != 1 ] || [ "${daemon:-0}" != 1 ] || [ "$hooks" != "$base_sb" ]; then
    echo "SKIP UNSTABLE .$tag" | tee "$OUT/$tag/status.txt"
    echo "SKIP UNSTABLE" >"$OUT/$tag/device_verdict.txt"
    return 0
  fi
  unlock_phone "$tag" "$scheme" "$ip"
  if grep -qE 'display_locked=1|LOCK_STATE=locked' "$OUT/$tag/unlock.txt"; then
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
    wait_hold "$tag" "$ip" "$md/pid_samples.txt" 20 45
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

# Phase 3: module phones independently
phase3_bisect 101 rootful 192.168.31.101 "$DEB_RF" "$VER_RF" || true
phase3_bisect 166 rootful 192.168.31.166 "$DEB_RF" "$VER_RF" || true

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
  echo "# R6 VERDICT"
  echo
  echo "elapsed_s=$ELAPSED"
  echo "VER_RF=$VER_RF SHA256_RF=$SHA_RF"
  echo "VER_RL=$VER_RL SHA256_RL=$SHA_RL"
  echo
  echo "| device | track | result |"
  echo "|---|---|---|"
  echo "| .53 | page | $(tr '\n' ' ' < "$OUT/53/device_verdict.txt" 2>/dev/null || echo missing) |"
  echo "| .112 | page | $(tr '\n' ' ' < "$OUT/112/device_verdict.txt" 2>/dev/null || echo missing) |"
  echo "| .101 | module | see MODULE_MATRIX_101.md |"
  echo "| .166 | module | see MODULE_MATRIX_166.md |"
  echo
  echo "Four results are independent. One FAIL does not hide the others."
  echo
  echo "不得宣称完全兼容或超越触动。"
} | tee "$OUT/VERDICT.md"

echo "OUT=$OUT"
echo "elapsed_s=$ELAPSED"
