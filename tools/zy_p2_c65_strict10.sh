#!/usr/bin/env bash
# C80 P2 strict gate for one explicitly selected ZiYan target, with a Home-only
# foreground/E2E reference on .171.  Internal evidence filenames retain the
# historical `101.txt` schema so existing analyzers remain compatible.
#
# This gate stops after the first failed round, but the remote round itself
# always runs a phase-aware diagnostic tail.  Unreached phases are NOT_RUN,
# while all reached-stage evidence is preserved before the 30-minute gate is
# prevented from starting.
set -u

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
TARGET_TAG="${ZY_P2_TARGET_TAG:-112}"
case "$TARGET_TAG" in 101|112|166) ;; *) echo "ERROR: invalid ZY_P2_TARGET_TAG=$TARGET_TAG" >&2; exit 2 ;; esac
IP101="${ZY_P2_TARGET_IP:-${ZY_P2_IP101:-192.168.31.$TARGET_TAG}}"
IP171="${ZY_P2_IP171:-192.168.31.171}"
ROUNDS="${ZY_P2_ROUNDS:-10}"
LIVE_FRONT_PROBE_OVERRIDE="${ZY_P2_LIVE_FRONT_PROBE:-}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${1:-$ROOT/tmp_shots/C80_STRICT_10R_${STAMP}_${TARGET_TAG}}"
LOG="$OUT/ROUNDS.txt"
SUMMARY="$OUT/SUMMARY.txt"

EXPECTED_VERSION="0.0.92-8-161-205-C-65.11-80+debug-3+debug"
EXPECTED_DEB_SHA="185e4149ca4d8b45819e387fb0b33556ea71b05aba43162f43f3e0c99c466fe8"
EXPECTED_DEVICE_FRAMECAP_SHA="65384d7e0e5f5735f86a03c7979d934a3254d7caf8cb71997ade8a70bb38518d"
EXPECTED_TARGET_UDID="${ZY_P2_TARGET_UDID:-}"
EXPECTED_IOS7_SHA="0a6325ca9a091a864a6c8e6e226be2dc952e39890c833702652b51a09ea55d3c"
EXPECTED_PATTERN_A="p48aa944a"
EXPECTED_PATTERN_B="p5cd58dc5"
EXPECTED_API_HEADER="wall_ms,find_ms,cycle_ms,x,y,hit,front_bid,mono_ms,api_seq,op,clock,embed,vm_gen,via,pattern_id,main,fuzzy,x1,y1,x2,y2,color,point_count,dropped_get"
EXPECTED_COLOR="12688231"
EXPECTED_APP="com.xztl.ios"
EXPECTED_HOME="com.apple.springboard"
MAX_MS=1200
TOAST_DURATION_MS=6000
TOAST_MAX_MS=8000
HOME_STABLE_MS=4500
MAX_ZIYAN_CORE_CPU_PCT=200
MAX_ZIYAN_CORE_RSS_KB=131072
MAX_ZIYAN_RSS_OLS_KB_PER_MIN=256
RESOURCE_CPU_TOL_PCT=1.0
RESOURCE_RSS_TOL_KB=1024
RESOURCE_OLS_TOL_KB_PER_MIN=64

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ConnectTimeout=8
          -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

# The independent foreground helper is intentionally allow-listed. It must be
# an already-installed, read-only binary accepting `front` and printing exactly
# `front=<bundle-id>`; no shell fragment is accepted here.
case "$LIVE_FRONT_PROBE_OVERRIDE" in
  ''|/*) ;;
  *) echo "ERROR: ZY_P2_LIVE_FRONT_PROBE must be an absolute path" >&2; exit 2 ;;
esac
case "$LIVE_FRONT_PROBE_OVERRIDE" in
  *[!A-Za-z0-9_./-]*)
    echo "ERROR: unsafe ZY_P2_LIVE_FRONT_PROBE path" >&2
    exit 2
    ;;
esac

ssh_one() {
  local ip="$1"
  shift
  # All callers pass one internally-built remote command. The override was
  # validated above, so exporting it cannot inject shell syntax.
  local remote_cmd="$*"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" \
    "ZY_P2_LIVE_FRONT_PROBE='$LIVE_FRONT_PROBE_OVERRIDE' $remote_cmd"
}

scp_from() {
  local ip="$1" remote="$2" local_path="$3"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "root@$ip:$remote" "$local_path"
}

# macOS has no guaranteed `timeout(1)`. Run host-side USB/Vision commands in a
# separate process group and terminate the whole group on timeout or signal, so
# a wedged usbmux/Vision call cannot hang the gate or survive as an orphan.
run_host_timeout() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
args = sys.argv[2:]
if timeout <= 0 or not args:
    raise SystemExit(126)
p = subprocess.Popen(args, start_new_session=True)

def stop_group(_signum=None, _frame=None):
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()

signal.signal(signal.SIGINT, stop_group)
signal.signal(signal.SIGTERM, stop_group)
try:
    rc = p.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    stop_group()
    raise SystemExit(124)
raise SystemExit(rc)
PY
}

cleanup_gate_state() {
  if [ -n "${TOAST_WATCH_PID:-}" ]; then
    kill "$TOAST_WATCH_PID" >/dev/null 2>&1 || true
    wait "$TOAST_WATCH_PID" 2>/dev/null || true
    TOAST_WATCH_PID=""
  fi
  # Cleanup is deliberately limited to the selected target's request and
  # instrumentation files.
  # Evidence files stay intact for postmortem; .171 remains unmodified except
  # for the user-authorized Home/minimize action performed by sample_171.
  ssh_one "$IP101" \
    "rm -f /usr/lib/ziyan/var/.ziyan_go_home /usr/lib/ziyan/var/.ziyan_open_app /usr/lib/ziyan/var/.ziyan_open_app.tmp /usr/lib/ziyan/var/.ziyan_p2_native_front_fast /usr/lib/ziyan/var/.ziyan_p2_toast_visual /usr/lib/ziyan/var/.ziyan_embed_api_probe /usr/lib/ziyan/var/.ziyan_embed_api_probe.tmp /usr/lib/ziyan/var/.ziyan_cmd.p2.*" \
    >/dev/null 2>&1 || true
}
trap cleanup_gate_state EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

kv() {
  local key="$1" file="$2"
  sed -n "s/^${key}=//p" "$file" | tail -1 | tr -d '\r'
}

proc_pid() {
  local role="$1" phase="$2" file="$3"
  sed -n "s/^PROC PHASE=${phase} ROLE=${role} COUNT=1 PID=\([0-9][0-9]*\).*/\1/p" "$file" | tail -1
}

proc_count() {
  local role="$1" phase="$2" file="$3"
  sed -n "s/^PROC PHASE=${phase} ROLE=${role} COUNT=\([0-9][0-9]*\).*/\1/p" "$file" | tail -1
}

proc_metric() {
  local role="$1" phase="$2" metric="$3" file="$4"
  awk -v wanted_role="$role" -v wanted_phase="$phase" -v wanted_metric="$metric" '
    $0 ~ ("^PROC PHASE=" wanted_phase " ROLE=" wanted_role " ") {
      for (i = 1; i <= NF; i++) {
        if ($i ~ ("^" wanted_metric "=")) {
          sub("^[^=]*=", "", $i)
          print $i
          exit
        }
      }
    }
  ' "$file"
}

write_verdict() {
  local verdict="$1" reason="$2"
  local summary_tmp="$SUMMARY.tmp.$$"
  if ! {
    echo "GATE=ZY_P2_C80_STRICT10_V7"
    echo "TARGET_TAG=$TARGET_TAG"
    echo "TARGET_IP=$IP101"
    echo "FINISHED_TS=$(date '+%F %T %z')"
    echo "EXPECTED_ROUNDS=$ROUNDS"
    echo "COMPLETED_ROUNDS=$completed"
    echo "VERDICT=$verdict"
    echo "REASON=$reason"
    echo "LUAEMBED_FIND_RELEASE_EVIDENCE=embed_api_csv+shadow+resident_ticket_balance"
    echo "LUAEMBED_GETCOLOR_COVERAGE=SHADOW_REQUIRED_NATURAL_REPORTED_IF_PRESENT"
    echo "EVIDENCE=$OUT"
  } >"$summary_tmp"; then
    echo "ERROR: failed to write verdict evidence: $summary_tmp" >&2
    return 1
  fi
  if ! mv "$summary_tmp" "$SUMMARY"; then
    echo "ERROR: failed to publish verdict evidence: $SUMMARY" >&2
    return 1
  fi
  echo "VERDICT=$verdict REASON=$reason OUT=$OUT"
}

case "$ROUNDS" in
  ''|*[!0-9]*) echo "ERROR: invalid ZY_P2_ROUNDS=$ROUNDS" >&2; exit 2 ;;
esac
[ "$ROUNDS" -ge 1 ] || { echo "ERROR: rounds must be >=1" >&2; exit 2; }

if [ -e "$OUT" ] && find "$OUT" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "ERROR: refusing to overwrite non-empty evidence directory: $OUT" >&2
  exit 2
fi
mkdir -p "$OUT/rounds"
: >"$LOG"
completed=0

TOAST_VISUAL_TOOL="$OUT/zy_toast_visual_gate"
for required_tool in idevice_id idevicescreenshot xcrun curl python3; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    write_verdict FAIL "missing_host_tool_${required_tool}" || true
    exit 1
  fi
done
if ! run_host_timeout 10 idevice_id -l >"$OUT/USB_UDIDS.txt" \
     2>"$OUT/USB_UDIDS.err"; then
  write_verdict FAIL "usb_enumeration_timeout_or_error" || true
  exit 1
fi
if [ -z "$EXPECTED_TARGET_UDID" ]; then
  usb_count=$(sed '/^[[:space:]]*$/d' "$OUT/USB_UDIDS.txt" | wc -l | tr -d ' ')
  if [ "$usb_count" = 1 ]; then
    EXPECTED_TARGET_UDID=$(sed '/^[[:space:]]*$/d' "$OUT/USB_UDIDS.txt" | head -1 | tr -d '\r')
  else
    write_verdict FAIL "usb_${TARGET_TAG}_udid_not_configured_count_${usb_count}" || true
    exit 1
  fi
fi
if ! grep -Fxq "$EXPECTED_TARGET_UDID" "$OUT/USB_UDIDS.txt"; then
  write_verdict FAIL "usb_${TARGET_TAG}_udid_not_present" || true
  exit 1
fi
if ! run_host_timeout 60 xcrun swiftc "$ROOT/tools/zy_toast_visual_gate.swift" \
     -o "$TOAST_VISUAL_TOOL" >"$OUT/toast_visual_build.log" 2>&1; then
  write_verdict FAIL "toast_visual_helper_build" || true
  exit 1
fi
if ! run_host_timeout 20 idevicescreenshot -u "$EXPECTED_TARGET_UDID" "$OUT/BASELINE_TARGET_USB.png" \
     >"$OUT/BASELINE_TARGET_USB_CAPTURE.txt" 2>&1; then
  write_verdict FAIL "usb_screenshot_service_unavailable" || true
  exit 1
fi
if ! python3 - "$OUT/BASELINE_TARGET_USB.png" <<'PY'
from PIL import Image, ImageStat
import sys
try:
    with Image.open(sys.argv[1]) as im:
        im.load()
        rgb = im.convert("RGB")
        ok = rgb.width >= 320 and rgb.height >= 320 and max(ImageStat.Stat(rgb).stddev) >= 1.0
except Exception:
    ok = False
raise SystemExit(0 if ok else 1)
PY
then
  write_verdict FAIL "usb_screenshot_invalid" || true
  exit 1
fi

DEB="$ROOT/packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-80+debug-3+debug_iphoneos-arm.deb"
LOCAL_DEB_SHA="$(shasum -a 256 "$DEB" 2>/dev/null | awk '{print $1}')"

cat >"$OUT/RUN_META.txt" <<META
GATE=ZY_P2_C80_STRICT10_V7
START_TS=$(date '+%F %T %z')
ROUNDS=$ROUNDS
TARGET_TAG=$TARGET_TAG
TARGET_IP=$IP101
IP101=$IP101
IP171=$IP171
EXPECTED_VERSION=$EXPECTED_VERSION
EXPECTED_DEB_SHA=$EXPECTED_DEB_SHA
EXPECTED_DEVICE_FRAMECAP_SHA=$EXPECTED_DEVICE_FRAMECAP_SHA
EXPECTED_TARGET_UDID=$EXPECTED_TARGET_UDID
TARGET_EVIDENCE_SCHEMA=rounds/*/101.txt
EXPECTED_IOS7_SHA=$EXPECTED_IOS7_SHA
EXPECTED_PATTERN_A=$EXPECTED_PATTERN_A
EXPECTED_PATTERN_B=$EXPECTED_PATTERN_B
EXPECTED_API_HEADER=$EXPECTED_API_HEADER
LOCAL_DEB=$DEB
LOCAL_DEB_SHA=$LOCAL_DEB_SHA
EXPECTED_COLOR=$EXPECTED_COLOR
MAX_MS=$MAX_MS
TOAST_MAX_MS=$TOAST_MAX_MS
TOAST_DURATION_MS=$TOAST_DURATION_MS
HOME_STABLE_MS=$HOME_STABLE_MS
MAX_ZIYAN_CORE_CPU_PCT=$MAX_ZIYAN_CORE_CPU_PCT
MAX_ZIYAN_CORE_RSS_KB=$MAX_ZIYAN_CORE_RSS_KB
MAX_ZIYAN_RSS_OLS_KB_PER_MIN=$MAX_ZIYAN_RSS_OLS_KB_PER_MIN
RESOURCE_CPU_TOL_PCT=$RESOURCE_CPU_TOL_PCT
RESOURCE_RSS_TOL_KB=$RESOURCE_RSS_TOL_KB
RESOURCE_OLS_TOL_KB_PER_MIN=$RESOURCE_OLS_TOL_KB_PER_MIN
LUAEMBED_FIND_RELEASE_EVIDENCE=embed_api_csv+shadow+resident_ticket_balance
LUAEMBED_GETCOLOR_COVERAGE=SHADOW_REQUIRED_NATURAL_REPORTED_IF_PRESENT
GIT_HEAD=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
META

if [ "$LOCAL_DEB_SHA" != "$EXPECTED_DEB_SHA" ]; then
  completed=0
  write_verdict FAIL "local_deb_sha_mismatch"
  exit 1
fi

REMOTE_HELPERS=$(cat <<'REMOTE'
V=/usr/lib/ziyan/var

now_ms() {
  # EPOCHREALTIME is wall-clock, not monotonic. elapsed_ms rejects a backwards
  # adjustment. Do not fall back to seconds-resolution time: that would silently
  # turn a 1200 ms gate into a 1200 s gate.
  local raw="${EPOCHREALTIME-}"
  raw="${raw/./}"
  if printf '%s\n' "$raw" | grep -Eq '^[0-9]{15,}$'; then
    printf '%s\n' "${raw:0:13}"
  else
    return 1
  fi
}

elapsed_ms() {
  start="$1"
  now="$(now_ms)" || { echo -1; return; }
  printf '%s\n' "$start" | grep -Eq '^[0-9]+$' || { echo -1; return; }
  printf '%s\n' "$now" | grep -Eq '^[0-9]+$' || { echo -1; return; }
  [ "$now" -ge "$start" ] || { echo -1; return; }
  echo $((now-start))
}

# Foreground lifecycle evidence is deliberately separate from front_bid and
# shm_bid, which are ZiYan's frame-routing IPC files.  A caller may provide an
# installed read-only probe; otherwise the gate reads App didBecomeActive /
# didEnterBackground evidence plus AX sampling.  Home also requires a new
# provider-7 frame and a 4.5s no-rebound window, so lifecycle alone cannot pass.
ZY_P2_LIVE_FRONT_PROBE_FOUND=""
for _zy_probe in "${ZY_P2_LIVE_FRONT_PROBE:-}" \
                 /usr/lib/ziyan/bin/open_transition_probe \
                 /usr/lib/ziyan/bin/ziyan_front_probe; do
  if [ -n "$_zy_probe" ] && [ -x "$_zy_probe" ]; then
    ZY_P2_LIVE_FRONT_PROBE_FOUND="$_zy_probe"
    break
  fi
done
unset _zy_probe

live_front_probe_available() {
  [ -n "${ZY_P2_LIVE_FRONT_PROBE_FOUND:-}" ]
}

live_front_probe_label() {
  if live_front_probe_available; then
    printf '%s\n' "$ZY_P2_LIVE_FRONT_PROBE_FOUND"
  elif [ -r "$V/.ziyan_sb_native_front_bid" ]; then
    printf '%s\n' "$V/.ziyan_sb_native_front_bid"
  else
    printf '%s\n' unavailable
  fi
}

run_live_front_probe() {
  local out="$V/.ziyan_p2_front_probe.$$" probe_pid watchdog_pid rc
  rm -f "$out"
  "$ZY_P2_LIVE_FRONT_PROBE_FOUND" front >"$out" 2>/dev/null &
  probe_pid=$!
  (
    sleep 1
    kill -TERM "$probe_pid" 2>/dev/null || exit 0
    sleep .2
    kill -KILL "$probe_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  wait "$probe_pid" 2>/dev/null
  rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [ "$rc" = 0 ]; then
    cat "$out" 2>/dev/null
  fi
  rm -f "$out"
  return "$rc"
}

native_front_field() {
  sed -n "s/^$1=//p" "$V/.ziyan_sb_native_front_bid" 2>/dev/null |
    head -1 | tr -d '\r'
}

live_front_bid_after() {
  local minimum_ts="${1:-0}" raw bid ts source now max_age
  if live_front_probe_available; then
    raw="$(run_live_front_probe 2>/dev/null)" || raw=""
    bid="$(printf '%s\n' "$raw" | sed -n 's/^front=//p' | head -1 |
      tr -d '\r' | tr -d '[:space:]')"
    if printf '%s\n' "$bid" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]+$'; then
      printf '%s\n' "$bid"
      return 0
    fi
  fi

  ts="$(native_front_field ts_ms)"
  bid="$(native_front_field bid)"
  source="$(native_front_field source)"
  printf '%s\n' "$minimum_ts:$ts" | grep -Eq '^[0-9]+:[0-9]+$' || return 1
  [ "$source" = springboard_exact_home_commit ] ||
    [ "$source" = app_did_become_active_reduced ] ||
    [ "$source" = ax_frontmost ] || return 1
  printf '%s\n' "$bid" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]+$' || return 1
  [ "$ts" -ge "$minimum_ts" ] || return 1
  now="$(now_ms)" || return 1
  [ "$now" -ge "$ts" ] || return 1
  max_age=1200
  [ "$source" = ax_frontmost ] && max_age=650
  [ $((now-ts)) -le "$max_age" ] || return 1
  printf '%s\n' "$bid"
}

live_front_or_unavailable() {
  local minimum_ts="${1:-0}" bid
  bid="$(live_front_bid_after "$minimum_ts" 2>/dev/null)" || bid=""
  [ -n "$bid" ] && printf '%s\n' "$bid" || printf '%s\n' UNAVAILABLE
}

status_text() {
  wget -qO- -T 1 http://127.0.0.1:50005/status 2>/dev/null
}

status_val() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1 | tr -d '\r'
}

is_uint() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+$'
}

# This proves internal ZiYan alignment only. Callers must additionally check
# live_front_bid for real iOS foreground ownership. With min_seq supplied, a
# cached but still-fresh frame cannot satisfy a newly issued transition.
status_matches() {
  local st="$1" wanted_front="$2" wanted_provider="$3" min_seq="${4:-}"
  local fresh_limit="${5:-1200}"
  local front shm provider status age seq session wants
  front="$(status_val "$st" front_bid)"
  shm="$(status_val "$st" shm_bid)"
  provider="$(status_val "$st" frame_provider)"
  status="$(status_val "$st" frame_status)"
  age="$(status_val "$st" frame_age_ms)"
  seq="$(status_val "$st" frame_seq)"
  session="$(status_val "$st" session)"
  wants="$(status_val "$st" wants_run)"
  [ "$front" = "$wanted_front" ] && [ "$shm" = "$wanted_front" ] &&
    [ "$provider" = "$wanted_provider" ] && [ "$status" = 0 ] &&
    [ "$session" = running ] && [ "$wants" = 1 ] || return 1
  is_uint "$age" && is_uint "$seq" || return 1
  [ "$age" -le "$fresh_limit" ] || return 1
  if [ -n "$min_seq" ]; then
    is_uint "$min_seq" || return 1
    [ "$seq" -gt "$min_seq" ] || return 1
  fi
  return 0
}

resident_status() {
  local budget_ms="$1" require_zero="$2" start st rr maps unmaps spent
  start="$(now_ms)"
  st=""
  while :; do
    st="$(status_text)"
    rr="$(status_val "$st" resident_readers)"
    maps="$(status_val "$st" resident_ticket_maps)"
    unmaps="$(status_val "$st" resident_ticket_unmaps)"
    if printf '%s:%s:%s\n' "$rr" "$maps" "$unmaps" |
         grep -Eq '^[0-9]+:[0-9]+:[0-9]+$' &&
       [ "$maps" -ge "$unmaps" ] 2>/dev/null &&
       [ $((maps-unmaps)) -eq "$rr" ] 2>/dev/null; then
      if [ "$require_zero" != 1 ] || [ "$rr" = 0 ]; then
        printf '%s\n' "$st"
        return
      fi
    fi
    spent="$(elapsed_ms "$start")"
    printf '%s\n' "$spent" | grep -Eq '^[0-9]+$' || break
    [ "$spent" -ge "$budget_ms" ] && break
    sleep .01
  done
  printf '%s\n' "$st"
}

file_text() {
  tr -d '\r\n' <"$1" 2>/dev/null
}

line_count() {
  if [ -f "$1" ]; then
    wc -l <"$1" 2>/dev/null | tr -d ' '
  else
    echo 0
  fi
}

file_sha() {
  if [ -f "$1" ]; then
    sha256sum "$1" 2>/dev/null | sed 's/[[:space:]].*//' | head -1
  else
    echo MISSING
  fi
}

file_exists() {
  [ -f "$1" ] && echo 1 || echo 0
}

