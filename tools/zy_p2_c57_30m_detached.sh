#!/bin/bash
set -u

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUT="${1:-$ROOT/tmp_shots/P2_30M_C57_$(date +%Y%m%d_%H%M%S)}"
LAUNCH_LABEL="${2:-${ZY_P2_LAUNCHCTL_LABEL:-}}"
LOG="$OUT/SAMPLES.txt"
SUMMARY="$OUT/SUMMARY.txt"
META="$OUT/RUN_META.txt"
MINUTE_DIR="$OUT/minutes"
LOCK_DIR="$OUT/.p2_running"
COMPLETE="$OUT/.p2_complete"
ANALYZER="$SCRIPT_DIR/zy_p2_strict_analyze.sh"

EXPECTED_MINUTES=30

remove_launch_job() {
  if test -n "$LAUNCH_LABEL"; then
    launchctl remove "$LAUNCH_LABEL" >/dev/null 2>&1 || true
  fi
}

if test -f "$COMPLETE"; then
  # launchctl submit may start the program again after it exits. A completed
  # output directory is immutable: do not truncate or append to its evidence.
  remove_launch_job
  exit 0
fi

mkdir -p "$OUT" "$MINUTE_DIR"

if test -s "$LOG" && ! test -f "$META"; then
  echo "ERROR: refusing to reuse legacy output without RUN_META.txt: $OUT" >&2
  echo "Use a new output directory; the existing SAMPLES.txt was preserved." >&2
  remove_launch_job
  exit 2
fi

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

  # Recover only the explicit per-run lock; never remove the output directory.
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || {
    echo "ERROR: stale lock could not be recovered: $LOCK_DIR" >&2
    return 1
  }
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
  meta_tmp="$META.tmp.$$"
  {
    echo "FORMAT_VERSION=2"
    echo "START_TS=$(date '+%F %T')"
    echo "EXPECTED_MINUTES=$EXPECTED_MINUTES"
    echo "RUNNER=$0"
    echo "LAUNCH_LABEL=$LAUNCH_LABEL"
  } > "$meta_tmp"
  mv "$meta_tmp" "$META"
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
    log_minute=$((log_minute+1))
  done
  mv "$log_tmp" "$LOG"
}

ssh_one() {
  local ip="$1"
  shift
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 "root@$ip" "$@"
}

sample_101() {
  ssh_one 192.168.31.101 'bash -s' <<'REMOTE'
v=/usr/lib/ziyan/var
echo 1 > "$v/.ziyan_go_home"
i=0
while test "$i" -lt 80; do
  f=$(cat "$v/.ziyan_front_bid" 2>/dev/null)
  echo "$f" | grep -qi springboard && break
  sleep .05
  i=$((i+1))
done
rm -f "$v/.ziyan_go_home"
echo 1 > "$v/.ziyan_force_recap"
echo 1 > "$v/.ziyan_frame_req"
j=0
hok=0
hp=
hs=
while test "$j" -lt 24; do
  bid=$(cat "$v/.ziyan_shm_front_bid" 2>/dev/null)
  hp=$(od -An -t u1 -j 50 -N 1 "$v/.ziyan_frame_shm" 2>/dev/null | tr -d " ")
  hs=$(od -An -t u1 -j 51 -N 1 "$v/.ziyan_frame_shm" 2>/dev/null | tr -d " ")
  echo "$bid" | grep -qi springboard && test "$hs" = 0 && test "$hp" != 8 && {
    hok=1
    break
  }
  sleep .05
  j=$((j+1))
done
echo com.xztl.ios > "$v/.ziyan_open_app"
k=0
while test "$k" -lt 180; do
  f2=$(cat "$v/.ziyan_front_bid" 2>/dev/null)
  test "$f2" = com.xztl.ios && break
  sleep .05
  k=$((k+1))
done
rm -f "$v/.ziyan_open_app"
rm -f "$v/.ziyan_color_rep" "$v/.ziyan_app_frame_ack"
n=m30_$(date +%s)_$$
printf "getColor\n706\n449\n%s\n" "$n" > "$v/.ziyan_color_req.tmp"
mv "$v/.ziyan_color_req.tmp" "$v/.ziyan_color_req"
q=0
while test "$q" -lt 100; do
  test -f "$v/.ziyan_color_rep" && grep -q "$n" "$v/.ziyan_color_rep" && break
  sleep .02
  q=$((q+1))
done
col=$(sed -n 3p "$v/.ziyan_color_rep" 2>/dev/null)
ap=$(od -An -t u1 -j 50 -N 1 "$v/.ziyan_frame_shm" 2>/dev/null | tr -d " ")
as=$(od -An -t u1 -j 51 -N 1 "$v/.ziyan_frame_shm" 2>/dev/null | tr -d " ")
seq=$(od -An -t u4 -j 20 -N 4 "$v/.ziyan_frame_shm" 2>/dev/null | tr -d " ")
pass=0
test "$hok" = 1 && test "$j" -le 24 && test "$k" -le 24 && test "$q" -le 60 \
  && test "$col" = 12688231 && test "$ap" = 8 && test "$as" = 0 && pass=1
echo "ZY101 PASS=$pass HOME50=$j HP=$hp HS=$hs APP50=$k REQ20=$q COLOR=$col AP=$ap AS=$as SEQ=$seq"
ps -A -o pid=,rss=,%cpu=,command= | awk '
  /ziyan_framecap serve/ {
    print "ZY101_PROC ROLE=framecap PID=" $1 " RSS=" $2 " CPU=" $3
  }
  /SpringBoard[.]app\/SpringBoard/ {
    print "ZY101_PROC ROLE=SpringBoard PID=" $1 " RSS=" $2 " CPU=" $3
  }
  /FGCQLibClient-mobile[.]app\/FGCQLibClient-mobile/ {
    print "ZY101_PROC ROLE=App PID=" $1 " RSS=" $2 " CPU=" $3
  }
'
REMOTE
}

