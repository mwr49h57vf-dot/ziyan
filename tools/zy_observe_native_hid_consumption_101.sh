#!/usr/bin/env bash
# Single .101 framecap-native IOKit delivery observation.
#
# This contrasts the currently loaded framecap `ziyan_embed_tap` route with
# BBTouch. It submits one tap only after proving SpringBoard is already
# foreground. It never sends Home/suspend/close and never restores a launched
# App.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="192.168.31.101"
V="/usr/lib/ziyan/var"
M="/private/var/mobile/Media/ZiYan"
X=1010
Y=294
HOLD_MS=90
EXPECTED_BID="com.xztl.ios"
MAP_MODE="${1:-portrait_glass}"
TARGET_HALF_W=96
TARGET_HALF_H=96
STAMP="$(date '+%Y%m%d_%H%M%S')"
RUN_ID="nativeconsume101_${STAMP}_$$"
OUT="$ROOT/tmp_shots/DEVICE101_NATIVE_HID_CONSUMPTION_${STAMP}_${RUN_ID##*_}"
REMOTE_SCRIPT="$M/_native_hid_consumption_${RUN_ID}.lua"
REMOTE_RESULT="$M/_native_hid_consumption_${RUN_ID}.txt"

case "$MAP_MODE" in
  portrait_glass)
    PROBE_X="$X"
    PROBE_Y="$Y"
    EXPECTED_HID="0.541,0.890"
    ;;
  logical_identity)
    # For init(1), map (x,y) -> (1 - y/640, x/1136). Feeding this
    # preimage makes the same event envelope carry the unrotated logical
    # normalized coordinate (1010/1136,294/640).
    PROBE_X=521
    PROBE_Y=71
    EXPECTED_HID="0.889,0.459"
    ;;
  *)
    echo "usage: $0 [portrait_glass|logical_identity]" >&2
    exit 2
    ;;
esac

SSH=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=12
  "root@$HOST"
)

ssh_r() {
  "${SSH[@]}" "$@"
}

mkdir -p "$OUT"
printf '%s\n' \
  "device=.101" \
  "host=$HOST" \
  "route=framecap_native_iohid" \
  "target=$X,$Y" \
  "probe_logic=$PROBE_X,$PROBE_Y" \
  "map_mode=$MAP_MODE" \
  "expected_hid=$EXPECTED_HID" \
  "target_half_size=$TARGET_HALF_W,$TARGET_HALF_H" \
  "hold_ms=$HOLD_MS" \
  "expected_bid=$EXPECTED_BID" \
  "run_id=$RUN_ID" \
  "constraint=no_home_no_suspend_no_close" \
  >"$OUT/metadata.txt"

