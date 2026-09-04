#!/usr/bin/env bash
# Observe one BBTouch tap in the already-visible .101 foreground App.
# The caller supplies a known actionable logical coordinate; this script does
# not launch, stop, minimize, or otherwise reposition the target App.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_TAG="${DEVICE_TAG:-101}"
HOST="192.168.31.$DEVICE_TAG"
if [ "$DEVICE_TAG" = 53 ]; then
  V="/var/jb/usr/lib/ziyan/var"
  LUA_BIN="/var/jb/usr/lib/ziyan/bin/lua5.3"
  LUA_RUNNER="/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua"
else
  V="/usr/lib/ziyan/var"
  LUA_BIN="/usr/lib/ziyan/bin/lua5.3"
  LUA_RUNNER="/usr/lib/ziyan/lib/lua/ziyan_run.lua"
fi
X="${1:?usage: $0 X Y [expected_front_bid] [bb|app|sb|lua]}"
Y="${2:?usage: $0 X Y [expected_front_bid] [bb|app|sb|lua]}"
EXPECTED_FRONT="${3:-com.xztl.ios}"
BACKEND="${4:-bb}"
INIT_ORIENT="${INIT_ORIENT:-1}"
HOLD_MS=90
STAMP="$(date '+%Y%m%d_%H%M%S')"
RUN_ID="app_tap_${DEVICE_TAG}_${STAMP}_$$"
OUT="$ROOT/tmp_shots/DEVICE${DEVICE_TAG}_FOREGROUND_APP_TAP_${STAMP}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 "root@$HOST")

ssh_r() { "${SSH[@]}" "$@"; }

mkdir -p "$OUT"
case "$BACKEND" in bb|app|sb|lua) ;; *) echo "backend must be bb, app, sb, or lua" >&2; exit 2 ;; esac
printf 'run_id=%s\ndevice=.%s\nx=%s\ny=%s\nexpected_front=%s\nbackend=%s\ninit=%s\n' \
  "$RUN_ID" "$DEVICE_TAG" "$X" "$Y" "$EXPECTED_FRONT" "$BACKEND" \
  "$INIT_ORIENT" >"$OUT/metadata.txt"

# Fail before input unless the requested App is visibly foreground and ZiYan
# has no live script/keep state. Coordinates remain init(1) logical pixels.
ssh_r "V='$V' EXPECTED='$EXPECTED_FRONT' BACKEND='$BACKEND' INIT='$INIT_ORIENT' sh -s" >"$OUT/preflight.txt" <<'EOS'
set -eu
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
orient=$(sed -n '1p' "$V/.ziyan_orient" 2>/dev/null || true)
active=$(test -e "$V/.ziyan_active" && echo 1 || echo 0)
embed=$(test -e "$V/.ziyan_lua_embedded" && echo 1 || echo 0)
keep=$(test -e "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
fc=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
sb=$(ps ax -o pid=,command= | sed -n '\|/SpringBoard.app/SpringBoard$|{s/^ *\([0-9][0-9]*\).*/\1/p;q;}')
bb=$(ps ax -o pid=,command= | sed -n '\|/backboardd$|{s/^ *\([0-9][0-9]*\).*/\1/p;q;}')
printf 'front=%s\norient=%s\nactive=%s\nembed=%s\nkeep=%s\nfc_n=%s\nsb_pid=%s\nbb_pid=%s\n' \
  "$front" "$orient" "$active" "$embed" "$keep" "$fc" "$sb" "$bb"
[ "$front" = "$EXPECTED" ]
if [ "$BACKEND" != "lua" ]; then
  [ "$orient" = "$INIT" ]
fi
[ "$active" = "0" ]
[ "$embed" = "0" ]
[ "$keep" = "0" ]
[ "$fc" = "1" ]
EOS

PORT="$(ssh_r "cat '$V/.ziyan_snap_http_port' 2>/dev/null" 2>/dev/null |
  tr -dc '0-9' || true)"