display_locked() {
  value="$(head -1 "$V/.ziyan_display_locked" 2>/dev/null | tr -d '\r\n')"
  if [ "$value" = 0 ] || [ "$value" = 1 ]; then
    echo "$value"
    return
  fi
  # Unlock deliberately removes `.ziyan_display_locked` and persists the real
  # SpringBoard result in `.ziyan_lock_state`.  Treat only an explicit 0/1 as
  # evidence; if both files are absent/corrupt the gate remains UNKNOWN.
  value="$(head -1 "$V/.ziyan_lock_state" 2>/dev/null | tr -d '\r\n')"
  if [ "$value" = 0 ] || [ "$value" = 1 ]; then
    echo "$value"
  else
    echo UNKNOWN
  fi
}

protocol_field() {
  key="$1"
  file="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1 | tr -d '\r'
}

match_count() {
  pattern="$1"
  file="$2"
  if [ -f "$file" ]; then
    grep -c "$pattern" "$file" 2>/dev/null || :
  else
    echo 0
  fi
}

embed_flag() {
  [ -f "$V/.ziyan_lua_embedded" ] && echo 1 || echo 0
}

embed_field() {
  sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p; s/^$1=\([0-9][0-9]*\).*/\1/p" \
    "$V/.ziyan_embed_alive" 2>/dev/null | tail -1
}

embed_age_s() {
  ets="$(embed_field ts)"
  now="$(date +%s)"
  printf '%s\n' "$ets" | grep -Eq '^[0-9]+$' || { echo -1; return; }
  printf '%s\n' "$now" | grep -Eq '^[0-9]+$' || { echo -1; return; }
  age=$((now-ets))
  [ "$age" -lt 0 ] && age=0
  echo "$age"
}

path_stat() {
  sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p" \
    "$V/.ziyan_path_stats" 2>/dev/null | tail -1
}

embed_script_path() {
  head -1 "$V/.ziyan_embed_script" 2>/dev/null | tr -d '\r\n'
}

embed_script_sha() {
  script_path="$(embed_script_path)"
  [ -n "$script_path" ] || { echo MISSING; return; }
  sha256sum "$script_path" 2>/dev/null | sed 's/[[:space:]].*//' | head -1
}

api_csv_header() {
  head -1 "$V/.ziyan_ts_cycle.csv" 2>/dev/null | tr -d '\r\n'
}

api_seq_last() {
  awk -F, 'NR>1 && $9 ~ /^[0-9]+$/ {if ($9>m)m=$9} END {print m+0}' \
    "$V/.ziyan_ts_cycle.csv" 2>/dev/null
}

pulse_n() {
  sed -n 's/.* n=\([0-9][0-9]*\).*/\1/p' "$V/.ziyan_find_pulse" 2>/dev/null | tail -1
}

toast_gen() {
  sed -n 's/.* gen=\([0-9][0-9]*\).*/\1/p' "$V/.ziyan_toast_dump" 2>/dev/null | tail -1
}

toast_gen_file() {
  sed -n 's/.* gen=\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | tail -1
}

emit_proc() {
  phase="$1"
  role="$2"
  pattern="$3"
  lines=$(ps -A -o pid=,ppid=,stat=,etime=,time=,rss=,%cpu=,command= 2>/dev/null |
    grep -F "$pattern" | grep -v grep)
  count=$(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d ' ')
  first=$(printf '%s\n' "$lines" | sed -n '1{s/^ *//;p;}')
  if [ "$count" = 1 ] && [ -n "$first" ]; then
    set -- $first
    echo "PROC PHASE=$phase ROLE=$role COUNT=1 PID=$1 PPID=$2 STAT=$3 ETIME=$4 CTIME=$5 RSS=$6 CPU=$7"
  else
    echo "PROC PHASE=$phase ROLE=$role COUNT=${count:-0} PID=0 PPID=0 STAT=- ETIME=- CTIME=0 RSS=0 CPU=0"
  fi
}

app_jetsam_state() {
  app_pid=$(ps -A -o pid=,command= 2>/dev/null |
    grep -F 'FGCQLibClient-mobile.app/FGCQLibClient-mobile' |
    grep -v grep | sed -n '1{s/^ *//;s/ .*//;p;}')
  is_uint "$app_pid" || { echo unavailable; return; }
  launchctl procinfo "$app_pid" 2>/dev/null |
    sed -n 's/^jetsam priority = \([0-9][0-9]*\): \(.*\)$/\1|\2/p' |
    tail -1 | tr -d '\r'
}

ts_status() {
  wget -qO- -T 1 http://127.0.0.1:50005/status 2>/dev/null | tr -d '\r\n'
}

ts_run_cfg() {
  tr -d '\r\n' </var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null
}

ts_err_size() {
  if [ -r /var/mobile/Media/TouchSprite/log/err.log ]; then
    wc -c </var/mobile/Media/TouchSprite/log/err.log 2>/dev/null |
      tr -d '[:space:]'
  else
    echo 0
  fi
}

ts_err_sha() {
  file_sha /var/mobile/Media/TouchSprite/log/err.log
}

emit_101_procs() {
  phase="$1"
  emit_proc "$phase" framecap "ziyan_framecap serve"
  emit_proc "$phase" ziyadaemond "/usr/lib/ziyan/bin/ziyadaemond"
  emit_proc "$phase" SpringBoard "SpringBoard.app/SpringBoard"
  emit_proc "$phase" App "FGCQLibClient-mobile.app/FGCQLibClient-mobile"
}

emit_171_procs() {
  phase="$1"
  emit_proc "$phase" TSDaemon "TouchSprite.app/TSDaemon"
  emit_proc "$phase" Hades "TouchSprite.app/Hades"
  emit_proc "$phase" SpringBoard "SpringBoard.app/SpringBoard"
  emit_proc "$phase" App "FGCQLibClient-mobile.app/FGCQLibClient-mobile"
}

relevant_zombies() {
  ps -A -o stat=,pid=,command= 2>/dev/null |
    grep -E '^[[:space:]]*Z' |
    grep -E 'ziyan|SpringBoard|FGCQLibClient-mobile|TSDaemon|Hades' |
    wc -l | tr -d ' '
}

single_pid_for() {
  pattern="$1"
  lines=$(ps -A -o pid=,command= 2>/dev/null | grep -F "$pattern" | grep -v grep)
  count=$(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || { echo 0; return; }
  printf '%s\n' "$lines" | sed -n '1{s/^ *//;s/ .*//;p;}'
}
REMOTE
)

fetch_171_snapshot() {
  local out_file="$1"
  curl -fsS --max-time 5 \
    "http://$IP171:50005/snapshot1?ext=jpg&orient=1&compress=0.4&scale=1" \
    -o "$out_file"
}

analyze_171_snapshot() {
  local image_file="$1" result_file="$2" require_login="$3"
  python3 - "$image_file" "$require_login" >"$result_file" <<'PY'
import sys
from pathlib import Path
from PIL import Image, ImageStat

p = Path(sys.argv[1])
require_login = sys.argv[2] == "1"
ok = True
reason = "ok"
login_hit = False
try:
    with Image.open(p) as im:
        im.load()
        rgb = im.convert("RGB")
        stat = ImageStat.Stat(rgb)
        extrema = rgb.getextrema()
        total = rgb.width * rgb.height
        black = sum(1 for px in rgb.getdata()
                    if px[0] <= 8 and px[1] <= 8 and px[2] <= 8)
        black_ratio = black / total if total else 1.0
        if rgb.size != (1136, 640):
            ok, reason = False, "geometry"
        elif black_ratio >= 0.98:
            ok, reason = False, "black_ratio"
        elif max(hi - lo for lo, hi in extrema) < 8 or max(stat.stddev) < 1.0:
            ok, reason = False, "uniform"
        points = [
            (0, 0, 0x90643B),
            (0, 1, 0x91653B),
            (0, 2, 0x92673C),
            (0, 3, 0x95683C),
        ]
        for base_y in range(443, 447):
            matched = True
            for dx, dy, color in points:
                got = rgb.getpixel((652 + dx, base_y + dy))
                expected = ((color >> 16) & 255, (color >> 8) & 255, color & 255)
                if max(abs(a - b) for a, b in zip(got, expected)) > 25:
                    matched = False
                    break
            if matched:
                login_hit = True
                break
        if require_login and not login_hit:
            ok, reason = False, "login_pattern_miss"
        print(f"SNAPSHOT={p.name}")
        print(f"WIDTH={rgb.width}")
        print(f"HEIGHT={rgb.height}")
        print(f"BLACK_RATIO={black_ratio:.6f}")
        print(f"SPATIAL_STDDEV={max(stat.stddev):.6f}")
except Exception as exc:
    ok, reason = False, f"decode:{type(exc).__name__}"
print(f"LOGIN_PATTERN={'PASS' if login_hit else 'MISS'}")
print(f"SNAPSHOT_VERDICT={'PASS' if ok else 'FAIL'}")
print(f"SNAPSHOT_REASON={reason}")
raise SystemExit(0 if ok else 1)
PY
}

BASE101="$OUT/BASELINE_101.txt"
if ! ssh_one "$IP101" 'bash -s' >"$BASE101" 2>&1 <<REMOTE
$REMOTE_HELPERS
echo "DEVICE=.$TARGET_TAG"
date '+TS=%Y-%m-%d %H:%M:%S %z'
dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: /VERSION=/p'
printf 'FRAMECAP_SHA='; sha256sum /usr/lib/ziyan/bin/ziyan_framecap 2>/dev/null | sed 's/[[:space:]].*//'
echo 1 >"\$V/.ziyan_p2_native_front_fast"
chmod 666 "\$V/.ziyan_p2_native_front_fast" 2>/dev/null
ST="\$(resident_status 600 1)"
live_wait_start="\$(now_ms)"
LIVE=""
while :; do
  LIVE="\$(live_front_bid_after 0 2>/dev/null)" || LIVE=""
  [ -n "\$LIVE" ] && break
  live_wait_ms="\$(elapsed_ms "\$live_wait_start")"
  is_uint "\$live_wait_ms" || break
  [ "\$live_wait_ms" -ge 2500 ] && break
  sleep .05
done
echo "CLOCK_MS=\$(now_ms)"
echo "LIVE_FRONT_PROBE=\$(live_front_probe_label)"
echo "LIVE_FRONT=\${LIVE:-UNAVAILABLE}"
echo "LIVE_FRONT_TS_MS=\$(native_front_field ts_ms)"
echo "LIVE_FRONT_SOURCE=\$(native_front_field source)"
echo "SESSION=\$(status_val "\$ST" session)"
echo "WANTS_RUN=\$(status_val "\$ST" wants_run)"
echo "FRAME_SEQ=\$(status_val "\$ST" frame_seq)"
echo "FRAME_AGE_MS=\$(status_val "\$ST" frame_age_ms)"
echo "FRAME_PROVIDER=\$(status_val "\$ST" frame_provider)"
echo "FRAME_STATUS=\$(status_val "\$ST" frame_status)"
echo "FRONT=\$(status_val "\$ST" front_bid)"
echo "SHM=\$(status_val "\$ST" shm_bid)"
echo "DISPLAY_LOCKED=\$(display_locked)"
echo "RESIDENT_READERS=\$(status_val "\$ST" resident_readers)"
echo "TICKET_MAPS=\$(status_val "\$ST" resident_ticket_maps)"
echo "TICKET_UNMAPS=\$(status_val "\$ST" resident_ticket_unmaps)"
echo "WRITER_WAITS=\$(status_val "\$ST" resident_writer_waits)"
echo "INVALID_UNMAPS=\$(status_val "\$ST" resident_invalid_unmaps)"
echo "TICKET_EXHAUSTS=\$(status_val "\$ST" resident_ticket_exhausts)"
echo "PULSE=\$(pulse_n)"
echo "EMBED_FLAG=\$(embed_flag)"
echo "EMBED_ALIVE_TS=\$(embed_field ts)"
echo "EMBED_ALIVE_PID=\$(embed_field pid)"
echo "EMBED_VM_GEN=\$(embed_field vm_gen)"
echo "EMBED_VM_START_MONO_MS=\$(embed_field vm_start_mono_ms)"
echo "EMBED_AGE_S=\$(embed_age_s)"
echo "EMBED_FIND=\$(path_stat via_embed_find)"
echo "COLOR_REQ_FIND=\$(path_stat via_color_req_find)"
echo "EMBED_SCRIPT=\$(embed_script_path)"
echo "EMBED_SCRIPT_SHA=\$(embed_script_sha)"
echo "API_CSV_HEADER=\$(api_csv_header)"
echo "API_SEQ=\$(api_seq_last)"
echo "EXIT_LINES=\$(line_count "\$V/.ziyan_framecap_exit_hist")"
echo "EXIT_HIST_EXISTS=\$(file_exists "\$V/.ziyan_framecap_exit_hist")"
echo "EXIT_SHA=\$(file_sha "\$V/.ziyan_framecap_exit_hist")"
echo "SIG11_LINES=\$(match_count 'event=signal value=11 ' "\$V/.ziyan_framecap_exit_hist")"
echo "ZOMBIES=\$(relevant_zombies)"
echo "RESIDENT=\$(file_text "\$V/.ziyan_resident_bytes")"
emit_101_procs baseline
echo 'EXIT_HIST_BEGIN'
cat "\$V/.ziyan_framecap_exit_hist" 2>/dev/null
echo 'EXIT_HIST_END'
echo 'TOAST_BEGIN'
cat "\$V/.ziyan_toast_dump" 2>/dev/null
echo 'TOAST_END'
REMOTE
then
  completed=0
  write_verdict FAIL "ssh_${TARGET_TAG}_baseline_failed"
  exit 1
fi

BASE171="$OUT/BASELINE_171.txt"
if ! ssh_one "$IP171" 'bash -s' >"$BASE171" 2>&1 <<REMOTE
$REMOTE_HELPERS
echo "DEVICE=.171"
echo "REFERENCE_SCOPE=171_HOME_ONLY_FOREGROUND_E2E_BASELINE"
date '+TS=%Y-%m-%d %H:%M:%S %z'
echo "TS_STATUS=\$(ts_status)"
echo "TS_RUN_CFG=\$(ts_run_cfg)"
echo "APP_JETSAM=\$(app_jetsam_state)"
echo "ERR_SIZE=\$(ts_err_size)"
echo "ERR_SHA=\$(ts_err_sha)"
echo "ZOMBIES=\$(relevant_zombies)"
emit_171_procs baseline
REMOTE
then
  completed=0
  write_verdict FAIL "ssh_171_baseline_failed"
  exit 1
fi

BASE171_SNAPSHOT="$OUT/BASELINE_171.jpg"
if ! fetch_171_snapshot "$BASE171_SNAPSHOT" ||
   ! analyze_171_snapshot "$BASE171_SNAPSHOT" "$OUT/BASELINE_171_SNAPSHOT.txt" 1; then
  completed=0
  write_verdict FAIL "baseline_171_snapshot_or_login" || true
  exit 1
fi

base_version="$(kv VERSION "$BASE101")"
base_framecap_sha="$(kv FRAMECAP_SHA "$BASE101")"
base_exit_lines="$(kv EXIT_LINES "$BASE101")"
base_exit_sha="$(kv EXIT_SHA "$BASE101")"
base_sig11="$(kv SIG11_LINES "$BASE101")"
base_embed_vm_gen="$(kv EMBED_VM_GEN "$BASE101")"
base_embed_vm_start="$(kv EMBED_VM_START_MONO_MS "$BASE101")"
base_invalid_unmaps="$(kv INVALID_UNMAPS "$BASE101")"
base_ticket_exhausts="$(kv TICKET_EXHAUSTS "$BASE101")"
base_frame_pid="$(proc_pid framecap baseline "$BASE101")"
base_zydaemon_pid="$(proc_pid ziyadaemond baseline "$BASE101")"
base_sb_pid="$(proc_pid SpringBoard baseline "$BASE101")"
base_app_pid="$(proc_pid App baseline "$BASE101")"
base_ts_daemon="$(proc_pid TSDaemon baseline "$BASE171")"
base_ts_hades="$(proc_pid Hades baseline "$BASE171")"
base_ts_sb="$(proc_pid SpringBoard baseline "$BASE171")"
base_ts_app="$(proc_pid App baseline "$BASE171")"
base_ts_err_size="$(kv ERR_SIZE "$BASE171")"
base_ts_err_sha="$(kv ERR_SHA "$BASE171")"

baseline_bad=0
[ "$base_version" = "$EXPECTED_VERSION" ] || baseline_bad=1
[ "$base_framecap_sha" = "$EXPECTED_DEVICE_FRAMECAP_SHA" ] || baseline_bad=1
[ "$(kv SESSION "$BASE101")" = running ] || baseline_bad=1
[ "$(kv WANTS_RUN "$BASE101")" = 1 ] || baseline_bad=1
[ "$(kv LIVE_FRONT_PROBE "$BASE101")" != unavailable ] || baseline_bad=1
[ "$(kv LIVE_FRONT "$BASE101")" = "$EXPECTED_APP" ] || baseline_bad=1
case "$(kv LIVE_FRONT_SOURCE "$BASE101")" in
  app_did_become_active_reduced|ax_frontmost) ;;
  *) baseline_bad=1 ;;
esac
[ "$(kv FRONT "$BASE101")" = "$EXPECTED_APP" ] || baseline_bad=1
[ "$(kv SHM "$BASE101")" = "$EXPECTED_APP" ] || baseline_bad=1
[ "$(kv DISPLAY_LOCKED "$BASE101")" = 0 ] || baseline_bad=1
[ "$(kv FRAME_PROVIDER "$BASE101")" = 8 ] || baseline_bad=1
[ "$(kv FRAME_STATUS "$BASE101")" = 0 ] || baseline_bad=1
[ "$(kv RESIDENT_READERS "$BASE101")" = 0 ] || baseline_bad=1
[ "$(kv TICKET_MAPS "$BASE101")" = "$(kv TICKET_UNMAPS "$BASE101")" ] || baseline_bad=1
[ "$(kv EMBED_FLAG "$BASE101")" = 1 ] || baseline_bad=1
[ "$(kv EMBED_ALIVE_PID "$BASE101")" = "$base_frame_pid" ] || baseline_bad=1
[ "$(kv COLOR_REQ_FIND "$BASE101")" = 0 ] || baseline_bad=1
[ "$(kv EMBED_SCRIPT_SHA "$BASE101")" = "$EXPECTED_IOS7_SHA" ] || baseline_bad=1
case "$(kv EMBED_SCRIPT "$BASE101")" in */ios7.lua) ;; *) baseline_bad=1 ;; esac
[ "$(kv API_CSV_HEADER "$BASE101")" = "$EXPECTED_API_HEADER" ] || baseline_bad=1
[ "$(kv EXIT_HIST_EXISTS "$BASE101")" = 1 ] || baseline_bad=1
[ -n "$base_exit_sha" ] && [ "$base_exit_sha" != MISSING ] || baseline_bad=1
base_age="$(kv FRAME_AGE_MS "$BASE101")"
case "$base_age" in ''|*[!0-9]*) baseline_bad=1 ;; *) [ "$base_age" -le "$MAX_MS" ] || baseline_bad=1 ;; esac
[ "$(kv ZOMBIES "$BASE101")" = 0 ] || baseline_bad=1
[ "$(kv ZOMBIES "$BASE171")" = 0 ] || baseline_bad=1
[ "$(kv TS_STATUS "$BASE171")" = f01 ] || baseline_bad=1
case "$(kv TS_RUN_CFG "$BASE171")" in
  runnow###*/main.lua) ;;
  *) baseline_bad=1 ;;
esac
[ "$(kv APP_JETSAM "$BASE171")" = "10|foreground" ] || baseline_bad=1
[ -n "$base_ts_err_sha" ] && [ "$base_ts_err_sha" != MISSING ] || baseline_bad=1
case "$base_ts_err_size" in ''|*[!0-9]*) baseline_bad=1 ;; esac
for value in "$base_exit_lines" "$base_sig11" "$(kv CLOCK_MS "$BASE101")" \
             "$(kv LIVE_FRONT_TS_MS "$BASE101")" \
             "$(kv TICKET_MAPS "$BASE101")" "$(kv TICKET_UNMAPS "$BASE101")" \
             "$(kv WRITER_WAITS "$BASE101")" "$base_invalid_unmaps" "$base_ticket_exhausts" \
             "$(kv EMBED_ALIVE_TS "$BASE101")" \
             "$base_embed_vm_gen" "$base_embed_vm_start" \
             "$(kv EMBED_AGE_S "$BASE101")" "$(kv EMBED_FIND "$BASE101")" \
             "$(kv API_SEQ "$BASE101")"; do
  case "$value" in ''|*[!0-9]*) baseline_bad=1 ;; esac
done
embed_age="$(kv EMBED_AGE_S "$BASE101")"
embed_find="$(kv EMBED_FIND "$BASE101")"
base_pulse="$(kv PULSE "$BASE101")"
case "$embed_age" in ''|*[!0-9]*) baseline_bad=1 ;; *) [ "$embed_age" -le 5 ] || baseline_bad=1 ;; esac
case "$embed_find" in ''|*[!0-9]*) baseline_bad=1 ;; *) [ "$embed_find" -gt 0 ] || baseline_bad=1 ;; esac
case "$base_pulse" in ''|*[!0-9]*) baseline_bad=1 ;; *) [ "$base_pulse" -gt 0 ] || baseline_bad=1 ;; esac
[ "$(kv API_SEQ "$BASE101")" -gt 0 ] 2>/dev/null || baseline_bad=1
[ "$base_invalid_unmaps" = 0 ] || baseline_bad=1
[ "$base_ticket_exhausts" = 0 ] || baseline_bad=1
[ "$base_embed_vm_gen" -gt 0 ] 2>/dev/null || baseline_bad=1
[ "$base_embed_vm_start" -gt 0 ] 2>/dev/null || baseline_bad=1
for role in framecap ziyadaemond SpringBoard App; do
  [ "$(proc_count "$role" baseline "$BASE101")" = 1 ] || baseline_bad=1
  role_pid="$(proc_pid "$role" baseline "$BASE101")"
  case "$role_pid" in ''|*[!0-9]*) baseline_bad=1 ;; *) [ "$role_pid" -gt 1 ] || baseline_bad=1 ;; esac
done
for role in TSDaemon Hades SpringBoard App; do
  [ "$(proc_count "$role" baseline "$BASE171")" = 1 ] || baseline_bad=1
  role_pid="$(proc_pid "$role" baseline "$BASE171")"
  case "$role_pid" in ''|*[!0-9]*) baseline_bad=1 ;; *) [ "$role_pid" -gt 1 ] || baseline_bad=1 ;; esac
