#!/bin/bash
# C87 Gate C 30-minute detached runner for .112 (temp adapter from c87) (real Home each minute).
# .171 is read-only Home/process observe only. Survives chat disconnect via launchctl.
set -u

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUT="${1:-$ROOT/tmp_shots/P2_30M_C88_$(date +%Y%m%d_%H%M%S)}"
LAUNCH_LABEL="${2:-${ZY_P2_LAUNCHCTL_LABEL:-}}"
LOG="$OUT/SAMPLES.txt"
SUMMARY="$OUT/SUMMARY.txt"
META="$OUT/RUN_META.txt"
MINUTE_DIR="$OUT/minutes"
LOCK_DIR="$OUT/.p2_running"
COMPLETE="$OUT/.p2_complete"

EXPECTED_MINUTES="${ZY_P2_EXPECTED_MINUTES:-30}"
EXPECTED_COLOR=12688231
EXPECTED_APP=com.xztl.ios

remove_launch_job() {
  if test -n "$LAUNCH_LABEL"; then
    launchctl remove "$LAUNCH_LABEL" >/dev/null 2>&1 || true
  fi
}

if test -f "$COMPLETE"; then
  remove_launch_job
  exit 0
fi

mkdir -p "$OUT" "$MINUTE_DIR"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if test -n "$old_pid" && kill -0 "$old_pid" 2>/dev/null; then
    echo "ERROR: P2 run already active: pid=$old_pid out=$OUT" >&2
    return 1
  fi
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" || return 1
  echo "$$" > "$LOCK_DIR/pid"
}

