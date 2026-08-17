#!/usr/bin/env bash
# 冷启动 SB/backboardd 稳态门禁
# 用法：bash tools/zy_sb_cold_stable_gate.sh [101 112 166 ...]
# 判据：采样窗口内 SB 与 backboardd 同一 PID，etime 单调增加；无新增 userspace-panic。
# 默认窗口 600s（10min）；ZY_SB_STABLE_SEC 可改。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SEC="${ZY_SB_STABLE_SEC:-600}"
SAMPLE="${ZY_SB_SAMPLE_SEC:-30}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/SB_COLD_STABLE_${STAMP}"
mkdir -p "$OUT"

TAGS=("$@")
if [ "${#TAGS[@]}" -eq 0 ]; then
  TAGS=(101 112 166)
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)

ssh_r() {
  local ip="$1"; shift
  local i
  for i in 1 2 3 4; do
    if sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@"; then
      return 0
    fi
    sleep $((i * 2))
  done
  return 1
}

ip_of() {
  case "$1" in
    53) echo 192.168.31.53 ;;
    101) echo 192.168.31.101 ;;
    112) echo 192.168.31.112 ;;
    166) echo 192.168.31.166 ;;
    *) return 1 ;;
  esac
}

probe() {
  local ip="$1"
  ssh_r "$ip" 'SB=$(ps -axo pid,etime,args | grep "[S]pringBoard.app/SpringBoard" | head -1)
BB=$(ps -axo pid,etime,args | grep "[b]ackboardd" | grep -v grep | head -1)
PANIC_N=$(ls /var/mobile/Library/Logs/CrashReporter/userspace-panic-*.ips 2>/dev/null | wc -l | tr -d " ")
SB_IPS=$(ls -t /var/mobile/Library/Logs/CrashReporter/SpringBoard-*.ips 2>/dev/null | head -1)
echo "SB_LINE=$SB"
echo "BB_LINE=$BB"
echo "PANIC_N=$PANIC_N"
echo "SB_IPS=$SB_IPS"
'
}

parse_pid() {
  # "  2448  16:19 /System/..." or "2448 16:19 ..."
  sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]].*/\1/p' <<<"$1" | head -1
}

FAIL=0
for tag in "${TAGS[@]}"; do
  IP=$(ip_of "$tag") || { echo "VERDICT=FAIL tag=$tag reason=bad_tag"; FAIL=1; continue; }
  LOG="$OUT/${tag}.log"
  echo "META tag=$tag ip=$IP sec=$SEC sample=$SAMPLE" | tee "$LOG"
  if ! nc -z -G 3 "$IP" 22 2>/dev/null; then
    echo "VERDICT=FAIL tag=$tag reason=ssh_down" | tee -a "$LOG"
    FAIL=1
    continue
  fi
  FIRST=$(probe "$IP") || { echo "VERDICT=FAIL tag=$tag reason=probe0"; FAIL=1; continue; }
  echo "$FIRST" | tee -a "$LOG"
  SB0=$(echo "$FIRST" | sed -n 's/^SB_LINE=//p')
  BB0=$(echo "$FIRST" | sed -n 's/^BB_LINE=//p')
  P0=$(echo "$FIRST" | sed -n 's/^PANIC_N=//p')
  SPID=$(parse_pid "$SB0")
  BPID=$(parse_pid "$BB0")
  if [ -z "$SPID" ] || [ -z "$BPID" ]; then
    echo "VERDICT=FAIL tag=$tag reason=no_sb_or_bb" | tee -a "$LOG"
    FAIL=1
    continue
  fi
  echo "ANCHOR sb_pid=$SPID bb_pid=$BPID panic_n=$P0" | tee -a "$LOG"
  ELAPSED=0
  OK=1
  while [ "$ELAPSED" -lt "$SEC" ]; do
    sleep "$SAMPLE"
    ELAPSED=$((ELAPSED + SAMPLE))
    CUR=$(probe "$IP") || { OK=0; echo "FAIL probe_at=${ELAPSED}s" | tee -a "$LOG"; break; }
    echo "t=${ELAPSED}s $CUR" | tee -a "$LOG"
    SB=$(echo "$CUR" | sed -n 's/^SB_LINE=//p')
    BB=$(echo "$CUR" | sed -n 's/^BB_LINE=//p')
    PN=$(echo "$CUR" | sed -n 's/^PANIC_N=//p')
    SP=$(parse_pid "$SB")
    BP=$(parse_pid "$BB")
    if [ "$SP" != "$SPID" ] || [ "$BP" != "$BPID" ]; then
      echo "FAIL pid_changed at=${ELAPSED}s sb=$SP/$SPID bb=$BP/$BPID" | tee -a "$LOG"
      OK=0
      break
    fi
    if [ "${PN:-0}" -gt "${P0:-0}" ]; then
      echo "FAIL new_userspace_panic at=${ELAPSED}s" | tee -a "$LOG"
      OK=0
      break
    fi
  done
  if [ "$OK" -eq 1 ]; then
    echo "VERDICT=PASS tag=$tag sec=$SEC sb_pid=$SPID bb_pid=$BPID" | tee -a "$LOG"
  else
    echo "VERDICT=FAIL tag=$tag" | tee -a "$LOG"
    FAIL=1
  fi
done

echo "==== SUMMARY ====" | tee "$OUT/SUMMARY.txt"
for tag in "${TAGS[@]}"; do
  echo -n ".$tag " | tee -a "$OUT/SUMMARY.txt"
  grep '^VERDICT=' "$OUT/${tag}.log" | tail -1 | tee -a "$OUT/SUMMARY.txt"
done
echo "OUT=$OUT"
exit "$FAIL"
