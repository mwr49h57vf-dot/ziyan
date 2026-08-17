#!/usr/bin/env bash
# Iteration 2: rootful 10-32 on .101/.166 only. One sbreload each.
# No killall SpringBoard/backboardd. Isolated per phone.
set -euo pipefail
if [ "${1:-}" != "--bbframe-r2" ]; then
  echo "only allowed: $0 --bbframe-r2" >&2
  exit 78
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
OUT="$ROOT/tmp_shots/AGENT_MVP_4PHONE_20260815_1/ITER2"
mkdir -p "$OUT"
DEB=$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*debug-10-32*_iphoneos-arm.deb | head -1)
VER=$(basename "$DEB" | sed -n 's/^com\.ziyan\.ziyan_\(.*\)_iphoneos-arm\.deb$/\1/p')
SHA=$(shasum -a 256 "$DEB" | awk '{print $1}')
echo "DEB=$DEB VER=$VER SHA=$SHA" | tee "$OUT/PRECHECK.md"

SSH_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=8)
SSH_PASS_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
               -o ConnectTimeout=8 -o PreferredAuthentications=password
               -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)

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

sample_pids() {
  ssh_r "$1" "bash -s" <<'EOS'
set +e
SBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
[ -n "$1" ] && echo SB=$1
BBLINE=$(ps -axo pid=,args= 2>/dev/null | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
[ -n "$1" ] && echo BB=$1
EOS
}

enable_six_and_flag() {
  local ip="$1"
  ssh_r "$ip" "bash -s" <<'EOS'
set +e
MS=/Library/MobileSubstrate/DynamicLibraries
for n in ZiYanFsCloak ZiYanDefense ZiYanAppTouch ZiYanFrameRelay ZiYanVol ZiYanBBFrame; do
  [ -f "$MS/$n.plist.ziyan_off" ] && mv -f "$MS/$n.plist.ziyan_off" "$MS/$n.plist"
done
echo 1 >/usr/lib/ziyan/var/.ziyan_bbframe_on
chmod 666 /usr/lib/ziyan/var/.ziyan_bbframe_on
: >/usr/lib/ziyan/var/.ziyan_inject_trace
chmod 666 /usr/lib/ziyan/var/.ziyan_inject_trace
echo SIX_ON_FLAG_ON
EOS
}

disable_six() {
  local ip="$1"
  ssh_r "$ip" "bash -s" <<'EOS'
set +e
MS=/Library/MobileSubstrate/DynamicLibraries
for n in ZiYanFsCloak ZiYanDefense ZiYanAppTouch ZiYanFrameRelay ZiYanVol ZiYanBBFrame; do
  [ -f "$MS/$n.plist" ] && mv -f "$MS/$n.plist" "$MS/$n.plist.ziyan_off"
done
rm -f /usr/lib/ziyan/var/.ziyan_bbframe_on
echo SIX_OFF
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
    if [ "$sb" != "$last_sb" ]; then sb_chg=$((sb_chg + 1)); last_sb="$sb"; fi
    if [ "$bb" != "$last_bb" ]; then bb_chg=$((bb_chg + 1)); last_bb="$bb"; fi
    if [ "$sb_chg" -gt 1 ] || [ "$bb_chg" -gt 1 ]; then
      echo "LOOP sb_chg=$sb_chg bb_chg=$bb_chg last_sb=$last_sb last_bb=$last_bb"
      return 3
    fi
    if [ "$sb" = "$sb0" ] && [ "$bb" = "$bb0" ]; then
      stable=$((stable + 1))
    else
      stable=0; sb0="$sb"; bb0="$bb"
    fi
    if [ "$stable" -ge "$hold" ] && [ "$sec" -ge "$min_obs" ]; then
      echo "STABLE SB=$sb BB=$bb hold=${stable}s observed=${sec}s"
      return 0
    fi
    sleep 1
  done
  echo "NOT_STABLE hold=${stable}s"
  return 1
}

run_one() {
  local tag="$1" ip="$2"
  local dest="$OUT/$tag"
  mkdir -p "$dest"
  echo "== ITER2 .$tag =="
  ssh_r "$ip" "echo PKG=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p'); ps -axo pid=,args= | grep -E '[S]pringBoard.app/SpringBoard|[b]ackboardd' | grep -v grep" \
    >"$dest/pre.txt" 2>&1 || true
  scp_to "$DEB" "$ip" /tmp/ziyan.deb
  ssh_r "$ip" "dpkg -i /tmp/ziyan.deb; echo DPKG_RC=\$?; echo installed=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')" \
    | tee "$dest/deploy.txt"
  grep -q 'INSTALL_OK no_auto_respring=1' "$dest/deploy.txt" || {
    echo "DEPLOY_FAIL .$tag" | tee "$dest/verdict.txt"
    return 0
  }
  grep -q "installed=$VER" "$dest/deploy.txt" || {
    echo "VERSION_MISMATCH .$tag" | tee "$dest/verdict.txt"
    return 0
  }
  echo "DEPLOY_OK .$tag" | tee -a "$dest/deploy.txt"
  enable_six_and_flag "$ip" | tee "$dest/enable.txt"
  echo "RELOAD_ONCE sbreload .$tag iter2" | tee "$dest/reload.txt"
  ssh_r "$ip" "sbreload" >>"$dest/reload.txt" 2>&1 || true
  sleep 3
  local ws
  set +e
  wait_hold "$ip" "$dest/pid_samples.txt" 30 50 30
  ws=$?
  set -e
  echo "wait_hold_rc=$ws" | tee -a "$dest/reload.txt"
  ssh_r "$ip" "cat /usr/lib/ziyan/var/.ziyan_inject_trace 2>/dev/null" \
    >"$dest/inject_trace.txt" 2>&1 || true
  ssh_r "$ip" "echo FC=\$(ps -ax -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep); echo DAEMON=\$(ps -ax -o command= | grep -E 'ziyadaemond|ziyan_zydaemond' | grep -vc grep); echo HOOKS=\$(tr '\n' ' ' < /usr/lib/ziyan/var/.ziyan_hooks)" \
    >"$dest/post.txt" 2>&1 || true
  if [ "$ws" = 0 ]; then
    echo "SB_RECOVERY_PASS .$tag" | tee "$dest/verdict.txt"
    return 0
  fi
  echo "DEVICE_ABORT_SB_LOOP .$tag" | tee "$dest/verdict.txt"
  disable_six "$ip" | tee -a "$dest/verdict.txt"
  set +e
  wait_hold "$ip" "$dest/settle.txt" 10 40 0
  set -e
  return 0
}

run_one 101 192.168.31.101 || true
run_one 166 192.168.31.166 || true

{
  echo "# ITER2 RESULT"
  echo "VER=$VER SHA=$SHA"
  echo "101=$(cat "$OUT/101/verdict.txt" 2>/dev/null | head -1)"
  echo "166=$(cat "$OUT/166/verdict.txt" 2>/dev/null | head -1)"
} | tee "$OUT/RESULT.md"
