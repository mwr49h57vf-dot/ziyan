#!/usr/bin/env bash
# Single .101 BBTouch delivery observation.
#
# This is intentionally not a business-script runner. It submits exactly one
# already-valid BBTouch request while SpringBoard is already foreground, then
# records the receipt, front-bundle transition, and before/after snapshots.
# It never emits a Home/suspend/close command and never restores a launched App.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="192.168.31.101"
V="/usr/lib/ziyan/var"
X=1010
Y=294
HOLD_MS=90
EXPECTED_BID="com.xztl.ios"
STAMP="$(date '+%Y%m%d_%H%M%S')"
NONCE="bbconsume101_${STAMP}_$$"
OUT="$ROOT/tmp_shots/DEVICE101_BBTOUCH_CONSUMPTION_${STAMP}_${NONCE##*_}"

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
  "target=$X,$Y" \
  "hold_ms=$HOLD_MS" \
  "expected_bid=$EXPECTED_BID" \
  "nonce=$NONCE" \
  "constraint=no_home_no_suspend_no_close" \
  >"$OUT/metadata.txt"

# The test is fail-closed: do not submit input if ZiYan is foreground, a script
# is still active, or the latest init geometry is not the ios7.lua contract.
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

# A capture refresh is not a front-app action. It does not change the selected
# foreground owner; it only asks the frame service to publish the visible frame.
ssh_r "echo 1 >'$V/.ziyan_force_recap'; echo nonce='$NONCE' >'$V/.ziyan_frame_req'; chmod 666 '$V/.ziyan_force_recap' '$V/.ziyan_frame_req' 2>/dev/null; sleep 1"
BEFORE_HTTP="$(snapshot "$OUT/before.png")"
printf 'before_http=%s\nbefore_bytes=%s\n' "$BEFORE_HTTP" "$(wc -c <"$OUT/before.png")" \
  >>"$OUT/metadata.txt"
[ "$BEFORE_HTTP" = "200" ]

ssh_r "V='$V' NONCE='$NONCE' X='$X' Y='$Y' HOLD_MS='$HOLD_MS' sh -s" \
  >"$OUT/submit.txt" <<'EOS'
set -eu
rm -f "$V/.ziyan_bbtouch_req" "$V/.ziyan_bbtouch_rep" "$V/.ziyan_bbtouch_state"
tmp="$V/.ziyan_bbtouch_req.${NONCE}.tmp"
printf 'tap\n1\n%s\n%s\n%s\n%s\n' "$X" "$Y" "$HOLD_MS" "$NONCE" >"$tmp"
chmod 666 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$V/.ziyan_bbtouch_req"
printf 'submitted_epoch_ms=%s\n' "$(date +%s000)"
EOS

# Polling is read-only. Once the target App is foreground it remains untouched.
{
  echo "elapsed_ms,front,rep,state,tail"
  for i in $(seq 1 32); do
    sample="$(ssh_r "V='$V' sh -s" <<'EOS'
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
rep=$(tr '\n' '|' <"$V/.ziyan_bbtouch_rep" 2>/dev/null || true)
state=$(tr '\n' '|' <"$V/.ziyan_bbtouch_state" 2>/dev/null || true)
tail=$(tail -n 2 "$V/.ziyan_touch_log" 2>/dev/null | tr '\n' '~' || true)
printf '%s\t%s\t%s\t%s\n' "$front" "$rep" "$state" "$tail"
EOS
)"
    IFS="$(printf '\t')" read -r front rep state tail <<<"$sample"
    printf '%s,%q,%q,%q,%q\n' "$((i * 250))" "$front" "$rep" "$state" "$tail"
    sleep 0.25
  done
} >"$OUT/monitor.csv"

ssh_r "echo 1 >'$V/.ziyan_force_recap'; echo nonce='${NONCE}_after' >'$V/.ziyan_frame_req'; chmod 666 '$V/.ziyan_force_recap' '$V/.ziyan_frame_req' 2>/dev/null; sleep 1"
AFTER_HTTP="$(snapshot "$OUT/after.png")"
printf 'after_http=%s\nafter_bytes=%s\n' "$AFTER_HTTP" "$(wc -c <"$OUT/after.png")" \
  >>"$OUT/metadata.txt"

