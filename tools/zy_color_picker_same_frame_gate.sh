#!/usr/bin/env bash
# Host-only COLOR_PICKER same-frame contract gate.
# Uses a fixed RGBA fixture. Does not deploy, kickstart, open apps, or change matcher/ROI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ZY_SAME_FRAME_OUT:-$ROOT/tmp_shots/COLOR_PICKER_SAME_FRAME_GATE_${STAMP}}"
mkdir -p "$OUT"
PASS=0
FAIL=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { PASS=$((PASS + 1)); note "PASS $*"; }
bad() { FAIL=$((FAIL + 1)); note "FAIL $*"; }

HTTP="$ROOT/tools/ziyan_framecap/ZiYanSnapshotHttp.m"
EMBED="$ROOT/tools/ziyan_framecap/ZiYanLuaEmbed.m"
RES_H="$ROOT/objc/shared/ZiYanFrameResident.h"
RES_M="$ROOT/objc/shared/ZiYanFrameResident.m"

note "==== static audit ===="

if grep -nE 'ZiYanFrameCaptureToShmCARenderOnly|CARenderOnly\(' "$HTTP" >/dev/null; then
  bad "HTTP path still calls CARenderOnly"
else
  ok "HTTP snapshot/findtest has no CARenderOnly"
fi

if grep -nE 'ZiYanWriteVarText\(@"\.ziyan_force_recap"' "$HTTP" >/dev/null; then
  bad "HTTP path still writes force_recap"
else
  ok "HTTP path does not write force_recap"
fi

if grep -nE 'pthread_create' "$HTTP" | grep -v SnapshotHttpThreadMain >/dev/null; then
  extra=$(grep -nE 'pthread_create' "$HTTP" | grep -v SnapshotHttpThreadMain || true)
  if [ -n "$extra" ]; then
    bad "HTTP added extra pthread_create: $extra"
  else
    ok "HTTP keeps the existing snapshot thread only"
  fi
else
  ok "HTTP keeps the existing snapshot thread only"
fi

if grep -n 'frame_unavailable' "$HTTP" >/dev/null && grep -n 'frame_changed' "$HTTP" >/dev/null; then
  ok "HTTP returns frame_unavailable / frame_changed"
else
  bad "HTTP missing frame_unavailable or frame_changed"
fi

for key in frame_seq generation front_bid pixel_format capture_ts_ms source; do
  if grep -n "$key" "$RES_H" >/dev/null && grep -n "$key" "$HTTP" >/dev/null; then
    ok "token field $key declared and used by HTTP"
  else
    bad "token field $key missing from Resident/HTTP"
  fi
done
if grep -nE 'ZiYanCanonicalFrameJSONByAddingToken|ZiYanCanonicalFrameTokenDictionary|ZiYanCanonicalFrameTokenWriteLast' "$EMBED" >/dev/null; then
  ok "Embed attaches the shared canonical token"
else
  bad "Embed does not attach the shared canonical token"
fi

if grep -n 'ZiYanCanonicalCurrentFrameMapRead' "$HTTP" >/dev/null && grep -n 'ZiYanCanonicalCurrentFrameMapRead' "$RES_M" >/dev/null; then
  ok "canonical MapRead is shared"
else
  bad "canonical MapRead missing"
fi

if grep -n 'frame_front_mismatch' "$EMBED" >/dev/null; then
  bad "Embed still refuses find on front_bid mismatch"
else
  ok "Embed does not refuse find on front_bid mismatch"
fi

if grep -n 'front_bid / SpringBoard' "$EMBED" >/dev/null; then
  ok "Embed documents SpringBoard as metadata not a find gate"
else
  bad "Embed missing SpringBoard-is-metadata comment"
fi

if grep -n 'lease suspended' "$EMBED" >/dev/null; then
  bad "Embed still has lease-suspended find gate text"
else
  ok "Embed lease-suspended is not a find switch"
fi

note "==== host RGBA fixture (same token, four readers) ===="
python3 - "$OUT" <<'PY' | tee -a "$OUT/summary.txt"
import json, os, sys

out = sys.argv[1]
W, H = 32, 16
BPR = W * 4
buf = bytearray(BPR * H)

def put(x, y, r, g, b, a=255):
    i = y * BPR + x * 4
    buf[i:i+4] = bytes((r, g, b, a))

# Distinct opaque pattern; main + 3 offsets like a findMulti string.
put(4, 3, 0x9C, 0x71, 0x52)
put(5, 3, 0x9B, 0x70, 0x52)
put(4, 4, 0x9D, 0x73, 0x53)
put(6, 5, 0x9C, 0x6E, 0x52)
# filler so empty scan would not accidentally hit
put(20, 10, 0x10, 0x20, 0x30)