done
for value in "$base_frame_pid" "$base_zydaemon_pid" "$base_sb_pid" "$base_app_pid" \
             "$base_ts_daemon" "$base_ts_hades" "$base_ts_sb" "$base_ts_app"; do
  case "$value" in ''|*[!0-9]*) baseline_bad=1 ;; esac
  [ "${value:-0}" -gt 0 ] 2>/dev/null || baseline_bad=1
done
if [ "$baseline_bad" != 0 ]; then
  completed=0
  write_verdict FAIL "baseline_not_strict_ready"
  exit 1
fi

echo "BASE framecap=$base_frame_pid sb=$base_sb_pid app=$base_app_pid exit_lines=$base_exit_lines sig11=$base_sig11" | tee -a "$LOG"
echo "BASE171 daemon=$base_ts_daemon hades=$base_ts_hades sb=$base_ts_sb app=$base_ts_app" | tee -a "$LOG"

analyze_png() {
  local png="$1" result="$2"
  python3 - "$png" >"$result" <<'PY'
import sys
from pathlib import Path
from PIL import Image, ImageStat

p = Path(sys.argv[1])
ok = True
reason = "ok"
try:
    with Image.open(p) as im:
        im.load()
        rgb = im.convert("RGB")
        stat = ImageStat.Stat(rgb)
        extrema = rgb.getextrema()
        total = rgb.width * rgb.height
        black = sum(1 for px in rgb.getdata() if px[0] <= 8 and px[1] <= 8 and px[2] <= 8)
        black_ratio = black / total if total else 1.0
        channel_spread = max(hi - lo for lo, hi in extrema)
        spatial_stddev = max(stat.stddev)
        if (rgb.width, rgb.height) != (1136, 640):
            ok, reason = False, "geometry"
        elif black_ratio >= 0.98:
            ok, reason = False, "black_ratio"
        elif channel_spread < 8 or spatial_stddev < 1.0:
            ok, reason = False, "uniform_frame"
        print(f"PNG={p.name}")
        print(f"WIDTH={rgb.width}")
        print(f"HEIGHT={rgb.height}")
        print(f"BLACK_RATIO={black_ratio:.6f}")
        print(f"CHANNEL_SPREAD={channel_spread}")
        print(f"SPATIAL_STDDEV={spatial_stddev:.6f}")
        print("MEAN=" + ",".join(f"{x:.3f}" for x in stat.mean))
except Exception as exc:
    ok, reason = False, f"decode:{type(exc).__name__}"
print(f"PNG_VERDICT={'PASS' if ok else 'FAIL'}")
print(f"PNG_REASON={reason}")
raise SystemExit(0 if ok else 1)
PY
}

sample_171() {
  local phase="$1" action="$2" out_file="$3"
  ssh_one "$IP171" "PHASE='$phase' ACTION='$action' bash -s" >"$out_file" 2>&1 <<REMOTE
$REMOTE_HELPERS
echo "PHASE=\$PHASE"
echo "REFERENCE_SCOPE=171_HOME_ONLY_FOREGROUND_E2E"
sample_start_ms="\$(now_ms)"
echo "SAMPLE_START_MS=\$sample_start_ms"
emit_171_procs before
echo "TS_STATUS_BEFORE=\$(ts_status)"
echo "TS_RUN_CFG_BEFORE=\$(ts_run_cfg)"
echo "ERR_SIZE_BEFORE=\$(ts_err_size)"
echo "ERR_SHA_BEFORE=\$(ts_err_sha)"
pre_jetsam="\$(app_jetsam_state)"
echo "APP_JETSAM_BEFORE=\$pre_jetsam"
ACTION_RC=0
action_t0="\$(now_ms)"
echo "ACTION_T0=\$action_t0"
case "\$ACTION" in
  home)
    activator send libactivator.system.homebutton >/dev/null 2>&1 ||
      uiopen 'activator://libactivator.system.homebutton' >/dev/null 2>&1 || ACTION_RC=1
    seen_nonfg=0
    nonfg_streak=0
    invalid_jetsam=0
    valid_jetsam_samples=0
    first_nonfg_ms=-1
    auto_return=0
    return_fg_ms=-1
    while :; do
      jetsam="\$(app_jetsam_state)"
      action_ms="\$(elapsed_ms "\$action_t0")"
      is_uint "\$action_ms" || break
      jetsam_valid=0
      case "\$jetsam" in
        *'|'*)
          jetsam_prio="\${jetsam%%|*}"
          jetsam_state="\${jetsam#*|}"
          case "\$jetsam_prio" in ''|*[!0-9]*) ;;
            *) [ -n "\$jetsam_state" ] && jetsam_valid=1 ;;
          esac
          ;;
      esac
      if [ "\$jetsam_valid" != 1 ]; then
        invalid_jetsam=1
        nonfg_streak=0
      else
        valid_jetsam_samples=\$((valid_jetsam_samples+1))
        if [ "\$jetsam" = '10|foreground' ]; then
          nonfg_streak=0
          if [ "\$seen_nonfg" = 1 ]; then
            auto_return=1
            return_fg_ms="\$action_ms"
            break
          fi
        else
          nonfg_streak=\$((nonfg_streak+1))
          if [ "\$seen_nonfg" = 0 ] && [ "\$nonfg_streak" -ge 2 ]; then
            seen_nonfg=1
            first_nonfg_ms="\$action_ms"
          fi
        fi
      fi
      [ "\$action_ms" -ge 6000 ] && break
      sleep .05
    done
    echo "HOME_SEEN_NONFG=\$seen_nonfg"
    echo "HOME_INVALID_JETSAM=\$invalid_jetsam"
    echo "HOME_VALID_JETSAM_SAMPLES=\$valid_jetsam_samples"
    echo "HOME_FIRST_NONFG_MS=\$first_nonfg_ms"
    echo "HOME_AUTO_RETURN=\$auto_return"
    echo "HOME_RETURN_FG_MS=\$return_fg_ms"
    ;;
  *) ACTION_RC=2 ;;
esac
echo "ACTION_RC=\$ACTION_RC"
echo "APP_JETSAM_AFTER=\$(app_jetsam_state)"
echo "TS_STATUS_AFTER=\$(ts_status)"
echo "TS_RUN_CFG_AFTER=\$(ts_run_cfg)"
echo "ERR_SIZE_AFTER=\$(ts_err_size)"
echo "ERR_SHA_AFTER=\$(ts_err_sha)"
echo "SAMPLE_END_MS=\$(now_ms)"
echo "ZOMBIES=\$(relevant_zombies)"
emit_171_procs after
REMOTE
}

toast_visual_watch() {
  local round="$1" rdir="$2" marker_round marker_phase marker_gen marker_tag
  ssh_one "$IP101" "WATCH_ROUND='$round' bash -s" <<'REMOTE' |
V=/usr/lib/ziyan/var
last=""
end=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -s "$V/.ziyan_p2_toast_visual" ]; then
    r=$(sed -n 's/^round=//p' "$V/.ziyan_p2_toast_visual" | head -1 | tr -d '\r')
    p=$(sed -n 's/^phase=//p' "$V/.ziyan_p2_toast_visual" | head -1 | tr -d '\r')
    g=$(sed -n 's/^gen=//p' "$V/.ziyan_p2_toast_visual" | head -1 | tr -d '\r')
    t=$(sed -n 's/^tag=//p' "$V/.ziyan_p2_toast_visual" | head -1 | tr -d '\r')
    cur="$r|$p|$g|$t"
    if [ "$r" = "$WATCH_ROUND" ] && [ -n "$g" ] && [ "$cur" != "$last" ]; then
      printf '%s\n' "$cur"
      last="$cur"
    fi
  fi
  sleep .05
done
REMOTE
  while IFS='|' read -r marker_round marker_phase marker_gen marker_tag; do
    case "$marker_round:$marker_phase:$marker_gen:$marker_tag" in
      "$round":HOME:[0-9]*:"p2-r${round}-home") visual_name=home ;;
      "$round":APP:[0-9]*:"p2-r${round}-app") visual_name=app ;;
      *) echo "VISUAL_WATCH_REJECT marker=$marker_round:$marker_phase:$marker_gen:$marker_tag"; continue ;;
    esac
    visual_png="$rdir/${visual_name}_toast_screen.png"
    visual_txt="$rdir/${visual_name}_toast_visual.txt"
    # Only the per-round unique tag may satisfy the screenshot gate. Generic
    # business text (for example 登录) could also exist in the underlying UI and
    # must never substitute for this exact Toast generation.
    visual_expected="$marker_tag"
    if run_host_timeout 20 idevicescreenshot -u "$EXPECTED_TARGET_UDID" "$visual_png" \
         >"$rdir/${visual_name}_toast_capture.txt" 2>&1 &&
       run_host_timeout 20 "$TOAST_VISUAL_TOOL" "$visual_png" "$visual_expected" \
         >"$visual_txt" 2>&1; then
      ssh_one "$IP101" \
        "printf 'round=%s\\nphase=%s\\ngen=%s\\n' '$marker_round' '$marker_phase' '$marker_gen' > /usr/lib/ziyan/var/.ziyan_p2_toast_visual_ack.tmp && mv /usr/lib/ziyan/var/.ziyan_p2_toast_visual_ack.tmp /usr/lib/ziyan/var/.ziyan_p2_toast_visual_ack" \
        >/dev/null 2>&1 || true
      echo "VISUAL_CAPTURE phase=$marker_phase gen=$marker_gen verdict=PASS"
    else
      echo "VISUAL_CAPTURE phase=$marker_phase gen=$marker_gen verdict=FAIL"
    fi
    [ "$marker_phase" = APP ] && break
  done
}

sample_101_round() {
  local round="$1" out_file="$2"
  ssh_one "$IP101" "ROUND='$round' bash -s" >"$out_file" 2>&1 <<REMOTE
$REMOTE_HELPERS
TMP_HOME="/tmp/zy_p2_c80_r\${ROUND}_home.png"
TMP_APP="/tmp/zy_p2_c80_r\${ROUND}_app.png"
TMP_HOME_TOAST="/tmp/zy_p2_c80_r\${ROUND}_home_toast.txt"
TMP_APP_TOAST="/tmp/zy_p2_c80_r\${ROUND}_app_toast.txt"
rm -f "\$TMP_HOME" "\$TMP_APP" "\$TMP_HOME_TOAST" "\$TMP_APP_TOAST"
rm -f "\$V/.ziyan_p2_toast_visual" "\$V/.ziyan_p2_toast_visual.tmp" \
      "\$V/.ziyan_p2_toast_visual_ack" "\$V/.ziyan_p2_toast_visual_ack.tmp"
echo 1 >"\$V/.ziyan_p2_native_front_fast"
chmod 666 "\$V/.ziyan_p2_native_front_fast" 2>/dev/null

cleanup_round_state() {
  rm -f "\$V/.ziyan_go_home" "\$V/.ziyan_open_app" \
        "\$V/.ziyan_open_app.tmp" "\$V/.ziyan_p2_native_front_fast" \
        "\$V/.ziyan_embed_api_probe" "\$V/.ziyan_embed_api_probe.tmp" \
        "\$V/.ziyan_p2_toast_visual" "\$V/.ziyan_p2_toast_visual.tmp" \
        "\$V/.ziyan_p2_toast_visual_ack" "\$V/.ziyan_p2_toast_visual_ack.tmp" \
        "\$V"/.ziyan_cmd.p2.* 2>/dev/null || true
}
trap cleanup_round_state EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

remote_rc=0
remote_reason=""
home_stage=FAIL
home_stable_stage=NOT_RUN
app_stage=NOT_RUN
home_toast_stage=NOT_RUN
app_toast_stage=NOT_RUN
daemon_getcolor_stage=NOT_RUN
daemon_find_stage=NOT_RUN
daemon_find_neg_stage=NOT_RUN
embed_shadow_stage=NOT_RUN
embed_natural_stage=NOT_RUN
home_snapshot=0
app_snapshot=0

set_remote_fail() {
  if [ "\$remote_rc" = 0 ]; then
    remote_rc="\$1"
    remote_reason="\$2"
  fi
}

emit_tagged_toast() {
  tag="\$1"
  cmd_tmp="\$V/.ziyan_cmd.p2.\$\$"
  rm -f "\$cmd_tmp"
  printf 'toast\n%s\n%d\n' "\$tag" $TOAST_DURATION_MS >"\$cmd_tmp" || return 1
  chmod 666 "\$cmd_tmp" 2>/dev/null
  mv "\$cmd_tmp" "\$V/.ziyan_cmd"
}

wait_new_toast() {
  prefix="\$1"
  before="\$2"
  expected_front="\$3"
  dest="\$4"
  t0="\$5"
  expected_tag="\$6"
  ok=0
  visual_ack=0
  visual_ms=-1
  after=""
  captured=""
  ms=-1
  while :; do
    after="\$(toast_gen)"
    tst="\$(status_text)"
    tf="\$(status_val "\$tst" front_bid)"
    t_live="\$(live_front_or_unavailable "\$t0")"
    ms="\$(elapsed_ms "\$t0")"
    case "\$ms" in ''|*[!0-9]*) break ;; esac
    if [ -n "\$after" ] && [ "\$after" != "\$before" ] &&
       [ "\$tf" = "\$expected_front" ] &&
       [ "\$t_live" = "\$expected_front" ] &&
       [ "\$ms" -le $TOAST_MAX_MS ] &&
       grep -q '^phase=visible_commit ' "\$V/.ziyan_toast_dump" 2>/dev/null &&
       grep -Fqx "text=\$expected_tag" "\$V/.ziyan_toast_dump" 2>/dev/null; then
      # The dump is atomically replaced by every toast.  Freeze exactly the
      # generation that satisfied the predicate; a later toast must not be
      # used as evidence for this transition.
      tmp="\${dest}.tmp.\$\$"
      rm -f "\$tmp"
      if cp "\$V/.ziyan_toast_dump" "\$tmp" 2>/dev/null; then
        captured="\$(toast_gen_file "\$tmp")"
        if [ "\$captured" = "\$after" ] &&
           grep -q '^phase=visible_commit ' "\$tmp" 2>/dev/null &&
           grep -Fqx "text=\$expected_tag" "\$tmp" 2>/dev/null; then
          if mv "\$tmp" "\$dest"; then
            rm -f "\$V/.ziyan_p2_toast_visual_ack" \
                  "\$V/.ziyan_p2_toast_visual_ack.tmp"
            marker_tmp="\$V/.ziyan_p2_toast_visual.tmp"
            printf 'round=%s\nphase=%s\ngen=%s\ntag=%s\n' \
              "\$ROUND" "\$prefix" "\$captured" "\$expected_tag" \
              >"\$marker_tmp"
            chmod 666 "\$marker_tmp" 2>/dev/null
            if mv "\$marker_tmp" "\$V/.ziyan_p2_toast_visual"; then
              visual_t0="\$(now_ms)"
              while :; do
                visual_ms="\$(elapsed_ms "\$visual_t0")"
                if [ "\$(protocol_field round "\$V/.ziyan_p2_toast_visual_ack")" = "\$ROUND" ] &&
                   [ "\$(protocol_field phase "\$V/.ziyan_p2_toast_visual_ack")" = "\$prefix" ] &&
                   [ "\$(protocol_field gen "\$V/.ziyan_p2_toast_visual_ack")" = "\$captured" ]; then
                  visual_ack=1
                  break
                fi
                is_uint "\$visual_ms" || break
                [ "\$visual_ms" -ge $TOAST_MAX_MS ] && break
                sleep .05
              done
            fi
            ok=\$visual_ack
            break
          fi
        fi
      fi
      rm -f "\$tmp"
    fi
    [ "\$ms" -ge $TOAST_MAX_MS ] && break
    sleep .05
  done
  if [ "\$ok" != 1 ]; then
    cp "\$V/.ziyan_toast_dump" "\$dest" 2>/dev/null || true
    captured="\$(toast_gen_file "\$dest")"
  fi
  echo "\${prefix}_TOAST_OK=\$ok"
  echo "\${prefix}_TOAST_MS=\$ms"
  echo "\${prefix}_TOAST_GEN_BEFORE=\$before"
  echo "\${prefix}_TOAST_GEN_AFTER=\$after"
  echo "\${prefix}_TOAST_CAPTURED_GEN=\$captured"
  echo "\${prefix}_TOAST_TAG=\$expected_tag"
  echo "\${prefix}_TOAST_VISUAL_ACK=\$visual_ack"
  echo "\${prefix}_TOAST_VISUAL_MS=\$visual_ms"
  [ "\$ok" = 1 ]
}

echo "ROUND=\$ROUND"
date '+ROUND_TS=%Y-%m-%d %H:%M:%S %z'
echo "ROUND_START_MS=\$(now_ms)"
emit_101_procs before
guard_frame_pid="\$(single_pid_for 'ziyan_framecap serve')"
guard_zydaemon_pid="\$(single_pid_for '/usr/lib/ziyan/bin/ziyadaemond')"
guard_sb_pid="\$(single_pid_for 'SpringBoard.app/SpringBoard')"
guard_app_pid="\$(single_pid_for 'FGCQLibClient-mobile.app/FGCQLibClient-mobile')"
echo "GUARD_FRAME_PID=\$guard_frame_pid"
echo "GUARD_ZYDAEMON_PID=\$guard_zydaemon_pid"
echo "GUARD_SB_PID=\$guard_sb_pid"
echo "GUARD_APP_PID=\$guard_app_pid"
round_process_guard() {
  [ "\$(single_pid_for 'ziyan_framecap serve')" = "\$guard_frame_pid" ] &&
    [ "\$(single_pid_for '/usr/lib/ziyan/bin/ziyadaemond')" = "\$guard_zydaemon_pid" ] &&
    [ "\$(single_pid_for 'SpringBoard.app/SpringBoard')" = "\$guard_sb_pid" ] &&
    [ "\$(single_pid_for 'FGCQLibClient-mobile.app/FGCQLibClient-mobile')" = "\$guard_app_pid" ]
}
echo "PULSE_BEFORE=\$(pulse_n)"
BST="\$(resident_status 350 0)"
echo "RESIDENT_READERS_BEFORE=\$(status_val "\$BST" resident_readers)"
echo "TICKET_MAPS_BEFORE=\$(status_val "\$BST" resident_ticket_maps)"
echo "TICKET_UNMAPS_BEFORE=\$(status_val "\$BST" resident_ticket_unmaps)"
echo "WRITER_WAITS_BEFORE=\$(status_val "\$BST" resident_writer_waits)"
echo "INVALID_UNMAPS_BEFORE=\$(status_val "\$BST" resident_invalid_unmaps)"
echo "TICKET_EXHAUSTS_BEFORE=\$(status_val "\$BST" resident_ticket_exhausts)"
echo "EMBED_FLAG_BEFORE=\$(embed_flag)"
echo "EMBED_ALIVE_TS_BEFORE=\$(embed_field ts)"
echo "EMBED_ALIVE_PID_BEFORE=\$(embed_field pid)"
echo "EMBED_VM_GEN_BEFORE=\$(embed_field vm_gen)"
echo "EMBED_VM_START_MONO_MS_BEFORE=\$(embed_field vm_start_mono_ms)"
echo "EMBED_AGE_S_BEFORE=\$(embed_age_s)"
echo "EMBED_FIND_BEFORE=\$(path_stat via_embed_find)"
echo "COLOR_REQ_FIND_BEFORE=\$(path_stat via_color_req_find)"
echo "EMBED_SCRIPT_SHA_BEFORE=\$(embed_script_sha)"
echo "API_CSV_HEADER_BEFORE=\$(api_csv_header)"
echo "API_SEQ_BEFORE=\$(api_seq_last)"
echo "APPFRAME_TIMEOUTS_BEFORE=\$(match_count 'side=client stage=timeout ' "\$V/.ziyan_app_frame_trace")"
echo "APPFRAME_INVALID_BEFORE=\$(match_count 'side=app stage=claim_invalid ' "\$V/.ziyan_app_frame_trace")"
echo "EXIT_LINES_BEFORE=\$(line_count "\$V/.ziyan_framecap_exit_hist")"
echo "EXIT_HIST_EXISTS_BEFORE=\$(file_exists "\$V/.ziyan_framecap_exit_hist")"
echo "EXIT_SHA_BEFORE=\$(file_sha "\$V/.ziyan_framecap_exit_hist")"
echo "SIG11_LINES_BEFORE=\$(match_count 'event=signal value=11 ' "\$V/.ziyan_framecap_exit_hist")"

# Home: the 1200 ms budget includes a real native-front sample produced after
# this request, a new provider-7 frame, and session continuity.  The pre-state
# must be the App/provider-8; an already-desktop device cannot pass instantly.
PRE_HST="\$(status_text)"
pre_home_seq="\$(status_val "\$PRE_HST" frame_seq)"
pre_home_live="\$(live_front_or_unavailable 0)"
pre_home_intent_nonce="\$(protocol_field nonce "\$V/.ziyan_home_intent")"
pre_home_intent_ts="\$(protocol_field ts_ms "\$V/.ziyan_home_intent")"
pre_home_intent_mono="\$(protocol_field intent_mono_ms "\$V/.ziyan_home_intent")"
echo "PRE_HOME_SESSION=\$(status_val "\$PRE_HST" session)"
echo "PRE_HOME_WANTS_RUN=\$(status_val "\$PRE_HST" wants_run)"
echo "PRE_HOME_FRONT=\$(status_val "\$PRE_HST" front_bid)"
echo "PRE_HOME_SHM=\$(status_val "\$PRE_HST" shm_bid)"
echo "PRE_HOME_PROVIDER=\$(status_val "\$PRE_HST" frame_provider)"
echo "PRE_HOME_STATUS=\$(status_val "\$PRE_HST" frame_status)"
echo "PRE_HOME_SEQ=\$pre_home_seq"
echo "PRE_HOME_LIVE_FRONT=\$pre_home_live"
echo "PRE_HOME_DISPLAY_LOCKED=\$(display_locked)"
echo "PRE_HOME_INTENT_NONCE=\$pre_home_intent_nonce"
echo "PRE_HOME_INTENT_TS=\$pre_home_intent_ts"
echo "PRE_HOME_INTENT_MONO=\$pre_home_intent_mono"

