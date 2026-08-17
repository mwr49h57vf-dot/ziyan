#!/usr/bin/env bash
# Controlled 4-phone inject reload + debug page-entry selftest (R3).
# Default (no flag): exit 78, no SSH, no respring.
# Only allowed invocation:
#   tools/zy_controlled_selftest_4phone.sh --controlled-selftest-4phone
set -euo pipefail

if [ "${1:-}" != "--controlled-selftest-4phone" ]; then
  echo "BLOCKED_CONTROLLED_SELFTEST_REQUIRED" >&2
  echo "refused: ${0:-unknown} default path does not connect or respring" >&2
  echo "only allowed: $0 --controlled-selftest-4phone" >&2
  exit 78
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/R5_DEBUG1029_4PHONE_${STAMP}"
mkdir -p "$OUT"
echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"

START_EPOCH=$(date +%s)
DEADLINE=$((START_EPOCH + 600))
ABORT=""
OVERALL=0
PAGE_PASS_N=0
PAGE_FAIL_N=0
LOCKED_N=0
DEPLOY_FAIL_N=0
INJECT_LIVE_N=0
SB_LOOP_N=0

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
  if past_deadline; then
    echo "DEADLINE_SKIP $ip" >&2
    return 124
  fi
  if ssh "${SSH_OPTS[@]}" "root@$ip" "$@" 2>/dev/null; then
    return 0
  fi
  sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
}

scp_to() {
  local src="$1" ip="$2" dst="$3"
  if past_deadline; then
    return 124
  fi
  if scp -o BatchMode=yes -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 "$src" "root@$ip:$dst" 2>/dev/null; then
    return 0
  fi
  sshpass -p "$PASS" scp "${SSH_PASS_OPTS[@]}" "$src" "root@$ip:$dst"
}

HOSTS=(
  "53 rootless 192.168.31.53"
  "101 rootful 192.168.31.101"
  "112 rootful 192.168.31.112"
  "166 rootful 192.168.31.166"
)

digits() { sed -n "s/^$1=\\([0-9][0-9]*\\).*/\\1/p" "$2" | head -1; }

ver_from_deb() {
  basename "$1" | sed -n 's/^com\.ziyan\.ziyan_\(.*\)_iphoneos-arm.*\.deb$/\1/p'
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
echo DATE=\$(date '+%Y-%m-%d %H:%M:%S')
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
echo LOCK_STATE=\$(tr -d '\r\n' < "\$VAR/.ziyan_lock_state" 2>/dev/null)
echo PENDING=\$([ -f "\$VAR/.ziyan_inject_reload_pending" ] && echo 1 || echo 0)
HOOKS=\$(tr '\n' ' ' < "\$VAR/.ziyan_hooks" 2>/dev/null)
echo HOOKS=\$HOOKS
echo HOOKS_SB_PID=\$(printf '%s\n' "\$HOOKS" | sed -n 's/.*sb_pid=\\([0-9][0-9]*\\).*/\\1/p' | head -1)
echo HOOKS_TS=\$(printf '%s\n' "\$HOOKS" | sed -n 's/.*ts=\\([0-9][0-9]*\\).*/\\1/p' | head -1)
for n in ZiYanAppTouch ZiYanBBFrame ZiYanDefense ZiYanFrameRelay ZiYanFsCloak ZiYanVol; do
  if [ -f "\$MS/\$n.plist" ]; then echo PLIST_\$n=on
  elif [ -f "\$MS/\$n.plist.ziyan_off" ]; then echo PLIST_\$n=off
  else echo PLIST_\$n=missing
  fi
done
EOS
}

write_snap() {
  local tag="$1" scheme="$2" ip="$3" dest="$4"
  if ! ssh_r "$ip" "bash -s" < <(snapshot_remote "$scheme") >"$dest" 2>&1; then
    echo "SSH_FAIL .$tag" | tee -a "$dest"
    return 1
  fi
  return 0
}

sb_etime_seconds() {
  local e
  e=$(sed -n 's/.*SB_ETIME=\([^ ]*\).*/\1/p' "$1" | head -1)
  [ -n "$e" ] || { echo 0; return; }
  awk -F: '{
    if (NF==3) print $1*3600+$2*60+$3;
    else if (NF==2) print $1*60+$2;
    else print $1+0;
  }' <<<"$e"
}

