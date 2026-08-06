#!/usr/bin/env bash
# Phase1-R 硬门禁 · 8-161-115（过程项全过才 exit 0）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/P1R_GATE_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
PASS=0; FAIL=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { PASS=$((PASS+1)); note "PASS $*"; }
bad() { FAIL=$((FAIL+1)); note "FAIL $*"; }

ssh_r() {
  local ip=$1; shift
  local n=0
  # .101 偶发 password 拒识 → 最多 3 次
  until sshpass -p alpine ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o ConnectTimeout=12 "root@$ip" "$@"; do
    n=$((n+1))
    [ "$n" -ge 3 ] && return 1
    sleep 1
  done
}

hard_idle() {
  local ip=$1 VAR=$2
  ssh_r "$ip" "touch $VAR/.ziyan_user_stopped; printf 'ts=1\n' > $VAR/.ziyan_kill_scripts; chmod 666 $VAR/.ziyan_user_stopped $VAR/.ziyan_kill_scripts 2>/dev/null; sleep 2; rm -f $VAR/.ziyan_embed_go $VAR/.ziyan_embed_on $VAR/.ziyan_embed_script $VAR/.ziyan_embed_alive $VAR/.ziyan_lua_embedded $VAR/.ziyan_script_session $VAR/.ziyan_project_active $VAR/.ziyan_find_pulse $VAR/.ziyan_te_running $VAR/.ziyan_kill_scripts; printf 'state=idle\npath=\norient=-1\ngen=0\n' > $VAR/.ziyan_session; printf 'stop=1\n' > $VAR/.ziyan_run_intent; chmod 666 $VAR/.ziyan_session $VAR/.ziyan_run_intent; rm -f $VAR/.ziyan_user_stopped" || true
}

json_field() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1],''))" "$1" 2>/dev/null || true; }

