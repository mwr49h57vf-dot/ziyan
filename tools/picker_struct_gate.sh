#!/usr/bin/env bash
# 抓色器 v1.3.4 生成结构 ↔ Lua ts_to_points ↔ /findtest FlatPointsJSON
# 硬项：Desktop 色串 roundtrip；四机 PNG 采点→make_fmc→findtest 命中≤3px
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/tmp_shots/PICKER_STRUCT_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"
PASS=0; FAIL=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { PASS=$((PASS+1)); note "PASS $*"; }
bad() { FAIL=$((FAIL+1)); note "FAIL $*"; }

note "==== offline structure (ColorPicker.py ≡ formats ≡ Desktop) ===="
if python3 "$ROOT/tools/ziyan_colorpicker/ZiYanColorPicker.py" --test >/dev/null; then
  ok "ColorPicker --test 1.3.4"
else
  bad "ColorPicker --test"
fi

if python3 - <<PY | tee "$OUT/struct_offline.txt"
import importlib.util, re, sys
ROOT = r"$ROOT"
spec = importlib.util.spec_from_file_location("cp", ROOT + "/tools/ziyan_colorpicker/ZiYanColorPicker.py")
cp = importlib.util.module_from_spec(spec); spec.loader.exec_module(cp)
spec2 = importlib.util.spec_from_file_location("fmt", ROOT + "/tools/ziyan_colorpicker/formats.py")
fmt = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(fmt)

def parse_color_token(tok):
    if isinstance(tok, int):
        return tok % 0x1000000, 0
    s = str(tok).replace(" ", "")
    bias = 0
    dash = s.find("-", 1)
    if dash >= 0:
        bs = s[dash + 1 :]; s = s[:dash]
        if bs.lower().startswith("0x"):
            bias = int(bs, 16)
        elif all(c in "0123456789abcdefABCDEF" for c in bs):
            bias = int(bs, 16)
        else:
            bias = int(bs)
    if re.match(r"^[0-9]+$", s):
        c = int(s)
    elif s.lower().startswith("0x"):
        c = int(s, 16)
    elif all(c in "0123456789abcdefABCDEF" for c in s):
        c = int(s, 16)
    else:
        c = int(s)
    return c % 0x1000000, bias % 0x1000000

def ts_to_points(main, offs):
    c0, b0 = parse_color_token(main)
    pts = [{"c": c0, "dx": 0, "dy": 0, "b": b0}]
    if offs:
        for part in offs.split(","):
            dx, dy, col = part.split("|")
            c, b = parse_color_token(col)
            pts.append({"c": c, "dx": int(dx), "dy": int(dy), "b": b})
    return pts

def flat_json(main, offs):
    m = parse_color_token(main)[0]
    arr = [m]
    if offs:
        for part in offs.split(","):
            dx, dy, cs = part.split("|")
            arr += [int(dx), int(dy), parse_color_token(cs)[0]]
    return arr

fail = 0
assert cp.APP_VER == "1.3.4"
print("PASS APP_VER", cp.APP_VER)
for path, tag in [("/Users/mac/Desktop/ios7.lua", "ios7"), ("/Users/mac/Desktop/ios8p.lua", "ios8p")]:
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        if "findMultiColorInRegionFuzzy" not in line:
            continue
        mm = re.search(
            r'findMultiColorInRegionFuzzy\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
            line,
        )
        main, offs = mm.group(1), mm.group(2)
        deg, ax, ay, sx, sy = map(int, mm.groups()[2:])
        pts = [{"x": 0, "y": 0, "c": int(main, 16)}]
        if offs:
            for part in offs.split(","):
                dx, dy, col = part.split("|")
                pts.append({"x": int(dx), "y": int(dy), "c": int(col, 16)})
        a = cp.make_fmc(pts).lower()
        b = fmt.make_fmc(pts).lower()
        e = ('%s, "%s"' % (main.lower(), offs)).lower()
        if a != e or b != e:
            print("FAIL fmc", tag, i); fail += 1
        else:
            print("PASS fmc", tag, "L" + str(i))
        lua = ts_to_points(main, offs)
        flat = flat_json(main, offs)
        if flat[0] != lua[0]["c"] or (offs and flat[1:4] != [lua[1]["dx"], lua[1]["dy"], lua[1]["c"]]):
            print("FAIL flat↔lua", tag, i); fail += 1
        else:
            print("PASS flat↔lua", tag, "L" + str(i))
        line_cp = cp.make_find_line(pts, ax, ay, sx, sy, deg, False)
        need = "%d, %d, %d, %d, %d)" % (deg, ax, ay, sx, sy)
        if need not in line_cp:
            print("FAIL arg_order", tag, i); fail += 1
        else:
            print("PASS arg_order", tag, "L" + str(i), need)