inject_verdict() {
  local f="$1"
  local cur_sb hooks_sb hooks_ts now etime sb_start
  cur_sb=$(digits SB_PID "$f")
  hooks_sb=$(sed -n 's/^HOOKS_SB_PID=//p' "$f" | head -1)
  hooks_ts=$(sed -n 's/^HOOKS_TS=//p' "$f" | head -1)
  now=$(sed -n 's/^NOW_TS=//p' "$f" | head -1)
  etime=$(sb_etime_seconds "$f")
  sb_start=0
  if [ -n "${now:-}" ] && [ -n "${etime:-}" ]; then
    sb_start=$((now - etime))
  fi
  echo "current_sb_pid=${cur_sb:-none}"
  echo "hooks_sb_pid=${hooks_sb:-none}"
  echo "hooks_ts=${hooks_ts:-none}"
  echo "sb_start_ts=${sb_start}"
  if [ -z "$cur_sb" ] || [ -z "$hooks_sb" ] || [ "$cur_sb" != "$hooks_sb" ]; then
    echo "inject=stale reason=sb_pid_mismatch"
    return 0
  fi
  if ! grep -q 'volume_menu+toast+icon' "$f"; then
    echo "inject=stale reason=hooks_missing"
    return 0
  fi
  echo "inject=live"
  return 0
}

restore_six_if_off() {
  local scheme="$1" ip="$2"
  ssh_r "$ip" "SCHEME=$scheme bash -s" <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then
  MS=/var/jb/Library/MobileSubstrate/DynamicLibraries
  TI=/var/jb/usr/lib/TweakInject
else
  MS=/Library/MobileSubstrate/DynamicLibraries
  TI=""
fi
for n in ZiYanAppTouch ZiYanBBFrame ZiYanDefense ZiYanFrameRelay ZiYanFsCloak ZiYanVol; do
  if [ -f "$MS/$n.plist.ziyan_off" ]; then
    mv -f "$MS/$n.plist.ziyan_off" "$MS/$n.plist"
    echo RESTORED_MS_$n
  fi
  if [ -n "$TI" ] && [ -f "$TI/$n.plist.ziyan_off" ]; then
    mv -f "$TI/$n.plist.ziyan_off" "$TI/$n.plist"
    echo RESTORED_TI_$n
  fi
done
EOS
}

disable_six() {
  local tag="$1" scheme="$2" ip="$3"
  ssh_r "$ip" "SCHEME=$scheme bash -s" <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then
  MS=/var/jb/Library/MobileSubstrate/DynamicLibraries
  TI=/var/jb/usr/lib/TweakInject
else
  MS=/Library/MobileSubstrate/DynamicLibraries
  TI=""
fi
for n in ZiYanAppTouch ZiYanBBFrame ZiYanDefense ZiYanFrameRelay ZiYanFsCloak ZiYanVol; do
  [ -f "$MS/$n.plist" ] && mv -f "$MS/$n.plist" "$MS/$n.plist.ziyan_off"
  if [ -n "$TI" ] && [ -f "$TI/$n.plist" ]; then
    mv -f "$TI/$n.plist" "$TI/$n.plist.ziyan_off"
  fi
  echo DISABLED_$n
done
EOS
  echo "DISABLED_SIX .$tag" | tee -a "$OUT/ABORT.txt"
}

# bash -s stdin: sampler argv never contains SpringBoard.app/SpringBoard.
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

