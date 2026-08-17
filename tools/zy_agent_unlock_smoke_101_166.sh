#!/usr/bin/env bash
# Unlock + AgentSmoke on .101/.166 after ITER2 SB_RECOVERY_PASS. Isolated.
set -euo pipefail
if [ "${1:-}" != "--unlock-smoke" ]; then
  echo "only allowed: $0 --unlock-smoke" >&2
  exit 78
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
OUT="$ROOT/tmp_shots/AGENT_MVP_4PHONE_20260815_1"
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

unlock_one() {
  local tag="$1" ip="$2"
  ssh_r "$ip" "bash -s" >"$OUT/ITER2/$tag/unlock.txt" 2>&1 <<'EOS' || true
set +e
V=/usr/lib/ziyan/var
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_BEFORE=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_BEFORE=$1
HOOKS=$(tr '\n' ' ' < "$V/.ziyan_hooks")
echo HOOKS_SB_PID=$(printf '%s\n' "$HOOKS" | sed -n 's/.*sb_pid=\([0-9][0-9]*\).*/\1/p' | head -1)
echo FRONT_BEFORE=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
rm -f "$V/.ziyan_unlock_rep"
if [ ! -e "$V/.ziyan_project_active" ] && [ ! -e "$V/.ziyan_script_session" ]; then
  date +%s >"$V/.ziyan_project_active"
  chmod 666 "$V/.ziyan_project_active"
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
echo display_locked=$(tr -d '\r\n' < "$V/.ziyan_display_locked")
echo front=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
echo LOCK_STATE=$(tr -d '\r\n' < "$V/.ziyan_lock_state")
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_AFTER=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_AFTER=$1
echo elapsed_s=$(( $(date +%s) - START ))
EOS
  if grep -qi '^unlock_rep=ok' "$OUT/ITER2/$tag/unlock.txt"; then
    echo "AUTO_UNLOCK_PASS .$tag" | tee -a "$OUT/ITER2/$tag/unlock.txt"
    {
      echo "# AUTO_UNLOCK .$tag"
      echo
      echo '```'
      cat "$OUT/ITER2/$tag/unlock.txt"
      echo '```'
    } >"$OUT/AUTO_UNLOCK_$tag.md"
    return 0
  fi
  echo "AUTO_UNLOCK_FAIL .$tag" | tee -a "$OUT/ITER2/$tag/unlock.txt"
  {
    echo "# AUTO_UNLOCK .$tag"
    echo
    echo '```'
    cat "$OUT/ITER2/$tag/unlock.txt"
    echo '```'
  } >"$OUT/AUTO_UNLOCK_$tag.md"
  return 1
}

smoke_one() {
  local tag="$1" ip="$2"
  ssh_r "$ip" "bash -s" >"$OUT/ITER2/$tag/agent_smoke.txt" 2>&1 <<'EOS' || true
set +e
V=/usr/lib/ziyan/var
printf 'com.ziyan.ziyan\n' > "$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app"
FRONT_OK=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  FG=$(tr -d '\r\n' < "$V/.ziyan_front_bid")
  echo "wait_front t=$i front=$FG"
  echo "$FG" | grep -q 'com.ziyan.ziyan' && FRONT_OK=1 && break
  sleep 1
done
echo FRONT_OK=$FRONT_OK
/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua /usr/lib/ziyan/lib/lua/ziyan_agent_smoke.lua
echo SMOKE_RC=$?
echo SESSION=$(tr '\n' ' ' < "$V/.ziyan_agent_session")
echo FC=$(ps -ax -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep)
SBLINE=$(ps -axo pid=,args= | grep '[S]pringBoard.app/SpringBoard' | head -1)
set -- $SBLINE
echo SB_AFTER=$1
BBLINE=$(ps -axo pid=,args= | grep '[b]ackboardd' | grep -v SpringBoard | head -1)
set -- $BBLINE
echo BB_AFTER=$1
echo Z=$(ps -ax -o stat= | grep -c Z || true)
EOS
  if grep -q 'state=STOPPED' "$OUT/ITER2/$tag/agent_smoke.txt"; then
    echo "AGENT_SMOKE_PASS .$tag" | tee "$OUT/AGENT_SMOKE_$tag.md"
    return 0
  fi
  if grep -q 'PAUSED_SAFE' "$OUT/ITER2/$tag/agent_smoke.txt"; then
    echo "AGENT_SMOKE_PAUSED_SAFE .$tag" | tee "$OUT/AGENT_SMOKE_$tag.md"
    return 0
  fi
  echo "AGENT_SMOKE_FAIL .$tag" | tee "$OUT/AGENT_SMOKE_$tag.md"
  cat "$OUT/ITER2/$tag/agent_smoke.txt" >>"$OUT/AGENT_SMOKE_$tag.md"
  return 1
}

for spec in "101 192.168.31.101" "166 192.168.31.166"; do
  set -- $spec
  echo "== UNLOCK+SMOKE .$1 =="
  if unlock_one "$1" "$2"; then
    smoke_one "$1" "$2" || true
  else
    echo "AGENT_SMOKE_SKIP unlock_fail" | tee "$OUT/AGENT_SMOKE_$1.md"
  fi
done
