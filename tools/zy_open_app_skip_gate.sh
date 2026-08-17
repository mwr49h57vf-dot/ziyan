#!/usr/bin/env bash
# Targeted open_app skip regression. Does not rerun Z2-30M.
# Usage: bash tools/zy_open_app_skip_gate.sh [53 101 112 166]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/OPEN_APP_SKIP_${STAMP}"
mkdir -p "$OUT"
if [ "$#" -eq 0 ]; then HOSTS=(53 101 112 166); else HOSTS=("$@"); fi
DEV_SH="$ROOT/tools/zy_open_app_skip_device.sh"

ssh_key() {
  ssh -n -o BatchMode=yes -o PasswordAuthentication=no \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=12 "root@192.168.31.$1" "$2"
}
scp_key() {
  scp -o BatchMode=yes -o PasswordAuthentication=no \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=12 "$1" "root@192.168.31.$2:$3"
}

var_of() {
  case "$1" in
    53) echo /var/jb/usr/lib/ziyan/var ;;
    *) echo /usr/lib/ziyan/var ;;
  esac
}

{
  echo "OUT=$OUT"
  echo "hosts=${HOSTS[*]}"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S %z')"
} | tee "$OUT/RUN.txt"

{
  echo "# A static: empty/blank/read-fail must not become com.ziyan.ziyan"
  if rg -n 'bid.length \? bid : @"com.ziyan.ziyan"|bundleId = @"com.ziyan.ziyan"|or "com.ziyan.ziyan"' \
      objc/tweak/springboard/Tweak.m objc/tweak/framerelay/Tweak.m lua/modules/AutoInject.lua; then
    echo STATIC_FAIL=1
  else
    echo STATIC_PASS=1
  fi
  echo "--- skip/invalid/launch_failed ---"
  rg -n 'ZiYanConsumeOpenAppFile|open_app_skip_empty|open_app_invalid|launch_failed|requestOpenApp' \
    objc/shared/ZiYanPaths.h objc/tweak/springboard/Tweak.m objc/tweak/framerelay/Tweak.m \
    lua/modules/AutoInject.lua
} >"$OUT/STATIC.txt" 2>&1

{
  shasum -a 256 \
    objc/shared/ZiYanPaths.h \
    objc/tweak/springboard/Tweak.m \
    objc/tweak/framerelay/Tweak.m \
    lua/modules/AutoInject.lua
  echo "control=$(sed -n 's/^Version: //p' control | head -1)"
} >"$OUT/SRC_HASH.txt"

ls -t packages/com.ziyan.ziyan_*_iphoneos-arm.deb 2>/dev/null | head -1 | tee "$OUT/deb_rf.path"
ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb 2>/dev/null | head -1 | tee "$OUT/deb_rl.path"
if [ -s "$OUT/deb_rf.path" ]; then shasum -a 256 "$(cat "$OUT/deb_rf.path")" >"$OUT/DEB_RF.sha256"; fi
if [ -s "$OUT/deb_rl.path" ]; then shasum -a 256 "$(cat "$OUT/deb_rl.path")" >"$OUT/DEB_RL.sha256"; fi

for obs in 149 171; do
  ssh_key "$obs" "printf 'HOST=%s\n' $obs; date; ps -ax -o pid,rss,etime,command | grep -E 'SpringBoard.app/SpringBoard|TSDaemon' | grep -v grep" \
    >"$OUT/ts${obs}_start.txt" 2>&1 || echo OBSERVER_UNREACHABLE >"$OUT/ts${obs}_start.txt"
done

fail_hosts=""
for H in "${HOSTS[@]}"; do
  V="$(var_of "$H")"
  D="$OUT/$H"
  mkdir -p "$D"
  echo "==== .$H ====" | tee "$D/host.log"
  scp_key "$DEV_SH" "$H" /tmp/zy_open_app_skip_device.sh >>"$D/host.log" 2>&1 || {
    echo "TRANSPORT_BLOCKED scp .$H" | tee -a "$D/host.log"
    fail_hosts="$fail_hosts $H"
    continue
  }
  ssh_key "$H" "chmod 755 /tmp/zy_open_app_skip_device.sh && H_TAG=$H VAR=$V /tmp/zy_open_app_skip_device.sh" \
    | tee "$D/device_run.txt"
  grep -E 'CASE |SUMMARY|VERDICT=|DEVICE_FINAL=|META |PICK ' "$D/device_run.txt" >"$D/SUMMARY.txt" || true
  if grep -q '^VERDICT=PASS' "$D/device_run.txt"; then
    echo ".$H PASS" | tee -a "$OUT/RUN.txt"
  else
    echo ".$H FAIL" | tee -a "$OUT/RUN.txt"
    fail_hosts="$fail_hosts $H"
  fi
done

for obs in 149 171; do
  ssh_key "$obs" "printf 'HOST=%s\n' $obs; date; ps -ax -o pid,rss,etime,command | grep -E 'SpringBoard.app/SpringBoard|TSDaemon' | grep -v grep" \
    >"$OUT/ts${obs}_end.txt" 2>&1 || echo OBSERVER_UNREACHABLE >"$OUT/ts${obs}_end.txt"
done

if [ -z "$fail_hosts" ]; then
  echo "VERDICT=PASS" | tee "$OUT/VERDICT.md"
else
  echo "VERDICT=FAIL hosts=$fail_hosts" | tee "$OUT/VERDICT.md"
fi
echo "OUT=$OUT"