wait_stable() {
  local tag="$1" scheme="$2" ip="$3" dest="$4"
  local sb0="" bb0="" sb_chg=0 bb_chg=0 stable=0 last_sb="" last_bb=""
  : >"$dest"
  for sec in $(seq 1 45); do
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
    if [ "$sb" != "$last_sb" ]; then
      sb_chg=$((sb_chg + 1))
      last_sb="$sb"
    fi
    if [ "$bb" != "$last_bb" ]; then
      bb_chg=$((bb_chg + 1))
      last_bb="$bb"
    fi
    if [ "$sb_chg" -gt 1 ] || [ "$bb_chg" -gt 1 ]; then
      echo "DEVICE_ABORT_SB_LOOP .$tag sb_chg=$sb_chg bb_chg=$bb_chg" | tee "$OUT/$tag/status.txt"
      disable_six "$tag" "$scheme" "$ip"
      echo "DEVICE_ABORT_SB_LOOP" | tee "$OUT/$tag/device_verdict.txt"
      return 3
    fi
    if [ "$sb" = "$sb0" ] && [ "$bb" = "$bb0" ]; then
      stable=$((stable + 1))
    else
      stable=0
      sb0="$sb"; bb0="$bb"
    fi
    if [ "$stable" -ge 20 ]; then
      echo "STABLE .$tag SB=$sb BB=$bb hold=${stable}s sb_chg=$sb_chg bb_chg=$bb_chg" | tee "$OUT/$tag/status.txt"
      return 0
    fi
    sleep 1
  done
  echo "NOT_STABLE .$tag hold=${stable}s sb_chg=$sb_chg bb_chg=$bb_chg" | tee "$OUT/$tag/status.txt"
  return 1
}

do_unlock() {
  local tag="$1" scheme="$2" ip="$3" dest="$4"
  ssh_r "$ip" "SCHEME=$scheme bash -s" >"$dest" 2>&1 <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var
else
  V=/usr/lib/ziyan/var
fi
TEST_MARKER_CREATED=0
if [ ! -e "$V/.ziyan_project_active" ] && [ ! -e "$V/.ziyan_script_session" ]; then
  date +%s >"$V/.ziyan_project_active"
  chmod 666 "$V/.ziyan_project_active" 2>/dev/null
  TEST_MARKER_CREATED=1
  echo MARKER_CREATED=1
fi
rm -f "$V/.ziyan_unlock_rep"
echo 1 >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
echo UNLOCK_REQ_WRITTEN
UNLOCK=timeout
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [ -s "$V/.ziyan_unlock_rep" ]; then
    if head -1 "$V/.ziyan_unlock_rep" | grep -q '^ok$'; then
      UNLOCK=ok
    else
      UNLOCK=err
    fi
    break
  fi
  sleep 0.5
done
[ "$TEST_MARKER_CREATED" = 1 ] && rm -f "$V/.ziyan_project_active"
rm -f "$V/.ziyan_unlock_req"
LOCK_STATE=$(tr -d '\r\n' <"$V/.ziyan_display_locked" 2>/dev/null)
if [ "$LOCK_STATE" != 0 ] && [ "$LOCK_STATE" != 1 ]; then
  LOCK_STATE=$(tr -d '\r\n' <"$V/.ziyan_lock_state" 2>/dev/null)
fi
FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
echo "unlock_status=$UNLOCK display_locked=${LOCK_STATE:-unknown} front=${FRONT:-unknown}"
echo UNLOCK_REP=$(tr '\n' '|' <"$V/.ziyan_unlock_rep" 2>/dev/null)
EOS
}

is_locked() {
  local f="$1"
  local lock
  lock=$(sed -n 's/^LOCK=//p' "$f" | head -1)
  [ "$lock" = 1 ]
}

# --- packages ---
DEB_RF="${ZY_SELFTEST_DEB_ROOTFUL:-}"
DEB_RL="${ZY_SELFTEST_DEB_ROOTLESS:-}"
if [ -z "$DEB_RF" ]; then
  DEB_RF="$ROOT/packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-98+debug-10-29-1+debug_iphoneos-arm.deb"
fi
if [ -z "$DEB_RL" ]; then
  DEB_RL="$ROOT/packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-98+debug-10-29-2+debug_iphoneos-arm64.deb"
fi
SHA_RF="missing"; SHA_RL="missing"
VER_RF="missing"; VER_RL="missing"
if [ -n "$DEB_RF" ] && [ -f "$DEB_RF" ]; then
  SHA_RF=$(shasum -a 256 "$DEB_RF" | awk '{print $1}')
  VER_RF=$(ver_from_deb "$DEB_RF")
fi
if [ -n "$DEB_RL" ] && [ -f "$DEB_RL" ]; then
  SHA_RL=$(shasum -a 256 "$DEB_RL" | awk '{print $1}')
  VER_RL=$(ver_from_deb "$DEB_RL")