# Fail before changing ZiYan state unless this is the ios7 init contract and
# there is no previous ZiYan business session to interrupt.
ssh_r "V='$V' sh -s" >"$OUT/preflight.txt" <<'EOS'
set -eu
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
orient=$(sed -n '1p' "$V/.ziyan_orient" 2>/dev/null || true)
lw=$(sed -n '2p' "$V/.ziyan_orient" 2>/dev/null || true)
lh=$(sed -n '3p' "$V/.ziyan_orient" 2>/dev/null || true)
active=$(test -e "$V/.ziyan_active" && echo 1 || echo 0)
embed=$(test -e "$V/.ziyan_embed_go" && echo 1 || echo 0)
keep=$(test -e "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
sb=$(ps ax -o pid=,command= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
bb=$(ps ax -o pid=,command= 2>/dev/null | grep -i '[b]ackboardd' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
fc=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
printf 'front=%s\norient=%s\nlogic=%sx%s\nactive=%s\nembed=%s\nkeep=%s\nsb_pid=%s\nbb_pid=%s\nfc_n=%s\n' \
  "$front" "$orient" "$lw" "$lh" "$active" "$embed" "$keep" "$sb" "$bb" "$fc"
[ "$front" = "com.apple.springboard" ]
[ "$orient" = "1" ]
[ "$lw" = "1136" ]
[ "$lh" = "640" ]
[ "$active" = "0" ]
[ "$embed" = "0" ]
[ "$keep" = "0" ]
[ "$fc" = "1" ]
EOS

PORT="$(ssh_r "cat '$V/.ziyan_snap_http_port' 2>/dev/null" | tr -dc '0-9')"
PORT="${PORT:-50005}"
printf 'snapshot_port=%s\n' "$PORT" >>"$OUT/metadata.txt"

snapshot() {
  local file="$1"
  curl -sS --connect-timeout 5 -m 15 -o "$file" -w '%{http_code}' \
    "http://$HOST:$PORT/snapshot"
}

ssh_r "echo 1 >'$V/.ziyan_force_recap'; echo nonce='$RUN_ID' >'$V/.ziyan_frame_req'; chmod 666 '$V/.ziyan_force_recap' '$V/.ziyan_frame_req' 2>/dev/null; sleep 1"
BEFORE_HTTP="$(snapshot "$OUT/before.png")"
printf 'before_http=%s\nbefore_bytes=%s\n' "$BEFORE_HTTP" "$(wc -c <"$OUT/before.png")" \
  >>"$OUT/metadata.txt"
[ "$BEFORE_HTTP" = "200" ]

printf '%s\n' \
  'function main()' \
  '  init(1)' \
  '  mSleep(300)' \
  "  local ok = ziyan_embed_tap(1, $PROBE_X, $PROBE_Y, $HOLD_MS)" \
  "  local f = io.open('$REMOTE_RESULT', 'w')" \
  "  if f then f:write('native_ok=' .. tostring(ok) .. '\\n'); f:close() end" \
  '  mSleep(1200)' \
  'end' \
  >"$OUT/probe.lua"

scp -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=12 "$OUT/probe.lua" "root@$HOST:$REMOTE_SCRIPT"

ssh_r "V='$V' M='$M' SCRIPT='$REMOTE_SCRIPT' RESULT='$REMOTE_RESULT' RUN_ID='$RUN_ID' sh -s" \
  >"$OUT/start.txt" <<'EOS'
set -eu
rm -f "$V/.ziyan_touch_native" "$V/.ziyan_hid_err" "$RESULT"
printf 'path=%s\nstop=0\n' "$SCRIPT" >"$V/.ziyan_run_intent"
printf '%s\n' "$SCRIPT" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
printf 'nonce=%s\n' "$RUN_ID" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" \
  "$V/.ziyan_embed_go" 2>/dev/null || true
printf 'started_epoch_ms=%s\n' "$(date +%s000)"
EOS

# Read-only monitor. If the visible icon opens its App, no follow-up control
# command is issued to that App.
{
  echo "elapsed_ms,front,result,native,hid_err"
  for i in $(seq 1 32); do
    sample="$(ssh_r "V='$V' RESULT='$REMOTE_RESULT' sh -s" <<'EOS'
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
result=$(test -e "$RESULT" && tr '\n' '|' <"$RESULT" || true)
native=$(test -e "$V/.ziyan_touch_native" && tr '\n' '|' <"$V/.ziyan_touch_native" || true)
hid=$(test -e "$V/.ziyan_hid_err" && tr '\n' '|' <"$V/.ziyan_hid_err" || true)
printf '%s\t%s\t%s\t%s\n' "$front" "$result" "$native" "$hid"
EOS
)"
    IFS="$(printf '\t')" read -r front result native hid <<<"$sample"
    printf '%s,%q,%q,%q,%q\n' "$((i * 250))" "$front" "$result" "$native" "$hid"
    sleep 0.25
  done
} >"$OUT/monitor.csv"

ssh_r "echo 1 >'$V/.ziyan_force_recap'; echo nonce='${RUN_ID}_after' >'$V/.ziyan_frame_req'; chmod 666 '$V/.ziyan_force_recap' '$V/.ziyan_frame_req' 2>/dev/null; sleep 1"
AFTER_HTTP="$(snapshot "$OUT/after.png")"
printf 'after_http=%s\nafter_bytes=%s\n' "$AFTER_HTTP" "$(wc -c <"$OUT/after.png")" \
  >>"$OUT/metadata.txt"

# Only stop/remove the ZiYan probe session. This does not act on the current
# foreground App, which is deliberately left unchanged after observation.
ssh_r "V='$V' SCRIPT='$REMOTE_SCRIPT' RESULT='$REMOTE_RESULT' sh -s" \
  >"$OUT/final_device.txt" <<'EOS'
set -eu
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
sb=$(ps ax -o pid=,command= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
bb=$(ps ax -o pid=,command= 2>/dev/null | grep -i '[b]ackboardd' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
fc=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
printf 'front=%s\nsb_pid=%s\nbb_pid=%s\nfc_n=%s\n' "$front" "$sb" "$bb" "$fc"
echo '=== native_result ==='
test -e "$RESULT" && cat "$RESULT" || true
echo '=== native_touch ==='
test -e "$V/.ziyan_touch_native" && cat "$V/.ziyan_touch_native" || true
echo '=== hid_err ==='
test -e "$V/.ziyan_hid_err" && cat "$V/.ziyan_hid_err" || true
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" \
  "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$SCRIPT" "$RESULT"
echo '=== cleanup_state ==='
for f in .ziyan_active .ziyan_embed_go .ziyan_lua_embedded .ziyan_keep_daemon; do
  test -e "$V/$f" && echo "present=$f" || echo "clear=$f"
done
EOS

DIFF="n/a"
TARGET_CHANGED="n/a"
DIFF_BBOX="n/a"
if [ "$AFTER_HTTP" = "200" ]; then
  DIFF_STATS="$(python3 - "$OUT/before.png" "$OUT/after.png" \
      "$X" "$Y" "$TARGET_HALF_W" "$TARGET_HALF_H" <<'PY'
import sys
from PIL import Image, ImageChops

before = Image.open(sys.argv[1]).convert("RGB")
after = Image.open(sys.argv[2]).convert("RGB")
target_x, target_y, half_w, half_h = map(int, sys.argv[3:])
if before.size != after.size:
    print("1.000000")
    print("unknown")
    print("size_mismatch")
    raise SystemExit
delta = ImageChops.difference(before, after).convert("L")
mask = delta.point(lambda px: 255 if px > 24 else 0)
changed = sum(1 for px in delta.getdata() if px > 24)
bbox = mask.getbbox()
if bbox is None:
    target_changed = 0
    bbox_text = "none"
else:
    left = max(0, target_x - half_w)
    top = max(0, target_y - half_h)
    right = min(mask.width, target_x + half_w + 1)
    bottom = min(mask.height, target_y + half_h + 1)
    target_changed = sum(
        1
        for py in range(top, bottom)
        for px in range(left, right)
        if mask.getpixel((px, py))
    )
    bbox_text = f"{bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]}"
print(f"{changed / (before.size[0] * before.size[1]):.6f}")
print(target_changed)
print(bbox_text)
PY
)"
  DIFF="$(printf '%s\n' "$DIFF_STATS" | sed -n '1p')"
  TARGET_CHANGED="$(printf '%s\n' "$DIFF_STATS" | sed -n '2p')"
  DIFF_BBOX="$(printf '%s\n' "$DIFF_STATS" | sed -n '3p')"
fi

NATIVE_OK=0
grep -A5 '^=== native_result ===' "$OUT/final_device.txt" | grep -q '^native_ok=true$' &&
  NATIVE_OK=1
IOHID_ROUTE=0
grep -A7 '^=== hid_err ===' "$OUT/final_device.txt" | grep -q '^route=iohid_dispatch$' &&
  IOHID_ROUTE=1
SAW_EXPECTED=0
grep -q "$EXPECTED_BID" "$OUT/monitor.csv" && SAW_EXPECTED=1
FINAL_FRONT="$(sed -n 's/^front=//p' "$OUT/final_device.txt" | head -1)"
SB0="$(sed -n 's/^sb_pid=//p' "$OUT/preflight.txt" | head -1)"
SB1="$(sed -n 's/^sb_pid=//p' "$OUT/final_device.txt" | head -1)"
BB0="$(sed -n 's/^bb_pid=//p' "$OUT/preflight.txt" | head -1)"
BB1="$(sed -n 's/^bb_pid=//p' "$OUT/final_device.txt" | head -1)"

{
  echo "# .101 native IOKit UI-consumption observation"
  echo
  echo "- visible target: \`$X,$Y\` (SpringBoard game icon center)"
  echo "- probe logic: \`$PROBE_X,$PROBE_Y\`"
  echo "- map mode: \`$MAP_MODE\`"
  echo "- expected HID: \`$EXPECTED_HID\`"
  echo "- expected bundle after an actual SpringBoard icon click: \`$EXPECTED_BID\`"
  echo "- native_ok: \`$NATIVE_OK\`"
  echo "- iohid_route: \`$IOHID_ROUTE\`"
  echo "- saw_expected_bid: \`$SAW_EXPECTED\`"
  echo "- final_front: \`$FINAL_FRONT\`"
  echo "- pixel_diff_ratio: \`$DIFF\`"
  echo "- target_changed_pixels: \`$TARGET_CHANGED\`"
  echo "- diff_bbox: \`$DIFF_BBOX\`"
  echo "- SpringBoard PID: \`$SB0 -> $SB1\`"
  echo "- BackBoard PID: \`$BB0 -> $BB1\`"
  echo "- constraints: no Home, suspend, close, SpringBoard restart, or BackBoard restart command was issued."
  echo
  if [ "$NATIVE_OK" = 1 ] && [ "$IOHID_ROUTE" = 1 ] && [ "$SAW_EXPECTED" = 1 ]; then
    echo "VERDICT=IOHID_DELIVERED_UI_RESPONSE"
    echo "The selected coordinate hypothesis reached the visible target."
  elif [ "$NATIVE_OK" = 1 ] && [ "$IOHID_ROUTE" = 1 ] && \
       [ "$FINAL_FRONT" = "com.apple.springboard" ] && [ "$TARGET_CHANGED" = "0" ]; then
    if [ "$MAP_MODE" = "logical_identity" ]; then
      echo "VERDICT=MAP_DISCRIMINATOR_NO_TARGET_RESPONSE"
      echo "The alternate logical-identity coordinate hypothesis produced no target response."
    else
      echo "VERDICT=IOHID_SUBMIT_NO_TARGET_RESPONSE"
    fi
  else
    echo "VERDICT=INCONCLUSIVE"
  fi
} >"$OUT/VERDICT.md"

shasum -a 256 "$OUT"/* >"$OUT/SHA256SUMS.txt"
cat "$OUT/VERDICT.md"
printf 'OUT=%s\n' "$OUT"