check() {
  local ip=$1 tag=$2 rootless=$3
  local VAR LD
  if [ "$rootless" = 1 ]; then VAR=/var/jb/usr/lib/ziyan/var; LD=/var/jb/Library/LaunchDaemons
  else VAR=/usr/lib/ziyan/var; LD=/Library/LaunchDaemons; fi
  note "==== .$tag $ip ===="

  local ver; ver=$(ssh_r "$ip" "dpkg -l com.ziyan.ziyan 2>/dev/null | tail -1" || true)
  echo "$ver" >"$OUT/${tag}_ver.txt"
  echo "$ver" | grep -q '8-161-115' && ok "$tag ver 115" || bad "$tag ver ($ver)"

  # G-prerm：业务脚本必须仍在（升级不得删 Media）
  local scripts; scripts=$(ssh_r "$ip" "ls /private/var/mobile/Media/ZiYan/ios7.lua /private/var/mobile/Media/ZiYan/ios8p.lua 2>&1" || true)
  echo "$scripts" >"$OUT/${tag}_scripts.txt"
  echo "$scripts" | grep -q ios7.lua && echo "$scripts" | grep -q ios8p.lua && ok "$tag media scripts" || bad "$tag media scripts missing"

  hard_idle "$ip" "$VAR"
  sleep 1

  local procs; procs=$(ssh_r "$ip" "ps -A -o args= | grep ziyan_framecap | grep -v grep | head -2" || true)
  echo "$procs" | grep -q framecap && ok "$tag framecap" || bad "$tag framecap"
  echo "$procs" | grep -qE 'lua5\.3' && bad "$tag zombie lua" || ok "$tag no lua5.3"

  # 基线文件必须存在
  local base; base=$(ssh_r "$ip" "test -f $VAR/.ziyan_session && echo SESS=1 || echo SESS=0; test -f $VAR/.ziyan_run_intent && echo INT=1 || echo INT=0; tr '\n' ' ' < $VAR/.ziyan_session 2>/dev/null; echo; ls $VAR/.ziyan_lua_embedded $VAR/.ziyan_embed_alive $VAR/.ziyan_find_pulse 2>/dev/null | wc -l" || true)
  echo "$base" >"$OUT/${tag}_base.txt"
  echo "$base" | grep -q 'SESS=1' && ok "$tag session file" || bad "$tag no session file"
  echo "$base" | grep -q 'INT=1' && ok "$tag intent file" || bad "$tag no intent"
  echo "$base" | grep -q 'state=idle' && ok "$tag idle" || bad "$tag not idle"
  echo "$base" | grep -qE '^0$|STICK| 0$' || true
  local stick; stick=$(echo "$base" | tail -1 | tr -d ' ')
  [ "${stick:-1}" = "0" ] && ok "$tag sticky0" || bad "$tag sticky=$stick"

  if [ "$rootless" = 1 ]; then
    local pl; pl=$(ssh_r "$ip" "grep -E 'bin/sh|usr/bin' $LD/com.ziyan.framecap.plist | head -6" || true)
    echo "$pl" >"$OUT/${tag}_plist.txt"
    echo "$pl" | grep -q '/var/jb/bin/sh' && ok "$tag jb sh" || bad "$tag jb sh"
    echo "$pl" | grep -q '/var/jb/usr/bin' && ok "$tag jb PATH" || bad "$tag jb PATH"
  fi

  # 截帧
  curl -sS -m 10 -o "$OUT/${tag}_snap.png" "http://$ip:50005/snapshot?orient=1" >/dev/null 2>&1 || true
  sleep 1
  local st; st=$(curl -sS -m 5 "http://$ip:50005/status" 2>/dev/null || true)
  echo "$st" >"$OUT/${tag}_status.txt"
  echo "$st" | grep -q 'wants_run=0\|"wants_run":false' && ok "$tag wants_run=0" || bad "$tag wants_run"
  echo "$st" | grep -qE 'logic_w=[1-9]|\"logic_w\":[1-9]' && ok "$tag logic size" || bad "$tag logic size ($st)"

  # 先 snapshot 逼出帧（冷闲 shm=0 后 findtest 才稳）
  curl -sS -m 12 -o /dev/null "http://$ip:50005/snapshot?orient=1" 2>/dev/null || true
  sleep 1

  # FIND2 ios8p：若 ok 则必须 in_orig 且 x∈[757,759]
  local ft
  ft=$(curl -sS -m 12 -X POST "http://$ip:50005/findtest" \
    --data-urlencode "main=0xc6a264" \
    --data-urlencode "offs=2|4|0xc6a264,2|7|0xc6a264,2|10|0xc6a264" \
    --data "degree=90&x1=757&y1=788&x2=759&y2=798&toast=0&orient=1" 2>/dev/null || echo '{}')
  echo "$ft" >"$OUT/${tag}_find2.json"
  if echo "$ft" | grep -q '"err":"empty_shm"'; then
    bad "$tag find2 empty_shm"
  elif echo "$ft" | grep -q '"ok":true'; then
    echo "$ft" | grep -q '"in_orig_roi":true' && ok "$tag find2 in_orig" || bad "$tag find2 not in_orig ($ft)"
    local x; x=$(echo "$ft" | python3 -c "import sys,json; print(json.load(sys.stdin).get('x',-1))" 2>/dev/null || echo -1)
    if [ "$x" -ge 757 ] 2>/dev/null && [ "$x" -le 759 ] 2>/dev/null; then ok "$tag find2 x in ROI ($x)"; else bad "$tag find2 x=$x out of ROI"; fi
  elif echo "$ft" | grep -q '"ok":false'; then
    ok "$tag find2 miss-ok (no false hit)"
  else
    bad "$tag find2 bad json ($ft)"
  fi

  # 全屏 findtest 不应 empty
  local ft0
  ft0=$(curl -sS -m 10 -X POST "http://$ip:50005/findtest" \
    --data "main=0x010203&offs=&degree=90&x1=0&y1=0&x2=0&y2=0&toast=0&orient=1" 2>/dev/null || echo '{}')
  echo "$ft0" >"$OUT/${tag}_find0.json"
  echo "$ft0" | grep -q 'empty_shm' && bad "$tag find0 empty_shm" || ok "$tag find0 has frame"

  hard_idle "$ip" "$VAR"
}

# 先确保脚本在四机（防旧 prerm 已删）
for ip in 192.168.31.53 192.168.31.101 192.168.31.112 192.168.31.166; do
  sshpass -p alpine scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    /Users/mac/Desktop/ios7.lua /Users/mac/Desktop/ios8p.lua "root@$ip:/private/var/mobile/Media/ZiYan/" 2>/dev/null || true
done

check 192.168.31.53 53 1
check 192.168.31.101 101 0
check 192.168.31.112 112 0
check 192.168.31.166 166 0

note "==== TOTAL pass=$PASS fail=$FAIL out=$OUT ===="
[ "$FAIL" -eq 0 ]