cleanup_lock() {
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

if ! acquire_lock; then
  exit 75
fi
trap cleanup_lock EXIT
trap 'exit 130' HUP INT TERM

if ! test -f "$META"; then
  {
    echo "FORMAT_VERSION=2"
    echo "GATE=C87_GATE_C_30M"
    echo "START_TS=$(date '+%F %T')"
    echo "EXPECTED_MINUTES=$EXPECTED_MINUTES"
    echo "EXPECTED_COLOR=$EXPECTED_COLOR"
    echo "RUNNER=$0"
    echo "LAUNCH_LABEL=$LAUNCH_LABEL"
  } > "$META.tmp.$$"
  mv "$META.tmp.$$" "$META"
fi

rebuild_log() {
  log_tmp="$LOG.tmp.$$"
  cp "$META" "$log_tmp"
  log_minute=1
  while test "$log_minute" -le "$EXPECTED_MINUTES"; do
    log_sample=$(printf '%s/%02d.sample' "$MINUTE_DIR" "$log_minute")
    if test -f "$log_sample"; then
      cat "$log_sample" >> "$log_tmp"
    fi
    log_minute=$((log_minute + 1))
  done
  mv "$log_tmp" "$LOG"
}

ssh_one() {
  local ip="$1"
  shift
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    "root@$ip" "$@"
}

sample_101() {
  ssh_one 192.168.31.112 "EXPECTED_COLOR='$EXPECTED_COLOR' EXPECTED_APP='$EXPECTED_APP' bash -s" <<'REMOTE'
set +e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
V=/usr/lib/ziyan/var
APP="${EXPECTED_APP:-com.xztl.ios}"
EXP="${EXPECTED_COLOR:-12688231}"

od1(){ od -An -t u1 -j "$2" -N 1 "$1" 2>/dev/null | tr -d ' \n'; }
od4(){ od -An -t u4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' \n'; }
# 计数必须排除探活用的 `grep -F ziyan_framecap serve`：其 argv 含子串
# `ziyan_framecap serve`，裸 grep -c 会在与 zydaemon/wrap 探活撞车时误报 FCN=2
# （C88 第17分 FAIL：功能全绿、PID 不变、exit_hist 无新 start，实拍已复现）。
pid_of(){ ps -axo pid=,args= | grep "$1" | grep -v grep | head -1 | sed 's/^ *//;s/ .*//'; }
fc_n(){ sleep 0.5; ps -axo args= | grep '[z]iyan_framecap serve' | grep -v grep | wc -l | tr -dc '0-9'; }

get_color(){
  rm -f "$V/.ziyan_color_rep"
  n=$1_$(date +%s)_$$
  printf "getColor\n706\n449\n%s\n" "$n" >"$V/.ziyan_color_req.tmp"
  mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
  q=0
  while test "$q" -lt 100; do
    test -f "$V/.ziyan_color_rep" && grep -q "$n" "$V/.ziyan_color_rep" && break
    sleep 0.05
    q=$((q+1))
  done
  COL=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null)
  AP=$(od1 "$V/.ziyan_frame_shm" 50)
  AS=$(od1 "$V/.ziyan_frame_shm" 51)
  SEQ=$(od4 "$V/.ziyan_frame_shm" 20)
  REQ=$q
}

SB0=$(pid_of 'SpringBoard.app/SpringBoard')
FC0=$(pid_of 'ziyan_framecap serve')
BB0=$(pid_of 'backboardd')
APP0=$(pid_of 'FGCQLibClient-mobile')
FCN0=$(fc_n)

# --- HOME ---
rm -f "$V/.ziyan_open_app" /private/var/mobile/Media/ZiYan/.ziyan_open_app
t0=$(date +%s)
printf '1\n' >"$V/.ziyan_go_home"
chmod 666 "$V/.ziyan_go_home" 2>/dev/null
i=0; HOK=0
while test "$i" -lt 80; do
  f=$(cat "$V/.ziyan_front_bid" 2>/dev/null)
  echo "$f" | grep -qi springboard && { HOK=1; break; }
  sleep 0.05
  i=$((i+1))
done
t1=$(date +%s)
HOME_MS=$(( (t1-t0)*1000 ))
sleep 4.5
FS=$(cat "$V/.ziyan_front_bid" 2>/dev/null)
HP=$(od1 "$V/.ziyan_frame_shm" 50)
HS=$(od1 "$V/.ziyan_frame_shm" 51)
if test "$HP" = 8; then
  echo 1 >"$V/.ziyan_force_recap"
  printf 'force=1\n' >"$V/.ziyan_frame_req"
  sleep 0.8
  HP=$(od1 "$V/.ziyan_frame_shm" 50)
  HS=$(od1 "$V/.ziyan_frame_shm" 51)
fi
echo "$FS" | grep -qi springboard || HOK=0
test "$HP" != 8 || HOK=0

# --- BACK APP + COLOR ---
k=0; AOK=0
while test "$k" -lt 30; do
  printf '%s\n' "$APP" >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  sleep 1.2
  rm -f "$V/.ziyan_open_app" /private/var/mobile/Media/ZiYan/.ziyan_open_app
  sleep 0.8
  get_color m30a
  f2=$(cat "$V/.ziyan_front_bid" 2>/dev/null)
  if test "$f2" = "$APP" && test "$COL" = "$EXP" && test "$AP" = 8 && test "$AS" = 0; then
    AOK=1
    break
  fi
  k=$((k+1))
done

SB1=$(pid_of 'SpringBoard.app/SpringBoard')
FC1=$(pid_of 'ziyan_framecap serve')
BB1=$(pid_of 'backboardd')
APP1=$(pid_of 'FGCQLibClient-mobile')
FCN1=$(fc_n)

pass=0
test "$HOK" = 1 && test "$AOK" = 1 && test "$HOME_MS" -le 5000 \
  && test "$SB1" = "$SB0" && test "$FC1" = "$FC0" && test "$BB1" = "$BB0" \
  && test -n "$APP1" && test "$FCN1" = 1 && pass=1

echo "ZY101 PASS=$pass HOK=$HOK HOME_MS=$HOME_MS HP=$HP HS=$HS AOK=$AOK APP_RETRY=$k COLOR=$COL AP=$AP AS=$AS SEQ=$SEQ REQ=$REQ FCN=$FCN1"
echo "ZY101_PROC ROLE=framecap PID=$FC1"
echo "ZY101_PROC ROLE=SpringBoard PID=$SB1"
echo "ZY101_PROC ROLE=backboardd PID=$BB1"
echo "ZY101_PROC ROLE=App PID=$APP1"
REMOTE
}