home_toast_before="\$(toast_gen)"
home_tag="p2-r\${ROUND}-home"
home_ok=0
home_ms=-1
home_t0=-1
h_live=UNAVAILABLE
HST="\$PRE_HST"
if status_matches "\$PRE_HST" "$EXPECTED_APP" 8 "" $MAX_MS &&
   [ "\$pre_home_live" = "$EXPECTED_APP" ] && is_uint "\$pre_home_seq"; then
  rm -f "\$V/.ziyan_open_app"
  home_t0="\$(now_ms)"
  if is_uint "\$home_t0"; then
    echo 1 >"\$V/.ziyan_go_home"
    chmod 666 "\$V/.ziyan_go_home" 2>/dev/null
    requested=0
    while :; do
      HST="\$(status_text)"
      hf="\$(status_val "\$HST" front_bid)"
      if [ "\$hf" = "$EXPECTED_HOME" ] && [ "\$requested" = 0 ]; then
        echo 1 >"\$V/.ziyan_force_recap"
        echo 1 >"\$V/.ziyan_frame_req"
        requested=1
      fi
      h_live="\$(live_front_or_unavailable "\$home_t0")"
      home_ms="\$(elapsed_ms "\$home_t0")"
      if status_matches "\$HST" "$EXPECTED_HOME" 7 "\$pre_home_seq" $MAX_MS &&
         [ "\$h_live" = "$EXPECTED_HOME" ] && is_uint "\$home_ms" &&
         [ "\$home_ms" -le $MAX_MS ]; then
        home_ok=1
        break
      fi
      is_uint "\$home_ms" || break
      [ "\$home_ms" -ge $MAX_MS ] && break
      sleep .05
    done
  else
    set_remote_fail 20 home_clock
  fi
  rm -f "\$V/.ziyan_go_home"
else
  set_remote_fail 20 pre_home
fi
echo "HOME_OK=\$home_ok"
echo "HOME_MS=\$home_ms"
echo "HOME_SESSION=\$(status_val "\$HST" session)"
echo "HOME_WANTS_RUN=\$(status_val "\$HST" wants_run)"
echo "HOME_PROVIDER=\$(status_val "\$HST" frame_provider)"
echo "HOME_STATUS=\$(status_val "\$HST" frame_status)"
echo "HOME_FRONT=\$(status_val "\$HST" front_bid)"
echo "HOME_SHM=\$(status_val "\$HST" shm_bid)"
echo "HOME_AGE_MS=\$(status_val "\$HST" frame_age_ms)"
echo "HOME_SEQ=\$(status_val "\$HST" frame_seq)"
echo "HOME_LIVE_FRONT=\$h_live"
echo "HOME_LIVE_TS_MS=\$(native_front_field ts_ms)"
echo "HOME_LIVE_SOURCE=\$(native_front_field source)"
echo "HOME_DISPLAY_LOCKED=\$(display_locked)"
home_intent_file="\$V/.ziyan_home_intent"
home_intent_nonce="\$(protocol_field nonce "\$home_intent_file")"
home_intent_epoch="\$(protocol_field epoch "\$home_intent_file")"
home_intent_ts="\$(protocol_field ts_ms "\$home_intent_file")"
home_intent_mono="\$(protocol_field intent_mono_ms "\$home_intent_file")"
home_deadline_mono="\$(protocol_field deadline_mono_ms "\$home_intent_file")"
home_cancel_until_mono="\$(protocol_field cancel_valid_until_mono_ms "\$home_intent_file")"
home_resign_ack="\$V/.ziyan_home_resign_ack.\$home_intent_nonce"
home_background_ack="\$V/.ziyan_home_background_ack.\$home_intent_nonce"
home_terminal="\$V/.ziyan_home_terminal.\$home_intent_nonce"
home_commit_evidence="\$V/.ziyan_home_commit_evidence.\$home_intent_nonce"
home_cancel_evidence="\$V/.ziyan_home_cancel.\$home_intent_nonce"

home_record_identity_matches() {
  record="\$1"
  [ "\$(protocol_field v "\$record")" = 3 ] &&
    [ "\$(protocol_field nonce "\$record")" = "\$home_intent_nonce" ] &&
    [ "\$(protocol_field epoch "\$record")" = "\$home_intent_epoch" ] &&
    [ "\$(protocol_field expected_bid "\$record")" = "$EXPECTED_APP" ] &&
    [ "\$(protocol_field intent_ts_ms "\$record")" = "\$home_intent_ts" ] &&
    [ "\$(protocol_field intent_mono_ms "\$record")" = "\$home_intent_mono" ]
}

home_event_in_action_window() {
  event_mono="\$(protocol_field event_mono_ms "\$1")"
  is_uint "\$event_mono" &&
    [ "\$event_mono" -ge "\$home_intent_mono" ] &&
    [ "\$event_mono" -le "\$home_deadline_mono" ]
}

home_cancel_matches_current() {
  cancel_event="\$(protocol_field event_mono_ms "\$home_cancel_evidence")"
  home_record_identity_matches "\$home_cancel_evidence" &&
    [ "\$(protocol_field bid "\$home_cancel_evidence")" = "$EXPECTED_APP" ] &&
    [ "\$(protocol_field decision "\$home_cancel_evidence")" = active_cancel ] &&
    is_uint "\$cancel_event" &&
    [ "\$cancel_event" -ge "\$home_intent_mono" ] &&
    [ "\$cancel_event" -le "\$home_cancel_until_mono" ]
}

home_resign_ts="\$(protocol_field ts_ms "\$home_resign_ack")"
home_resign_event_mono="\$(protocol_field event_mono_ms "\$home_resign_ack")"
home_background_ts="\$(protocol_field ts_ms "\$home_background_ack")"
home_background_event_mono="\$(protocol_field event_mono_ms "\$home_background_ack")"
home_terminal_ts="\$(protocol_field ts_ms "\$home_terminal")"
home_terminal_event_mono="\$(protocol_field event_mono_ms "\$home_terminal")"
home_commit_ts="\$(protocol_field commit_ts_ms "\$home_commit_evidence")"
home_commit_mono="\$(protocol_field commit_mono_ms "\$home_commit_evidence")"
home_commit_ack_ts="\$(protocol_field ack_ts_ms "\$home_commit_evidence")"
home_native_nonce="\$(native_front_field nonce)"
home_native_bid="\$(native_front_field bid)"
home_native_source="\$(native_front_field source)"
home_native_ts="\$(native_front_field ts_ms)"

home_commit_ok=0
if [ "\$(protocol_field v "\$home_intent_file")" = 3 ] &&
   [ -n "\$home_intent_nonce" ] &&
   [ "\$home_intent_nonce" != "\$pre_home_intent_nonce" ] &&
   [ "\$(protocol_field expected_bid "\$home_intent_file")" = "$EXPECTED_APP" ] &&
   is_uint "\$home_t0" && is_uint "\$home_intent_epoch" &&
   is_uint "\$home_intent_ts" && is_uint "\$home_intent_mono" &&
   is_uint "\$home_deadline_mono" && is_uint "\$home_cancel_until_mono" &&
   [ "\$home_intent_ts" -ge "\$home_t0" ] &&
   [ \$((home_intent_ts-home_t0)) -le $MAX_MS ] &&
   [ "\$home_deadline_mono" -ge "\$home_intent_mono" ] &&
   [ "\$home_cancel_until_mono" -ge "\$home_deadline_mono" ] &&
   home_record_identity_matches "\$home_resign_ack" &&
   [ "\$(protocol_field bid "\$home_resign_ack")" = "$EXPECTED_APP" ] &&
   home_event_in_action_window "\$home_resign_ack" &&
   home_record_identity_matches "\$home_background_ack" &&
   [ "\$(protocol_field bid "\$home_background_ack")" = "$EXPECTED_APP" ] &&
   home_event_in_action_window "\$home_background_ack" &&
   is_uint "\$home_resign_ts" && is_uint "\$home_background_ts" &&
   [ "\$home_resign_event_mono" -le "\$home_background_event_mono" ] &&
   home_record_identity_matches "\$home_terminal" &&
   [ "\$(protocol_field bid "\$home_terminal")" = "$EXPECTED_HOME" ] &&
   [ "\$(protocol_field decision "\$home_terminal")" = home_commit ] &&
   home_event_in_action_window "\$home_terminal" &&
   home_record_identity_matches "\$home_commit_evidence" &&
   [ "\$(protocol_field decision "\$home_commit_evidence")" = home_commit ] &&
   [ "\$(protocol_field status "\$home_commit_evidence")" = ok ] &&
   [ "\$(protocol_field front_write "\$home_commit_evidence")" = 1 ] &&
   [ "\$(protocol_field native_write "\$home_commit_evidence")" = 1 ] &&
   [ "\$(protocol_field late_cancel "\$home_commit_evidence")" = 0 ] &&
   [ "\$(protocol_field native_before "\$home_commit_evidence")" = "$EXPECTED_HOME" ] &&
   [ "\$(protocol_field native_after "\$home_commit_evidence")" = "$EXPECTED_HOME" ] &&
   [ "\$(protocol_field native_source "\$home_commit_evidence")" = springboard_exact_home_commit ] &&
   is_uint "\$home_terminal_ts" && is_uint "\$home_commit_ts" &&
   is_uint "\$home_commit_mono" &&
   [ "\$home_commit_ack_ts" = "\$home_background_ts" ] &&
   [ "\$home_commit_ts" = "\$home_terminal_ts" ] &&
   [ "\$home_commit_mono" = "\$home_terminal_event_mono" ] &&
   [ "\$home_commit_mono" -ge "\$home_background_event_mono" ] &&
   [ "\$home_commit_mono" -le "\$home_deadline_mono" ] &&
   [ "\$home_commit_ts" -ge "\$home_intent_ts" ] &&
   [ ! -e "\$home_cancel_evidence" ]; then
  home_commit_ok=1
fi
echo "HOME_INTENT_NONCE=\$home_intent_nonce"
echo "HOME_INTENT_EPOCH=\$home_intent_epoch"
echo "HOME_INTENT_TS=\$home_intent_ts"
echo "HOME_INTENT_MONO=\$home_intent_mono"
echo "HOME_DEADLINE_MONO=\$home_deadline_mono"
echo "HOME_CANCEL_UNTIL_MONO=\$home_cancel_until_mono"
echo "HOME_RESIGN_EVENT_MONO=\$home_resign_event_mono"
echo "HOME_BACKGROUND_TS=\$home_background_ts"
echo "HOME_BACKGROUND_EVENT_MONO=\$home_background_event_mono"
echo "HOME_TERMINAL_TS=\$home_terminal_ts"
echo "HOME_TERMINAL_EVENT_MONO=\$home_terminal_event_mono"
echo "HOME_COMMIT_TS=\$home_commit_ts"
echo "HOME_COMMIT_MONO=\$home_commit_mono"
echo "HOME_NATIVE_NONCE=\$home_native_nonce"
echo "HOME_COMMIT_OK=\$home_commit_ok"
echo "HOME_TERMINAL_DECISION=\$(protocol_field decision "\$home_terminal")"
echo "HOME_COMMIT_STATUS=\$(protocol_field status "\$home_commit_evidence")"
echo "HOME_COMMIT_FRONT_WRITE=\$(protocol_field front_write "\$home_commit_evidence")"
echo "HOME_COMMIT_NATIVE_WRITE=\$(protocol_field native_write "\$home_commit_evidence")"
echo "HOME_COMMIT_NATIVE_BEFORE=\$(protocol_field native_before "\$home_commit_evidence")"
echo "HOME_COMMIT_NATIVE_AFTER=\$(protocol_field native_after "\$home_commit_evidence")"
echo "HOME_COMMIT_NATIVE_SOURCE=\$(protocol_field native_source "\$home_commit_evidence")"
echo "HOME_COMMIT_ACK_TS=\$home_commit_ack_ts"
echo "HOME_CANCEL_AT_COMMIT=\$(file_exists "\$home_cancel_evidence")"
echo "HOME_COMMIT_LINE=\$(grep -F "go_home background_commit nonce=\$home_intent_nonce " \
  "\$V/.ziyan_minimize_log" 2>/dev/null | tail -1)"

if [ "\$home_ok" = 1 ] && [ "\$home_commit_ok" = 1 ]; then
  home_stage=PASS
else
  if [ "\$home_ok" = 1 ]; then
    set_remote_fail 34 home_commit
  else
    set_remote_fail 21 home
  fi
fi

if [ "\$home_stage" = PASS ]; then
  # A transition that rebounds to the App even briefly is still a Home failure.
  # Continuously inspect the interval through 4.5s from the original request;
  # sparse 1.5/3.0/4.5s snapshots can miss a short App rebound.
  home_stable_stage=FAIL
  stable_violation=0
  stable_rebound=0
  stable_cancel_invalid=0
  stable_locked=0
  stable_proc_violation=0
  stable_elapsed=-1
  stable_checks=0
  home_stable_t0="\$(now_ms)"
  echo "HOME_STABLE_T0=\$home_stable_t0"
  SST="\$HST"
  stable_live="\$h_live"
  if ! is_uint "\$home_stable_t0"; then
    stable_violation=1
  fi
  while [ "\$stable_violation" = 0 ]; do
    stable_elapsed="\$(elapsed_ms "\$home_stable_t0")"
    is_uint "\$stable_elapsed" || { stable_violation=1; break; }
    if [ "\$(display_locked)" != 0 ]; then
      stable_locked=1
      stable_violation=1
      break
    fi
    if [ \$((stable_checks % 5)) -eq 0 ] && ! round_process_guard; then
      stable_proc_violation=1
      stable_violation=1
      break
    fi
    if [ -f "\$home_cancel_evidence" ]; then
      if home_cancel_matches_current; then
        stable_rebound=1
      else
        stable_cancel_invalid=1
      fi
      stable_violation=1
      break
    fi
    SST="\$(status_text)"
    stable_live="\$(live_front_or_unavailable "\$home_t0")"
    stable_checks=\$((stable_checks + 1))
    if ! status_matches "\$SST" "$EXPECTED_HOME" 7 "\$pre_home_seq" $MAX_MS ||
       [ "\$stable_live" != "$EXPECTED_HOME" ]; then
      stable_violation=1
      break
    fi
    [ "\$stable_elapsed" -ge $HOME_STABLE_MS ] && break
    sleep .05
  done
  echo "HOME_STABLE_OK=\$((stable_violation == 0 ? 1 : 0))"
  echo "HOME_STABLE_MS=\$stable_elapsed"
  echo "HOME_STABLE_CHECKS=\$stable_checks"
  echo "HOME_STABLE_REBOUND=\$stable_rebound"
  echo "HOME_STABLE_CANCEL_INVALID=\$stable_cancel_invalid"
  echo "HOME_STABLE_LOCKED=\$stable_locked"
  echo "HOME_STABLE_PROC_VIOLATION=\$stable_proc_violation"
  echo "HOME_STABLE_SESSION=\$(status_val "\$SST" session)"
  echo "HOME_STABLE_WANTS_RUN=\$(status_val "\$SST" wants_run)"
  echo "HOME_STABLE_PROVIDER=\$(status_val "\$SST" frame_provider)"
  echo "HOME_STABLE_STATUS=\$(status_val "\$SST" frame_status)"
  echo "HOME_STABLE_FRONT=\$(status_val "\$SST" front_bid)"
  echo "HOME_STABLE_SHM=\$(status_val "\$SST" shm_bid)"
  echo "HOME_STABLE_SEQ=\$(status_val "\$SST" frame_seq)"
  echo "HOME_STABLE_LIVE_FRONT=\$stable_live"
  echo "HOME_STABLE_DISPLAY_LOCKED=\$(display_locked)"
  if [ "\$stable_violation" = 0 ]; then
    home_stable_stage=PASS
  else
    set_remote_fail 33 home_stability
  fi
fi

# The no-rebound window starts immediately after the first valid Home commit.
# Toast may wait 4s and snapshot may block 2s, so both are deliberately after
# the continuous stability latch; otherwise a transient rebound can be missed.
if [ "\$home_stage" = PASS ] && [ "\$home_stable_stage" = PASS ]; then
  home_toast_t0="\$(now_ms)"
  echo "HOME_TOAST_T0=\$home_toast_t0"
  if is_uint "\$home_toast_t0" &&
     emit_tagged_toast "\$home_tag" &&
     wait_new_toast HOME "\$home_toast_before" "$EXPECTED_HOME" \
       "\$TMP_HOME_TOAST" "\$home_toast_t0" "\$home_tag"; then
    home_toast_stage=PASS
  else
    home_toast_stage=FAIL
    set_remote_fail 31 home_toast
  fi
fi
if wget -qO "\$TMP_HOME" -T 2 http://127.0.0.1:50005/snapshot 2>/dev/null; then
  home_snapshot=1
fi

home_cancel_after_stable=0
home_cancel_after_stable_valid=0
if [ "\$home_stage" = PASS ] && [ -f "\$home_cancel_evidence" ]; then
  home_cancel_after_stable=1
  home_cancel_matches_current && home_cancel_after_stable_valid=1
  home_stable_stage=FAIL
  set_remote_fail 35 home_rebound_after_stable
fi
echo "HOME_CANCEL_AFTER_STABLE=\$home_cancel_after_stable"
echo "HOME_CANCEL_AFTER_STABLE_VALID=\$home_cancel_after_stable_valid"