fi
{
  echo "# PRECHECK"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "flag=--controlled-selftest-4phone"
  echo "no_auto_respring=1"
  echo "DEB_RF=${DEB_RF:-missing}"
  echo "DEB_RL=${DEB_RL:-missing}"
  echo "VER_RF=$VER_RF"
  echo "VER_RL=$VER_RL"
  echo "SHA256_RF=$SHA_RF"
  echo "SHA256_RL=$SHA_RL"
} | tee "$OUT/PRECHECK.md"

# --- phase 2: install ---
for spec in "${HOSTS[@]}"; do
  set -- $spec
  tag="$1"; scheme="$2"; ip="$3"
  mkdir -p "$OUT/$tag"
  : >"$OUT/$tag/deploy.txt"
  echo "== DEPLOY .$tag ==" | tee -a "$OUT/$tag/deploy.txt"
  if ! write_snap "$tag" "$scheme" "$ip" "$OUT/$tag/pre.txt"; then
    echo "DEPLOY_FAIL .$tag TRANSPORT_BLOCKED" | tee -a "$OUT/$tag/deploy.txt"
    DEPLOY_FAIL_N=$((DEPLOY_FAIL_N + 1))
    echo 0 >"$OUT/$tag/deploy_ok"
    continue
  fi
  inject_verdict "$OUT/$tag/pre.txt" | tee "$OUT/$tag/inject_pre.txt" | tee -a "$OUT/$tag/deploy.txt"
  pre_sb=$(digits SB_PID "$OUT/$tag/pre.txt")
  pre_bb=$(digits BB_PID "$OUT/$tag/pre.txt")
  echo "pre_sb=$pre_sb pre_bb=$pre_bb" | tee -a "$OUT/$tag/deploy.txt"
  deb="$DEB_RF"; expect="$VER_RF"
  [ "$scheme" = rootless ] && { deb="$DEB_RL"; expect="$VER_RL"; }
  if [ -z "$deb" ] || [ ! -f "$deb" ]; then
    echo "DEPLOY_FAIL .$tag NO_DEB" | tee -a "$OUT/$tag/deploy.txt"
    DEPLOY_FAIL_N=$((DEPLOY_FAIL_N + 1))
    echo 0 >"$OUT/$tag/deploy_ok"
    continue
  fi
  echo "INSTALL $deb expect=$expect" | tee -a "$OUT/$tag/deploy.txt"
  if ! scp_to "$deb" "$ip" /tmp/ziyan.deb; then
    echo "DEPLOY_FAIL .$tag SCP" | tee -a "$OUT/$tag/deploy.txt"
    DEPLOY_FAIL_N=$((DEPLOY_FAIL_N + 1))
    echo 0 >"$OUT/$tag/deploy_ok"
    continue
  fi
  if ! ssh_r "$ip" 'dpkg -i /tmp/ziyan.deb; echo DPKG_RC=$?' >>"$OUT/$tag/deploy.txt" 2>&1; then
    echo "DEPLOY_FAIL .$tag DPKG_SSH" | tee -a "$OUT/$tag/deploy.txt"
    DEPLOY_FAIL_N=$((DEPLOY_FAIL_N + 1))
    echo 0 >"$OUT/$tag/deploy_ok"
    continue
  fi
  write_snap "$tag" "$scheme" "$ip" "$OUT/$tag/post_install.txt" || true
  got=$(sed -n 's/^PKG=//p' "$OUT/$tag/post_install.txt" | head -1)
  post_sb=$(digits SB_PID "$OUT/$tag/post_install.txt")
  post_bb=$(digits BB_PID "$OUT/$tag/post_install.txt")
  pending=$(sed -n 's/^PENDING=//p' "$OUT/$tag/post_install.txt" | head -1)
  echo "installed=$got" | tee -a "$OUT/$tag/deploy.txt"
  echo "install_sb_before=$pre_sb after=$post_sb" | tee -a "$OUT/$tag/deploy.txt"
  echo "install_bb_before=$pre_bb after=$post_bb" | tee -a "$OUT/$tag/deploy.txt"
  echo "pending=$pending" | tee -a "$OUT/$tag/deploy.txt"
  ok=1
  grep -q 'INSTALL_OK no_auto_respring=1' "$OUT/$tag/deploy.txt" || { echo "MISSING_NO_AUTO_RESPRING" | tee -a "$OUT/$tag/deploy.txt"; ok=0; }
  [ "$got" = "$expect" ] || { echo "VERSION_MISMATCH got=$got expect=$expect" | tee -a "$OUT/$tag/deploy.txt"; ok=0; }
  [ "$pending" = 1 ] || { echo "MISSING_PENDING" | tee -a "$OUT/$tag/deploy.txt"; ok=0; }
  if [ -n "$pre_sb" ] && [ -n "$post_sb" ] && [ "$pre_sb" != "$post_sb" ]; then
    echo "INSTALL_CHANGED_SB" | tee -a "$OUT/$tag/deploy.txt"
    ok=0
  fi
  if [ -n "$pre_bb" ] && [ -n "$post_bb" ] && [ "$pre_bb" != "$post_bb" ]; then
    echo "INSTALL_CHANGED_BB" | tee -a "$OUT/$tag/deploy.txt"
    ok=0
  fi
  if [ "$ok" = 1 ]; then
    echo "DEPLOY_OK .$tag" | tee -a "$OUT/$tag/deploy.txt"
    echo 1 >"$OUT/$tag/deploy_ok"
  else
    echo "DEPLOY_FAIL .$tag" | tee -a "$OUT/$tag/deploy.txt"
    DEPLOY_FAIL_N=$((DEPLOY_FAIL_N + 1))
    echo 0 >"$OUT/$tag/deploy_ok"
  fi
  echo "== RESTORE_PLIST_IF_OFF .$tag ==" | tee -a "$OUT/$tag/deploy.txt"
  restore_six_if_off "$scheme" "$ip" >>"$OUT/$tag/deploy.txt" 2>&1 || true
  ssh_r "$ip" 'killall -9 ZiYan 2>/dev/null || true; echo ZIYAN_KILLED_FOR_NEW_BIN' >>"$OUT/$tag/deploy.txt" 2>&1 || true