sample_171() {
  ssh_one 192.168.31.171 'bash -s' <<'REMOTE'
emit_processes() {
  phase="$1"
  ps -A -o pid=,rss=,%cpu=,command= | awk -v phase="$phase" '
    /TouchSprite[.]app\/TSDaemon/ {
      print "TS171_PROC PHASE=" phase " ROLE=TSDaemon PID=" $1 " RSS=" $2 " CPU=" $3
    }
    /TouchSprite[.]app\/Hades/ {
      print "TS171_PROC PHASE=" phase " ROLE=Hades PID=" $1 " RSS=" $2 " CPU=" $3
    }
    /SpringBoard[.]app\/SpringBoard/ {
      print "TS171_PROC PHASE=" phase " ROLE=SpringBoard PID=" $1 " RSS=" $2 " CPU=" $3
    }
    /FGCQLibClient-mobile[.]app\/FGCQLibClient-mobile/ {
      print "TS171_PROC PHASE=" phase " ROLE=App PID=" $1 " RSS=" $2 " CPU=" $3
    }
  '
}

emit_processes before
activator send libactivator.system.homebutton >/dev/null 2>&1 \
  || uiopen "activator://libactivator.system.homebutton" >/dev/null 2>&1 \
  || true
sleep 1
uiopen com.xztl.ios:// >/dev/null 2>&1 || true
sleep 1
emit_processes after
REMOTE
}

rebuild_log

minute=1
while test "$minute" -le "$EXPECTED_MINUTES"; do
  sample_file=$(printf '%s/%02d.sample' "$MINUTE_DIR" "$minute")
  if test -f "$sample_file" \
    && grep -q "^MINUTE=$minute " "$sample_file" \
    && grep -q "^MINUTE_END=$minute " "$sample_file"; then
    minute=$((minute+1))
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

  elapsed=$(( $(date +%s) - started ))
  remain=$((60-elapsed))
  {
    echo "MINUTE=$minute TS=$sample_ts"
    echo "ZY101_RC=$zy_rc"
    printf '%s\n' "$zy"
    echo "TS171_RC=$ts_rc"
    printf '%s\n' "$ts"
    echo "MINUTE_END=$minute ELAPSED=$elapsed SLEEP=$remain"
  } > "$sample_tmp"
  mv "$sample_tmp" "$sample_file"
  rebuild_log
  cat "$sample_file"

  if test "$minute" -lt "$EXPECTED_MINUTES" && test "$remain" -gt 0; then
    sleep "$remain"
  fi
  minute=$((minute+1))
done

rebuild_log
if test ! -x "$ANALYZER"; then
  echo "ERROR: strict analyzer is missing or not executable: $ANALYZER" >&2
  remove_launch_job
  exit 2
fi

if "$ANALYZER" "$LOG" "$SUMMARY"; then
  verdict_rc=0
else
  verdict_rc=$?
fi

complete_tmp="$COMPLETE.tmp.$$"
{
  echo "DONE_TS=$(date '+%F %T')"
  echo "SUMMARY=$SUMMARY"
  if test "$verdict_rc" -eq 0; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
} > "$complete_tmp"
mv "$complete_tmp" "$COMPLETE"

# launchctl submit jobs can be relaunched after normal exit. Remove the exact
# supplied label only after all evidence and the immutable completion marker
# have been atomically committed.
remove_launch_job
exit "$verdict_rc"
