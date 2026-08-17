#!/bin/bash
# Exact SpringBoard / backboardd PID verify.
# Never treat a line that merely CONTAINS "SpringBoard" as SpringBoard.
#
# Usage:
#   zy_sb_pid_verify.sh                     # local (usually FAIL on Mac)
#   zy_sb_pid_verify.sh 192.168.31.101      # remote SSH
#   zy_sb_pid_verify.sh --save FILE [host]
#   zy_sb_pid_verify.sh --compare BEFORE AFTER
#   zy_sb_pid_verify.sh --selftest
#
# Restart rule: PID change alone is not enough.
# SB_RESTART=YES only when SB_PID changes AND SB_LSTART changes
# (launch_time must move). Same PID + same LSTART = no restart.
set -u

MODE=run
SAVE=""
HOST=""
BEFORE=""
AFTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest; shift ;;
    --compare) MODE=compare; BEFORE="${2:-}"; AFTER="${3:-}"; shift 3 ;;
    --save) SAVE="${2:-}"; shift 2 ;;
    --help|-h)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      HOST="$1"
      shift
      ;;
  esac
done

SB_EXACT="/System/Library/CoreServices/SpringBoard.app/SpringBoard"
BB_EXACT="/usr/libexec/backboardd"

# Return 0 if LINE is exactly the SpringBoard binary with no extra tokens.
is_exact_sb() {
  local LINE="$1"
  case "$LINE" in
    *"$SB_EXACT")
      local TAIL="${LINE##*"$SB_EXACT"}"
      TAIL="${TAIL#"${TAIL%%[![:space:]]*}"}"
      [ -z "$TAIL" ]
      ;;
    *)
      return 1
      ;;
  esac
}

