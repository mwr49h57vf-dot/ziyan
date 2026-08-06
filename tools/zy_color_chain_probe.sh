#!/bin/bash
# 色点专线：解析 Desktop ios7/ios8p 活跃 find 链，在指定机 getColor+find（与引擎刀解耦）
# 用法: tools/zy_color_chain_probe.sh 101|112|166|53
set -euo pipefail
H="${1:?ip suffix e.g. 101}"
PW="${ZY_SSH_PASS:-alpine}"
IP="192.168.31.$H"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/COLOR_PROBE_$(date +%Y%m%d_%H%M%S)_$H"
mkdir -p "$OUT"

if [ "$H" = "53" ]; then
  SCRIPT=/Users/mac/Desktop/ios8p.lua
else
  SCRIPT=/Users/mac/Desktop/ios7.lua
fi
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT"; exit 1; }
cp "$SCRIPT" "$OUT/script.lua"

python3 - "$SCRIPT" "$OUT/chains.json" <<'PY'
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
    for part in m.group(2).split(","):
        dx,dy,col=part.split("|")
        c=int(col,16) if col.startswith("0x") else int(col)
        pts.append({"c":c,"dx":int(dx),"dy":int(dy),"b":0})
    chains.append(dict(line=i,deg=int(m.group(3)),
        x1=int(m.group(4)),y1=int(m.group(5)),
        x2=int(m.group(6)),y2=int(m.group(7)),pts=pts,first=first))
json.dump(chains, open(sys.argv[2],"w"), indent=2)
print("chains", len(chains))
PY

sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o ConnectTimeout=12 "root@$IP" "bash -s" <<REMOTE | tee "$OUT/REPORT.txt"
V=/usr/lib/ziyan/var
[ -d /var/jb/usr/lib/ziyan/var ] && V=/var/jb/usr/lib/ziyan/var
echo FRONT=\$(cat \$V/.ziyan_front_bid 2>/dev/null)
echo ORIENT=\$(tr '\\n' ' ' <\$V/.ziyan_orient 2>/dev/null)
echo VER=\$(dpkg -l com.ziyan.ziyan 2>/dev/null | tail -1)
REMOTE

python3 - "$OUT/chains.json" "$IP" "$PW" "$OUT/REPORT.txt" <<'PY'
import json, subprocess, sys
chains=json.load(open(sys.argv[1]))
ip,pw,rep=sys.argv[2],sys.argv[3],sys.argv[4]
def ssh(cmd):
    return subprocess.check_output([
        "sshpass","-p",pw,"ssh","-o","StrictHostKeyChecking=no",
        "-o","PreferredAuthentications=password","-o","PubkeyAuthentication=no",
        f"root@{ip}", cmd], text=True, stderr=subprocess.STDOUT)
lines=[]
for ci,ch in enumerate(chains):
    x1,y1=ch["x1"],ch["y1"]
    cmd=f'''V=/usr/lib/ziyan/var; [ -d /var/jb/usr/lib/ziyan/var ] && V=/var/jb/usr/lib/ziyan/var
rm -f $V/.ziyan_color_rep
printf "getColor\\n{x1}\\n{y1}\\ngc\\n" >$V/.ziyan_color_req.tmp
mv -f $V/.ziyan_color_req.tmp $V/.ziyan_color_req
for i in $(seq 1 50); do [ -f $V/.ziyan_color_rep ] && break; sleep 0.05; done
c=$(sed -n "3p" $V/.ziyan_color_rep)
echo GC_L{ch["line"]}_{x1}_{y1}=$c
PTS='{json.dumps(ch["pts"],separators=(",",":"))}'
rm -f $V/.ziyan_color_rep
printf '%s\\n' findMulti "$PTS" '{ch["deg"]}' '{ch["x1"]}' '{ch["y1"]}' '{ch["x2"]}' '{ch["y2"]}' 'fm{ci}' >$V/.ziyan_color_req.tmp
mv -f $V/.ziyan_color_req.tmp $V/.ziyan_color_req
for i in $(seq 1 60); do [ -f $V/.ziyan_color_rep ] && break; sleep 0.05; done
echo FIND_L{ch["line"]}=$(tr "\\n" "|" <$V/.ziyan_color_rep)
'''
    try:
        out=ssh(cmd).strip()
    except Exception as e:
        out=f"FAIL {e}"
    lines.append(out)
    print(out)
open(rep,"a").write("\n"+ "\n".join(lines)+"\n")
print("OUT", rep)
PY
echo "OUT=$OUT"