if [ "\$home_stage" = PASS ] && [ "\$home_stable_stage" = PASS ]; then
  # App: require the immediately preceding Home/provider-7 state, then a new
  # provider-8 seq plus native App sample newer than the open request.
  app_stage=FAIL
  app_toast_before="\$(toast_gen)"
  app_tag="p2-r\${ROUND}-app"
  PRE_AST="\$(status_text)"
  pre_app_seq="\$(status_val "\$PRE_AST" frame_seq)"
  pre_app_live="\$(live_front_or_unavailable 0)"
  echo "PRE_APP_SESSION=\$(status_val "\$PRE_AST" session)"
  echo "PRE_APP_WANTS_RUN=\$(status_val "\$PRE_AST" wants_run)"
  echo "PRE_APP_FRONT=\$(status_val "\$PRE_AST" front_bid)"
  echo "PRE_APP_SHM=\$(status_val "\$PRE_AST" shm_bid)"
  echo "PRE_APP_PROVIDER=\$(status_val "\$PRE_AST" frame_provider)"
  echo "PRE_APP_STATUS=\$(status_val "\$PRE_AST" frame_status)"
  echo "PRE_APP_SEQ=\$pre_app_seq"
  echo "PRE_APP_LIVE_FRONT=\$pre_app_live"
  echo "PRE_APP_DISPLAY_LOCKED=\$(display_locked)"
  app_ok=0
  app_ms=-1
  app_t0=-1
  a_live=UNAVAILABLE
  AST="\$PRE_AST"
  if status_matches "\$PRE_AST" "$EXPECTED_HOME" 7 "" $MAX_MS &&
     [ "\$pre_app_live" = "$EXPECTED_HOME" ] && is_uint "\$pre_app_seq"; then
    rm -f "\$V/.ziyan_app_user_closed"
    printf '%s\n' "$EXPECTED_APP" >"\$V/.ziyan_open_app.tmp"
    chmod 666 "\$V/.ziyan_open_app.tmp" 2>/dev/null
    app_t0="\$(now_ms)"
    if is_uint "\$app_t0"; then
      mv "\$V/.ziyan_open_app.tmp" "\$V/.ziyan_open_app"
      requested=0
      while :; do
        AST="\$(status_text)"
        af="\$(status_val "\$AST" front_bid)"
        if [ "\$af" = "$EXPECTED_APP" ] && [ "\$requested" = 0 ]; then
          rm -f "\$V/.ziyan_open_app"
          echo 1 >"\$V/.ziyan_force_recap"
          echo 1 >"\$V/.ziyan_frame_req"
          requested=1
        fi
        a_live="\$(live_front_or_unavailable "\$app_t0")"
        app_ms="\$(elapsed_ms "\$app_t0")"
        if status_matches "\$AST" "$EXPECTED_APP" 8 "\$pre_app_seq" $MAX_MS &&
           [ "\$a_live" = "$EXPECTED_APP" ] && is_uint "\$app_ms" &&
           [ "\$app_ms" -le $MAX_MS ]; then
          app_ok=1
          break
        fi
        is_uint "\$app_ms" || break
        [ "\$app_ms" -ge $MAX_MS ] && break
        sleep .05
      done
    else
      set_remote_fail 29 app_clock
    fi
  else
    set_remote_fail 29 pre_app
  fi
  rm -f "\$V/.ziyan_open_app"
  echo "APP_OK=\$app_ok"
  echo "APP_MS=\$app_ms"
  echo "APP_SESSION=\$(status_val "\$AST" session)"
  echo "APP_WANTS_RUN=\$(status_val "\$AST" wants_run)"
  echo "APP_PROVIDER=\$(status_val "\$AST" frame_provider)"
  echo "APP_STATUS=\$(status_val "\$AST" frame_status)"
  echo "APP_FRONT=\$(status_val "\$AST" front_bid)"
  echo "APP_SHM=\$(status_val "\$AST" shm_bid)"
  echo "APP_AGE_MS=\$(status_val "\$AST" frame_age_ms)"
  echo "APP_SEQ=\$(status_val "\$AST" frame_seq)"
  echo "APP_LIVE_FRONT=\$a_live"
  echo "APP_LIVE_TS_MS=\$(native_front_field ts_ms)"
  echo "APP_LIVE_SOURCE=\$(native_front_field source)"
  echo "APP_DISPLAY_LOCKED=\$(display_locked)"

  if [ "\$app_ok" = 1 ]; then
    app_stage=PASS
    api_seq_app_start="\$(api_seq_last)"
    api_vm_gen_app_start="\$(embed_field vm_gen)"
    echo "API_SEQ_APP_START=\$api_seq_app_start"
    echo "API_VM_GEN_APP_START=\$api_vm_gen_app_start"
    if emit_tagged_toast "\$app_tag" &&
       wait_new_toast APP "\$app_toast_before" "$EXPECTED_APP" \
         "\$TMP_APP_TOAST" "\$app_t0" "\$app_tag"; then
      app_toast_stage=PASS
    else
      app_toast_stage=FAIL
      set_remote_fail 32 app_toast
    fi

    if wget -qO "\$TMP_APP" -T 2 http://127.0.0.1:50005/snapshot 2>/dev/null; then
      app_snapshot=1
    fi

    # Same-VM shadow proof: the request is consumed only by the next natural
    # business find wrapper inside the running LuaEmbed VM.  The ack proves a
    # real getColor plus positive/negative 1x1 find without color_req fallback.
    embed_shadow_stage=FAIL
    shadow_nonce="c80shadow_r\${ROUND}_\$(date +%s)_\$\$"
    shadow_ack="\$V/.ziyan_embed_api_probe_ack.\$shadow_nonce"
    rm -f "\$V/.ziyan_embed_api_probe" "\$V/.ziyan_embed_api_probe.tmp" \
          "\$shadow_ack"
    printf 'version=1\nnonce=%s\nx=706\ny=449\n' "\$shadow_nonce" \
      >"\$V/.ziyan_embed_api_probe.tmp"
    chmod 666 "\$V/.ziyan_embed_api_probe.tmp" 2>/dev/null
    shadow_t0="\$(now_ms)"
    mv "\$V/.ziyan_embed_api_probe.tmp" "\$V/.ziyan_embed_api_probe"
    shadow_wait_ms=-1
    while :; do
      shadow_wait_ms="\$(elapsed_ms "\$shadow_t0")"
      if [ -f "\$shadow_ack" ] &&
         [ "\$(protocol_field nonce "\$shadow_ack")" = "\$shadow_nonce" ]; then
        break
      fi
      is_uint "\$shadow_wait_ms" || break
      [ "\$shadow_wait_ms" -ge 15000 ] && break
      sleep .05
    done
    echo "EMBED_SHADOW_NONCE=\$shadow_nonce"
    echo "EMBED_SHADOW_WAIT_MS=\$shadow_wait_ms"
    for shadow_key in version nonce status mode embed embed_pid script vm_gen \
      vm_start_mono_ms clock x y \
      color alt_color get_ms hit_ms miss_ms total_ms hit_x hit_y miss_x miss_y \
      get_ok hit_ok miss_ok get_via hit_via miss_via keep_was keep_temp \
      keep_restore_ok embed_get_delta embed_find_delta color_req_get_delta \
      color_req_find_delta front reason; do
      shadow_value="\$(protocol_field "\$shadow_key" "\$shadow_ack")"
      shadow_upper="\$(printf '%s' "\$shadow_key" | tr '[:lower:]' '[:upper:]')"
      echo "EMBED_SHADOW_\${shadow_upper}=\$shadow_value"
    done
    if [ "\$(protocol_field status "\$shadow_ack")" = ok ] &&
       [ "\$(protocol_field nonce "\$shadow_ack")" = "\$shadow_nonce" ]; then
      embed_shadow_stage=PASS
    else
      set_remote_fail 26 embed_shadow
    fi

    embed_natural_stage=FAIL
    api_natural_wait_t0="\$(now_ms)"
    api_seq_natural_after="\$(api_seq_last)"
    api_natural_wait_ms=-1
    if is_uint "\$api_seq_app_start" && is_uint "\$api_natural_wait_t0"; then
      api_seq_target=\$((api_seq_app_start + 20))
      while :; do
        api_seq_natural_after="\$(api_seq_last)"
        api_natural_wait_ms="\$(elapsed_ms "\$api_natural_wait_t0")"
        if is_uint "\$api_seq_natural_after" &&
           [ "\$api_seq_natural_after" -ge "\$api_seq_target" ]; then
          embed_natural_stage=PASS
          break
        fi
        is_uint "\$api_natural_wait_ms" || break
        [ "\$api_natural_wait_ms" -ge 15000 ] && break
        sleep .05
      done
    fi
    echo "API_SEQ_NATURAL_AFTER=\$api_seq_natural_after"
    echo "API_NATURAL_WAIT_MS=\$api_natural_wait_ms"
    if [ "\$embed_natural_stage" != PASS ]; then
      set_remote_fail 27 embed_natural_samples
    fi

    # Deterministic daemon-IPC protocol probe.  This writes color_req and is
    # intentionally NOT labelled LuaEmbed coverage; LuaEmbed proof is the
    # same-VM shadow ack plus monotonic natural API CSV parsed on the host.
    # Timing begins immediately before the atomic publish (mv).
    daemon_getcolor_stage=FAIL
    rm -f "\$V/.ziyan_color_rep"
    nonce="c80_r\${ROUND}_\$(date +%s)_\$\$"
    printf 'getColor\n706\n449\n%s\n' "\$nonce" >"\$V/.ziyan_color_req.tmp"
    color_t0="\$(now_ms)"
    mv "\$V/.ziyan_color_req.tmp" "\$V/.ziyan_color_req"
    color_ok=0
    color_ms=-1
    while :; do
      if [ -f "\$V/.ziyan_color_rep" ] && grep -q "\$nonce" "\$V/.ziyan_color_rep" 2>/dev/null; then
        color_ok=1
      fi
      color_ms="\$(elapsed_ms "\$color_t0")"
      [ "\$color_ok" = 1 ] && break
      case "\$color_ms" in ''|*[!0-9]*) break ;; esac
      [ "\$color_ms" -ge $MAX_MS ] && break
      sleep .02
    done
    color="\$(sed -n 3p "\$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')"
    echo "DAEMON_GETCOLOR_ACK=\$color_ok"
    echo "DAEMON_GETCOLOR_MS=\$color_ms"
    echo "DAEMON_COLOR=\$color"
    if [ "\$color_ok" = 1 ] && [ "\$color" = "$EXPECTED_COLOR" ]; then
      case "\$color_ms" in ''|*[!0-9]*) set_remote_fail 23 getcolor_clock ;;
        *) if [ "\$color_ms" -le $MAX_MS ]; then daemon_getcolor_stage=PASS; else set_remote_fail 23 getcolor_slow; fi ;;
      esac
    else
      set_remote_fail 23 getcolor
    fi

    # Controlled daemon correctness probe.  This is a known screen fixture from
    # the earlier login capture; it is deliberately not labelled as the current
    # ios7.lua business pattern or as LuaEmbed latency.
    daemon_find_stage=FAIL
    rm -f "\$V/.ziyan_color_rep"
    fnonce="c80_find_r\${ROUND}_\$(date +%s)_\$\$"
    printf 'findMulti\n[{"c":12688231,"dx":0,"dy":0,"b":0},{"c":11963216,"dx":1,"dy":2,"b":0},{"c":13873793,"dx":1,"dy":4,"b":0},{"c":14202760,"dx":0,"dy":5,"b":0}]\n90\n706\n449\n707\n454\n%s\n' "\$fnonce" >"\$V/.ziyan_color_req.tmp"
    find_t0="\$(now_ms)"
    mv "\$V/.ziyan_color_req.tmp" "\$V/.ziyan_color_req"
    find_ack=0
    find_ms=-1
    while :; do
      if [ -f "\$V/.ziyan_color_rep" ] && grep -q "\$fnonce" "\$V/.ziyan_color_rep" 2>/dev/null; then
        find_ack=1
      fi
      find_ms="\$(elapsed_ms "\$find_t0")"
      [ "\$find_ack" = 1 ] && break
      case "\$find_ms" in ''|*[!0-9]*) break ;; esac
      [ "\$find_ms" -ge $MAX_MS ] && break
      sleep .02
    done
    find_body="\$(sed -n 3p "\$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')"
    echo "DAEMON_FIND_ACK=\$find_ack"
    echo "DAEMON_FIND_MS=\$find_ms"
    echo "DAEMON_FIND_BODY=\$find_body"
    if [ "\$find_ack" = 1 ] && printf '%s\n' "\$find_body" | grep -q '"ok":true'; then
      case "\$find_ms" in ''|*[!0-9]*) set_remote_fail 24 find_clock ;;
        *) if [ "\$find_ms" -le $MAX_MS ]; then daemon_find_stage=PASS; else set_remote_fail 24 find_slow; fi ;;
      esac
    else
      set_remote_fail 24 find
    fi

    # Contradictory offsets at the same relative coordinate must never match.
    # This catches implementations that only test the base color and ignore the
    # multi-point constraints.
    daemon_find_neg_stage=FAIL
    rm -f "\$V/.ziyan_color_rep"
    fneg_nonce="c80_find_neg_r\${ROUND}_\$(date +%s)_\$\$"
    printf 'findMulti\n[{"c":12688231,"dx":0,"dy":0,"b":0},{"c":0,"dx":1,"dy":2,"b":0},{"c":16777215,"dx":1,"dy":2,"b":0}]\n100\n706\n449\n707\n454\n%s\n' "\$fneg_nonce" >"\$V/.ziyan_color_req.tmp"
    find_neg_t0="\$(now_ms)"
    mv "\$V/.ziyan_color_req.tmp" "\$V/.ziyan_color_req"
    find_neg_ack=0
    find_neg_ms=-1
    while :; do
      if [ -f "\$V/.ziyan_color_rep" ] && grep -Fq "\$fneg_nonce" "\$V/.ziyan_color_rep" 2>/dev/null; then
        find_neg_ack=1
      fi
      find_neg_ms="\$(elapsed_ms "\$find_neg_t0")"
      [ "\$find_neg_ack" = 1 ] && break
      case "\$find_neg_ms" in ''|*[!0-9]*) break ;; esac
      [ "\$find_neg_ms" -ge $MAX_MS ] && break
      sleep .02
    done
    find_neg_body="\$(sed -n 3p "\$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')"
    echo "DAEMON_FIND_NEG_ACK=\$find_neg_ack"
    echo "DAEMON_FIND_NEG_MS=\$find_neg_ms"
    echo "DAEMON_FIND_NEG_BODY=\$find_neg_body"
    if [ "\$find_neg_ack" = 1 ] &&
       printf '%s\n' "\$find_neg_body" | grep -q '"ok":false'; then
      case "\$find_neg_ms" in ''|*[!0-9]*) set_remote_fail 25 find_neg_clock ;;
        *) if [ "\$find_neg_ms" -le $MAX_MS ]; then daemon_find_neg_stage=PASS; else set_remote_fail 25 find_neg_slow; fi ;;
      esac
    else
      set_remote_fail 25 find_offsets_ignored
    fi
  else
    set_remote_fail 22 app
  fi
fi

echo "PULSE_AFTER=\$(pulse_n)"
# 失败也必须走到这个收尾：用真实时钟有界等票，然后保存完整诊断。
ticket_t0="\$(now_ms)"
RST="\$(resident_status 250 1)"
ticket_wait_ms="\$(elapsed_ms "\$ticket_t0")"
echo "TICKET_DRAIN_MS=\$ticket_wait_ms"
echo "RESIDENT_READERS=\$(status_val "\$RST" resident_readers)"
echo "TICKET_MAPS_AFTER=\$(status_val "\$RST" resident_ticket_maps)"
echo "TICKET_UNMAPS_AFTER=\$(status_val "\$RST" resident_ticket_unmaps)"
echo "WRITER_WAITS_AFTER=\$(status_val "\$RST" resident_writer_waits)"
echo "INVALID_UNMAPS_AFTER=\$(status_val "\$RST" resident_invalid_unmaps)"
echo "TICKET_EXHAUSTS_AFTER=\$(status_val "\$RST" resident_ticket_exhausts)"
echo "EMBED_FLAG_AFTER=\$(embed_flag)"
echo "EMBED_ALIVE_TS_AFTER=\$(embed_field ts)"
echo "EMBED_ALIVE_PID_AFTER=\$(embed_field pid)"
echo "EMBED_VM_GEN_AFTER=\$(embed_field vm_gen)"
echo "EMBED_VM_START_MONO_MS_AFTER=\$(embed_field vm_start_mono_ms)"
echo "EMBED_AGE_S_AFTER=\$(embed_age_s)"
echo "EMBED_FIND_AFTER=\$(path_stat via_embed_find)"
echo "COLOR_REQ_FIND_AFTER=\$(path_stat via_color_req_find)"
echo "EMBED_SCRIPT_SHA_AFTER=\$(embed_script_sha)"
echo "API_CSV_HEADER_AFTER=\$(api_csv_header)"
echo "API_SEQ_AFTER=\$(api_seq_last)"
echo "APPFRAME_TIMEOUTS_AFTER=\$(match_count 'side=client stage=timeout ' "\$V/.ziyan_app_frame_trace")"
echo "APPFRAME_INVALID_AFTER=\$(match_count 'side=app stage=claim_invalid ' "\$V/.ziyan_app_frame_trace")"
echo "EXIT_LINES_AFTER=\$(line_count "\$V/.ziyan_framecap_exit_hist")"
echo "EXIT_HIST_EXISTS_AFTER=\$(file_exists "\$V/.ziyan_framecap_exit_hist")"
echo "EXIT_SHA_AFTER=\$(file_sha "\$V/.ziyan_framecap_exit_hist")"
echo "SIG11_LINES_AFTER=\$(match_count 'event=signal value=11 ' "\$V/.ziyan_framecap_exit_hist")"
echo "ZOMBIES=\$(relevant_zombies)"
echo "RESIDENT=\$(file_text "\$V/.ziyan_resident_bytes")"
emit_101_procs after
echo "HOME_STAGE=\$home_stage"
echo "HOME_STABLE_STAGE=\$home_stable_stage"
echo "APP_STAGE=\$app_stage"
echo "HOME_TOAST_STAGE=\$home_toast_stage"
echo "APP_TOAST_STAGE=\$app_toast_stage"
echo "DAEMON_GETCOLOR_STAGE=\$daemon_getcolor_stage"
echo "DAEMON_FIND_STAGE=\$daemon_find_stage"
echo "DAEMON_FIND_NEG_STAGE=\$daemon_find_neg_stage"
echo "EMBED_SHADOW_STAGE=\$embed_shadow_stage"
echo "EMBED_NATURAL_STAGE=\$embed_natural_stage"
echo "HOME_SNAPSHOT=\$home_snapshot"
echo "APP_SNAPSHOT=\$app_snapshot"
echo "ROUND_END_MS=\$(now_ms)"
echo "DIAG_TAIL=1"
if [ "\$remote_rc" = 0 ]; then
  echo "ROUND_REMOTE_VERDICT=COMPLETE"
else
  echo "ROUND_REMOTE_VERDICT=FAIL_\$remote_reason"
fi
exit "\$remote_rc"
REMOTE
}

completed=0
overall_reason=all_rounds_passed

for round in $(seq 1 "$ROUNDS"); do
  RDIR="$(printf '%s/rounds/%02d' "$OUT" "$round")"
  mkdir -p "$RDIR"
  echo "ROUND=$round START=$(date '+%F %T %z')" | tee -a "$LOG"

  if ! sample_171 "r${round}_home" home "$RDIR/171_home.txt"; then
    overall_reason="round_${round}_171_home_ssh"
    write_verdict FAIL "$overall_reason"
    exit 1
  fi
  if ! fetch_171_snapshot "$RDIR/171_home.jpg" ||
     ! analyze_171_snapshot "$RDIR/171_home.jpg" "$RDIR/171_home_snapshot.txt" 1; then
    overall_reason="round_${round}_171_home_snapshot"
    write_verdict FAIL "$overall_reason" || true
    exit 1
  fi

  round_rc=0
  toast_visual_watch "$round" "$RDIR" >"$RDIR/toast_visual_watch.txt" 2>&1 &
  TOAST_WATCH_PID=$!
  sleep .3
  sample_101_round "$round" "$RDIR/101.txt" || round_rc=$?
  for _watch_wait in $(seq 1 20); do
    kill -0 "$TOAST_WATCH_PID" 2>/dev/null || break
    sleep .1
  done
  kill "$TOAST_WATCH_PID" >/dev/null 2>&1 || true
  wait "$TOAST_WATCH_PID" 2>/dev/null || true
  TOAST_WATCH_PID=""

  # Pull only evidence that the remote round says it froze.  Repeated SCP calls
  # for NOT_RUN files triggered iOS sshd authentication throttling and then made
  # the real exit-history pull look missing.
  exit_hist_pull_ok=0
  exit_tmp="$RDIR/exit_hist.txt.tmp"
  for pull_try in 1 2 3; do
    rm -f "$exit_tmp"
    if ssh_one "$IP101" "cat /usr/lib/ziyan/var/.ziyan_framecap_exit_hist" \
         >"$exit_tmp" 2>"$RDIR/exit_hist_pull_${pull_try}.err" &&
       [ -s "$exit_tmp" ]; then
      mv "$exit_tmp" "$RDIR/exit_hist.txt"
      exit_hist_pull_ok=1
      break
    fi
    sleep 1
  done
  rm -f "$exit_tmp"
  api_csv_pull_ok=0
  api_csv_tmp="$RDIR/api_cycle.csv.tmp"
  for pull_try in 1 2 3; do
    rm -f "$api_csv_tmp"
    if ssh_one "$IP101" "cat /usr/lib/ziyan/var/.ziyan_ts_cycle.csv" \
         >"$api_csv_tmp" 2>"$RDIR/api_cycle_pull_${pull_try}.err" &&
       [ "$(sed -n '1p' "$api_csv_tmp" | tr -d '\r')" = "$EXPECTED_API_HEADER" ]; then
      mv "$api_csv_tmp" "$RDIR/api_cycle.csv"
      api_csv_pull_ok=1
      break
    fi
    sleep 1
  done
  rm -f "$api_csv_tmp"
  api_window_analyze_ok=0
  if [ "$api_csv_pull_ok" = 1 ]; then
    if python3 - "$RDIR/api_cycle.csv" \
         "$(kv API_SEQ_APP_START "$RDIR/101.txt")" \
         "$(kv API_SEQ_AFTER "$RDIR/101.txt")" \
         "$EXPECTED_APP" "$(kv API_VM_GEN_APP_START "$RDIR/101.txt")" \
         "$EXPECTED_PATTERN_A" "$EXPECTED_PATTERN_B" \
         "$MAX_MS" "$RDIR/embed_api_window.csv" \
         >"$RDIR/embed_api_window.txt" <<'PY'
import csv
import math
import sys

src, start_raw, end_raw, expected_front, vm_gen_raw, pattern_a, pattern_b, max_raw, out_csv = sys.argv[1:]
try:
    start_seq = int(start_raw)
    end_seq = int(end_raw)
    expected_vm_gen = int(vm_gen_raw)
    max_ms = float(max_raw)
except Exception:
    raise SystemExit(2)
if expected_vm_gen < 1:
    raise SystemExit(2)

expected_header = [
    "wall_ms", "find_ms", "cycle_ms", "x", "y", "hit", "front_bid",
    "mono_ms", "api_seq", "op", "clock", "embed", "vm_gen", "via", "pattern_id",
    "main", "fuzzy", "x1", "y1", "x2", "y2", "color", "point_count",
    "dropped_get",
]
meta = {
    pattern_a: {"main": 9250329, "fuzzy": 90, "x1": 1010, "y1": 294,
                "x2": 1010, "y2": 300, "point_count": 4},
    pattern_b: {"main": 13382436, "fuzzy": 90, "x1": 25, "y1": 21,
                "x2": 25, "y2": 27, "point_count": 4},
}

with open(src, newline="", encoding="utf-8", errors="strict") as f:
    reader = csv.DictReader(f)
    if reader.fieldnames != expected_header:
        raise SystemExit(3)
    rows = []
    for row in reader:
        try:
            seq = int(row["api_seq"])
        except Exception:
            continue
        if start_seq < seq <= end_seq:
            row["_seq"] = seq
            rows.append(row)

if end_seq <= start_seq or not rows:
    raise SystemExit(4)
seqs = [r["_seq"] for r in rows]
if len(seqs) != len(set(seqs)) or seqs != sorted(seqs):
    raise SystemExit(5)
if seqs[0] != start_seq + 1 or seqs[-1] != end_seq:
    raise SystemExit(13)
if seqs != list(range(start_seq + 1, end_seq + 1)):
    raise SystemExit(14)

find_rows = []
get_rows = []
pattern_counts = {pattern_a: 0, pattern_b: 0}
last_mono = None
last_find_mono = None
for row in rows:
    if row["clock"] != "embed_mono" or row["embed"] != "1" or row["via"] != "embed":
        raise SystemExit(6)
    if int(row["vm_gen"]) != expected_vm_gen:
        raise SystemExit(17)
    if row["front_bid"] != expected_front or int(row["dropped_get"]) != 0:
        raise SystemExit(7)
    duration = float(row["find_ms"])
    if not math.isfinite(duration) or duration < 0 or duration > max_ms:
        raise SystemExit(8)
    mono = int(row["mono_ms"])
    cycle = float(row["cycle_ms"])
    if mono < 0 or not math.isfinite(cycle) or cycle < 0:
        raise SystemExit(15)
    if last_mono is not None and mono < last_mono:
        raise SystemExit(16)
    last_mono = mono
    row["_duration"] = duration
    if row["op"] == "find":
        if last_find_mono is not None:
            expected_cycle = mono - last_find_mono
            if abs(cycle - expected_cycle) > 0.01:
                raise SystemExit(18)
        last_find_mono = mono
        pid = row["pattern_id"]
        if pid not in meta:
            raise SystemExit(9)
        for key, expected in meta[pid].items():
            if int(row[key]) != expected:
                raise SystemExit(10)
        pattern_counts[pid] += 1
        find_rows.append(row)
    elif row["op"] == "getColor":
        if abs(cycle) > 0.01:
            raise SystemExit(19)
        get_rows.append(row)
    else:
        raise SystemExit(11)

if len(find_rows) < 20 or min(pattern_counts.values()) < 5:
    raise SystemExit(12)

def nearest(values, pct):
    values = sorted(values)
    rank = max(1, min(len(values), math.ceil(len(values) * pct / 100.0)))
    return values[rank - 1]

find_ms = [r["_duration"] for r in find_rows]
get_ms = [r["_duration"] for r in get_rows]
with open(out_csv, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["api_seq", "vm_gen", "op", "pattern_id", "duration_ms", "x", "y", "hit"])
    for row in rows:
        w.writerow([row["_seq"], row["vm_gen"], row["op"], row["pattern_id"],
                    f'{row["_duration"]:.3f}', row["x"], row["y"], row["hit"]])

print("API_WINDOW_OK=1")
print(f"API_SEQ_START={start_seq}")
print(f"API_SEQ_END={end_seq}")
print(f"API_VM_GEN={expected_vm_gen}")
print(f"EMBED_FIND_SAMPLES={len(find_rows)}")
print(f"EMBED_PATTERN_A_SAMPLES={pattern_counts[pattern_a]}")
print(f"EMBED_PATTERN_B_SAMPLES={pattern_counts[pattern_b]}")
print(f"EMBED_FIND_MS_P50={nearest(find_ms, 50):.3f}")
print(f"EMBED_FIND_MS_P95={nearest(find_ms, 95):.3f}")
print(f"EMBED_FIND_MS_MAX={max(find_ms):.3f}")
print(f"EMBED_GETCOLOR_NATURAL_SAMPLES={len(get_rows)}")
if get_ms:
    print(f"EMBED_GETCOLOR_MS_P50={nearest(get_ms, 50):.3f}")
    print(f"EMBED_GETCOLOR_MS_P95={nearest(get_ms, 95):.3f}")
    print(f"EMBED_GETCOLOR_MS_MAX={max(get_ms):.3f}")
