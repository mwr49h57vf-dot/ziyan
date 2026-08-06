#!/usr/bin/env bash
# Phase3 8-161-104 四机自测（从 Mac 探 50005；禁代启业务脚本）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/P3_SELFTEST_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
PASS=0
FAIL=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { PASS=$((PASS+1)); note "PASS $*" ; }
bad() { FAIL=$((FAIL+1)); note "FAIL $*" ; }

ssh_r() {
  local ip=$1; shift
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o ConnectTimeout=10 "root@$ip" "$@"
}

check_phone() {
  local ip=$1 tag=$2 rootless=$3
  local VAR
  if [ "$rootless" = 1 ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
  note "==== .$tag $ip ===="
  local ver
  ver=$(ssh_r "$ip" "dpkg -l com.ziyan.ziyan 2>/dev/null | tail -1" 2>/dev/null || true)
  echo "$ver" >"$OUT/${tag}_ver.txt"
  if echo "$ver" | grep -q '8-161-104'; then ok "$tag version 104"; else bad "$tag version not 104 ($ver)"; fi

  local procs
  procs=$(ssh_r "$ip" "ps -A -o pid=,args= 2>/dev/null | grep -E 'ziyan_framecap|lua5.3' | grep -v grep | head -8" 2>/dev/null || true)
  echo "$procs" >"$OUT/${tag}_procs.txt"
  if echo "$procs" | grep -q ziyan_framecap; then ok "$tag framecap up"; else bad "$tag framecap missing"; fi
  if echo "$procs" | grep -qE '\(lua5\.3\)'; then bad "$tag zombie lua5.3"; else ok "$tag no zombie lua"; fi

  # 清粘停，会话置 idle；拉起帧后再读 status
  ssh_r "$ip" "rm -f $VAR/.ziyan_user_stopped $VAR/.ziyan_stop $VAR/.ziyan_lua_hung; printf 'state=idle\npath=\norient=-1\ngen=0\n' > $VAR/.ziyan_session; chmod 666 $VAR/.ziyan_session; echo 1 > $VAR/.ziyan_force_recap; echo 1 > $VAR/.ziyan_snap_http_want" 2>/dev/null || true
  # 先 snapshot 逼出帧
  curl -sS -m 8 -o /dev/null "http://$ip:50005/snapshot?orient=1" 2>/dev/null || true
  sleep 1
  local st=""
  for _try in 1 2 3 4 5 6; do
    st=$(curl -sS -m 4 "http://$ip:50005/status" 2>/dev/null || curl -sS -m 4 "http://$ip:50015/status" 2>/dev/null || true)
    if echo "$st" | grep -qE 'logic_w=[1-9]|w=[1-9]'; then break; fi
    curl -sS -m 6 -o /dev/null "http://$ip:50005/snapshot?orient=1" 2>/dev/null || true
    sleep 1
  done
  echo "$st" >"$OUT/${tag}_status.txt"
  if echo "$st" | grep -q zy1; then ok "$tag snap http"; else bad "$tag snap http down"; return; fi

  if [ "$tag" = 53 ]; then
    if echo "$st" | grep -qE 'logic_w=(2208|1242)|w=2208|h=1242'; then
      ok "$tag 8P-class logic"
    else
      bad "$tag missing 8P logic ($st)"
    fi
    if echo "$st" | grep -q 'scale=3'; then ok "$tag scale=3"; else bad "$tag scale not 3"; fi
    if echo "$st" | grep -q 'scheme=rootless'; then ok "$tag rootless"; else bad "$tag scheme"; fi
  else
    if echo "$st" | grep -qE 'logic_w=(1136|640)|w=640|h=1136|w=1136'; then
      ok "$tag 7-class size"
    else
      bad "$tag missing 7-class size"
    fi
    if echo "$st" | grep -q 'scale=2'; then ok "$tag scale=2"; else bad "$tag scale not 2 (got $(echo "$st" | grep scale=))"; fi
    if echo "$st" | grep -q 'scheme=rootful'; then ok "$tag rootful"; else bad "$tag scheme"; fi
  fi

  local ft
  ft=$(curl -sS -m 6 -X POST "http://$ip:50005/findtest" \
    --data "main=0x010203&offs=&degree=90&x1=0&y1=0&x2=0&y2=0&toast=0&orient=1" 2>/dev/null || true)
  echo "$ft" >"$OUT/${tag}_findtest.json"
  if echo "$ft" | grep -q '"ok"'; then ok "$tag findtest json"; else bad "$tag findtest ($ft)"; fi

  # 抓色器尺寸：/snapshot?orient=1 应 200
  local code
  code=$(curl -sS -m 8 -o "$OUT/${tag}_snap.png" -w '%{http_code}' "http://$ip:50005/snapshot?orient=1" 2>/dev/null || echo 000)
  if [ "$code" = 200 ] && [ -s "$OUT/${tag}_snap.png" ]; then ok "$tag snapshot png"; else bad "$tag snapshot http=$code"; fi
}

check_phone 192.168.31.53 53 1
check_phone 192.168.31.101 101 0
check_phone 192.168.31.112 112 0
check_phone 192.168.31.166 166 0

note "==== TOTAL pass=$PASS fail=$FAIL out=$OUT ===="
[ "$FAIL" -eq 0 ]
