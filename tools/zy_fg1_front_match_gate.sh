#!/usr/bin/env bash
# 刀 FG1：找色总在前台；取色是什么就找什么色
# 对 Desktop 每条活跃 find：切到对应前台 → shm 对齐 → getColor+findMulti
# 约定（ios7/ios8p）：chain0=色点A→SpringBoard；chain1+=色点B→游戏 BID
# 禁止用另一前台命中冒充本条；无主副色等级
# 用法: bash tools/zy_fg1_front_match_gate.sh [53|166|all]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/FG1_GATE_${STAMP}"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

[[ -f "$DESKTOP_IOS7" && -f "$DESKTOP_IOS8P" ]] || { echo "FATAL missing Desktop"; exit 2; }
echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "WANT=$WANT" | tee -a "$OUT/OUT_PATH.txt"

parse_chains() {
  python3 - "$1" "$2" <<'PY'
import re, json, sys
src=open(sys.argv[1]).read()
chains=[]
for i,line in enumerate(src.splitlines(),1):
    if "findMultiColor" not in line or line.strip().startswith("--"): continue
    m=re.search(
        r'findMultiColorInRegionFuzzy\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
        line)
    if not m: continue
    first=int(m.group(1),16)
    pts=[{"c":first,"dx":0,"dy":0,"b":0}]
    for part in (m.group(2) or "").split(","):
        if not part.strip(): continue
        dx,dy,col=part.split("|")
        c=int(col,16) if col.startswith("0x") else int(col)
        pts.append({"c":c,"dx":int(dx),"dy":int(dy),"b":0})
    chains.append(dict(line=i,deg=int(m.group(3)),
        x1=int(m.group(4)),y1=int(m.group(5)),
        x2=int(m.group(6)),y2=int(m.group(7)),pts=pts,first=first))
json.dump(chains, open(sys.argv[2],"w"), indent=2)
print(len(chains))
PY
}

