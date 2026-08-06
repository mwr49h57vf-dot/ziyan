#!/usr/bin/env bash
# Phase1-R · 抓色器 ↔ 业务找色/分支门禁 · 8-161-115
# 硬项：formats≡Desktop；本机色串 ok⇒in_orig；/biztest 分支；禁假命中出 ROI
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/P1R_PICKER_BIZ_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
PASS=0; FAIL=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { PASS=$((PASS+1)); note "PASS $*"; }
bad() { FAIL=$((FAIL+1)); note "FAIL $*"; }

ssh_r() {
  local host=$1; shift
  local n=0
  until sshpass -p alpine ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o ConnectTimeout=12 "root@$host" "$@"; do
    n=$((n+1)); [ "$n" -ge 3 ] && return 1; sleep 1
  done
}

hard_idle() {
  local host=$1 VAR=$2
  ssh_r "$host" "touch $VAR/.ziyan_user_stopped; printf 'ts=1\n' > $VAR/.ziyan_kill_scripts; chmod 666 $VAR/.ziyan_user_stopped $VAR/.ziyan_kill_scripts 2>/dev/null; sleep 2; rm -f $VAR/.ziyan_embed_go $VAR/.ziyan_embed_on $VAR/.ziyan_embed_script $VAR/.ziyan_embed_alive $VAR/.ziyan_lua_embedded $VAR/.ziyan_script_session $VAR/.ziyan_project_active $VAR/.ziyan_find_pulse $VAR/.ziyan_te_running $VAR/.ziyan_kill_scripts; printf 'state=idle\npath=\norient=-1\ngen=0\n' > $VAR/.ziyan_session; printf 'stop=1\n' > $VAR/.ziyan_run_intent; chmod 666 $VAR/.ziyan_session $VAR/.ziyan_run_intent; rm -f $VAR/.ziyan_user_stopped" || true
}

ensure_frame() {
  local host=$1
  if ! curl -sS -m 6 "http://$host:50005/status" >/dev/null 2>&1; then
    if [ "$host" = "192.168.31.53" ]; then
      ssh_r "$host" "launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || true" || true
    else
      ssh_r "$host" "launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || (launchctl unload /Library/LaunchDaemons/com.ziyan.framecap.plist 2>/dev/null; launchctl load /Library/LaunchDaemons/com.ziyan.framecap.plist 2>/dev/null); true" || true
    fi
    sleep 3
  fi
  curl -sS -m 12 -o /dev/null "http://$host:50005/snapshot?orient=1" 2>/dev/null || true
  sleep 1
}

jflag() {
  # stdin JSON → 1/0 for key true|1
  python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
v=d.get(sys.argv[1])
print("1" if v is True or v==1 else "0")' "$1" 2>/dev/null || echo 0
}

note "==== host formats ↔ Desktop ===="
if python3 - <<'PY' | tee "$OUT/formats_roundtrip.txt"
import importlib.util, sys, re
p = "/Users/mac/Desktop/ZiYan_副本/tools/ziyan_colorpicker/formats.py"
spec = importlib.util.spec_from_file_location("formats", p)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fail = 0
for path, tag in [("/Users/mac/Desktop/ios8p.lua","ios8p"),("/Users/mac/Desktop/ios7.lua","ios7")]:
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        if "findMultiColorInRegionFuzzy" not in line: continue
        mm = re.search(r'findMultiColorInRegionFuzzy\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)', line)
        if not mm: print("FAIL parse", tag, i); fail += 1; continue
        main, offs = mm.group(1).lower(), mm.group(2)
        deg, ax, ay, sx, sy = map(int, mm.groups()[2:])
        pts = [{"x":0,"y":0,"c":int(main,16)}]
        if offs:
            for part in offs.split(","):
                dx,dy,col=part.split("|"); pts.append({"x":int(dx),"y":int(dy),"c":int(col,16)})
        fmc = m.make_fmc(pts); expect = '%s, "%s"' % (main, offs)
        if fmc.lower()!=expect.lower(): print("FAIL fmc",tag,i); fail+=1
        else: print("PASS fmc",tag,"L"+str(i))
        gen = m.make_find_multi_color_in_region_fuzzy(pts,ax,ay,sx,sy,degree=deg)
        need = "%d, %d, %d, %d, %d)" % (deg,ax,ay,sx,sy)
        if need not in gen: print("FAIL gen",tag,i); fail+=1
        else: print("PASS gen",tag,"L"+str(i))
sys.exit(1 if fail else 0)
PY
then ok "host formats Desktop"; else bad "host formats Desktop"; fi