PORT="${PORT:-50005}"
snapshot() {
  local file="$1"
  local phase="$2"
  ssh_r "V='$V' NONCE='${RUN_ID}_${phase}' sh -s" <<'EOS' >/dev/null
printf '1\n' >"$V/.ziyan_force_recap"
printf 'nonce=%s\n' "$NONCE" >"$V/.ziyan_frame_req"
chmod 666 "$V/.ziyan_force_recap" "$V/.ziyan_frame_req" 2>/dev/null || true
EOS
  local attempt sig
  for attempt in 1 2 3 4 5; do
    sleep 1
    curl -sS --connect-timeout 5 -m 15 -o "$file" \
      "http://$HOST:$PORT/snapshot" || true
    sig="$(od -An -tx1 -N8 "$file" 2>/dev/null | tr -d ' \n')"
    [ "$sig" = "89504e470d0a1a0a" ] && break
    printf '1\n' | ssh_r "cat >'$V/.ziyan_force_recap'" >/dev/null
  done
  [ "${sig:-}" = "89504e470d0a1a0a" ] || {
    echo "snapshot unavailable after 5 attempts: $phase" >&2
    return 1
  }
  printf '%s_frame_seq=%s\n' "$phase" \
    "$(ssh_r "cat '$V/.ziyan_frame_seq' 2>/dev/null" | tr -dc '0-9')" \
    >>"$OUT/metadata.txt"
}
snapshot "$OUT/before.png" before

ssh_r "V='$V' LUA_BIN='$LUA_BIN' LUA_RUNNER='$LUA_RUNNER' NONCE='$RUN_ID' X='$X' Y='$Y' HOLD='$HOLD_MS' BACKEND='$BACKEND' INIT='$INIT_ORIENT' sh -s" \
  >"$OUT/submit.txt" <<'EOS'
set -eu
if [ "$BACKEND" = lua ]; then
  rm -f "$V/.ziyan_prefer_app_touch" "$V/.ziyan_app_touch_ui" \
    "$V/.ziyan_lua_tap_probe" "$V/.ziyan_tap_meta"
  cat >"/tmp/ziyan_lua_tap_probe.lua" <<LUA
init($INIT)
local ok = tap($X, $Y)
local f = io.open("$V/.ziyan_lua_tap_probe", "w")
if f then
  f:write("$NONCE\\n", ok and "ok\\n1\\n" or "err\\n0\\n")
  f:close()
end
LUA
  if [ "$V" = "/var/jb/usr/lib/ziyan/var" ]; then
    DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib \
      "$LUA_BIN" "$LUA_RUNNER" /tmp/ziyan_lua_tap_probe.lua
  else
    "$LUA_BIN" "$LUA_RUNNER" /tmp/ziyan_lua_tap_probe.lua
  fi
  exit 0
fi
if [ "$BACKEND" = bb ]; then
  req="$V/.ziyan_bbtouch_req"
  rm -f "$req" "$V/.ziyan_bbtouch_rep" "$V/.ziyan_bbtouch_state"
else
  req="$V/.ziyan_touch_req"
  rm -f "$req" "$V/.ziyan_touch_rep" "$V/.ziyan_app_touch_dispatch"
  if [ "$BACKEND" = app ]; then
    printf '1\n' >"$V/.ziyan_prefer_app_touch"
    printf '1\n' >"$V/.ziyan_app_touch_ui"
    chmod 666 "$V/.ziyan_prefer_app_touch" "$V/.ziyan_app_touch_ui" 2>/dev/null || true
  else
    rm -f "$V/.ziyan_prefer_app_touch" "$V/.ziyan_app_touch_ui" \
      "$V/.ziyan_app_alive" "$V/.ziyan_app_fg"
  fi
fi
tmp="${req}.${NONCE}.tmp"
printf 'tap\n1\n%s\n%s\n%s\n%s\n' "$X" "$Y" "$HOLD" "$NONCE" >"$tmp"
chmod 666 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$req"
EOS

sleep 2
snapshot "$OUT/after.png" after
ssh_r "V='$V' BACKEND='$BACKEND' sh -s" >"$OUT/final_device.txt" <<'EOS'
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
fc=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
sb=$(ps ax -o pid=,command= | sed -n '\|/SpringBoard.app/SpringBoard$|{s/^ *\([0-9][0-9]*\).*/\1/p;q;}')
bb=$(ps ax -o pid=,command= | sed -n '\|/backboardd$|{s/^ *\([0-9][0-9]*\).*/\1/p;q;}')
printf 'front=%s\nfc_n=%s\nsb_pid=%s\nbb_pid=%s\n' "$front" "$fc" "$sb" "$bb"
if [ "$BACKEND" = lua ]; then
  echo '=== reply ==='; cat "$V/.ziyan_lua_tap_probe" 2>/dev/null || true
  echo '=== state ==='; cat "$V/.ziyan_tap_meta" 2>/dev/null || true
  echo '=== hid ==='; cat "$V/.ziyan_hid_err" 2>/dev/null || true