else:
    print("EMBED_GETCOLOR_MS_P50=UNAVAILABLE")
    print("EMBED_GETCOLOR_MS_P95=UNAVAILABLE")
    print("EMBED_GETCOLOR_MS_MAX=UNAVAILABLE")
PY
    then
      api_window_analyze_ok=1
    fi
  fi
  [ "$(kv HOME_SNAPSHOT "$RDIR/101.txt")" = 1 ] &&
    scp_from "$IP101" "/tmp/zy_p2_c80_r${round}_home.png" "$RDIR/home.png" >/dev/null 2>&1 || true
  [ "$(kv APP_SNAPSHOT "$RDIR/101.txt")" = 1 ] &&
    scp_from "$IP101" "/tmp/zy_p2_c80_r${round}_app.png" "$RDIR/app.png" >/dev/null 2>&1 || true
  [ "$(kv HOME_TOAST_STAGE "$RDIR/101.txt")" = PASS ] &&
    scp_from "$IP101" "/tmp/zy_p2_c80_r${round}_home_toast.txt" "$RDIR/home_toast.txt" >/dev/null 2>&1 || true
  [ "$(kv APP_TOAST_STAGE "$RDIR/101.txt")" = PASS ] &&
    scp_from "$IP101" "/tmp/zy_p2_c80_r${round}_app_toast.txt" "$RDIR/app_toast.txt" >/dev/null 2>&1 || true

  fail=0
  reason=""
  mark_fail() { fail=1; reason="${reason}${reason:+,}$1"; }
  is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
  check_toast() {
    local tag="$1" expected_text="$2" file="$3" gen_before="$4" gen_after="$5" captured="$6" toast_ms="$7" file_gen
    if [ ! -f "$file" ]; then
      mark_fail "${tag}_toast_evidence_missing"
      return
    fi
    grep -q '^phase=visible_commit ' "$file" || mark_fail "${tag}_toast_phase"
    grep -q 'branch=rawLand_identity_iOS13' "$file" || mark_fail "${tag}_toast_branch"
    grep -q 'sceneActivation=0' "$file" || mark_fail "${tag}_toast_scene"
    grep -q 'hidden=0' "$file" || mark_fail "${tag}_toast_hidden"
    grep -q 'alpha=1.00' "$file" || mark_fail "${tag}_toast_alpha"
    grep -q 'raw=568x320' "$file" || mark_fail "${tag}_toast_raw_geom"
    grep -q 'winFrame=0.0,0.0,568.0x320.0' "$file" || mark_fail "${tag}_toast_win_geom"
    grep -q 'rootBounds=568.0x320.0 rootCenter=284.0,160.0' "$file" || mark_fail "${tag}_toast_root_geom"
    grep -q 'rot.a=1.000 rot.b=0.000' "$file" || mark_fail "${tag}_toast_rotation"
    grep -Fqx "text=$expected_text" "$file" || mark_fail "${tag}_toast_wrong_text"
    file_gen="$(sed -n 's/.* gen=\([0-9][0-9]*\).*/\1/p' "$file" | tail -1)"
    is_uint "$gen_after" || mark_fail "${tag}_toast_after_gen_invalid"
    is_uint "$captured" || mark_fail "${tag}_toast_captured_gen_invalid"
    if is_uint "$toast_ms"; then [ "$toast_ms" -le "$TOAST_MAX_MS" ] || mark_fail "${tag}_toast_slow"; else mark_fail "${tag}_toast_ms_invalid"; fi
    [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] || mark_fail "${tag}_toast_gen_not_new"
    [ "$captured" = "$gen_after" ] || mark_fail "${tag}_toast_capture_mismatch"
    [ "$file_gen" = "$gen_after" ] || mark_fail "${tag}_toast_file_gen_mismatch"
    if ! python3 - "$file" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"labelInWindow=([-0-9.]+),([-0-9.]+),([-0-9.]+)x([-0-9.]+)", text)
if not m:
    raise SystemExit(1)
x, y, w, h = map(float, m.groups())
ok = (x >= -0.5 and y >= 240.0 and w > 0 and h > 0 and
      x + w <= 568.5 and y + h <= 320.5 and
      abs((x + w / 2.0) - 284.0) <= 2.0)
raise SystemExit(0 if ok else 1)
PY
    then
      mark_fail "${tag}_toast_label_geom"
    fi
  }

  check_toast_visual() {
    local tag="$1" prefix="$2" image_file="$3" result_file="$4" visual_ms
    [ "$(kv "${prefix}_TOAST_VISUAL_ACK" "$RDIR/101.txt")" = 1 ] || mark_fail "${tag}_toast_visual_ack"
    visual_ms="$(kv "${prefix}_TOAST_VISUAL_MS" "$RDIR/101.txt")"
    if is_uint "$visual_ms"; then
      [ "$visual_ms" -le "$TOAST_MAX_MS" ] || mark_fail "${tag}_toast_visual_slow"
    else
      mark_fail "${tag}_toast_visual_ms_invalid"
    fi
    [ -s "$image_file" ] || mark_fail "${tag}_toast_visual_image_missing"
    [ -s "$result_file" ] || mark_fail "${tag}_toast_visual_result_missing"
    grep -q '^POSITION_OK=1$' "$result_file" 2>/dev/null || mark_fail "${tag}_toast_visual_position"
    grep -q '^VISUAL_VERDICT=PASS$' "$result_file" 2>/dev/null || mark_fail "${tag}_toast_visual_verdict"
  }

  [ "$round_rc" = 0 ] || mark_fail "remote_rc_$round_rc"
  if [ "$(kv DIAG_TAIL "$RDIR/101.txt")" != 1 ]; then
    mark_fail diagnostic_tail_missing
  else
  home_stage="$(kv HOME_STAGE "$RDIR/101.txt")"
  home_ms="$(kv HOME_MS "$RDIR/101.txt")"
  pre_home_seq="$(kv PRE_HOME_SEQ "$RDIR/101.txt")"
  home_seq="$(kv HOME_SEQ "$RDIR/101.txt")"
  [ "$(kv PRE_HOME_SESSION "$RDIR/101.txt")" = running ] || mark_fail pre_home_session
  [ "$(kv PRE_HOME_WANTS_RUN "$RDIR/101.txt")" = 1 ] || mark_fail pre_home_wants_run
  [ "$(kv PRE_HOME_FRONT "$RDIR/101.txt")" = "$EXPECTED_APP" ] || mark_fail pre_home_front
  [ "$(kv PRE_HOME_SHM "$RDIR/101.txt")" = "$EXPECTED_APP" ] || mark_fail pre_home_shm
  [ "$(kv PRE_HOME_PROVIDER "$RDIR/101.txt")" = 8 ] || mark_fail pre_home_provider
  [ "$(kv PRE_HOME_STATUS "$RDIR/101.txt")" = 0 ] || mark_fail pre_home_status
  [ "$(kv PRE_HOME_LIVE_FRONT "$RDIR/101.txt")" = "$EXPECTED_APP" ] || mark_fail pre_home_live_front
  [ "$(kv PRE_HOME_DISPLAY_LOCKED "$RDIR/101.txt")" = 0 ] || mark_fail pre_home_locked
  case "$home_stage" in
    PASS)
      [ "$(kv HOME_OK "$RDIR/101.txt")" = 1 ] || mark_fail home_not_ready
      [ "$(kv HOME_SESSION "$RDIR/101.txt")" = running ] || mark_fail home_session
      [ "$(kv HOME_WANTS_RUN "$RDIR/101.txt")" = 1 ] || mark_fail home_wants_run
      [ "$(kv HOME_PROVIDER "$RDIR/101.txt")" = 7 ] || mark_fail home_provider
      [ "$(kv HOME_STATUS "$RDIR/101.txt")" = 0 ] || mark_fail home_status
      [ "$(kv HOME_FRONT "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_front
      [ "$(kv HOME_SHM "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_shm
      [ "$(kv HOME_LIVE_FRONT "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_live_front
      [ "$(kv HOME_DISPLAY_LOCKED "$RDIR/101.txt")" = 0 ] || mark_fail home_locked
      [ "$(kv HOME_COMMIT_OK "$RDIR/101.txt")" = 1 ] || mark_fail home_background_commit
      [ -n "$(kv HOME_INTENT_NONCE "$RDIR/101.txt")" ] || mark_fail home_intent_nonce
      [ "$(kv HOME_INTENT_NONCE "$RDIR/101.txt")" != "$(kv PRE_HOME_INTENT_NONCE "$RDIR/101.txt")" ] || mark_fail home_intent_not_new
      [ "$(kv HOME_TERMINAL_DECISION "$RDIR/101.txt")" = home_commit ] || mark_fail home_terminal_decision
      [ "$(kv HOME_COMMIT_STATUS "$RDIR/101.txt")" = ok ] || mark_fail home_commit_status
      [ "$(kv HOME_COMMIT_FRONT_WRITE "$RDIR/101.txt")" = 1 ] || mark_fail home_commit_front_write
      [ "$(kv HOME_COMMIT_NATIVE_WRITE "$RDIR/101.txt")" = 1 ] || mark_fail home_commit_native_write
      [ "$(kv HOME_COMMIT_NATIVE_BEFORE "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_commit_native_before
      [ "$(kv HOME_COMMIT_NATIVE_AFTER "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_commit_native_after
      [ "$(kv HOME_COMMIT_NATIVE_SOURCE "$RDIR/101.txt")" = springboard_exact_home_commit ] || mark_fail home_commit_native_source
      [ "$(kv HOME_CANCEL_AT_COMMIT "$RDIR/101.txt")" = 0 ] || mark_fail home_cancel_at_commit
      case "$(kv HOME_LIVE_SOURCE "$RDIR/101.txt")" in
        springboard_exact_home_commit|ax_frontmost) ;;
        *) mark_fail home_live_source ;;
      esac
      [ "$(kv HOME_COMMIT_ACK_TS "$RDIR/101.txt")" = "$(kv HOME_BACKGROUND_TS "$RDIR/101.txt")" ] || mark_fail home_commit_ack_ts
      [ "$(kv HOME_TERMINAL_TS "$RDIR/101.txt")" = "$(kv HOME_COMMIT_TS "$RDIR/101.txt")" ] || mark_fail home_terminal_commit_ts
      if is_uint "$pre_home_seq" && is_uint "$home_seq"; then
        [ "$home_seq" -gt "$pre_home_seq" ] || mark_fail home_seq_not_advanced
      else
        mark_fail home_seq_invalid
      fi
      if is_uint "$home_ms"; then [ "$home_ms" -le "$MAX_MS" ] || mark_fail home_slow; else mark_fail home_ms_invalid; fi
      home_age="$(kv HOME_AGE_MS "$RDIR/101.txt")"
      if is_uint "$home_age"; then [ "$home_age" -le "$MAX_MS" ] || mark_fail home_age; else mark_fail home_age_invalid; fi
      ;;
    FAIL) mark_fail home_stage_fail ;;
    *) mark_fail home_stage_missing ;;
  esac

  home_stable_stage="$(kv HOME_STABLE_STAGE "$RDIR/101.txt")"
  case "$home_stable_stage" in
    PASS)
      [ "$(kv HOME_STABLE_OK "$RDIR/101.txt")" = 1 ] || mark_fail home_stable_not_ready
      [ "$(kv HOME_STABLE_SESSION "$RDIR/101.txt")" = running ] || mark_fail home_stable_session
      [ "$(kv HOME_STABLE_WANTS_RUN "$RDIR/101.txt")" = 1 ] || mark_fail home_stable_wants_run
      [ "$(kv HOME_STABLE_PROVIDER "$RDIR/101.txt")" = 7 ] || mark_fail home_stable_provider
      [ "$(kv HOME_STABLE_STATUS "$RDIR/101.txt")" = 0 ] || mark_fail home_stable_status
      [ "$(kv HOME_STABLE_FRONT "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_stable_front
      [ "$(kv HOME_STABLE_SHM "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_stable_shm
      [ "$(kv HOME_STABLE_LIVE_FRONT "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail home_stable_live_front
      [ "$(kv HOME_STABLE_DISPLAY_LOCKED "$RDIR/101.txt")" = 0 ] || mark_fail home_stable_locked
      [ "$(kv HOME_STABLE_REBOUND "$RDIR/101.txt")" = 0 ] || mark_fail home_stable_rebound
      [ "$(kv HOME_STABLE_CANCEL_INVALID "$RDIR/101.txt")" = 0 ] || mark_fail home_stable_cancel_invalid
      [ "$(kv HOME_STABLE_LOCKED "$RDIR/101.txt")" = 0 ] || mark_fail home_stable_lock_latched
      [ "$(kv HOME_STABLE_PROC_VIOLATION "$RDIR/101.txt")" = 0 ] || mark_fail home_stable_proc_latched
      [ "$(kv HOME_CANCEL_AFTER_STABLE "$RDIR/101.txt")" = 0 ] || mark_fail home_cancel_after_stable
      stable_ms="$(kv HOME_STABLE_MS "$RDIR/101.txt")"
      stable_checks="$(kv HOME_STABLE_CHECKS "$RDIR/101.txt")"
      if is_uint "$stable_ms"; then
        [ "$stable_ms" -ge "$HOME_STABLE_MS" ] || mark_fail home_stable_window_short
      else
        mark_fail home_stable_ms_invalid
      fi
      if is_uint "$stable_checks"; then
        [ "$stable_checks" -ge 10 ] || mark_fail home_stable_checks_too_few
      else
        mark_fail home_stable_checks_invalid
      fi
      ;;
    FAIL) mark_fail home_stability_fail ;;
    NOT_RUN) [ "$home_stage" = PASS ] && mark_fail home_stability_not_run ;;
    *) mark_fail home_stability_stage_missing ;;
  esac

  home_toast_stage="$(kv HOME_TOAST_STAGE "$RDIR/101.txt")"
  case "$home_toast_stage" in
    PASS) [ "$(kv HOME_TOAST_OK "$RDIR/101.txt")" = 1 ] || mark_fail home_toast_not_new; check_toast home "p2-r${round}-home" "$RDIR/home_toast.txt" "$(kv HOME_TOAST_GEN_BEFORE "$RDIR/101.txt")" "$(kv HOME_TOAST_GEN_AFTER "$RDIR/101.txt")" "$(kv HOME_TOAST_CAPTURED_GEN "$RDIR/101.txt")" "$(kv HOME_TOAST_MS "$RDIR/101.txt")"; check_toast_visual home HOME "$RDIR/home_toast_screen.png" "$RDIR/home_toast_visual.txt" ;;
    FAIL) mark_fail home_toast_not_new ;;
    NOT_RUN) [ "$home_stage" = PASS ] && mark_fail home_toast_not_run ;;
    *) mark_fail home_toast_stage_missing ;;
  esac

  app_stage="$(kv APP_STAGE "$RDIR/101.txt")"
  app_ms="$(kv APP_MS "$RDIR/101.txt")"
  pre_app_seq="$(kv PRE_APP_SEQ "$RDIR/101.txt")"
  app_seq="$(kv APP_SEQ "$RDIR/101.txt")"
  if [ "$home_stage" = PASS ] && [ "$home_stable_stage" = PASS ]; then
    [ "$(kv PRE_APP_SESSION "$RDIR/101.txt")" = running ] || mark_fail pre_app_session
    [ "$(kv PRE_APP_WANTS_RUN "$RDIR/101.txt")" = 1 ] || mark_fail pre_app_wants_run
    [ "$(kv PRE_APP_FRONT "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail pre_app_front
    [ "$(kv PRE_APP_SHM "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail pre_app_shm
    [ "$(kv PRE_APP_PROVIDER "$RDIR/101.txt")" = 7 ] || mark_fail pre_app_provider
    [ "$(kv PRE_APP_STATUS "$RDIR/101.txt")" = 0 ] || mark_fail pre_app_status
    [ "$(kv PRE_APP_LIVE_FRONT "$RDIR/101.txt")" = "$EXPECTED_HOME" ] || mark_fail pre_app_live_front
    [ "$(kv PRE_APP_DISPLAY_LOCKED "$RDIR/101.txt")" = 0 ] || mark_fail pre_app_locked
  fi
  case "$app_stage" in
    PASS)
      [ "$(kv APP_OK "$RDIR/101.txt")" = 1 ] || mark_fail app_not_ready
      [ "$(kv APP_SESSION "$RDIR/101.txt")" = running ] || mark_fail app_session
      [ "$(kv APP_WANTS_RUN "$RDIR/101.txt")" = 1 ] || mark_fail app_wants_run
      [ "$(kv APP_PROVIDER "$RDIR/101.txt")" = 8 ] || mark_fail app_provider
      [ "$(kv APP_STATUS "$RDIR/101.txt")" = 0 ] || mark_fail app_status
      [ "$(kv APP_FRONT "$RDIR/101.txt")" = "$EXPECTED_APP" ] || mark_fail app_front
      [ "$(kv APP_SHM "$RDIR/101.txt")" = "$EXPECTED_APP" ] || mark_fail app_shm
      [ "$(kv APP_LIVE_FRONT "$RDIR/101.txt")" = "$EXPECTED_APP" ] || mark_fail app_live_front
      [ "$(kv APP_DISPLAY_LOCKED "$RDIR/101.txt")" = 0 ] || mark_fail app_locked
      case "$(kv APP_LIVE_SOURCE "$RDIR/101.txt")" in app_did_become_active_reduced|ax_frontmost) ;; *) mark_fail app_live_source ;; esac
      if is_uint "$pre_app_seq" && is_uint "$app_seq"; then
        [ "$app_seq" -gt "$pre_app_seq" ] || mark_fail app_seq_not_advanced
      else
        mark_fail app_seq_invalid
      fi
      if is_uint "$app_ms"; then [ "$app_ms" -le "$MAX_MS" ] || mark_fail app_slow; else mark_fail app_ms_invalid; fi
      app_age="$(kv APP_AGE_MS "$RDIR/101.txt")"
      if is_uint "$app_age"; then [ "$app_age" -le "$MAX_MS" ] || mark_fail app_age; else mark_fail app_age_invalid; fi
      ;;
    FAIL) mark_fail app_stage_fail ;;
    NOT_RUN) [ "$home_stage" = PASS ] && [ "$home_stable_stage" = PASS ] && mark_fail app_not_run ;;
    *) mark_fail app_stage_missing ;;
  esac

  app_toast_stage="$(kv APP_TOAST_STAGE "$RDIR/101.txt")"
  case "$app_toast_stage" in
    PASS) [ "$(kv APP_TOAST_OK "$RDIR/101.txt")" = 1 ] || mark_fail app_toast_not_new; check_toast app "p2-r${round}-app" "$RDIR/app_toast.txt" "$(kv APP_TOAST_GEN_BEFORE "$RDIR/101.txt")" "$(kv APP_TOAST_GEN_AFTER "$RDIR/101.txt")" "$(kv APP_TOAST_CAPTURED_GEN "$RDIR/101.txt")" "$(kv APP_TOAST_MS "$RDIR/101.txt")"; check_toast_visual app APP "$RDIR/app_toast_screen.png" "$RDIR/app_toast_visual.txt" ;;
    FAIL) mark_fail app_toast_not_new ;;
    NOT_RUN) [ "$app_stage" = PASS ] && mark_fail app_toast_not_run ;;
    *) mark_fail app_toast_stage_missing ;;
  esac

  embed_shadow_stage="$(kv EMBED_SHADOW_STAGE "$RDIR/101.txt")"
  case "$embed_shadow_stage" in
    PASS)
      [ "$(kv EMBED_SHADOW_VERSION "$RDIR/101.txt")" = 1 ] || mark_fail embed_shadow_version
      [ "$(kv EMBED_SHADOW_STATUS "$RDIR/101.txt")" = ok ] || mark_fail embed_shadow_status
      [ "$(kv EMBED_SHADOW_MODE "$RDIR/101.txt")" = embed_vm_shadow ] || mark_fail embed_shadow_mode
      [ "$(kv EMBED_SHADOW_EMBED "$RDIR/101.txt")" = true ] || mark_fail embed_shadow_not_embed
      [ "$(kv EMBED_SHADOW_EMBED_PID "$RDIR/101.txt")" = "$base_frame_pid" ] || mark_fail embed_shadow_pid
      [ "$(kv EMBED_SHADOW_VM_GEN "$RDIR/101.txt")" = "$base_embed_vm_gen" ] || mark_fail embed_shadow_vm_gen
      [ "$(kv EMBED_SHADOW_VM_START_MONO_MS "$RDIR/101.txt")" = "$base_embed_vm_start" ] || mark_fail embed_shadow_vm_start
      case "$(kv EMBED_SHADOW_SCRIPT "$RDIR/101.txt")" in */ios7.lua) ;; *) mark_fail embed_shadow_script ;; esac
      [ "$(kv EMBED_SHADOW_CLOCK "$RDIR/101.txt")" = embed_mono ] || mark_fail embed_shadow_clock
      [ "$(kv EMBED_SHADOW_X "$RDIR/101.txt")" = 706 ] || mark_fail embed_shadow_x
      [ "$(kv EMBED_SHADOW_Y "$RDIR/101.txt")" = 449 ] || mark_fail embed_shadow_y
      [ "$(kv EMBED_SHADOW_COLOR "$RDIR/101.txt")" = "$EXPECTED_COLOR" ] || mark_fail embed_shadow_color
      shadow_color="$(kv EMBED_SHADOW_COLOR "$RDIR/101.txt")"
      shadow_alt="$(kv EMBED_SHADOW_ALT_COLOR "$RDIR/101.txt")"
      if is_uint "$shadow_color" && is_uint "$shadow_alt"; then
        [ "$shadow_alt" -eq $((16777215-shadow_color)) ] || mark_fail embed_shadow_alt_color
      else
        mark_fail embed_shadow_alt_color_invalid
      fi
      [ "$(kv EMBED_SHADOW_GET_OK "$RDIR/101.txt")" = 1 ] || mark_fail embed_shadow_get
      [ "$(kv EMBED_SHADOW_HIT_OK "$RDIR/101.txt")" = 1 ] || mark_fail embed_shadow_hit
      [ "$(kv EMBED_SHADOW_MISS_OK "$RDIR/101.txt")" = 1 ] || mark_fail embed_shadow_miss
      [ "$(kv EMBED_SHADOW_HIT_X "$RDIR/101.txt")" = 706 ] || mark_fail embed_shadow_hit_x
      [ "$(kv EMBED_SHADOW_HIT_Y "$RDIR/101.txt")" = 449 ] || mark_fail embed_shadow_hit_y
      [ "$(kv EMBED_SHADOW_MISS_X "$RDIR/101.txt")" = -1 ] || mark_fail embed_shadow_miss_x
      [ "$(kv EMBED_SHADOW_MISS_Y "$RDIR/101.txt")" = -1 ] || mark_fail embed_shadow_miss_y
      for via_key in GET_VIA HIT_VIA MISS_VIA; do
        [ "$(kv "EMBED_SHADOW_${via_key}" "$RDIR/101.txt")" = embed ] || mark_fail "embed_shadow_${via_key}_not_embed"
      done
      [ "$(kv EMBED_SHADOW_KEEP_WAS "$RDIR/101.txt")" = 0 ] || mark_fail embed_shadow_stale_keep
      [ "$(kv EMBED_SHADOW_KEEP_TEMP "$RDIR/101.txt")" = 1 ] || mark_fail embed_shadow_keep_not_exercised
      [ "$(kv EMBED_SHADOW_KEEP_RESTORE_OK "$RDIR/101.txt")" = 1 ] || mark_fail embed_shadow_keep_restore
      shadow_get_delta="$(kv EMBED_SHADOW_EMBED_GET_DELTA "$RDIR/101.txt")"
      shadow_find_delta="$(kv EMBED_SHADOW_EMBED_FIND_DELTA "$RDIR/101.txt")"
      is_uint "$shadow_get_delta" && [ "$shadow_get_delta" -eq 1 ] || mark_fail embed_shadow_get_delta
      is_uint "$shadow_find_delta" && [ "$shadow_find_delta" -eq 2 ] || mark_fail embed_shadow_find_delta
      [ "$(kv EMBED_SHADOW_COLOR_REQ_GET_DELTA "$RDIR/101.txt")" = 0 ] || mark_fail embed_shadow_color_req_get
      [ "$(kv EMBED_SHADOW_COLOR_REQ_FIND_DELTA "$RDIR/101.txt")" = 0 ] || mark_fail embed_shadow_color_req_find
      [ "$(kv EMBED_SHADOW_FRONT "$RDIR/101.txt")" = "$EXPECTED_APP" ] || mark_fail embed_shadow_front
      [ -z "$(kv EMBED_SHADOW_REASON "$RDIR/101.txt")" ] || mark_fail embed_shadow_reason
      shadow_wait_ms="$(kv EMBED_SHADOW_WAIT_MS "$RDIR/101.txt")"
      if is_uint "$shadow_wait_ms"; then [ "$shadow_wait_ms" -le 15000 ] || mark_fail embed_shadow_wait_slow; else mark_fail embed_shadow_wait_invalid; fi
      for time_key in GET_MS HIT_MS MISS_MS; do
        shadow_time="$(kv "EMBED_SHADOW_${time_key}" "$RDIR/101.txt")"
        if is_uint "$shadow_time"; then [ "$shadow_time" -le "$MAX_MS" ] || mark_fail "embed_shadow_${time_key}_slow"; else mark_fail "embed_shadow_${time_key}_invalid"; fi
      done
      shadow_total_ms="$(kv EMBED_SHADOW_TOTAL_MS "$RDIR/101.txt")"
      if is_uint "$shadow_total_ms"; then [ "$shadow_total_ms" -le $((MAX_MS*3)) ] || mark_fail embed_shadow_total_slow; else mark_fail embed_shadow_total_invalid; fi
      ;;
    FAIL) mark_fail embed_shadow_stage_fail ;;
    NOT_RUN) [ "$app_stage" = PASS ] && mark_fail embed_shadow_not_run ;;
    *) mark_fail embed_shadow_stage_missing ;;
  esac

  daemon_getcolor_stage="$(kv DAEMON_GETCOLOR_STAGE "$RDIR/101.txt")"
  daemon_get_ms="$(kv DAEMON_GETCOLOR_MS "$RDIR/101.txt")"
  case "$daemon_getcolor_stage" in
    PASS)
      [ "$(kv DAEMON_GETCOLOR_ACK "$RDIR/101.txt")" = 1 ] || mark_fail daemon_getcolor_no_ack
      [ "$(kv DAEMON_COLOR "$RDIR/101.txt")" = "$EXPECTED_COLOR" ] || mark_fail daemon_color_wrong
      if is_uint "$daemon_get_ms"; then [ "$daemon_get_ms" -le "$MAX_MS" ] || mark_fail daemon_getcolor_slow; else mark_fail daemon_getcolor_ms_invalid; fi
      ;;
    FAIL)
      mark_fail daemon_getcolor_stage_fail
      ;;
    NOT_RUN) [ "$app_stage" = PASS ] && mark_fail daemon_getcolor_not_run ;;
    *) mark_fail daemon_getcolor_stage_missing ;;
  esac

  daemon_find_stage="$(kv DAEMON_FIND_STAGE "$RDIR/101.txt")"
  daemon_find_ms="$(kv DAEMON_FIND_MS "$RDIR/101.txt")"
  case "$daemon_find_stage" in
    PASS)
      [ "$(kv DAEMON_FIND_ACK "$RDIR/101.txt")" = 1 ] || mark_fail daemon_find_no_ack
      if is_uint "$daemon_find_ms"; then [ "$daemon_find_ms" -le "$MAX_MS" ] || mark_fail daemon_find_slow; else mark_fail daemon_find_ms_invalid; fi
      if ! python3 - "$(kv DAEMON_FIND_BODY "$RDIR/101.txt")" <<'PY'