# findtest 一次：ok⇒in_orig；empty 重试
run_find() {
  local host=$1 tag=$2 name=$3 main=$4 offs=$5 x1=$6 y1=$7 x2=$8 y2=$9
  local ft="" n
  for n in 1 2 3 4; do
    ensure_frame "$host"
    ft=$(curl -sS -m 18 -X POST "http://$host:50005/findtest" \
      --data-urlencode "main=$main" --data-urlencode "offs=$offs" \
      --data "degree=90&x1=$x1&y1=$y1&x2=$x2&y2=$y2&toast=0&orient=1" 2>/dev/null || echo '{}')
    echo "$ft" >"$OUT/${tag}_${name}_t${n}.json"
    echo "$ft" | grep -q empty_shm || break
    sleep 1
  done
  echo "$ft" >"$OUT/${tag}_${name}.json"
  if echo "$ft" | grep -q empty_shm; then
    bad "$tag $name empty_shm"; return 1
  fi
  if [ "$(echo "$ft" | jflag ok)" = "1" ]; then
    [ "$(echo "$ft" | jflag in_orig_roi)" = "1" ] && ok "$tag $name ok⇒in_orig" || { bad "$tag $name not in_orig"; return 1; }
    local x; x=$(echo "$ft" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("x",-1))' 2>/dev/null || echo -1)
    if [ "$x" -ge "$x1" ] 2>/dev/null && [ "$x" -le "$x2" ] 2>/dev/null; then
      ok "$tag $name x in ROI ($x)"
    else
      bad "$tag $name x=$x out"; return 1
    fi
  else
    ok "$tag $name miss-ok"
  fi
  return 0
}

run_biz() {
  local host=$1 tag=$2 sc=$3
  local bz="" n
  for n in 1 2 3 4; do
    ensure_frame "$host"
    bz=$(curl -sS -m 35 -X POST "http://$host:50005/biztest" --data "script=$sc&orient=1" 2>/dev/null || echo '{}')
    echo "$bz" >"$OUT/${tag}_biz_${sc}_t${n}.json"
    echo "$bz" | grep -qE '"branch":"(tap|login|searching)"' && break
    sleep 2
  done
  echo "$bz" >"$OUT/${tag}_biz_${sc}.json"
  if [ "$(echo "$bz" | jflag ok)" = "1" ]; then ok "$tag biz $sc ok"; else bad "$tag biz $sc ($bz)"; fi
  echo "$bz" | grep -qE '"branch":"(tap|login|searching)"' && ok "$tag biz $sc branch" || bad "$tag biz $sc no branch"
  python3 - <<PY
import json,sys
d=json.load(open("$OUT/${tag}_biz_${sc}.json"))
for k in ("find1","find2"):
    f=d.get(k) or {}
    if f.get("ok") in (True,1) and f.get("in_orig_roi") not in (True,1):
        print("FAIL",k); sys.exit(2)
print("logic", d.get("branch"), d.get("toast_would"))
PY
  [ $? -eq 0 ] && ok "$tag biz $sc safety" || bad "$tag biz $sc safety"
}

check_8p() {
  local host=192.168.31.53 tag=53 VAR=/var/jb/usr/lib/ziyan/var
  note "==== .53 ios8p ===="
  local ver; ver=$(ssh_r "$host" "dpkg -l com.ziyan.ziyan 2>/dev/null | tail -1" || true)
  echo "$ver" | grep -q '8-161-115' && ok "53 ver 115" || bad "53 ver"
  hard_idle "$host" "$VAR"; sleep 2
  # 先 biz（内部连跑两次 findtest+CARender 暖帧），再单点 find（禁冷闲 empty_shm 假失败）
  ensure_frame "$host"; sleep 1; ensure_frame "$host"
  run_biz "$host" "$tag" ios8p
  run_find "$host" "$tag" f1 0xfdffed "-3|3|0xf3f3ca,-1|4|0xfffff7,2|8|0x410703" 2010 279 2015 287 || true
  run_find "$host" "$tag" f2 0xc6a264 "2|4|0xc6a264,2|7|0xc6a264,2|10|0xc6a264" 757 788 759 798 || true
  hard_idle "$host" "$VAR"
}

check_7s() {
  local host=$1 tag=$2
  local VAR=/usr/lib/ziyan/var
  note "==== .$tag ios7 ===="
  local ver; ver=$(ssh_r "$host" "dpkg -l com.ziyan.ziyan 2>/dev/null | tail -1" || true)
  echo "$ver" | grep -q '8-161-115' && ok "$tag ver 115" || bad "$tag ver"
  hard_idle "$host" "$VAR"; sleep 2
  ensure_frame "$host"; sleep 1; ensure_frame "$host"
  run_biz "$host" "$tag" ios7
  run_find "$host" "$tag" f1 0xc68c1a "1|1|0xc48d12,2|1|0xd29829,2|4|0x7b492c" 1008 306 1010 310 || true
  run_find "$host" "$tag" f2 0xc19b67 "1|2|0xb68b50,1|4|0xd3b281,0|5|0xd8b788" 706 449 707 454 || true
  hard_idle "$host" "$VAR"
}

check_8p
check_7s 192.168.31.101 101
check_7s 192.168.31.112 112
check_7s 192.168.31.166 166

note "==== TOTAL pass=$PASS fail=$FAIL out=$OUT ===="
[ "$FAIL" -eq 0 ]