is_exact_bb() {
  local LINE="$1"
  case "$LINE" in
    *"$BB_EXACT")
      local TAIL="${LINE##*"$BB_EXACT"}"
      TAIL="${TAIL#"${TAIL%%[![:space:]]*}"}"
      [ -z "$TAIL" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# Reject helpers: crash reporter, xpcproxy, grep, path fragments.
is_false_sb() {
  local LINE="$1"
  case "$LINE" in
    *"SpringBoard"*)
      is_exact_sb "$LINE" && return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_selftest() {
  local FAIL=0
  pass() { echo "[PASS] $*"; }
  bad() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

  is_exact_sb "123 $SB_EXACT" && pass "exact SB accepted" || bad "exact SB rejected"
  is_exact_bb "456 $BB_EXACT" && pass "exact BB accepted" || bad "exact BB rejected"

  is_false_sb "789 /usr/sbin/syslogd SpringBoard helper" && pass "helper rejected" || bad "helper accepted"
  is_false_sb "790 /usr/libexec/xpcproxy SpringBoard" && pass "xpcproxy rejected" || bad "xpcproxy accepted"
  is_false_sb "791 grep SpringBoard" && pass "grep rejected" || bad "grep accepted"
  is_false_sb "792 $SB_EXACT -disableForNextLaunch" && pass "SB extra args rejected" || bad "SB extra args accepted"
  is_false_sb "793 /var/mobile/Library/Logs/CrashReporter/SpringBoard-2026.ips" && pass "ips path rejected" || bad "ips path accepted"
  is_exact_sb "794 /Applications/SpringBoard.app/SpringBoard" && bad "wrong SB path accepted" || pass "wrong SB path rejected"

  # compare rule
  TMPD=$(mktemp -d)
  printf 'SB_PID=100\nSB_LSTART=Sun Aug 16 18:00:00 2026\nBB_PID=200\nBB_LSTART=Sun Aug 16 18:00:01 2026\n' >"$TMPD/a"
  printf 'SB_PID=100\nSB_LSTART=Sun Aug 16 18:00:00 2026\nBB_PID=200\nBB_LSTART=Sun Aug 16 18:00:01 2026\n' >"$TMPD/b"
  OUTC=$("$0" --compare "$TMPD/a" "$TMPD/b")
  echo "$OUTC" | grep -q 'SB_RESTART=NO' && pass "same pid+lstart = no restart" || bad "same pid+lstart misclassified"
  printf 'SB_PID=101\nSB_LSTART=Sun Aug 16 18:00:00 2026\nBB_PID=200\nBB_LSTART=Sun Aug 16 18:00:01 2026\n' >"$TMPD/c"
  OUTC=$("$0" --compare "$TMPD/a" "$TMPD/c")
  echo "$OUTC" | grep -q 'SB_RESTART=NO' && pass "pid change without lstart change = NOT restart" || bad "pid-only change treated as restart"
  printf 'SB_PID=101\nSB_LSTART=Sun Aug 16 18:10:00 2026\nBB_PID=201\nBB_LSTART=Sun Aug 16 18:10:01 2026\n' >"$TMPD/d"
  OUTC=$("$0" --compare "$TMPD/a" "$TMPD/d")
  echo "$OUTC" | grep -q 'SB_RESTART=YES' && pass "pid+lstart change = restart" || bad "true restart missed"
  rm -rf "$TMPD"

  echo "-----"
  if [ "$FAIL" -eq 0 ]; then
    echo "SB_PID_VERIFY_SELFTEST=PASS"
    exit 0
  fi
  echo "SB_PID_VERIFY_SELFTEST=FAIL count=$FAIL"
  exit 1
}

kv() {
  local FILE="$1" KEY="$2"
  awk -F= -v k="$KEY" '$1==k {print substr($0,index($0,"=")+1); exit}' "$FILE"
}

run_compare() {
  if [ ! -f "$BEFORE" ] || [ ! -f "$AFTER" ]; then
    echo "SB_COMPARE=FAIL missing_file"
    echo "BEFORE=$BEFORE"
    echo "AFTER=$AFTER"
    exit 1
  fi
  local BP BA LP LA
  BP=$(kv "$BEFORE" SB_PID)
  BA=$(kv "$AFTER" SB_PID)
  LP=$(kv "$BEFORE" SB_LSTART)
  LA=$(kv "$AFTER" SB_LSTART)
  echo "SB_PID_BEFORE=$BP"
  echo "SB_PID_AFTER=$BA"
  echo "SB_LSTART_BEFORE=$LP"
  echo "SB_LSTART_AFTER=$LA"
  echo "BB_PID_BEFORE=$(kv "$BEFORE" BB_PID)"
  echo "BB_PID_AFTER=$(kv "$AFTER" BB_PID)"
  echo "BB_LSTART_BEFORE=$(kv "$BEFORE" BB_LSTART)"
  echo "BB_LSTART_AFTER=$(kv "$AFTER" BB_LSTART)"
  if [ -n "$BP" ] && [ -n "$BA" ] && [ "$BP" != "$BA" ] && [ -n "$LP" ] && [ -n "$LA" ] && [ "$LP" != "$LA" ]; then
    echo "SB_RESTART=YES"
    echo "SB_RESTART_RULE=pid_and_launch_time_changed"
  else
    echo "SB_RESTART=NO"
    if [ "$BP" != "$BA" ] && [ "$LP" = "$LA" ]; then
      echo "SB_RESTART_NOTE=pid_changed_but_lstart_same_do_not_treat_as_restart"
    fi
  fi
  echo "CRASHREPORTER_HINT=/var/mobile/Library/Logs/CrashReporter/*.ips"
  echo "SB_COMPARE=DONE"
}

if [ "$MODE" = selftest ]; then
  run_selftest
fi
if [ "$MODE" = compare ]; then
  run_compare
  exit 0
fi

remote() {
  if [ -n "$HOST" ]; then
    # Do not use ssh -n: the remote script is sent on stdin.
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null "root@$HOST" "bash -s"
  else
    bash -s
  fi
}

# Do not wrap this heredoc in $(...): a case-pattern ")" would terminate it.
_VERIFY_OUT=$(mktemp)
remote <<'END' >"$_VERIFY_OUT"
set +e
echo TIME=$(date '+%Y-%m-%d %H:%M:%S %z')
echo HOSTNAME=$(hostname 2>/dev/null)
echo RAW_PS_BEGIN
ps -ax -o pid=,lstart=,etime=,command= 2>/dev/null
echo RAW_PS_END

SB_EXACT="/System/Library/CoreServices/SpringBoard.app/SpringBoard"
BB_EXACT="/usr/libexec/backboardd"
SB_PID=; SB_N=0
BB_PID=; BB_N=0

while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  set -- $LINE
  PID=$1
  case "$PID" in
    ''|*[!0-9]*) continue ;;
  esac
  case "$LINE" in
    *"$SB_EXACT")
      TAIL=${LINE##*"$SB_EXACT"}
      TAIL=${TAIL#"${TAIL%%[![:space:]]*}"}
      if [ -n "$TAIL" ]; then
        echo REJECT_SB_EXTRA="$LINE"
        continue
      fi
      SB_N=$((SB_N + 1))
      SB_PID=$PID
      ;;
    *"$BB_EXACT")
      TAIL=${LINE##*"$BB_EXACT"}
      TAIL=${TAIL#"${TAIL%%[![:space:]]*}"}
      if [ -n "$TAIL" ]; then
        echo REJECT_BB_EXTRA="$LINE"
        continue
      fi
      BB_N=$((BB_N + 1))
      BB_PID=$PID
      ;;
    *[Ss]pring[Bb]oard*)
      echo REJECT_SB_SUBSTRING="$LINE"
      ;;
  esac
done <<EOF
$(ps -ax -o pid=,command= 2>/dev/null)
EOF

if [ -n "$SB_PID" ]; then
  set -- $(ps -p "$SB_PID" -o pid=,etime=,lstart= 2>/dev/null)
  echo SB_PID=$1
  echo SB_ETIME=$2
  shift 2
  echo SB_LSTART="$*"
fi
if [ -n "$BB_PID" ]; then
  set -- $(ps -p "$BB_PID" -o pid=,etime=,lstart= 2>/dev/null)
  echo BB_PID=$1
  echo BB_ETIME=$2
  shift 2
  echo BB_LSTART="$*"
fi
echo SB_MATCH_COUNT=$SB_N
echo BB_MATCH_COUNT=$BB_N
if [ "$SB_N" -eq 1 ] && [ "$BB_N" -eq 1 ]; then
  echo SB_PID_VERIFY=PASS
else
  echo SB_PID_VERIFY=FAIL
fi
echo CRASHREPORTER_DIR=/var/mobile/Library/Logs/CrashReporter
END

cat "$_VERIFY_OUT"
if [ -n "$SAVE" ]; then
  cat "$_VERIFY_OUT" >"$SAVE"
  echo SAVED="$SAVE"
fi
rm -f "$_VERIFY_OUT"