done

# --- phase 3+4: reload, unlock, page ---
SAFE_LUA="$ROOT/layout/private/var/mobile/Media/ZiYan/_zy_page_entry_selftest.lua"
if [ ! -f "$SAFE_LUA" ]; then
  SAFE_LUA="$OUT/_zy_page_entry_selftest.lua"
  cat >"$SAFE_LUA" <<'LUA'
-- Safe page-entry selftest. Not a user business script.
function main()
  toast("page_entry_selftest", 1)
  mSleep(300)
end
LUA
fi

for spec in "${HOSTS[@]}"; do
  set -- $spec
  tag="$1"; scheme="$2"; ip="$3"
  mkdir -p "$OUT/$tag"
  : >>"$OUT/$tag/reload.txt"
  : >>"$OUT/$tag/pid_samples.txt"
  : >>"$OUT/$tag/unlock.txt"
  : >>"$OUT/$tag/page_run.txt"
  if [ "$scheme" = rootless ]; then
    VAR=/var/jb/usr/lib/ziyan/var
  else
    VAR=/usr/lib/ziyan/var
  fi
  deploy_ok=$(cat "$OUT/$tag/deploy_ok" 2>/dev/null || echo 0)
  if [ "$deploy_ok" != 1 ]; then
    echo "SKIP_RELOAD .$tag deploy_not_ok" | tee "$OUT/$tag/reload.txt"
    echo "PAGE_SKIP .$tag deploy_not_ok" | tee "$OUT/$tag/page_verdict.txt"
    echo "SKIP DEPLOY" >"$OUT/$tag/device_verdict.txt"
    : >"$OUT/$tag/pid_samples.txt"
    : >"$OUT/$tag/unlock.txt"
    : >"$OUT/$tag/page_run.txt"
    continue
  fi

  if ! write_snap "$tag" "$scheme" "$ip" "$OUT/$tag/pre_reload.txt"; then
    echo "TRANSPORT .$tag reload" | tee "$OUT/$tag/reload.txt"
    echo "SKIP TRANSPORT" >"$OUT/$tag/device_verdict.txt"
    : >"$OUT/$tag/pid_samples.txt"
    : >"$OUT/$tag/unlock.txt"
    : >"$OUT/$tag/page_run.txt"
    continue
  fi
  inject_verdict "$OUT/$tag/pre_reload.txt" | tee "$OUT/$tag/inject.txt"
  echo "RELOAD_ONCE sbreload .$tag (R5 always once after install)" | tee "$OUT/$tag/reload.txt"
  if ! ssh_r "$ip" 'command -v sbreload >/dev/null && sbreload; echo SBRELOAD_RC=$?' \
      >>"$OUT/$tag/reload.txt" 2>&1; then
    echo "SSH_FAIL_RELOAD .$tag" | tee -a "$OUT/$tag/reload.txt"
    echo "SKIP TRANSPORT" >"$OUT/$tag/device_verdict.txt"
    : >"$OUT/$tag/pid_samples.txt"
    : >"$OUT/$tag/unlock.txt"
    : >"$OUT/$tag/page_run.txt"
    continue
  fi

  ws=0
  wait_stable "$tag" "$scheme" "$ip" "$OUT/$tag/pid_samples.txt" || ws=$?
  if [ "$ws" = 3 ]; then
    SB_LOOP_N=$((SB_LOOP_N + 1))
    echo "SKIP_PAGE .$tag device_sb_loop" | tee "$OUT/$tag/page_verdict.txt"
    echo "SKIP SB_LOOP" >"$OUT/$tag/device_verdict.txt"
    continue
  fi
  do_unlock "$tag" "$scheme" "$ip" "$OUT/$tag/unlock.txt"
  write_snap "$tag" "$scheme" "$ip" "$OUT/$tag/post.txt" || true
  inject_verdict "$OUT/$tag/post.txt" | tee "$OUT/$tag/inject_post.txt"
  base_sb=$(digits SB_PID "$OUT/$tag/post.txt")
  base_bb=$(digits BB_PID "$OUT/$tag/post.txt")
  fc=$(sed -n 's/^FC_N=//p' "$OUT/$tag/post.txt" | head -1)
  daemon=$(sed -n 's/^DAEMON=//p' "$OUT/$tag/post.txt" | head -1)
  live=0
  grep -q 'inject=live' "$OUT/$tag/inject_post.txt" && live=1
  [ "$live" = 1 ] && INJECT_LIVE_N=$((INJECT_LIVE_N + 1))
  echo "post_sb=$base_sb post_bb=$base_bb fc=$fc daemon=$daemon live=$live" | tee -a "$OUT/$tag/reload.txt"

  if is_locked "$OUT/$tag/post.txt"; then
    echo "LOCKED_SKIP .$tag" | tee "$OUT/$tag/status.txt" "$OUT/$tag/page_verdict.txt"
    echo "SKIP LOCKED" >"$OUT/$tag/device_verdict.txt"
    LOCKED_N=$((LOCKED_N + 1))
    continue
  fi
  if [ "$deploy_ok" != 1 ]; then
    echo "PAGE_SKIP .$tag deploy_not_ok" | tee "$OUT/$tag/page_verdict.txt"
    echo "SKIP DEPLOY" >"$OUT/$tag/device_verdict.txt"
    continue
  fi
  if [ "$live" != 1 ]; then
    echo "PAGE_SKIP .$tag inject_not_live" | tee "$OUT/$tag/page_verdict.txt"
    echo "SKIP INJECT" >"$OUT/$tag/device_verdict.txt"
    : >"$OUT/$tag/page_run.txt"
    continue
  fi
  if [ "$ws" != 0 ] || [ "${fc:-0}" != 1 ] || [ "${daemon:-0}" != 1 ]; then
    echo "PAGE_SKIP .$tag not_ready fc=$fc daemon=$daemon ws=$ws" | tee "$OUT/$tag/page_verdict.txt"
    echo "SKIP UNSTABLE" >"$OUT/$tag/device_verdict.txt"
    : >"$OUT/$tag/page_run.txt"
    continue
  fi

  NONCE="pst_${tag}_$(date +%s)_$RANDOM"
  echo "NONCE=$NONCE" | tee "$OUT/$tag/nonce.txt"
  scp_to "$SAFE_LUA" "$ip" /private/var/mobile/Media/ZiYan/_zy_page_entry_selftest.lua || true

  if ! ssh_r "$ip" "VAR=$VAR NONCE=$NONCE bash -s" >"$OUT/$tag/page_run.txt" 2>&1 <<'EOS'
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
  if echo "$FG" | grep -q 'com.ziyan.ziyan'; then
    FRONT_OK=1
    break
  fi
  sleep 1