import json
import sys
try:
    obj = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
ok = (isinstance(obj, dict) and obj.get("ok") is True and
      type(obj.get("x")) is int and type(obj.get("y")) is int and
      obj["x"] == 706 and obj["y"] == 449)
raise SystemExit(0 if ok else 1)
PY
      then
        mark_fail daemon_find_json_or_coordinate
      fi
      ;;
    FAIL) mark_fail daemon_find_stage_fail ;;
    NOT_RUN) [ "$app_stage" = PASS ] && mark_fail daemon_find_not_run ;;
    *) mark_fail daemon_find_stage_missing ;;
  esac

  daemon_find_neg_stage="$(kv DAEMON_FIND_NEG_STAGE "$RDIR/101.txt")"
  daemon_find_neg_ms="$(kv DAEMON_FIND_NEG_MS "$RDIR/101.txt")"
  case "$daemon_find_neg_stage" in
    PASS)
      [ "$(kv DAEMON_FIND_NEG_ACK "$RDIR/101.txt")" = 1 ] || mark_fail daemon_find_neg_no_ack
      if is_uint "$daemon_find_neg_ms"; then [ "$daemon_find_neg_ms" -le "$MAX_MS" ] || mark_fail daemon_find_neg_slow; else mark_fail daemon_find_neg_ms_invalid; fi
      if ! python3 - "$(kv DAEMON_FIND_NEG_BODY "$RDIR/101.txt")" <<'PY'
import json
import sys
try:
    obj = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
ok = (isinstance(obj, dict) and obj.get("ok") is False and
      type(obj.get("x")) is int and type(obj.get("y")) is int and
      obj["x"] == -1 and obj["y"] == -1)
raise SystemExit(0 if ok else 1)
PY
      then
        mark_fail daemon_find_offsets_not_enforced
      fi
      ;;
    FAIL) mark_fail daemon_find_neg_stage_fail ;;
    NOT_RUN) [ "$app_stage" = PASS ] && mark_fail daemon_find_neg_not_run ;;
    *) mark_fail daemon_find_neg_stage_missing ;;
  esac

  path_attempted=0
  case "$daemon_getcolor_stage:$daemon_find_stage:$daemon_find_neg_stage" in
    NOT_RUN:NOT_RUN:NOT_RUN) ;;
    *) path_attempted=1 ;;
  esac

  before_pulse="$(kv PULSE_BEFORE "$RDIR/101.txt")"
  after_pulse="$(kv PULSE_AFTER "$RDIR/101.txt")"
  if [ "$path_attempted" = 1 ]; then
    case "$before_pulse:$after_pulse" in
      *[!0-9:]*|:|*:|:*) mark_fail pulse_invalid ;;
      *) [ "$after_pulse" -gt "$before_pulse" ] || mark_fail pulse_not_advancing ;;
    esac
  fi

  embed_find_before="$(kv EMBED_FIND_BEFORE "$RDIR/101.txt")"
  embed_find_after="$(kv EMBED_FIND_AFTER "$RDIR/101.txt")"
  embed_ts_before="$(kv EMBED_ALIVE_TS_BEFORE "$RDIR/101.txt")"
  embed_ts_after="$(kv EMBED_ALIVE_TS_AFTER "$RDIR/101.txt")"
  embed_vm_before="$(kv EMBED_VM_GEN_BEFORE "$RDIR/101.txt")"
  embed_vm_after="$(kv EMBED_VM_GEN_AFTER "$RDIR/101.txt")"
  embed_vm_app_start="$(kv API_VM_GEN_APP_START "$RDIR/101.txt")"
  embed_vm_start_before="$(kv EMBED_VM_START_MONO_MS_BEFORE "$RDIR/101.txt")"
  embed_vm_start_after="$(kv EMBED_VM_START_MONO_MS_AFTER "$RDIR/101.txt")"
  for value in "$embed_find_before" "$embed_find_after" "$embed_ts_before" "$embed_ts_after" \
               "$embed_vm_before" "$embed_vm_after" "$embed_vm_app_start" \
               "$embed_vm_start_before" "$embed_vm_start_after" \
               "$(kv EMBED_AGE_S_BEFORE "$RDIR/101.txt")" "$(kv EMBED_AGE_S_AFTER "$RDIR/101.txt")"; do
    is_uint "$value" || mark_fail embed_diag_invalid
  done
  [ "$(kv EMBED_FLAG_BEFORE "$RDIR/101.txt")" = 1 ] || mark_fail embed_flag_before
  [ "$(kv EMBED_FLAG_AFTER "$RDIR/101.txt")" = 1 ] || mark_fail embed_flag_after
  [ "$(kv EMBED_ALIVE_PID_BEFORE "$RDIR/101.txt")" = "$base_frame_pid" ] || mark_fail embed_pid_before
  [ "$(kv EMBED_ALIVE_PID_AFTER "$RDIR/101.txt")" = "$base_frame_pid" ] || mark_fail embed_pid_after
  [ "$embed_vm_before" = "$base_embed_vm_gen" ] || mark_fail embed_vm_changed_before
  [ "$embed_vm_app_start" = "$base_embed_vm_gen" ] || mark_fail embed_vm_changed_app_start
  [ "$embed_vm_after" = "$base_embed_vm_gen" ] || mark_fail embed_vm_changed_after
  [ "$embed_vm_start_before" = "$base_embed_vm_start" ] || mark_fail embed_vm_start_changed_before
  [ "$embed_vm_start_after" = "$base_embed_vm_start" ] || mark_fail embed_vm_start_changed_after
  [ "$(kv EMBED_SCRIPT_SHA_BEFORE "$RDIR/101.txt")" = "$EXPECTED_IOS7_SHA" ] || mark_fail embed_script_sha_before
  [ "$(kv EMBED_SCRIPT_SHA_AFTER "$RDIR/101.txt")" = "$EXPECTED_IOS7_SHA" ] || mark_fail embed_script_sha_after
  [ "$(kv API_CSV_HEADER_BEFORE "$RDIR/101.txt")" = "$EXPECTED_API_HEADER" ] || mark_fail api_header_before
  [ "$(kv API_CSV_HEADER_AFTER "$RDIR/101.txt")" = "$EXPECTED_API_HEADER" ] || mark_fail api_header_after
  [ "$(kv COLOR_REQ_FIND_BEFORE "$RDIR/101.txt")" = 0 ] || mark_fail lua_color_req_before
  [ "$(kv COLOR_REQ_FIND_AFTER "$RDIR/101.txt")" = 0 ] || mark_fail lua_color_req_after
  [ "$(kv EMBED_NATURAL_STAGE "$RDIR/101.txt")" = PASS ] || mark_fail embed_natural_stage
  api_seq_start="$(kv API_SEQ_APP_START "$RDIR/101.txt")"
  api_seq_end="$(kv API_SEQ_AFTER "$RDIR/101.txt")"
  if is_uint "$api_seq_start" && is_uint "$api_seq_end"; then
    [ "$api_seq_end" -ge $((api_seq_start + 20)) ] || mark_fail embed_api_seq_short
  else
    mark_fail embed_api_seq_invalid
  fi
  [ "$api_csv_pull_ok" = 1 ] || mark_fail embed_api_csv_pull
  [ "$api_window_analyze_ok" = 1 ] || mark_fail embed_api_window
  if [ "$api_window_analyze_ok" = 1 ]; then
    [ "$(kv API_WINDOW_OK "$RDIR/embed_api_window.txt")" = 1 ] || mark_fail embed_api_window_flag
    [ "$(kv API_VM_GEN "$RDIR/embed_api_window.txt")" = "$base_embed_vm_gen" ] || mark_fail embed_api_window_vm_gen
    embed_samples="$(kv EMBED_FIND_SAMPLES "$RDIR/embed_api_window.txt")"
    pattern_a_samples="$(kv EMBED_PATTERN_A_SAMPLES "$RDIR/embed_api_window.txt")"
    pattern_b_samples="$(kv EMBED_PATTERN_B_SAMPLES "$RDIR/embed_api_window.txt")"
    is_uint "$embed_samples" && [ "$embed_samples" -ge 20 ] || mark_fail embed_find_samples_low
    is_uint "$pattern_a_samples" && [ "$pattern_a_samples" -ge 5 ] || mark_fail embed_pattern_a_low
    is_uint "$pattern_b_samples" && [ "$pattern_b_samples" -ge 5 ] || mark_fail embed_pattern_b_low
  fi
  if is_uint "$embed_ts_before" && is_uint "$embed_ts_after"; then
    [ "$embed_ts_after" -ge "$embed_ts_before" ] || mark_fail embed_heartbeat_reversed
  fi
  for age_key in EMBED_AGE_S_BEFORE EMBED_AGE_S_AFTER; do
    age_value="$(kv "$age_key" "$RDIR/101.txt")"
    is_uint "$age_value" && [ "$age_value" -le 5 ] || mark_fail "${age_key}_stale"
  done

  for key in EXIT_LINES_BEFORE EXIT_LINES_AFTER SIG11_LINES_BEFORE SIG11_LINES_AFTER; do
    is_uint "$(kv "$key" "$RDIR/101.txt")" || mark_fail "${key}_invalid"
  done
  [ "$(kv EXIT_HIST_EXISTS_BEFORE "$RDIR/101.txt")" = 1 ] || mark_fail exit_hist_missing_before
  [ "$(kv EXIT_HIST_EXISTS_AFTER "$RDIR/101.txt")" = 1 ] || mark_fail exit_hist_missing_after
  [ "$(kv EXIT_LINES_BEFORE "$RDIR/101.txt")" = "$base_exit_lines" ] || mark_fail exit_hist_changed_before
  [ "$(kv EXIT_LINES_AFTER "$RDIR/101.txt")" = "$base_exit_lines" ] || mark_fail exit_hist_changed_after
  [ "$(kv EXIT_SHA_BEFORE "$RDIR/101.txt")" = "$base_exit_sha" ] || mark_fail exit_hist_hash_changed_before
  [ "$(kv EXIT_SHA_AFTER "$RDIR/101.txt")" = "$base_exit_sha" ] || mark_fail exit_hist_hash_changed_after
  [ "$(kv SIG11_LINES_BEFORE "$RDIR/101.txt")" = "$base_sig11" ] || mark_fail sigsegv_changed_before
  [ "$(kv SIG11_LINES_AFTER "$RDIR/101.txt")" = "$base_sig11" ] || mark_fail sigsegv_added
  if [ "$exit_hist_pull_ok" = 1 ] && [ -f "$RDIR/exit_hist.txt" ]; then
    pulled_exit_sha="$(shasum -a 256 "$RDIR/exit_hist.txt" 2>/dev/null | awk '{print $1}')"
    [ "$pulled_exit_sha" = "$base_exit_sha" ] || mark_fail exit_hist_pull_mismatch
  else
    mark_fail exit_hist_pull_missing
  fi
  [ "$(kv ZOMBIES "$RDIR/101.txt")" = 0 ] || mark_fail zombie

  readers_before="$(kv RESIDENT_READERS_BEFORE "$RDIR/101.txt")"
  readers_after="$(kv RESIDENT_READERS "$RDIR/101.txt")"
  maps_before="$(kv TICKET_MAPS_BEFORE "$RDIR/101.txt")"
  unmaps_before="$(kv TICKET_UNMAPS_BEFORE "$RDIR/101.txt")"
  maps_after="$(kv TICKET_MAPS_AFTER "$RDIR/101.txt")"
  unmaps_after="$(kv TICKET_UNMAPS_AFTER "$RDIR/101.txt")"
  waits_before="$(kv WRITER_WAITS_BEFORE "$RDIR/101.txt")"
  waits_after="$(kv WRITER_WAITS_AFTER "$RDIR/101.txt")"
  invalid_before="$(kv INVALID_UNMAPS_BEFORE "$RDIR/101.txt")"
  invalid_after="$(kv INVALID_UNMAPS_AFTER "$RDIR/101.txt")"
  exhaust_before="$(kv TICKET_EXHAUSTS_BEFORE "$RDIR/101.txt")"
  exhaust_after="$(kv TICKET_EXHAUSTS_AFTER "$RDIR/101.txt")"
  ticket_drain_ms="$(kv TICKET_DRAIN_MS "$RDIR/101.txt")"
  if is_uint "$ticket_drain_ms"; then
    [ "$ticket_drain_ms" -le 250 ] || mark_fail ticket_drain_slow
  else
    mark_fail ticket_drain_invalid
  fi
  ticket_valid=1
  for value in "$readers_before" "$readers_after" "$maps_before" "$unmaps_before" \
               "$maps_after" "$unmaps_after" "$waits_before" "$waits_after" \
               "$invalid_before" "$invalid_after" "$exhaust_before" "$exhaust_after"; do
    is_uint "$value" || ticket_valid=0
  done
  if [ "$ticket_valid" = 1 ]; then
    [ "$maps_before" -ge "$unmaps_before" ] || mark_fail ticket_before_underflow
    [ $((maps_before-unmaps_before)) -eq "$readers_before" ] || mark_fail ticket_before_invariant
    if [ "$path_attempted" = 1 ]; then
      [ "$maps_after" -gt "$maps_before" ] || mark_fail ticket_path_not_exercised
    fi
    [ "$maps_after" -ge "$maps_before" ] || mark_fail ticket_maps_reversed
    [ "$unmaps_after" -ge "$unmaps_before" ] || mark_fail ticket_unmaps_reversed
    [ "$readers_after" = 0 ] || mark_fail resident_ticket_stuck
    [ "$maps_after" = "$unmaps_after" ] || mark_fail ticket_map_unmap_mismatch
    [ "$waits_after" -ge "$waits_before" ] || mark_fail writer_waits_reversed
    [ "$invalid_before" = "$base_invalid_unmaps" ] || mark_fail invalid_unmaps_changed_before
    [ "$invalid_after" = "$base_invalid_unmaps" ] || mark_fail invalid_unmaps_added
    [ "$exhaust_before" = "$base_ticket_exhausts" ] || mark_fail ticket_exhausts_changed_before
    [ "$exhaust_after" = "$base_ticket_exhausts" ] || mark_fail ticket_exhausts_added
  else
    mark_fail ticket_counts_invalid
  fi
  for prefix in APPFRAME_TIMEOUTS APPFRAME_INVALID; do
    before_value="$(kv "${prefix}_BEFORE" "$RDIR/101.txt")"
    after_value="$(kv "${prefix}_AFTER" "$RDIR/101.txt")"
    if is_uint "$before_value" && is_uint "$after_value"; then
      [ "$after_value" = "$before_value" ] || mark_fail "${prefix}_added"
    else
      mark_fail "${prefix}_invalid"
    fi
  done

  resident="$(kv RESIDENT "$RDIR/101.txt")"
  printf '%s\n' "$resident" | grep -q 'over=0' || mark_fail resident_over_budget
  resident_bytes="$(printf '%s\n' "$resident" | sed -n 's/^\([0-9][0-9]*\) .*/\1/p')"
  case "$resident_bytes" in ''|*[!0-9]*) mark_fail resident_bytes_invalid ;; *) [ "$resident_bytes" -le 6291456 ] || mark_fail resident_bytes_high ;; esac

  for phase in before after; do
    [ "$(proc_count framecap "$phase" "$RDIR/101.txt")" = 1 ] || mark_fail "framecap_count_$phase"
    [ "$(proc_count ziyadaemond "$phase" "$RDIR/101.txt")" = 1 ] || mark_fail "zydaemon_count_$phase"
    [ "$(proc_count SpringBoard "$phase" "$RDIR/101.txt")" = 1 ] || mark_fail "sb_count_$phase"
    [ "$(proc_count App "$phase" "$RDIR/101.txt")" = 1 ] || mark_fail "app_count_$phase"
    [ "$(proc_pid framecap "$phase" "$RDIR/101.txt")" = "$base_frame_pid" ] || mark_fail "framecap_pid_$phase"
    [ "$(proc_pid ziyadaemond "$phase" "$RDIR/101.txt")" = "$base_zydaemon_pid" ] || mark_fail "zydaemon_pid_$phase"
    [ "$(proc_pid SpringBoard "$phase" "$RDIR/101.txt")" = "$base_sb_pid" ] || mark_fail "sb_pid_$phase"
    [ "$(proc_pid App "$phase" "$RDIR/101.txt")" = "$base_app_pid" ] || mark_fail "app_pid_$phase"
  done

  f="$RDIR/171_home.txt"
  [ "$(kv ACTION_RC "$f")" = 0 ] || mark_fail 171_action
  [ "$(kv ZOMBIES "$f")" = 0 ] || mark_fail 171_zombie
  [ "$(kv TS_STATUS_BEFORE "$f")" = f01 ] || mark_fail 171_status_before
  [ "$(kv TS_STATUS_AFTER "$f")" = f01 ] || mark_fail 171_status_after
  [ "$(kv TS_RUN_CFG_BEFORE "$f")" = "$(kv TS_RUN_CFG "$BASE171")" ] || mark_fail 171_run_cfg_before
  [ "$(kv TS_RUN_CFG_AFTER "$f")" = "$(kv TS_RUN_CFG "$BASE171")" ] || mark_fail 171_run_cfg_after
  [ "$(kv ERR_SIZE_BEFORE "$f")" = "$base_ts_err_size" ] || mark_fail 171_err_size_before
  [ "$(kv ERR_SIZE_AFTER "$f")" = "$base_ts_err_size" ] || mark_fail 171_errlog_grew
  [ "$(kv ERR_SHA_BEFORE "$f")" = "$base_ts_err_sha" ] || mark_fail 171_err_sha_before
  [ "$(kv ERR_SHA_AFTER "$f")" = "$base_ts_err_sha" ] || mark_fail 171_errlog_changed
  for phase in before after; do
    [ "$(proc_count TSDaemon "$phase" "$f")" = 1 ] || mark_fail "171_daemon_count"
    [ "$(proc_count Hades "$phase" "$f")" = 1 ] || mark_fail "171_hades_count"
    [ "$(proc_count SpringBoard "$phase" "$f")" = 1 ] || mark_fail "171_sb_count"
    [ "$(proc_count App "$phase" "$f")" = 1 ] || mark_fail "171_app_count"
    [ "$(proc_pid TSDaemon "$phase" "$f")" = "$base_ts_daemon" ] || mark_fail "171_daemon_pid"
    [ "$(proc_pid Hades "$phase" "$f")" = "$base_ts_hades" ] || mark_fail "171_hades_pid"
    [ "$(proc_pid SpringBoard "$phase" "$f")" = "$base_ts_sb" ] || mark_fail "171_sb_pid"
    [ "$(proc_pid App "$phase" "$f")" = "$base_ts_app" ] || mark_fail "171_app_pid"
  done

  [ "$(kv APP_JETSAM_BEFORE "$RDIR/171_home.txt")" = "10|foreground" ] || mark_fail 171_pre_not_foreground
  [ "$(kv HOME_INVALID_JETSAM "$RDIR/171_home.txt")" = 0 ] || mark_fail 171_jetsam_probe_invalid
  [ "$(kv HOME_SEEN_NONFG "$RDIR/171_home.txt")" = 1 ] || mark_fail 171_home_transition_not_seen
  ts_home_ms="$(kv HOME_FIRST_NONFG_MS "$RDIR/171_home.txt")"
  if is_uint "$ts_home_ms"; then
    [ "$ts_home_ms" -le "$MAX_MS" ] || mark_fail 171_home_slow
  else
    mark_fail 171_home_ms_invalid
  fi
  [ "$(kv HOME_AUTO_RETURN "$RDIR/171_home.txt")" = 1 ] || mark_fail 171_business_auto_return_missing
  ts_return_ms="$(kv HOME_RETURN_FG_MS "$RDIR/171_home.txt")"
  if is_uint "$ts_return_ms"; then
    [ "$ts_return_ms" -le 6000 ] || mark_fail 171_return_slow
  else
    mark_fail 171_return_ms_invalid
  fi
  [ "$(kv APP_JETSAM_AFTER "$RDIR/171_home.txt")" = "10|foreground" ] || mark_fail 171_auto_return_not_foreground
  grep -q '^SNAPSHOT_VERDICT=PASS$' "$RDIR/171_home_snapshot.txt" || mark_fail 171_home_snapshot_invalid
  grep -q '^LOGIN_PATTERN=PASS$' "$RDIR/171_home_snapshot.txt" || mark_fail 171_auto_return_login_miss

  if [ "$(kv HOME_SNAPSHOT "$RDIR/101.txt")" = 1 ]; then
    if ! analyze_png "$RDIR/home.png" "$RDIR/home_png.txt"; then mark_fail home_black_or_invalid; fi
  else
    mark_fail home_snapshot_missing
  fi
  if [ "$app_stage" != NOT_RUN ]; then
    if [ "$(kv APP_SNAPSHOT "$RDIR/101.txt")" = 1 ]; then
      if ! analyze_png "$RDIR/app.png" "$RDIR/app_png.txt"; then mark_fail app_black_or_invalid; fi
    else
      mark_fail app_snapshot_missing
    fi
  fi
  if [ -f "$RDIR/home.png" ] && [ -f "$RDIR/app.png" ]; then
    home_sha="$(shasum -a 256 "$RDIR/home.png" 2>/dev/null | awk '{print $1}')"
    app_sha="$(shasum -a 256 "$RDIR/app.png" 2>/dev/null | awk '{print $1}')"
    [ -n "$home_sha" ] && [ -n "$app_sha" ] && [ "$home_sha" != "$app_sha" ] || mark_fail home_app_png_identical
  fi

  if [ "$home_stage" = PASS ] && [ "$app_stage" = PASS ]; then
    home_seq="$(kv HOME_SEQ "$RDIR/101.txt")"
    app_seq="$(kv APP_SEQ "$RDIR/101.txt")"
    if is_uint "$home_seq" && is_uint "$app_seq"; then
      [ "$app_seq" -gt "$home_seq" ] || mark_fail seq_not_advancing
    else
      mark_fail seq_invalid
    fi
  fi
  fi

  if [ "$fail" = 0 ]; then
    completed=$round
    echo "ROUND=$round VERDICT=PASS HOME_MS=$home_ms APP_MS=$app_ms EMBED_FIND_MS_P50=$(kv EMBED_FIND_MS_P50 "$RDIR/embed_api_window.txt") EMBED_FIND_MS_P95=$(kv EMBED_FIND_MS_P95 "$RDIR/embed_api_window.txt") EMBED_SAMPLES=$(kv EMBED_FIND_SAMPLES "$RDIR/embed_api_window.txt") SHADOW_TOTAL_MS=$(kv EMBED_SHADOW_TOTAL_MS "$RDIR/101.txt") DAEMON_GETCOLOR_MS=$daemon_get_ms DAEMON_FIND_MS=$daemon_find_ms DAEMON_FIND_NEG_MS=$daemon_find_neg_ms DAEMON_COLOR=$(kv DAEMON_COLOR "$RDIR/101.txt") TS171_HOME_MS=$(kv HOME_FIRST_NONFG_MS "$RDIR/171_home.txt") TS171_RETURN_MS=$(kv HOME_RETURN_FG_MS "$RDIR/171_home.txt") PULSE_DELTA=$((after_pulse-before_pulse)) API_SEQ_DELTA=$((api_seq_end-api_seq_start)) TICKET_MAP_DELTA=$((maps_after-maps_before)) WRITER_WAIT_DELTA=$((waits_after-waits_before))" | tee -a "$LOG"
  else
    overall_reason="round_${round}:${reason}"
    echo "ROUND=$round VERDICT=FAIL REASON=$reason" | tee -a "$LOG"
    write_verdict FAIL "$overall_reason"
    exit 1
  fi
