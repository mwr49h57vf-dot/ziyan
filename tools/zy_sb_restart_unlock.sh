#!/usr/bin/env bash
# Cleanup-first authorized SpringBoard restart and no-passcode unlock.
# Usage: bash tools/zy_sb_restart_unlock.sh <101|112|166|53>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?usage: $0 101|112|166|53}"
case "$TAG" in
  53) HOST=192.168.31.53; SCHEME=rootless; VAR=/var/jb/usr/lib/ziyan/var ;;
  101|112|166) HOST=192.168.31.$TAG; SCHEME=rootful; VAR=/usr/lib/ziyan/var ;;
  *) echo "unknown device .$TAG" >&2; exit 2 ;;
esac

OUT="$ROOT/tmp_shots/SB_RESTART_UNLOCK_$(date '+%Y%m%d_%H%M%S')_${TAG}_$$"
mkdir -p "$OUT"

# Always clear all ZiYan test devices before touching SpringBoard.
bash "$ROOT/tools/zy_pretest_clean_4phone.sh" >"$OUT/pretest.txt" 2>&1

PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o ServerAliveInterval=10 -o ServerAliveCountMax=6)
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$HOST" true >/dev/null 2>&1; then
  SSH=(ssh "${SSH_OPTS[@]}" "root@$HOST")
else
  SSH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$HOST")
fi

"${SSH[@]}" "SCHEME='$SCHEME' VAR='$VAR' TAG='$TAG' bash -s" >"$OUT/device.txt" <<'REMOTE'
set -euo pipefail
echo "DEVICE=.$TAG SCHEME=$SCHEME"
pid_for() {
  ps -A -o pid=,args= 2>/dev/null |
    grep -E "$1" | grep -v grep | sed 's/^ *//' | cut -d' ' -f1 | head -1
}
echo "PRE_SB=$(pid_for '/SpringBoard\.app/SpringBoard')"
echo "PRE_BB=$(pid_for '/backboardd')"
echo "PRE_FC_N=$(ps -A -o args= | grep -F 'ziyan_framecap serve' | grep -vc grep || true)"

# Test processes must be gone; the single framecap and zydaemon owner may stay.
if ps -A -o args= | grep -E 'ziyan_run\.lua|ios7\.lua|ios8p\.lua|lua5\.3.*ziyan_run|com\.xztl\.ios|com\.ljzbbadao\.game' | grep -v grep >/dev/null 2>&1; then
  echo 'RESTART_PRECONDITION=FAIL_TEST_PROCESS_REMAINS'
  ps -A -o pid=,args= | grep -E 'ziyan_run\.lua|ios7\.lua|ios8p\.lua|lua5\.3.*ziyan_run|com\.xztl\.ios|com\.ljzbbadao\.game' | grep -v grep || true
  exit 20
fi
for f in .ziyan_active .ziyan_keep_daemon .ziyan_embed_go .ziyan_touch_req .ziyan_bbtouch_req; do
  if [ -e "$VAR/$f" ]; then echo "RESTART_PRECONDITION=FAIL_RESIDUAL:$f"; exit 21; fi
done
echo 'RESTART_PRECONDITION=PASS'

if command -v sbreload >/dev/null 2>&1; then
  sbreload
  echo 'RESTART_METHOD=sbreload'
else
  killall -9 SpringBoard
  echo 'RESTART_METHOD=killall_SpringBoard'
fi
sleep 8

mkdir -p "$VAR"
date +%s >"$VAR/.ziyan_project_active"
rm -f "$VAR/.ziyan_unlock_rep"
printf '1\n' >"$VAR/.ziyan_unlock_req"
chmod 666 "$VAR/.ziyan_project_active" "$VAR/.ziyan_unlock_req" 2>/dev/null || true
unlock=0
for i in $(seq 1 30); do
  if [ -s "$VAR/.ziyan_unlock_rep" ] && grep -q '^ok$' "$VAR/.ziyan_unlock_rep"; then unlock=1; echo "AUTO_UNLOCK=PASS wait=$i"; break; fi
  sleep 0.5
done
rm -f "$VAR/.ziyan_unlock_req" "$VAR/.ziyan_project_active"
[ "$unlock" = 1 ] || { echo 'AUTO_UNLOCK=FAIL'; exit 22; }

POST_SB=$(pid_for '/SpringBoard\.app/SpringBoard')
POST_BB=$(pid_for '/backboardd')
LOCK=$(cat "$VAR/.ziyan_lock_state" 2>/dev/null || true)
FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null || true)
FC_N=$(ps -A -o args= | grep -F 'ziyan_framecap serve' | grep -vc grep || true)
echo "POST_SB=$POST_SB POST_BB=$POST_BB LOCK_STATE=$LOCK FRONT=$FRONT FC_N=$FC_N"
[ "$LOCK" = 0 ] || { echo 'AUTO_UNLOCK=FAIL_LOCK_STATE'; exit 23; }
[ "$FC_N" = 1 ] || { echo 'POSTCONDITION=FAIL_FC_N'; exit 24; }
echo 'VERDICT=SB_RESTART_UNLOCK_PASS'
REMOTE

cp "$OUT/device.txt" "$OUT/device_copy.txt"
cat >"$OUT/VERDICT.md" <<EOF
# SpringBoard restart and unlock

- device: .$TAG
- pretest: $OUT/pretest.txt
- device evidence: $OUT/device.txt
- policy: cleanup-first, authorized restart, no-passcode unlock
EOF
if grep -q 'VERDICT=SB_RESTART_UNLOCK_PASS' "$OUT/device.txt"; then
  echo 'VERDICT=SB_RESTART_UNLOCK_PASS' | tee -a "$OUT/VERDICT.md"
else
  echo 'VERDICT=SB_RESTART_UNLOCK_FAIL' | tee -a "$OUT/VERDICT.md"
  exit 1
fi
echo "OUT=$OUT"