print("TOTAL_FAIL", fail)
sys.exit(1 if fail else 0)
PY
then ok "offline Desktop/Lua/FlatPoints"; else bad "offline Desktop/Lua/FlatPoints"; fi

note "==== device PNG→make_fmc→/findtest (≤3px) ===="
if python3 - <<PY | tee "$OUT/device_roundtrip.txt"
import http.client, json, urllib.parse, time, sys
from PIL import Image
from importlib.util import spec_from_file_location, module_from_spec
ROOT = r"$ROOT"
spec = spec_from_file_location("cp", ROOT + "/tools/ziyan_colorpicker/ZiYanColorPicker.py")
cp = module_from_spec(spec); spec.loader.exec_module(cp)

def post_find(ip, main, offs, deg, x1, y1, x2, y2, retries=4):
    body = urllib.parse.urlencode({
        "main": "0x%06x" % (main & 0xffffff),
        "offs": offs, "degree": deg,
        "x1": x1, "y1": y1, "x2": x2, "y2": y2,
        "orient": 1, "toast": 0,
    })
    last = None
    for _ in range(retries):
        try:
            conn = http.client.HTTPConnection(ip, 50005, timeout=20)
            conn.request("POST", "/findtest", body=body.encode(), headers={
                "Content-Type": "application/x-www-form-urlencoded", "Connection": "close"})
            r = conn.getresponse(); raw = r.read(); conn.close()
            return json.loads(raw.decode("utf-8", "replace"))
        except Exception as e:
            last = e; time.sleep(1.0)
    raise last

def snap(ip, retries=4):
    last = None
    for _ in range(retries):
        try:
            conn = http.client.HTTPConnection(ip, 50005, timeout=15)
            conn.request("GET", "/snapshot?orient=1", headers={"Connection": "close"})
            r = conn.getresponse(); raw = r.read(); conn.close()
            if r.status != 200:
                raise RuntimeError("HTTP %s len=%d" % (r.status, len(raw)))
            open("/tmp/picker_gate_%s.png" % ip, "wb").write(raw)
            return Image.open("/tmp/picker_gate_%s.png" % ip).convert("RGB")
        except Exception as e:
            last = e; time.sleep(1.0)
    raise last

def rgb_c(im, x, y):
    r, g, b = im.getpixel((x, y))
    return (r << 16) | (g << 8) | b

fail = 0
for ip in ["192.168.31.53", "192.168.31.101", "192.168.31.112", "192.168.31.166"]:
    print("====", ip, flush=True)
    try:
        im = snap(ip)
    except Exception as e:
        print("SNAP_FAIL", e); fail += 1; continue
    found = None
    for y in range(im.height // 4, im.height * 3 // 4, 17):
        for x in range(im.width // 4, im.width * 3 // 4, 23):
            c = rgb_c(im, x, y)
            if (c >> 16) & 0xff > 30 or (c >> 8) & 0xff > 30 or c & 0xff > 30:
                pts = [{"x": x + dx, "y": y + dy, "c": rgb_c(im, x + dx, y + dy)}
                       for dx, dy in [(0, 0), (1, 0), (0, 1), (2, 2)]]
                if all(0 <= p["x"] < im.width and 0 <= p["y"] < im.height for p in pts):
                    found = pts; break
        if found:
            break
    if not found:
        print("NO_COLOR"); fail += 1; continue
    main, offs = cp.make_fmc_offs(found)
    ax, ay, sx, sy = cp.roi_bbox(found)
    try:
        rep = post_find(ip, main, offs, 90, ax, ay, sx, sy)
    except Exception as e:
        print("FIND_FAIL", e); fail += 1; continue
    ok = bool(rep.get("ok")) and int(rep.get("x", -1)) >= 0
    hx, hy = int(rep.get("x", -1)), int(rep.get("y", -1))
    dist = abs(hx - found[0]["x"]) + abs(hy - found[0]["y"]) if ok else 999
    good = ok and bool(rep.get("in_orig_roi")) and dist <= 3
    print("multi good=%s hit=(%d,%d) expect=(%d,%d) dist=%d via=%s" % (
        good, hx, hy, found[0]["x"], found[0]["y"], dist, rep.get("via")))
    if not good:
        print(rep); fail += 1
print("TOTAL_FAIL", fail)
sys.exit(1 if fail else 0)
PY
then ok "device PNG→findtest 4phone"; else bad "device PNG→findtest 4phone"; fi

note "==== RESULT PASS=$PASS FAIL=$FAIL OUT=$OUT ===="
[ "$FAIL" -eq 0 ]