ssh_r "V='$V' sh -s" >"$OUT/final_device.txt" <<'EOS'
set -eu
front=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null || true)
sb=$(ps ax -o pid=,command= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
bb=$(ps ax -o pid=,command= 2>/dev/null | grep -i '[b]ackboardd' | sed -n '1s/^ *\([0-9][0-9]*\).*/\1/p')
fc=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
printf 'front=%s\nsb_pid=%s\nbb_pid=%s\nfc_n=%s\n' "$front" "$sb" "$bb" "$fc"
echo '=== bbtouch_rep ==='
cat "$V/.ziyan_bbtouch_rep" 2>/dev/null || true
echo '=== bbtouch_state ==='
cat "$V/.ziyan_bbtouch_state" 2>/dev/null || true
echo '=== touch_log_tail ==='
tail -n 12 "$V/.ziyan_touch_log" 2>/dev/null || true
echo '=== cleanup_state ==='
for f in .ziyan_active .ziyan_embed_go .ziyan_lua_embedded .ziyan_keep_daemon; do
  test -e "$V/$f" && echo "present=$f" || echo "clear=$f"
done
EOS

DIFF="n/a"
if [ "$AFTER_HTTP" = "200" ]; then
  DIFF="$(python3 - "$OUT/before.png" "$OUT/after.png" <<'PY'
import sys
from PIL import Image, ImageChops

before = Image.open(sys.argv[1]).convert("RGB")
after = Image.open(sys.argv[2]).convert("RGB")
if before.size != after.size:
    print("1.000000")
    raise SystemExit
delta = ImageChops.difference(before, after).convert("L")
changed = sum(1 for px in delta.getdata() if px > 24)
print(f"{changed / (before.size[0] * before.size[1]):.6f}")
PY
)"
fi

REP_OK=0
grep -q "^$NONCE$" "$OUT/final_device.txt" &&
  grep -A6 '^=== bbtouch_rep ===' "$OUT/final_device.txt" | grep -q '^ok$' &&
  REP_OK=1
SAW_EXPECTED=0
grep -q "$EXPECTED_BID" "$OUT/monitor.csv" && SAW_EXPECTED=1
FINAL_FRONT="$(sed -n 's/^front=//p' "$OUT/final_device.txt" | head -1)"
SB0="$(sed -n 's/^sb_pid=//p' "$OUT/preflight.txt" | head -1)"
SB1="$(sed -n 's/^sb_pid=//p' "$OUT/final_device.txt" | head -1)"
BB0="$(sed -n 's/^bb_pid=//p' "$OUT/preflight.txt" | head -1)"
BB1="$(sed -n 's/^bb_pid=//p' "$OUT/final_device.txt" | head -1)"

{
  echo "# .101 BBTouch UI-consumption observation"
  echo
  echo "- target: \`$X,$Y\` (visible SpringBoard game icon center)"
  echo "- expected bundle after an actual SpringBoard icon click: \`$EXPECTED_BID\`"
  echo "- receipt_ok: \`$REP_OK\`"
  echo "- saw_expected_bid: \`$SAW_EXPECTED\`"
  echo "- final_front: \`$FINAL_FRONT\`"
  echo "- pixel_diff_ratio: \`$DIFF\`"
  echo "- SpringBoard PID: \`$SB0 -> $SB1\`"
  echo "- BackBoard PID: \`$BB0 -> $BB1\`"
  echo "- constraints: no Home, suspend, close, SpringBoard restart, or BackBoard restart command was issued."
  echo
  if [ "$REP_OK" = 1 ] && [ "$SAW_EXPECTED" = 1 ]; then
    echo "VERDICT=DELIVERED_UI_RESPONSE"
    echo "The exact BBTouch request was consumed by SpringBoard sufficiently to launch the visible target icon."
  elif [ "$REP_OK" = 1 ] && [ "$FINAL_FRONT" = "com.apple.springboard" ] && [ "$DIFF" = "0.000000" ]; then
    echo "VERDICT=SUBMIT_NO_UI_RESPONSE"
    echo "BackBoard reported local down/up submission, but the icon-center tap produced neither front transition nor visible UI change."
  else
    echo "VERDICT=INCONCLUSIVE"
    echo "The observation has a partial signal; inspect monitor.csv, final_device.txt, and snapshots before changing the touch layer."
  fi
} >"$OUT/VERDICT.md"

shasum -a 256 "$OUT"/* >"$OUT/SHA256SUMS.txt"
cat "$OUT/VERDICT.md"
printf 'OUT=%s\n' "$OUT"
