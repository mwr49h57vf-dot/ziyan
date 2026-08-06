#!/usr/bin/env bash
# Phase1-R 8-161-110 四机自测（禁代启业务脚本）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/P1_SELFTEST_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
PASS=0
FAIL=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { PASS=$((PASS+1)); note "PASS $*" ; }
bad() { FAIL=$((FAIL+1)); note "FAIL $*" ; }

ssh_r() {
  local ip=$1; shift
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o ConnectTimeout=12 "root@$ip" "$@"
}

# 真停：用户停 + 清粘滞（对标触动 Script stopped）
hard_idle() {
  local ip=$1 rootless=$2
  local VAR
  if [ "$rootless" = 1 ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
  ssh_r "$ip" "touch $VAR/.ziyan_user_stopped; printf 'ts=1\npid_req=0\n' > $VAR/.ziyan_kill_scripts; chmod 666 $VAR/.ziyan_user_stopped $VAR/.ziyan_kill_scripts; sleep 2; rm -f $VAR/.ziyan_embed_go $VAR/.ziyan_embed_on $VAR/.ziyan_embed_script $VAR/.ziyan_embed_alive $VAR/.ziyan_lua_embedded $VAR/.ziyan_script_session $VAR/.ziyan_project_active $VAR/.ziyan_find_pulse $VAR/.ziyan_te_running; printf 'state=idle\npath=\norient=-1\ngen=0\n' > $VAR/.ziyan_session; printf 'stop=1\n' > $VAR/.ziyan_run_intent; chmod 666 $VAR/.ziyan_session $VAR/.ziyan_run_intent" || true
}

check_phone() {
  local ip=$1 tag=$2 rootless=$3
  local VAR
  if [ "$rootless" = 1 ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
  note "==== .$tag $ip ===="
  local ver
  ver=$(ssh_r "$ip" "dpkg -l com.ziyan.ziyan 2>/dev/null | tail -1" 2>/dev/null || true)
  echo "$ver" >"$OUT/${tag}_ver.txt"
  if echo "$ver" | grep -q '8-161-110'; then ok "$tag version 110"; else bad "$tag version not 110 ($ver)"; fi

  hard_idle "$ip" "$rootless"
  sleep 1

  local procs
  procs=$(ssh_r "$ip" "ps -A -o pid=,args= 2>/dev/null | grep -E 'ziyan_framecap|lua5.3' | grep -v grep | head -8" 2>/dev/null || true)
  echo "$procs" >"$OUT/${tag}_procs.txt"
  if echo "$procs" | grep -q ziyan_framecap; then ok "$tag framecap up"; else bad "$tag framecap missing"; fi
  if echo "$procs" | grep -qE '\(lua5\.3\)'; then bad "$tag zombie lua5.3"; else ok "$tag no zombie lua"; fi

  # 粘滞必须空；session idle
  local stick
  stick=$(ssh_r "$ip" "echo SESSION=\$(tr '\\n' ' ' < $VAR/.ziyan_session); echo EMBED=\$(ls $VAR/.ziyan_lua_embedded $VAR/.ziyan_embed_alive $VAR/.ziyan_find_pulse 2>/dev/null | wc -l)" 2>/dev/null || true)
  echo "$stick" >"$OUT/${tag}_sticky.txt"
  if echo "$stick" | grep -q 'state=idle'; then ok "$tag session idle"; else bad "$tag session not idle ($stick)"; fi
  if echo "$stick" | grep -qE 'EMBED= *0'; then ok "$tag no embed sticky"; else bad "$tag embed sticky ($stick)"; fi

  # rootless：plist PATH / argv0
  if [ "$rootless" = 1 ]; then
    local pl
    pl=$(ssh_r "$ip" "grep -A2 ProgramArguments /var/jb/Library/LaunchDaemons/com.ziyan.framecap.plist | head -5; grep -A2 'key>PATH' /var/jb/Library/LaunchDaemons/com.ziyan.framecap.plist | head -5" 2>/dev/null || true)
    echo "$pl" >"$OUT/${tag}_plist.txt"
    if echo "$pl" | grep -q '/var/jb/bin/sh'; then ok "$tag plist sh=jb"; else bad "$tag plist sh"; fi
    if echo "$pl" | grep -q '/var/jb/usr/bin'; then ok "$tag plist PATH=jb"; else bad "$tag plist PATH"; fi
  fi

  ssh_r "$ip" "rm -f $VAR/.ziyan_user_stopped; echo 1 > $VAR/.ziyan_force_recap; echo 1 > $VAR/.ziyan_snap_http_want" 2>/dev/null || true
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
    if echo "$st" | grep -qE 'logic_w=(2208|1242)|w=2208|h=1242'; then ok "$tag 8P-class logic"; else bad "$tag missing 8P logic"; fi
    if echo "$st" | grep -q 'scale=3'; then ok "$tag scale=3"; else bad "$tag scale not 3"; fi
  else
    if echo "$st" | grep -qE 'logic_w=(1136|640)|w=640|h=1136|w=1136'; then ok "$tag 7-class size"; else bad "$tag missing 7-class size"; fi
    if echo "$st" | grep -q 'scale=2'; then ok "$tag scale=2"; else bad "$tag scale not 2"; fi
  fi

  local ft
  ft=$(curl -sS -m 6 -X POST "http://$ip:50005/findtest" \
    --data "main=0x010203&offs=&degree=90&x1=0&y1=0&x2=0&y2=0&toast=0&orient=1" 2>/dev/null || true)
  echo "$ft" >"$OUT/${tag}_findtest.json"
  if echo "$ft" | grep -q '"ok"'; then ok "$tag findtest json"; else bad "$tag findtest ($ft)"; fi

  # 再硬 idle，确认 findtest 未留下业务会话
  hard_idle "$ip" "$rootless"
  stick=$(ssh_r "$ip" "tr '\\n' ' ' < $VAR/.ziyan_session; ls $VAR/.ziyan_find_pulse 2>/dev/null | wc -l" 2>/dev/null || true)
  if echo "$stick" | grep -q 'state=idle'; then ok "$tag final idle"; else bad "$tag final not idle"; fi
}

check_phone 192.168.31.53 53 1
check_phone 192.168.31.101 101 0
check_phone 192.168.31.112 112 0
check_phone 192.168.31.166 166 0

note "==== TOTAL pass=$PASS fail=$FAIL out=$OUT ===="
[ "$FAIL" -eq 0 ]