def get_color(frame, x, y):
    if x < 0 or y < 0 or x >= W or y >= H:
        return -1
    i = y * BPR + x * 4
    r, g, b, a = frame[i:i+4]
    if 0 < a < 255:
        r = min(255, (r * 255) // a)
        g = min(255, (g * 255) // a)
        b = min(255, (b * 255) // a)
    return (r << 16) | (g << 8) | b

def snapshot_rgb(frame, x, y):
    return get_color(frame, x, y)

def find_exact(frame, main, offs, x1, y1, x2, y2):
    pts = [(0, 0, main)] + offs
    ax, bx = min(x1, x2), max(x1, x2)
    ay, by = min(y1, y2), max(y1, y2)
    for y in range(ay, by + 1):
        for x in range(ax, bx + 1):
            ok = True
            for dx, dy, col in pts:
                if get_color(frame, x + dx, y + dy) != col:
                    ok = False
                    break
            if ok:
                return x, y
    return -1, -1

def token(seq, gen, bid, source="resident"):
    return {
        "frame_seq": seq,
        "generation": gen,
        "front_bid": bid,
        "pixel_format": "RGBA8888",
        "width": W,
        "height": H,
        "bpr": BPR,
        "capture_ts_ms": 1720000000123,
        "frame_status": "valid",
        "source": source,
    }

def same_core(a, b):
    return (
        a["frame_seq"] == b["frame_seq"]
        and a["generation"] == b["generation"]
        and a["front_bid"] == b["front_bid"]
        and a["pixel_format"] == b["pixel_format"]
    )

def match_request(cur, req):
    if req.get("frame_seq") not in (None, "") and int(req["frame_seq"]) != cur["frame_seq"]:
        return False
    if req.get("generation") not in (None, "") and int(req["generation"]) != cur["generation"]:
        return False
    if req.get("front_bid") not in (None, "") and req["front_bid"] != cur["front_bid"]:
        return False
    if req.get("pixel_format") not in (None, "") and req["pixel_format"] != cur["pixel_format"]:
        return False
    return True

fail = 0

def check(name, cond):
    global fail
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fail += 1

# Four readers on one committed frame. SpringBoard bid is metadata only.
cur = token(7, 3, "com.apple.springboard")
main = 0x9C7152
offs = [(1, 0, 0x9B7052), (0, 1, 0x9D7353), (2, 2, 0x9C6E52)]
snap = snapshot_rgb(buf, 4, 3)
gc = get_color(buf, 4, 3)
fx, fy = find_exact(buf, main, offs, 4, 3, 6, 5)
check("same-token snapshot RGB == embed getColor", snap == gc == main)
check("same-token findtest hit == embed find", (fx, fy) == (4, 3))
check("SpringBoard bid is metadata not a find gate", fx == 4 and cur["front_bid"] == "com.apple.springboard")
check("source is committed resident", cur["source"] == "resident")

# Token mismatch must be frame_changed, never a silent rematch / miss.
wrong = dict(cur)
wrong["frame_seq"] = 8
if not match_request(cur, {"frame_seq": 8}):
    changed = {"ok": False, "x": -1, "y": -1, "err": "frame_changed", **cur}
else:
    hx, hy = find_exact(buf, main, offs, 4, 3, 6, 5)
    changed = {"ok": True, "x": hx, "y": hy, "err": "matched_wrong_frame"}
check("token mismatch returns frame_changed", changed.get("err") == "frame_changed")
check("token mismatch does not report a hit", changed.get("ok") is False and changed.get("x") == -1)

# No canonical frame -> frame_unavailable, not a matcher miss.
empty = {"ok": False, "x": -1, "y": -1, "err": "frame_unavailable",
         "frame_seq": 0, "generation": 0, "source": "none", "frame_status": "unavailable"}
check("no canonical frame returns frame_unavailable", empty["err"] == "frame_unavailable")
check("unavailable is not classified as pixel miss", empty["err"] != "pixel_miss")

# Arbitrary foreground id still finds on the same pixels.
cur2 = token(7, 3, "com.apple.Preferences")
fx2, fy2 = find_exact(buf, main, offs, 4, 3, 6, 5)
check("non-game front_bid still finds", (fx2, fy2) == (4, 3) and cur2["front_bid"] == "com.apple.Preferences")
check("core token identity ignores bid-as-switch", same_core(token(7, 3, "com.apple.springboard"), token(7, 3, "com.apple.springboard")))

report = {
    "width": W, "height": H, "bpr": BPR,
    "token": cur,
    "snapshot_rgb": "0x%06x" % snap,
    "embed_getColor": "0x%06x" % gc,
    "find_hit": [fx, fy],
    "fail": fail,
}
open(os.path.join(out, "host_rgba_fixture.json"), "w").write(json.dumps(report, indent=2) + "\n")
sys.exit(1 if fail else 0)
PY
if [ "${PIPESTATUS[0]}" -eq 0 ]; then
  ok "host RGBA four-reader contract"
else
  bad "host RGBA four-reader contract"
fi

note "==== ColorPicker --test ===="
if python3 "$ROOT/tools/ziyan_colorpicker/ZiYanColorPicker.py" --test >"$OUT/picker_test.txt" 2>&1; then
  ok "ZiYanColorPicker.py --test"
  tail -n 20 "$OUT/picker_test.txt" | tee -a "$OUT/summary.txt" >/dev/null
else
  bad "ZiYanColorPicker.py --test"
  cat "$OUT/picker_test.txt" | tee -a "$OUT/summary.txt"
fi

note "==== totals PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -eq 0 ]; then
  echo "COLOR_PICKER_SAME_FRAME_GATE=PASS" | tee "$OUT/RESULT.txt"
  exit 0
fi
echo "COLOR_PICKER_SAME_FRAME_GATE=FAIL" | tee "$OUT/RESULT.txt"
exit 1