done
echo FRONT_OK=$FRONT_OK
if [ "$FRONT_OK" != 1 ]; then
  echo PAGE_FAIL_NOT_FOREGROUND
  rm -f "$VAR/.ziyan_page_selftest_req" /private/var/mobile/Media/ZiYan/.ziyan_page_selftest_req
  echo stop=1 >"$VAR/.ziyan_stop"
  exit 0
fi
printf 'nonce=%s\n' "$NONCE" > "$VAR/.ziyan_page_selftest_req"
chmod 666 "$VAR/.ziyan_page_selftest_req"
cp -f "$VAR/.ziyan_page_selftest_req" /private/var/mobile/Media/ZiYan/.ziyan_page_selftest_req
echo REQ_WRITTEN nonce=$NONCE
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if grep -q "PAGE_SELFTEST_DONE nonce=$NONCE" "$VAR/.ziyan_page_selftest_log" \
      /private/var/mobile/Media/ZiYan/.ziyan_page_selftest_log \
      "$VAR/.ziyan_minimize_log" 2>/dev/null; then
    echo GOT_DONE t=$i
    if grep -qE 'run_ok _zy_page_entry_selftest|page_entry minimize_once' \
        "$VAR/.ziyan_minimize_log" 2>/dev/null; then
      echo GOT_RUN_OK t=$i
      break
    fi
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
rm -f "$VAR/.ziyan_lua_run.pid" "$VAR/.ziyan_app_run_trig"
echo CLEANUP_DONE
EOS
  then
    echo "PAGE_FAIL .$tag transport" | tee "$OUT/$tag/page_verdict.txt"
    PAGE_FAIL_N=$((PAGE_FAIL_N + 1))
    continue
  fi

  f="$OUT/$tag/page_run.txt"
  path_ok=$(awk '/--- SELFTEST_LOG ---/,/--- MINIMIZE_LOG ---/' "$f" | grep -c "PAGE_SELFTEST_RUN_BUTTON_PATH nonce=$NONCE" || true)
  enter_ok=$(awk '/--- SELFTEST_LOG ---/,/--- MINIMIZE_LOG ---/' "$f" | grep -c "PAGE_SELFTEST_ENTER nonce=$NONCE" || true)
  done_ok=$(awk '/--- SELFTEST_LOG ---/,/--- MINIMIZE_LOG ---/' "$f" | grep -c "PAGE_SELFTEST_DONE nonce=$NONCE" || true)
  min_once=$(awk '/--- MINIMIZE_LOG ---/,/--- ENSURE ---/' "$f" | grep -c 'page_entry minimize_once' || true)
  run_ok=$(awk '/--- MINIMIZE_LOG ---/,/--- ENSURE ---/' "$f" \
    | grep -E 'run_ok _zy_page_entry_selftest|run_ok .*selftest' \
    | sed 's/.*run_ok /run_ok /' \
    | sort -u \
    | wc -l | tr -d ' ')
  already=$(grep -c 'already_ready' "$f" || true)
  has_trig=$(sed -n 's/^HAS_RUN_TRIG=//p' "$f" | tail -1)
  has_menu=$(sed -n 's/^HAS_MENU_TRIG=//p' "$f" | tail -1)
  vol_page=$(grep -c 'page_entry.*volume\|entry=volume' "$f" || true)
  kill_hit=$(grep -cE 'SIGTERM ZiYan|terminate ZiYan|SIGKILL ZiYan|minimize FBS terminate' "$f" || true)
  sb_a=$(sed -n 's/^SB_AFTER=\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
  bb_a=$(sed -n 's/^BB_AFTER=\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
  pid_ok=1
  if [ -n "$base_sb" ] && [ -n "$sb_a" ] && [ "$base_sb" != "$sb_a" ]; then pid_ok=0; fi
  if [ -n "$base_bb" ] && [ -n "$bb_a" ] && [ "$base_bb" != "$bb_a" ]; then pid_ok=0; fi
  {
    echo "nonce=$NONCE"
    echo "enter=$enter_ok path=$path_ok done=$done_ok"
    echo "min_once=$min_once"
    echo "run_ok=$run_ok"
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
      && [ "${min_once:-0}" -eq 1 ] && [ "${run_ok:-0}" -eq 1 ] \
      && [ "${already:-0}" -ge 1 ] && [ "$pid_ok" = 1 ] \
      && [ "${vol_page:-0}" = 0 ] && [ "${kill_hit:-0}" = 0 ] \
      && [ "${has_trig:-0}" != 1 ] && [ "${has_menu:-0}" != 1 ]; then
    echo "PAGE_HOST_OK .$tag" | tee -a "$OUT/$tag/page_verdict.txt"
    echo "PASS" >"$OUT/$tag/device_verdict.txt"
    PAGE_PASS_N=$((PAGE_PASS_N + 1))
  else
    echo "PAGE_FAIL .$tag" | tee -a "$OUT/$tag/page_verdict.txt"
    echo "FAIL PAGE" >"$OUT/$tag/device_verdict.txt"
    PAGE_FAIL_N=$((PAGE_FAIL_N + 1))
  fi
done

ELAPSED=$(( $(date +%s) - START_EPOCH ))
{
  echo "# VERDICT"
  echo
  echo "elapsed_s=$ELAPSED"
  echo "abort=${ABORT:-none}"
  echo "VER_RF=$VER_RF SHA256_RF=$SHA_RF"
  echo "VER_RL=$VER_RL SHA256_RL=$SHA_RL"
  echo "deploy_fail=$DEPLOY_FAIL_N inject_live=$INJECT_LIVE_N locked=$LOCKED_N sb_loop=$SB_LOOP_N"
  echo "page_pass=$PAGE_PASS_N page_fail=$PAGE_FAIL_N"
  echo
  for spec in "${HOSTS[@]}"; do
    set -- $spec
    echo "## .$1"
    echo '```'
    grep -E 'DEPLOY_|installed=|VERSION_|pending=|install_sb|install_bb' "$OUT/$1/deploy.txt" 2>/dev/null || true
    cat "$OUT/$1/inject.txt" 2>/dev/null || true
    cat "$OUT/$1/inject_post.txt" 2>/dev/null || true
    cat "$OUT/$1/status.txt" 2>/dev/null || echo missing_status
    echo
    cat "$OUT/$1/page_verdict.txt" 2>/dev/null || echo no_page
    echo DEVICE=$(cat "$OUT/$1/device_verdict.txt" 2>/dev/null || echo unknown)
    echo '```'
    echo
  done
  if [ "$PAGE_PASS_N" -eq 4 ] && [ "$PAGE_FAIL_N" -eq 0 ] && [ "$DEPLOY_FAIL_N" -eq 0 ] && [ "$LOCKED_N" -eq 0 ] && [ "$SB_LOOP_N" -eq 0 ]; then
    echo "R5_4PHONE_PASS=YES"
    echo "PAGE_ENTRY_4PHONE=PASS"
    echo "RESULT=R5_4PHONE_PASS"
  else
    echo "R5_4PHONE_PASS=NO"
    echo "PAGE_ENTRY_4PHONE=PARTIAL"
    echo "RESULT=PARTIAL pass=$PAGE_PASS_N fail=$PAGE_FAIL_N deploy_fail=$DEPLOY_FAIL_N locked=$LOCKED_N sb_loop=$SB_LOOP_N"
  fi
  echo
  echo "不得宣称完全兼容或超越触动。"
} | tee "$OUT/VERDICT.md"

if [ "$PAGE_PASS_N" -eq 4 ] && [ "$DEPLOY_FAIL_N" -eq 0 ] && [ "$LOCKED_N" -eq 0 ] && [ "$SB_LOOP_N" -eq 0 ]; then
  exit 0
fi
exit 4