elif [ "$BACKEND" = bb ]; then
  echo '=== reply ==='; cat "$V/.ziyan_bbtouch_rep" 2>/dev/null || true
  echo '=== state ==='; cat "$V/.ziyan_bbtouch_state" 2>/dev/null || true
else
  echo '=== reply ==='; cat "$V/.ziyan_touch_rep" 2>/dev/null || true
  echo '=== state ==='
  if [ "$BACKEND" = app ]; then
    cat "$V/.ziyan_app_touch_dispatch" 2>/dev/null || true
  else
    cat "$V/.ziyan_observation_packet" 2>/dev/null || true
  fi
fi
echo '=== residual ==='
for f in .ziyan_active .ziyan_lua_embedded .ziyan_keep_daemon; do
  test -e "$V/$f" && echo "present=$f" || echo "clear=$f"
done
rm -f "$V/.ziyan_bbtouch_req" "$V/.ziyan_touch_req" \
  "$V/.ziyan_prefer_app_touch" "$V/.ziyan_app_touch_ui"
EOS

DIFF="$(python3 - "$OUT/before.png" "$OUT/after.png" <<'PY'
import sys
from PIL import Image, ImageChops

a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
if a.size != b.size:
    print("1.000000")
else:
    d = ImageChops.difference(a, b).convert("L")
    changed = sum(px > 24 for px in d.getdata())
    print(f"{changed / (a.width * a.height):.6f}")
PY
)"
REP_OK=0
grep -A8 '^=== reply ===' "$OUT/final_device.txt" | grep -q "^$RUN_ID$" &&
  grep -A8 '^=== reply ===' "$OUT/final_device.txt" | grep -q '^ok$' &&
  REP_OK=1
DISPATCH_OK=0
if [ "$BACKEND" = lua ]; then
  [ "$REP_OK" = 1 ] && DISPATCH_OK=1
elif [ "$BACKEND" = bb ]; then
  grep -A8 '^=== state ===' "$OUT/final_device.txt" | grep -q '^phase=up$' &&
    grep -A8 '^=== state ===' "$OUT/final_device.txt" | grep -q '^ok=1$' &&
    DISPATCH_OK=1
elif [ "$BACKEND" = app ]; then
  grep -A8 '^=== state ===' "$OUT/final_device.txt" |
    grep -Eq '^app_dispatch phase=up hid=1 ui=1 want_ui=1$' &&
    DISPATCH_OK=1
else
  [ "$REP_OK" = 1 ] && DISPATCH_OK=1
fi
SB0="$(sed -n 's/^sb_pid=//p' "$OUT/preflight.txt")"
SB1="$(sed -n 's/^sb_pid=//p' "$OUT/final_device.txt")"
BB0="$(sed -n 's/^bb_pid=//p' "$OUT/preflight.txt")"
BB1="$(sed -n 's/^bb_pid=//p' "$OUT/final_device.txt")"

{
  echo "# .$DEVICE_TAG foreground App tap observation"
  echo
  echo "- run_id: \`$RUN_ID\`"
  echo "- coordinate: \`$X,$Y\` (init($INIT_ORIENT) logical)"
  echo "- backend: \`$BACKEND\`"
  echo "- receipt_ok: \`$REP_OK\`"
  echo "- dispatch_ok: \`$DISPATCH_OK\`"
  echo "- pixel_diff_ratio: \`$DIFF\`"
  echo "- SpringBoard PID: \`$SB0 -> $SB1\`"
  echo "- BackBoard PID: \`$BB0 -> $BB1\`"
  echo
  # 新鲜前后帧出现业务 UI 变化是最高级证据；AppTouch 的可选 UIKit
  # 主队列诊断标记可能晚于 HID 已被应用消费，不得反过来否定画面变化。
  if [ "$REP_OK" = 1 ] &&
     [ "$SB0" = "$SB1" ] && [ "$BB0" = "$BB1" ] &&
     [ "$DIFF" != "0.000000" ]; then
    echo "VERDICT=APP_TOUCH_UI_RESPONSE"
  elif [ "$REP_OK" = 1 ] && [ "$DISPATCH_OK" = 1 ]; then
    echo "VERDICT=TOUCH_SENT_NO_UI_CHANGE"
  else
    echo "VERDICT=APP_TOUCH_UNAVAILABLE"
  fi
} >"$OUT/VERDICT.md"

shasum -a 256 "$OUT"/* >"$OUT/SHA256SUMS.txt"
cat "$OUT/VERDICT.md"
printf 'OUT=%s\n' "$OUT"
