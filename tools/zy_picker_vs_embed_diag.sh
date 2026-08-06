#!/usr/bin/env bash
# 抓色器对照排查（禁改 Desktop 色参；禁用触动色参）
# 对照链：ColorPicker/formats roundtrip ↔ HTTP /findtest+/biztest ↔ 机上 IPC findMulti
# 用法：bash tools/zy_picker_vs_embed_diag.sh [all|53|101|112|166]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/PICKER_VS_EMBED_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { note "PASS $*"; }
bad() { note "FAIL $*"; }

# Desktop 色参（只读，与抓色器 SAME 审计一致）
# ios8p
P8_F1_MAIN=0xfdffed
P8_F1_OFFS='-3|3|0xf3f3ca,-1|4|0xfffff7,2|8|0x410703'
P8_F1_ROI=(2010 279 2015 287)
P8_F2_MAIN=0xc6a264
P8_F2_OFFS='2|4|0xc6a264,2|7|0xc6a264,2|10|0xc6a264'
P8_F2_ROI=(757 788 759 798)
# ios7
P7_F1_MAIN=0xc68c1a
P7_F1_OFFS='1|1|0xc48d12,2|1|0xd29829,2|4|0x7b492c'
P7_F1_ROI=(1008 306 1010 310)
P7_F2_MAIN=0xc19b67
P7_F2_OFFS='1|2|0xb68b50,1|4|0xd3b281,0|5|0xd8b788'
P7_F2_ROI=(706 449 707 454)

ensure_http() {
  local ip="$1" scheme="$2" n
  for n in 1 2 3 4 5; do
    if curl -sS -m 4 "http://$ip:50005/status" >/dev/null 2>&1; then return 0; fi
    if [ "$scheme" = rootless ]; then
      ssh_r "$ip" 'killall -9 ziyan_framecap 2>/dev/null; sleep 1; nohup /var/jb/usr/lib/ziyan/bin/ziyan_framecap serve >/dev/null 2>&1 &' || true
    else
      ssh_r "$ip" 'launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || (killall -9 ziyan_framecap 2>/dev/null; sleep 1; nohup /usr/lib/ziyan/bin/ziyan_framecap serve >/dev/null 2>&1 &)' || true
    fi
    sleep 2
  done
  curl -sS -m 5 "http://$ip:50005/status" >/dev/null 2>&1
}