done

# Percentiles use nearest rank and are computed only after every strict sample
# passed.  Raw per-round files remain the source of truth.
percentile() {
  local key="$1" pct="$2"
  for f in "$OUT"/rounds/*/101.txt; do kv "$key" "$f"; done |
    sort -n | awk -v p="$pct" '{a[NR]=$1} END {if (NR<1){print 0; exit} r=int((NR*p+99)/100); if(r<1)r=1; if(r>NR)r=NR; print a[r]}'
}

maximum() {
  local key="$1"
  for f in "$OUT"/rounds/*/101.txt; do kv "$key" "$f"; done |
    sort -n | tail -1
}

LATENCY_TMP="$OUT/LATENCY.txt.tmp.$$"
if ! {
  echo "HOME_MS_P50=$(percentile HOME_MS 50)"
  echo "HOME_MS_P95=$(percentile HOME_MS 95)"
  echo "HOME_MS_MAX=$(maximum HOME_MS)"
  echo "APP_MS_P50=$(percentile APP_MS 50)"
  echo "APP_MS_P95=$(percentile APP_MS 95)"
  echo "APP_MS_MAX=$(maximum APP_MS)"
  echo "HOME_AGE_MS_P50=$(percentile HOME_AGE_MS 50)"
  echo "HOME_AGE_MS_P95=$(percentile HOME_AGE_MS 95)"
  echo "HOME_AGE_MS_MAX=$(maximum HOME_AGE_MS)"
  echo "APP_AGE_MS_P50=$(percentile APP_AGE_MS 50)"
  echo "APP_AGE_MS_P95=$(percentile APP_AGE_MS 95)"
  echo "APP_AGE_MS_MAX=$(maximum APP_AGE_MS)"
  echo "DAEMON_GETCOLOR_MS_P50=$(percentile DAEMON_GETCOLOR_MS 50)"
  echo "DAEMON_GETCOLOR_MS_P95=$(percentile DAEMON_GETCOLOR_MS 95)"
  echo "DAEMON_GETCOLOR_MS_MAX=$(maximum DAEMON_GETCOLOR_MS)"
  echo "DAEMON_FIND_MS_P50=$(percentile DAEMON_FIND_MS 50)"
  echo "DAEMON_FIND_MS_P95=$(percentile DAEMON_FIND_MS 95)"
  echo "DAEMON_FIND_MS_MAX=$(maximum DAEMON_FIND_MS)"
  echo "DAEMON_FIND_NEG_MS_P50=$(percentile DAEMON_FIND_NEG_MS 50)"
  echo "DAEMON_FIND_NEG_MS_P95=$(percentile DAEMON_FIND_NEG_MS 95)"
  echo "DAEMON_FIND_NEG_MS_MAX=$(maximum DAEMON_FIND_NEG_MS)"
  echo "EMBED_SHADOW_GET_MS_P50=$(percentile EMBED_SHADOW_GET_MS 50)"
  echo "EMBED_SHADOW_GET_MS_P95=$(percentile EMBED_SHADOW_GET_MS 95)"
  echo "EMBED_SHADOW_HIT_MS_P50=$(percentile EMBED_SHADOW_HIT_MS 50)"
  echo "EMBED_SHADOW_HIT_MS_P95=$(percentile EMBED_SHADOW_HIT_MS 95)"
  echo "EMBED_SHADOW_MISS_MS_P50=$(percentile EMBED_SHADOW_MISS_MS 50)"
  echo "EMBED_SHADOW_MISS_MS_P95=$(percentile EMBED_SHADOW_MISS_MS 95)"
  echo "TS171_HOME_MS_P50=$(for f in "$OUT"/rounds/*/171_home.txt; do kv HOME_FIRST_NONFG_MS "$f"; done | sort -n | awk '{a[NR]=$1} END {if(!NR){print 0}else{print a[int((NR*50+99)/100)]}}')"
  echo "TS171_HOME_MS_P95=$(for f in "$OUT"/rounds/*/171_home.txt; do kv HOME_FIRST_NONFG_MS "$f"; done | sort -n | awk '{a[NR]=$1} END {if(!NR){print 0}else{r=int((NR*95+99)/100);if(r>NR)r=NR;print a[r]}}')"
  echo "TS171_RETURN_MS_P50=$(for f in "$OUT"/rounds/*/171_home.txt; do kv HOME_RETURN_FG_MS "$f"; done | sort -n | awk '{a[NR]=$1} END {if(!NR){print 0}else{print a[int((NR*50+99)/100)]}}')"
  echo "TS171_RETURN_MS_P95=$(for f in "$OUT"/rounds/*/171_home.txt; do kv HOME_RETURN_FG_MS "$f"; done | sort -n | awk '{a[NR]=$1} END {if(!NR){print 0}else{r=int((NR*95+99)/100);if(r>NR)r=NR;print a[r]}}')"
  echo "TS171_RAW_FIND_MS=UNAVAILABLE"
  python3 - "$OUT" <<'PY'
import csv
import glob
import math
import re
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])

def nearest(values, pct):
    values = sorted(values)
    rank = max(1, min(len(values), math.ceil(len(values) * pct / 100.0)))
    return values[rank - 1]

find_ms = []
get_ms = []
patterns = {}
for file in sorted(glob.glob(str(root / "rounds" / "*" / "embed_api_window.csv"))):
    with open(file, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            duration = float(row["duration_ms"])
            if row["op"] == "find":
                find_ms.append(duration)
                patterns[row["pattern_id"]] = patterns.get(row["pattern_id"], 0) + 1
            elif row["op"] == "getColor":
                get_ms.append(duration)
if not find_ms:
    raise SystemExit(20)
print(f"EMBED_FIND_SAMPLES={len(find_ms)}")
print(f"EMBED_PATTERN_A_SAMPLES={patterns.get('p48aa944a', 0)}")
print(f"EMBED_PATTERN_B_SAMPLES={patterns.get('p5cd58dc5', 0)}")
print(f"EMBED_FIND_MS_P50={nearest(find_ms, 50):.3f}")
print(f"EMBED_FIND_MS_P95={nearest(find_ms, 95):.3f}")
print(f"EMBED_FIND_MS_MAX={max(find_ms):.3f}")
print(f"EMBED_GETCOLOR_NATURAL_SAMPLES={len(get_ms)}")
if get_ms:
    print(f"EMBED_GETCOLOR_MS_P50={nearest(get_ms, 50):.3f}")
    print(f"EMBED_GETCOLOR_MS_P95={nearest(get_ms, 95):.3f}")
    print(f"EMBED_GETCOLOR_MS_MAX={max(get_ms):.3f}")
else:
    print("EMBED_GETCOLOR_MS_P50=UNAVAILABLE")
    print("EMBED_GETCOLOR_MS_P95=UNAVAILABLE")
    print("EMBED_GETCOLOR_MS_MAX=UNAVAILABLE")

proc_re = re.compile(
    r"^PROC PHASE=(\S+) ROLE=(\S+) COUNT=1 PID=(\d+) .* "
    r"CTIME=(\S+) RSS=(\d+) CPU=(\S+)$"
)

def cpu_seconds(raw):
    parts = raw.split(":")
    if len(parts) == 2:
        return float(parts[0]) * 60 + float(parts[1])
    if len(parts) == 3:
        return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
    return float(parts[0])

def parse_kv(path):
    out = {}
    procs = {}
    for line in path.read_text(errors="replace").splitlines():
        m = proc_re.match(line)
        if m:
            phase, role, _pid, ctime, rss, _cpu = m.groups()
            procs[(phase, role)] = (cpu_seconds(ctime), int(rss))
        elif "=" in line:
            key, value = line.split("=", 1)
            out[key] = value
    return out, procs

def slope(points):
    if len(points) < 2:
        return 0.0
    t0 = points[0][0]
    xs = [(t - t0) / 60000.0 for t, _ in points]
    ys = [v for _, v in points]
    xm = statistics.fmean(xs)
    ym = statistics.fmean(ys)
    den = sum((x - xm) ** 2 for x in xs)
    return 0.0 if den == 0 else sum((x - xm) * (y - ym) for x, y in zip(xs, ys)) / den

def summarize(prefix, samples, roles):
    cpu_delta = 0.0
    wall = 0.0
    rss_values = []
    rss_points = []
    for path, start_key, end_key in samples:
        kv, procs = parse_kv(path)
        start = int(kv[start_key])
        end = int(kv[end_key])
        if end <= start:
            raise ValueError(f"bad window {path}")
        wall += (end - start) / 1000.0
        before_rss = 0
        after_rss = 0
        for role in roles:
            b = procs[("before", role)]
            a = procs[("after", role)]
            if a[0] < b[0]:
                raise ValueError(f"cpu reversed {path} {role}")
            cpu_delta += a[0] - b[0]
            before_rss += b[1]
            after_rss += a[1]
        rss_values.extend([before_rss, after_rss])
        rss_points.extend([(start, before_rss), (end, after_rss)])
    print(f"{prefix}_CPU_PCT={(cpu_delta / wall * 100.0):.3f}")
    print(f"{prefix}_RSS_KB_P50={nearest(rss_values, 50):.0f}")
    print(f"{prefix}_RSS_KB_P95={nearest(rss_values, 95):.0f}")
    print(f"{prefix}_RSS_KB_MAX={max(rss_values):.0f}")
    print(f"{prefix}_RSS_KB_DELTA={rss_values[-1] - rss_values[0]}")
    print(f"{prefix}_RSS_KB_OLS_PER_MIN={slope(rss_points):.3f}")

zy_samples = [(Path(p), "ROUND_START_MS", "ROUND_END_MS")
              for p in sorted(glob.glob(str(root / "rounds" / "*" / "101.txt")))]
ts_samples = []
for p in sorted(glob.glob(str(root / "rounds" / "*" / "171_home.txt"))):
    ts_samples.append((Path(p), "SAMPLE_START_MS", "SAMPLE_END_MS"))
summarize("STRICT10_ZIYAN_CORE", zy_samples, ["framecap", "ziyadaemond"])
summarize("STRICT10_TS_CORE", ts_samples, ["TSDaemon", "Hades"])
PY
} >"$LATENCY_TMP"; then
  echo "ERROR: failed to generate complete latency evidence" >&2
  write_verdict FAIL latency_evidence_generation || true
  exit 2
fi
for required_key in HOME_MS_P95 APP_MS_P95 EMBED_FIND_MS_P95 \
  DAEMON_FIND_MS_P95 STRICT10_ZIYAN_CORE_CPU_PCT STRICT10_TS_CORE_CPU_PCT \
  STRICT10_ZIYAN_CORE_RSS_KB_P95 STRICT10_TS_CORE_RSS_KB_P95 \
  STRICT10_ZIYAN_CORE_RSS_KB_OLS_PER_MIN STRICT10_TS_CORE_RSS_KB_OLS_PER_MIN; do
  if ! grep -q "^${required_key}=" "$LATENCY_TMP"; then
    echo "ERROR: missing latency key $required_key" >&2
    write_verdict FAIL "latency_key_${required_key}" || true
    exit 2
  fi
done

RESOURCE_TMP="$OUT/RESOURCE_GATE.txt.tmp.$$"
resource_ok=0
if python3 - "$LATENCY_TMP" "$ROUNDS" "$MAX_ZIYAN_CORE_CPU_PCT" \
     "$MAX_ZIYAN_CORE_RSS_KB" "$MAX_ZIYAN_RSS_OLS_KB_PER_MIN" \
     "$RESOURCE_CPU_TOL_PCT" "$RESOURCE_RSS_TOL_KB" \
     "$RESOURCE_OLS_TOL_KB_PER_MIN" >"$RESOURCE_TMP" <<'PY'
import math
import sys

path = sys.argv[1]
rounds = int(sys.argv[2])
limits = list(map(float, sys.argv[3:]))
max_cpu, max_rss, max_ols, cpu_tol, rss_tol, ols_tol = limits
values = {}
with open(path, encoding="utf-8", errors="strict") as f:
    for line in f:
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            values[k] = v

def number(key):
    value = float(values[key])
    if not math.isfinite(value):
        raise ValueError(key)
    return value

zy_cpu = number("STRICT10_ZIYAN_CORE_CPU_PCT")
ts_cpu = number("STRICT10_TS_CORE_CPU_PCT")
zy_rss = number("STRICT10_ZIYAN_CORE_RSS_KB_P95")
ts_rss = number("STRICT10_TS_CORE_RSS_KB_P95")
zy_ols = number("STRICT10_ZIYAN_CORE_RSS_KB_OLS_PER_MIN")
ts_ols = number("STRICT10_TS_CORE_RSS_KB_OLS_PER_MIN")

relation_enforced = rounds >= 3
cpu_ok = 0 <= zy_cpu <= max_cpu
rss_ok = 0 <= zy_rss <= max_rss
ols_ceiling = ts_ols + ols_tol
ols_ok = zy_ols <= max_ols
if relation_enforced:
    cpu_ok = cpu_ok and zy_cpu <= ts_cpu + cpu_tol
    rss_ok = rss_ok and zy_rss <= ts_rss + rss_tol
    ols_ok = ols_ok and zy_ols <= ols_ceiling
overall = cpu_ok and rss_ok and ols_ok

print(f"RESOURCE_ROUNDS={rounds}")
print(f"RESOURCE_RELATION_GATE={'ENFORCED' if relation_enforced else 'NOT_ENOUGH_ROUNDS'}")
print(f"ZIYAN_CPU_PCT={zy_cpu:.3f}")
print(f"TS171_CPU_PCT={ts_cpu:.3f}")
print(f"CPU_ABS_MAX_PCT={max_cpu:.3f}")
print(f"CPU_REL_TOL_PCT={cpu_tol:.3f}")
print(f"CPU_NO_WORSE={1 if cpu_ok else 0}")
print(f"ZIYAN_RSS_KB_P95={zy_rss:.0f}")
print(f"TS171_RSS_KB_P95={ts_rss:.0f}")
print(f"RSS_ABS_MAX_KB={max_rss:.0f}")
print(f"RSS_REL_TOL_KB={rss_tol:.0f}")
print(f"RSS_NO_WORSE={1 if rss_ok else 0}")
print(f"ZIYAN_RSS_OLS_KB_PER_MIN={zy_ols:.3f}")
print(f"TS171_RSS_OLS_KB_PER_MIN={ts_ols:.3f}")
print(f"RSS_OLS_ABS_MAX_KB_PER_MIN={max_ols:.3f}")
print(f"RSS_OLS_REL_CEILING_KB_PER_MIN={ols_ceiling:.3f}")
print(f"RSS_OLS_NO_WORSE={1 if ols_ok else 0}")
print("TS171_RAW_FIND_MS=UNAVAILABLE")
print(f"RESOURCE_VERDICT={'PASS' if overall else 'FAIL'}")
raise SystemExit(0 if overall else 1)
PY
then
  resource_ok=1
fi
if ! mv "$LATENCY_TMP" "$OUT/LATENCY.txt"; then
  write_verdict FAIL latency_evidence_publish || true
  exit 2
fi
if [ ! -s "$RESOURCE_TMP" ] || ! mv "$RESOURCE_TMP" "$OUT/RESOURCE_GATE.txt"; then
  write_verdict FAIL resource_evidence_publish || true
  exit 2
fi
if [ "$resource_ok" != 1 ]; then
  write_verdict FAIL resource_budget_or_171_relation || true
  exit 1
fi

if ! write_verdict PASS all_rounds_passed; then
  exit 2
fi
exit 0