# Remote helpers as one-shot snippets
remote_prep() {
  local ip="$1" scheme="$2"
  ssh_r "$ip" "SCHEME=$scheme bash -s" <<'R'
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
mkdir -p "$V"
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
rm -f "$V/.ziyan_keep_daemon" "$V/.ziyan_session_keep" "$V/.ziyan_active" "$V/.ziyan_open_app"
launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || launchctl kickstart -k com.ziyan.framecap 2>/dev/null || true
sleep 1
echo VER=$(dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\([^ ]*\).*/\1/p')
echo PREP_OK
R
}

remote_go_home() {
  local ip="$1" scheme="$2"
  ssh_r "$ip" "SCHEME=$scheme bash -s" <<'R'
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo 1 >"$V/.ziyan_go_home"; chmod 666 "$V/.ziyan_go_home" 2>/dev/null
  sleep 0.9; rm -f "$V/.ziyan_go_home"
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "HOME try$i FRONT=$F"
  echo "$F" | grep -qi springboard && exit 0
done
exit 1
R
}

remote_open_bid() {
  local ip="$1" scheme="$2" bid="$3"
  ssh_r "$ip" "SCHEME=$scheme BID=$bid bash -s" <<'R'
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf '%s\n' "$BID" >"$V/.ziyan_open_app"; chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  sleep 1
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "OPEN try$i FRONT=$F"
  echo "$F" | grep -q "$BID" && { rm -f "$V/.ziyan_open_app"; exit 0; }
done
rm -f "$V/.ziyan_open_app"; exit 1
R
}

remote_align() {
  local ip="$1" scheme="$2" mode="$3" bid="$4"
  ssh_r "$ip" "SCHEME=$scheme MODE=$mode BID=$bid bash -s" <<'R'
set +e
if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
for t in $(seq 1 35); do
  echo 1 >"$V/.ziyan_force_recap"; chmod 666 "$V/.ziyan_force_recap" 2>/dev/null
  echo "nonce=fg1_$MODE_$t" >"$V/.ziyan_frame_req"; chmod 666 "$V/.ziyan_frame_req"
  sleep 1
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  S=$(tr -d '\r\n' <"$V/.ziyan_shm_front_bid" 2>/dev/null)
  echo "align t=$t FRONT=$F SHM=$S"
  if [ "$MODE" = home ]; then
    echo "$F" | grep -qi springboard || { echo 1 >"$V/.ziyan_go_home"; sleep 0.7; rm -f "$V/.ziyan_go_home"; continue; }
    echo "$S" | grep -qi springboard && exit 0
  else
    echo "$F" | grep -q "$BID" || continue
    echo "$S" | grep -q "$BID" && exit 0
  fi
done
exit 1
R
}

remote_find_chain() {
  local ip="$1" scheme="$2" x1="$3" y1="$4" x2="$5" y2="$6" deg="$7" pts="$8" tag="$9"
  ssh_r "$ip" "SCHEME=$scheme X1=$x1 Y1=$y1 X2=$x2 Y2=$y2 DEG=$deg TAG=$tag bash -s" <<R
set +e
if [ "\$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
F=\$(tr -d '\\r\\n' <"\$V/.ziyan_front_bid" 2>/dev/null)
S=\$(tr -d '\\r\\n' <"\$V/.ziyan_shm_front_bid" 2>/dev/null)
echo FRONT=\$F SHM=\$S
rm -f "\$V/.ziyan_color_rep"
printf 'getColor\\n%s\\n%s\\ngc\\n' "\$X1" "\$Y1" >"\$V/.ziyan_color_req"
for i in \$(seq 1 60); do [ -f "\$V/.ziyan_color_rep" ] && break; sleep 0.05; done
echo GC=\$(tr '\\n' '|' <"\$V/.ziyan_color_rep")
rm -f "\$V/.ziyan_color_rep"
printf '%s\\n' findMulti '$pts' "\$DEG" "\$X1" "\$Y1" "\$X2" "\$Y2" "fm\$TAG" >"\$V/.ziyan_color_req"
for i in \$(seq 1 80); do [ -f "\$V/.ziyan_color_rep" ] && break; sleep 0.05; done
echo FIND=\$(tr '\\n' '|' <"\$V/.ziyan_color_rep")
R
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" script_local="$4" script_name="$5" bid="$6"
  local chains_json="$OUT/chains_${tag}.json"
  local gate="$OUT/gate_${tag}.txt"
  : >"$gate"
  echo "[fg1] .$tag $script_name" | tee -a "$gate"
  parse_chains "$script_local" "$chains_json" | tee -a "$gate"
  scp_r "$script_local" "$ip" "/private/var/mobile/Media/ZiYan/$script_name" 2>&1 | grep -v Warning || true
  bash "$ROOT/tools/zy_miss_fuse_emergency.sh" "$tag" 2>&1 | tee -a "$OUT/fuse_${tag}.txt" | tail -2
  remote_prep "$ip" "$scheme" | tee -a "$gate"

  local n fail=0 pass=0
  n=$(python3 -c "import json;print(len(json.load(open('$chains_json'))))")
  local i=0
  while [ "$i" -lt "$n" ]; do
    local scene line x1 y1 x2 y2 deg pts first
    eval "$(python3 - "$chains_json" "$i" <<'PY'
import json,sys
ch=json.load(open(sys.argv[1]))[int(sys.argv[2])]
pts=json.dumps(ch["pts"],separators=(",",":"))
print("line=%d" % ch["line"])
print("x1=%d" % ch["x1"]); print("y1=%d" % ch["y1"])
print("x2=%d" % ch["x2"]); print("y2=%d" % ch["y2"])
print("deg=%d" % ch["deg"])
print("first=%d" % ch["first"])
print("pts=%r" % pts)
PY
)"
    if [ "$i" = 0 ]; then scene=home; else scene=game; fi
    echo "==== chain$i line=$line scene=$scene first=$(printf '0x%06x' "$first") ====" | tee -a "$gate"
    if [ "$scene" = home ]; then
      if remote_go_home "$ip" "$scheme" | tee -a "$gate"; then
        echo "PASS chain${i}_home" | tee -a "$gate"; pass=$((pass+1))
      else
        echo "FAIL chain${i}_home" | tee -a "$gate"; fail=1
      fi
      if remote_align "$ip" "$scheme" home "$bid" | tee -a "$gate"; then
        echo "PASS chain${i}_align" | tee -a "$gate"; pass=$((pass+1))
      else
        echo "FAIL chain${i}_align" | tee -a "$gate"; fail=1
      fi
    else
      if remote_open_bid "$ip" "$scheme" "$bid" | tee -a "$gate"; then
        echo "PASS chain${i}_open" | tee -a "$gate"; pass=$((pass+1))
      else
        echo "FAIL chain${i}_open" | tee -a "$gate"; fail=1
      fi
      if remote_align "$ip" "$scheme" game "$bid" | tee -a "$gate"; then
        echo "PASS chain${i}_align" | tee -a "$gate"; pass=$((pass+1))
      else
        echo "FAIL chain${i}_align" | tee -a "$gate"; fail=1
      fi
    fi
    local freport
    freport=$(remote_find_chain "$ip" "$scheme" "$x1" "$y1" "$x2" "$y2" "$deg" "$pts" "c$i" 2>&1 | grep -v Warning) || true
    echo "$freport" | tee -a "$gate"
    # wrong-front guard
    if [ "$scene" = home ]; then
      echo "$freport" | grep -qi 'FRONT=com.apple.springboard' || { echo "FAIL chain${i}_wrong_front" | tee -a "$gate"; fail=1; }
    else
      echo "$freport" | grep -q "FRONT=$bid" || echo "$freport" | grep -q "FRONT=.*$bid" || {
        # allow substring
        echo "$freport" | grep -q "$bid" || { echo "FAIL chain${i}_wrong_front" | tee -a "$gate"; fail=1; }
      }
    fi
    if echo "$freport" | grep -qE '"ok":true'; then
      echo "PASS chain${i}_find" | tee -a "$gate"; pass=$((pass+1))
    else
      echo "FAIL chain${i}_find" | tee -a "$gate"; fail=1
    fi
    i=$((i+1))
  done

  echo "SUMMARY pass_steps=$pass fail=$fail chains=$n" | tee -a "$gate"
  if [ "$fail" = 0 ] && [ "$n" -gt 0 ]; then
    echo "VERDICT=PASS" | tee -a "$gate"
  else
    echo "VERDICT=FAIL" | tee -a "$gate"
  fi
}

case "$WANT" in
  all)
    run_one 53 192.168.31.53 rootless "$DESKTOP_IOS8P" ios8p.lua com.ljzbbadao.game
    run_one 166 192.168.31.166 rootful "$DESKTOP_IOS7" ios7.lua com.ljzbbadao.game
    ;;
  53) run_one 53 192.168.31.53 rootless "$DESKTOP_IOS8P" ios8p.lua com.ljzbbadao.game ;;
  166) run_one 166 192.168.31.166 rootful "$DESKTOP_IOS7" ios7.lua com.ljzbbadao.game ;;
  *) echo "usage: $0 [53|166|all]"; exit 2 ;;
esac

PASS_H=0; FAIL_H=0
for f in "$OUT"/gate_*.txt; do
  [ -f "$f" ] || continue
  echo "---- $(basename "$f") ----"; tail -20 "$f"
  if grep -q 'VERDICT=PASS' "$f"; then PASS_H=$((PASS_H+1)); else FAIL_H=$((FAIL_H+1)); fi
done
{
  echo "# FG1 front-match gate"
  echo "stamp=$STAMP want=$WANT"
  echo "PASS_HOSTS=$PASS_H FAIL_HOSTS=$FAIL_H"
  echo "RULE=find on matching front only; pick color = find color; no primary/secondary"
  if [ "$FAIL_H" = 0 ] && [ "$PASS_H" -gt 0 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