open_game() {
  local ip="$1" scheme="$2" bid="$3" VAR
  if [ "$scheme" = rootless ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
  ssh_r "$ip" "VAR=$VAR BID=$bid bash -s" <<'EOS'
set +e
for i in 1 2 3 4 5 6 7 8; do
  printf '%s\n' "$BID" >"$VAR/.ziyan_open_app"
  chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
  sleep 0.9
  F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "$F" | grep -q "$BID" && { rm -f "$VAR/.ziyan_open_app"; echo OPEN_OK; exit 0; }
done
rm -f "$VAR/.ziyan_open_app"
echo OPEN_FAIL front=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
EOS
}

force_snap() {
  local ip="$1"
  curl -sS -m 15 -o "$OUT/snap_${ip##*.}.png" "http://$ip:50005/snapshot?orient=1" >/dev/null 2>&1 || true
  sleep 0.8
}

findtest_one() {
  local ip="$1" name="$2" main="$3" offs="$4" x1="$5" y1="$6" x2="$7" y2="$8"
  local ft n
  for n in 1 2 3; do
    force_snap "$ip"
    ft=$(curl -sS -m 20 -X POST "http://$ip:50005/findtest" \
      --data-urlencode "main=$main" --data-urlencode "offs=$offs" \
      --data "degree=90&x1=$x1&y1=$y1&x2=$x2&y2=$y2&toast=0&orient=1" 2>/dev/null || echo '{}')
    echo "$ft" | grep -q empty_shm || break
    sleep 1
  done
  echo "$ft" >"$OUT/${ip##*.}_${name}_findtest.json"
  echo "$ft"
}

# IPC find：Mac 侧编 points，经 base64 传机，避免 | 被 shell 拆
ipc_find() {
  local ip="$1" scheme="$2" name="$3" main="$4" offs="$5" x1="$6" y1="$7" x2="$8" y2="$9"
  local pts ptsb64
  pts=$(python3 -c 'import json,sys
main=int(sys.argv[1],16); offs=sys.argv[2]
pts=[{"c":main,"dx":0,"dy":0,"b":25}]
if offs:
  for part in offs.split(","):
    dx,dy,col=part.split("|")
    pts.append({"c":int(col,16),"dx":int(dx),"dy":int(dy),"b":25})
print(json.dumps(pts,separators=(",",":")))' "$main" "$offs")
  ptsb64=$(printf '%s' "$pts" | base64 | tr -d '\n')
  ssh_r "$ip" "SCHEME=$scheme NAME=$name PTSB64=$ptsb64 X1=$x1 Y1=$y1 X2=$x2 Y2=$y2 bash -s" <<'EOS'
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var; BIN=/var/jb/usr/lib/ziyan/bin
else
  VAR=/usr/lib/ziyan/var; BIN=/usr/lib/ziyan/bin
fi
PTS=$(printf '%s' "$PTSB64" | base64 -d 2>/dev/null || printf '%s' "$PTSB64" | base64 -D 2>/dev/null)
echo 1 >"$VAR/.ziyan_force_recap"
echo "nonce=pve_${NAME}_$$" >"$VAR/.ziyan_frame_req"
"$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
sleep 1.0
rm -f "$VAR/.ziyan_color_rep"
printf 'findMulti\n%s\n90\n%s\n%s\n%s\n%s\n%s\n' "$PTS" "$X1" "$Y1" "$X2" "$Y2" "$NAME" \
  >"$VAR/.ziyan_color_req"
for i in $(seq 1 50); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
tr '\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null
echo
echo FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo SHM=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
CX=$(( (X1+X2)/2 )); CY=$(( (Y1+Y2)/2 ))
rm -f "$VAR/.ziyan_color_rep"
printf 'getColor\n%s\n%s\ngc\n' "$CX" "$CY" >"$VAR/.ziyan_color_req"
for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
echo GC_${CX}_${CY}=$(tr '\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null)
EOS
}

biztest_one() {
  local ip="$1" sc="$2"
  local bz n
  for n in 1 2 3; do
    force_snap "$ip"
    bz=$(curl -sS -m 35 -X POST "http://$ip:50005/biztest" --data "script=$sc&orient=1" 2>/dev/null || echo '{}')
    echo "$bz" | grep -qE '"branch":"' && break
    sleep 1
  done
  echo "$bz" >"$OUT/${ip##*.}_biz_${sc}.json"
  echo "$bz"
}

cmp_phone() {
  local tag="$1" ip="$2" scheme="$3" bid="$4" script="$5"
  local main1 offs1 r1 main2 offs2 r2 sc
  note "======== .$tag $script bid=$bid ========"
  if ! ensure_http "$ip" "$scheme"; then
    bad "$tag http:50005 unreachable"; return 1
  fi
  local st; st=$(curl -sS -m 5 "http://$ip:50005/status" 2>/dev/null || echo '{}')
  echo "$st" >"$OUT/${tag}_status.txt"
  note "STATUS .$tag $(echo "$st" | tr '\n' ' ' | head -c 220)"

  open_game "$ip" "$scheme" "$bid" | tee -a "$OUT/${tag}_open.txt" | tail -1

  if [ "$script" = ios8p ]; then
    sc=ios8p
    main1=$P8_F1_MAIN; offs1=$P8_F1_OFFS; r1=("${P8_F1_ROI[@]}")
    main2=$P8_F2_MAIN; offs2=$P8_F2_OFFS; r2=("${P8_F2_ROI[@]}")
  else
    sc=ios7
    main1=$P7_F1_MAIN; offs1=$P7_F1_OFFS; r1=("${P7_F1_ROI[@]}")
    main2=$P7_F2_MAIN; offs2=$P7_F2_OFFS; r2=("${P7_F2_ROI[@]}")
  fi

  note "---- .$tag /biztest $sc ----"
  local bz; bz=$(biztest_one "$ip" "$sc")
  note "BIZTEST .$tag $(echo "$bz" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin)
 print("branch=",d.get("branch"),"toast_would=",d.get("toast_would"),"f1=",(d.get("find1") or {}).get("ok"),"f2=",(d.get("find2") or {}).get("ok"))
except Exception as e:
 print("parse_err",e,sys.stdin.read()[:120] if False else "")
' 2>/dev/null || echo "$bz" | head -c 200)"

  run_pair() {
    local name="$1" main="$2" offs="$3" x1="$4" y1="$5" x2="$6" y2="$7"
    note "---- .$tag $name findtest vs IPC ----"
    local ft; ft=$(findtest_one "$ip" "$name" "$main" "$offs" "$x1" "$y1" "$x2" "$y2")
    local ft_ok; ft_ok=$(echo "$ft" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin); print("1" if d.get("ok") in (True,1) else "0")
except: print("0")' 2>/dev/null || echo 0)
    note "FINDTEST .$tag $name ok=$ft_ok raw=$(echo "$ft" | tr '\n' ' ' | head -c 240)"

    local ipc; ipc=$(ipc_find "$ip" "$scheme" "$name" "$main" "$offs" "$x1" "$y1" "$x2" "$y2")
    echo "$ipc" >"$OUT/${tag}_${name}_ipc.txt"
    local ipc_ok=0
    echo "$ipc" | grep -qE '"ok":true' && ipc_ok=1
    note "IPC .$tag $name ok=$ipc_ok $(echo "$ipc" | tr '\n' ' ' | head -c 280)"

    if [ "$ft_ok" = "$ipc_ok" ]; then
      ok "$tag $name findtest≡IPC (both=$ft_ok)"
    else
      bad "$tag $name findtest=$ft_ok IPC=$ipc_ok DIVERGE"
    fi
  }
  run_pair f1 "$main1" "$offs1" "${r1[0]}" "${r1[1]}" "${r1[2]}" "${r1[3]}"
  run_pair f2 "$main2" "$offs2" "${r2[0]}" "${r2[1]}" "${r2[2]}" "${r2[3]}"
}

note "OUT=$OUT"
note "==== offline: ColorPicker --test + formats≡Desktop ===="
if python3 "$ROOT/tools/ziyan_colorpicker/ZiYanColorPicker.py" --test >/dev/null 2>"$OUT/cp_test.err"; then
  ok "ColorPicker --test 1.3.4"
else
  bad "ColorPicker --test"; cat "$OUT/cp_test.err" | tee -a "$OUT/summary.txt" || true
fi

python3 - <<PY | tee "$OUT/formats_desktop.txt"
import importlib.util, re, sys
ROOT = r"$ROOT"
spec = importlib.util.spec_from_file_location("fmt", ROOT + "/tools/ziyan_colorpicker/formats.py")
fmt = importlib.util.module_from_spec(spec); spec.loader.exec_module(fmt)
fail = 0
for path, tag in [("/Users/mac/Desktop/ios7.lua","ios7"),("/Users/mac/Desktop/ios8p.lua","ios8p")]:
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        if "findMultiColorInRegionFuzzy" not in line: continue
        mm = re.search(
            r'findMultiColorInRegionFuzzy\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
            line)
        if not mm:
            print("FAIL parse", tag, i); fail += 1; continue
        main, offs = mm.group(1).lower(), mm.group(2)
        deg, ax, ay, sx, sy = map(int, mm.groups()[2:])
        pts = [{"x":0,"y":0,"c":int(main,16)}]
        if offs:
            for part in offs.split(","):
                dx,dy,col = part.split("|")
                pts.append({"x":int(dx),"y":int(dy),"c":int(col,16)})
        fmc = fmt.make_fmc(pts)
        expect = '%s, "%s"' % (main, offs)
        same = fmc.lower() == expect.lower()
        print(("PASS" if same else "FAIL"), "fmc", tag, "L"+str(i), "SAME="+str(same))
        if not same: fail += 1
sys.exit(1 if fail else 0)
PY
if [ $? -eq 0 ]; then ok "formats≡Desktop"; else bad "formats≡Desktop"; fi

case "$WANT" in
  all)
    cmp_phone 53 192.168.31.53 rootless com.ljzbbadao.game ios8p || true
    cmp_phone 101 192.168.31.101 rootful com.xztl.ios ios7 || true
    cmp_phone 112 192.168.31.112 rootful com.xztl.ios ios7 || true
    cmp_phone 166 192.168.31.166 rootful com.xztl.ios ios7 || true
    ;;
  53) cmp_phone 53 192.168.31.53 rootless com.ljzbbadao.game ios8p ;;
  101) cmp_phone 101 192.168.31.101 rootful com.xztl.ios ios7 ;;
  112) cmp_phone 112 192.168.31.112 rootful com.xztl.ios ios7 ;;
  166) cmp_phone 166 192.168.31.166 rootful com.xztl.ios ios7 ;;
  *) echo "bad $WANT"; exit 2 ;;
esac

{
  echo "# PICKER vs EMBED 对照 VERDICT"
  echo
  echo "- 色参来源：Desktop ≡ 子砚抓色器 formats（未改色参、未用触动色参）"
  echo "- 对照：HTTP /findtest+/biztest（抓色器同核）↔ IPC findMulti（业务 embed 同核）"
  echo
  grep -E 'PASS |FAIL |BIZTEST|FINDTEST|IPC |STATUS|DIVERGE|========' "$OUT/summary.txt" || true
  echo
  if grep -q 'FAIL .* DIVERGE' "$OUT/summary.txt"; then
    echo "## OVERALL=FAIL (findtest≠IPC 同核分歧)"
  elif grep -q '^FAIL ' "$OUT/summary.txt"; then
    echo "## OVERALL=FAIL (见上)"
  else
    # 两边都 miss 也算「一致」；业务能否点中另看自测
    echo "## OVERALL=AGREE (findtest≡IPC；命中与否见 biztest/自测)"
  fi
} | tee "$OUT/VERDICT.md"
cp -f "$OUT/VERDICT.md" "$ROOT/tmp_shots/PICKER_VS_EMBED_VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