sample_171() {
  ssh_one 192.168.31.171 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin; bash -s' <<'REMOTE'
set +e
emit() {
  phase="$1"
  ps -axo pid=,rss=,%cpu=,args= | while read -r pid rss cpu args; do
    case "$args" in
      *TouchSprite.app/TSDaemon*)
        echo "TS171_PROC PHASE=$phase ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu" ;;
      *TouchSprite.app/Hades*)
        echo "TS171_PROC PHASE=$phase ROLE=Hades PID=$pid RSS=$rss CPU=$cpu" ;;
      *SpringBoard.app/SpringBoard*)
        echo "TS171_PROC PHASE=$phase ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu" ;;
      *FGCQLibClient-mobile*)
        echo "TS171_PROC PHASE=$phase ROLE=App PID=$pid RSS=$rss CPU=$cpu" ;;
    esac
  done
}
emit before
activator send libactivator.system.homebutton >/dev/null 2>&1 \
  || uiopen 'activator://libactivator.system.homebutton' >/dev/null 2>&1 \
  || true
sleep 1
uiopen 'com.xztl.ios://' >/dev/null 2>&1 || true
sleep 1
emit after
REMOTE
}

rebuild_log

minute=1
fail_minute=0
pass_n=0
while test "$minute" -le "$EXPECTED_MINUTES"; do
  sample_file=$(printf '%s/%02d.sample' "$MINUTE_DIR" "$minute")
  if test -f "$sample_file" \
    && grep -q "^MINUTE=$minute " "$sample_file" \
    && grep -q "^MINUTE_END=$minute " "$sample_file"; then
    if grep -q 'ZY101 PASS=1' "$sample_file"; then
      pass_n=$((pass_n + 1))
    elif test "$fail_minute" = 0; then
      fail_minute=$minute
    fi
    minute=$((minute + 1))
    continue
  fi

  sample_tmp="$sample_file.tmp.$$"
  rm -f "$sample_tmp"
  started=$(date +%s)
  sample_ts=$(date '+%F %T')

  if zy=$(sample_101 2>&1); then
    zy_rc=0
  else
    zy_rc=$?
    zy="$zy
ZY101 SSH_FAIL RC=$zy_rc"
  fi

  if ts=$(sample_171 2>&1); then
    ts_rc=0
  else
    ts_rc=$?
    ts="$ts
TS171 SSH_FAIL RC=$ts_rc"
  fi

  {
    echo "MINUTE=$minute TS=$sample_ts"
    echo "ZY101_RC=$zy_rc"
    printf '%s\n' "$zy"
    echo "TS171_RC=$ts_rc"
    printf '%s\n' "$ts"
    echo "MINUTE_END=$minute"
  } > "$sample_tmp"
  mv "$sample_tmp" "$sample_file"

  if echo "$zy" | grep -q 'ZY101 PASS=1'; then
    pass_n=$((pass_n + 1))
  else
    if test "$fail_minute" = 0; then
      fail_minute=$minute
    fi
    # Gate C: stop on first FAIL (do not glue partial 30m)
    rebuild_log
    {
      echo "END_TS=$(date '+%F %T')"
      echo "PASS_N=$pass_n"
      echo "EXPECTED_MINUTES=$EXPECTED_MINUTES"
      echo "FIRST_FAIL_MINUTE=$fail_minute"
      echo "VERDICT=FAIL"
    } > "$SUMMARY"
    rebuild_log
    remove_launch_job
    touch "$COMPLETE"
    exit 1
  fi

  rebuild_log
  elapsed=$(( $(date +%s) - started ))
  remain=$((60 - elapsed))
  if test "$remain" -gt 0; then
    sleep "$remain"
  fi
  minute=$((minute + 1))
done

rebuild_log
{
  echo "END_TS=$(date '+%F %T')"
  echo "PASS_N=$pass_n"
  echo "EXPECTED_MINUTES=$EXPECTED_MINUTES"
  if test "$pass_n" -eq "$EXPECTED_MINUTES"; then
    echo "VERDICT=PASS"
  else
    echo "FIRST_FAIL_MINUTE=$fail_minute"
    echo "VERDICT=FAIL"
  fi
} > "$SUMMARY"
remove_launch_job
touch "$COMPLETE"
test "$pass_n" -eq "$EXPECTED_MINUTES"
