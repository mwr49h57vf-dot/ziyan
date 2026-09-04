#!/usr/bin/env bash
# Single .101 SpringBoard-owned touch observation.
#
# The target is the visible third Home-page indicator, not an app icon. That
# keeps ZiYanScreenBridge's icon-launch fallback out of scope while testing its
# SpringBoard-main-thread event construction and delivery context.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="192.168.31.101"
V="/usr/lib/ziyan/var"
X=956
Y=352
HOLD_MS=90
TARGET_HALF_W=96
TARGET_HALF_H=96
STAMP="$(date '+%Y%m%d_%H%M%S')"
NONCE="sbconsume101_${STAMP}_$$"
OUT="$ROOT/tmp_shots/DEVICE101_SPRINGBOARD_HID_CONSUMPTION_${STAMP}_${NONCE##*_}"

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
  "route=springboard_screenbridge_touch_req" \
  "target=$X,$Y" \
  "target_kind=home_page_indicator" \
  "hold_ms=$HOLD_MS" \
  "nonce=$NONCE" \
  "constraint=no_home_no_suspend_no_close_no_app_icon_target" \
  >"$OUT/metadata.txt"

# Do not alter the front owner. This test needs the current init(1) frame and
# an idle ZiYan session, otherwise it exits before publishing the request.
ssh_r "V='$V' sh -s" >"$OUT/preflight.txt" <<'EOS'
set -eu
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
orient=$(sed -n '1p' "$V/.ziyan_orient" 2>/dev/null || true)
lw=$(sed -n '2p' "$V/.ziyan_orient" 2>/dev/null || true)
lh=$(sed -n '3p' "$V/.ziyan_orient" 2>/dev/null || true)
active=$(test -e "$V/.ziyan_active" && echo 1 || echo 0)
embed=$(test -e "$V/.ziyan_embed_go" && echo 1 || echo 0)
keep=$(test -e "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
sb_rows=$(ps ax -o pid=,command= 2>/dev/null |
  sed -n '\|/System/Library/CoreServices/SpringBoard\.app/SpringBoard$|p')
sb_count=$(printf '%s\n' "$sb_rows" | sed '/^$/d' | wc -l | tr -d ' ')
sb=$(printf '%s\n' "$sb_rows" |
  sed -n '1s/^ *\([0-9][0-9]*\) .*/\1/p')
bb=$(ps ax -o pid=,command= 2>/dev/null | grep -i '[b]ackboardd' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
fc=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
printf 'front=%s\norient=%s\nlogic=%sx%s\nactive=%s\nembed=%s\nkeep=%s\nsb_candidate_count=%s\nsb_pid=%s\nbb_pid=%s\nfc_n=%s\n' \
  "$front" "$orient" "$lw" "$lh" "$active" "$embed" "$keep" "$sb_count" "$sb" "$bb" "$fc"
echo '=== springboard_candidates ==='
printf '%s\n' "$sb_rows"
[ "$front" = "com.apple.springboard" ]
[ "$orient" = "1" ]
[ "$lw" = "1136" ]
[ "$lh" = "640" ]
[ "$active" = "0" ]
[ "$embed" = "0" ]
[ "$keep" = "0" ]
[ "$sb_count" = "1" ]
[ -n "$sb" ]
[ "$fc" = "1" ]
EOS

PORT="$(ssh_r "cat '$V/.ziyan_snap_http_port' 2>/dev/null" | tr -dc '0-9')"
PORT="${PORT:-50005}"
printf 'snapshot_port=%s\n' "$PORT" >>"$OUT/metadata.txt"

snapshot() {
  curl -sS --connect-timeout 5 -m 15 -o "$1" -w '%{http_code}' \
    "http://$HOST:$PORT/snapshot"
}

ssh_r "echo 1 >'$V/.ziyan_force_recap'; echo nonce='$NONCE' >'$V/.ziyan_frame_req'; chmod 666 '$V/.ziyan_force_recap' '$V/.ziyan_frame_req' 2>/dev/null; sleep 1"
BEFORE_HTTP="$(snapshot "$OUT/before.png")"
printf 'before_http=%s\nbefore_bytes=%s\n' "$BEFORE_HTTP" "$(wc -c <"$OUT/before.png")" \
  >>"$OUT/metadata.txt"
[ "$BEFORE_HTTP" = "200" ]

ssh_r "V='$V' NONCE='$NONCE' X='$X' Y='$Y' HOLD_MS='$HOLD_MS' sh -s" \
  >"$OUT/submit.txt" <<'EOS'
set -eu
rm -f "$V/.ziyan_touch_req" "$V/.ziyan_touch_rep" "$V/.ziyan_observation_packet"
tmp="$V/.ziyan_touch_req.${NONCE}.tmp"
printf 'tap\n1\n%s\n%s\n%s\n%s\n' "$X" "$Y" "$HOLD_MS" "$NONCE" >"$tmp"
chmod 666 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$V/.ziyan_touch_req"
printf 'submitted_epoch_ms=%s\n' "$(date +%s000)"
EOS

{
  echo "elapsed_ms,front,rep,observation"
  for i in $(seq 1 32); do
    sample="$(ssh_r "V='$V' sh -s" <<'EOS'
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
rep=$(test -e "$V/.ziyan_touch_rep" && tr '\n' '|' <"$V/.ziyan_touch_rep" || true)
obs=$(test -e "$V/.ziyan_observation_packet" && tr '\n' '|' <"$V/.ziyan_observation_packet" || true)
printf '%s\t%s\t%s\n' "$front" "$rep" "$obs"
EOS
)"
    IFS="$(printf '\t')" read -r front rep obs <<<"$sample"
    printf '%s,%q,%q,%q\n' "$((i * 250))" "$front" "$rep" "$obs"
    sleep 0.25
  done
} >"$OUT/monitor.csv"

ssh_r "echo 1 >'$V/.ziyan_force_recap'; echo nonce='${NONCE}_after' >'$V/.ziyan_frame_req'; chmod 666 '$V/.ziyan_force_recap' '$V/.ziyan_frame_req' 2>/dev/null; sleep 1"
AFTER_HTTP="$(snapshot "$OUT/after.png")"
printf 'after_http=%s\nafter_bytes=%s\n' "$AFTER_HTTP" "$(wc -c <"$OUT/after.png")" \
  >>"$OUT/metadata.txt"

ssh_r "V='$V' NONCE='$NONCE' sh -s" >"$OUT/final_device.txt" <<'EOS'
set -eu
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
sb_rows=$(ps ax -o pid=,command= 2>/dev/null |
  sed -n '\|/System/Library/CoreServices/SpringBoard\.app/SpringBoard$|p')
sb_count=$(printf '%s\n' "$sb_rows" | sed '/^$/d' | wc -l | tr -d ' ')
sb=$(printf '%s\n' "$sb_rows" |
  sed -n '1s/^ *\([0-9][0-9]*\) .*/\1/p')
bb=$(ps ax -o pid=,command= 2>/dev/null | grep -i '[b]ackboardd' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
fc=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
printf 'front=%s\nsb_candidate_count=%s\nsb_pid=%s\nbb_pid=%s\nfc_n=%s\n' \
  "$front" "$sb_count" "$sb" "$bb" "$fc"
echo '=== springboard_candidates ==='
printf '%s\n' "$sb_rows"
echo '=== touch_rep ==='
test -e "$V/.ziyan_touch_rep" && cat "$V/.ziyan_touch_rep" || true
echo '=== observation ==='
test -e "$V/.ziyan_observation_packet" && cat "$V/.ziyan_observation_packet" || true
echo '=== cleanup_state ==='
for f in .ziyan_active .ziyan_embed_go .ziyan_lua_embedded .ziyan_keep_daemon; do
  test -e "$V/$f" && echo "present=$f" || echo "clear=$f"
done
rm -f "$V/.ziyan_touch_req"
EOS

DIFF_STATS="$(python3 - "$OUT/before.png" "$OUT/after.png" "$X" "$Y" \
    "$TARGET_HALF_W" "$TARGET_HALF_H" <<'PY'
import sys
from PIL import Image, ImageChops

before = Image.open(sys.argv[1]).convert("RGB")
after = Image.open(sys.argv[2]).convert("RGB")
target_x, target_y, half_w, half_h = map(int, sys.argv[3:])
delta = ImageChops.difference(before, after).convert("L")
mask = delta.point(lambda px: 255 if px > 24 else 0)
changed = sum(px > 24 for px in delta.getdata())
bbox = mask.getbbox()
left = max(0, target_x - half_w)
top = max(0, target_y - half_h)
right = min(mask.width, target_x + half_w + 1)
bottom = min(mask.height, target_y + half_h + 1)
target_changed = sum(
    1 for py in range(top, bottom) for px in range(left, right)
    if mask.getpixel((px, py))
)
print(f"{changed / (before.width * before.height):.6f}")
print(target_changed)
print("none" if bbox is None else ",".join(map(str, bbox)))
PY
)"
DIFF="$(printf '%s\n' "$DIFF_STATS" | sed -n '1p')"
TARGET_CHANGED="$(printf '%s\n' "$DIFF_STATS" | sed -n '2p')"
DIFF_BBOX="$(printf '%s\n' "$DIFF_STATS" | sed -n '3p')"

REP_OK=0
grep -A4 '^=== touch_rep ===' "$OUT/final_device.txt" | grep -q "^$NONCE$" &&
  grep -A4 '^=== touch_rep ===' "$OUT/final_device.txt" | grep -q '^ok$' &&
  REP_OK=1
FINAL_FRONT="$(sed -n 's/^front=//p' "$OUT/final_device.txt" | head -1)"
SB0="$(sed -n 's/^sb_pid=//p' "$OUT/preflight.txt" | head -1)"
SB1="$(sed -n 's/^sb_pid=//p' "$OUT/final_device.txt" | head -1)"
BB0="$(sed -n 's/^bb_pid=//p' "$OUT/preflight.txt" | head -1)"
BB1="$(sed -n 's/^bb_pid=//p' "$OUT/final_device.txt" | head -1)"

{
  echo "# .101 SpringBoard-owned HID-consumption observation"
  echo
  echo "- target: \`$X,$Y\` (third Home-page indicator, not an app icon)"
  echo "- receipt_ok: \`$REP_OK\`"
  echo "- final_front: \`$FINAL_FRONT\`"
  echo "- pixel_diff_ratio: \`$DIFF\`"
  echo "- target_changed_pixels: \`$TARGET_CHANGED\`"
  echo "- diff_bbox: \`$DIFF_BBOX\`"
  echo "- SpringBoard PID: \`$SB0 -> $SB1\`"
  echo "- BackBoard PID: \`$BB0 -> $BB1\`"
  echo "- constraints: no Home, suspend, close, SpringBoard restart, BackBoard restart, or app-icon target was used."
  echo
  if [ -z "$SB0" ] || [ -z "$SB1" ] || [ "$SB0" != "$SB1" ]; then
    echo "VERDICT=INVALID_RUN_SB_PID_CHANGED"
    echo "SpringBoard PID was not stable during the observation, so no visual delta can be attributed to this submitted event."
  elif [ "$REP_OK" = 1 ] && [ "$FINAL_FRONT" = "com.apple.springboard" ] &&
     [ "$TARGET_CHANGED" -gt 0 ]; then
    echo "VERDICT=SPRINGBOARD_OWNED_UI_RESPONSE_CANDIDATE"
    echo "The page-indicator target changed without an app launch. This isolates SpringBoard delivery context; it is not evidence of a business-icon click."
  elif [ "$REP_OK" = 1 ] && [ "$FINAL_FRONT" = "com.apple.springboard" ]; then
    echo "VERDICT=SPRINGBOARD_OWNED_SUBMIT_NO_TARGET_RESPONSE"
  else
    echo "VERDICT=INCONCLUSIVE"
  fi
} >"$OUT/VERDICT.md"

shasum -a 256 "$OUT"/* >"$OUT/SHA256SUMS.txt"
cat "$OUT/VERDICT.md"
printf 'OUT=%s\n' "$OUT"
