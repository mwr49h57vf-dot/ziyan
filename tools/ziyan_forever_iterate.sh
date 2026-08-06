#!/bin/bash
# ZiYan forever iteration — stop ONLY when tmp_shots/STOP_ITERATE exists
# or user places file containing 停止迭代. Do not exit otherwise.
set -u
ROOT="/Users/mac/Desktop/ZiYan_副本"
LOG="$ROOT/tmp_shots/forever_iterate.log"
STATUS="$ROOT/tmp_shots/forever_status.txt"
STOP1="$ROOT/tmp_shots/STOP_ITERATE"
STOP2="$ROOT/tmp_shots/停止迭代"
STOPF="$ROOT/tmp_shots/STOP_FOREVER"
mkdir -p "$ROOT/tmp_shots"
ROUND=0

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
should_stop() {
  [[ -f "$STOP1" || -f "$STOP2" || -f "$STOPF" ]] && return 0
  return 1
}

cleanup_tests() {
  # 清理主机侧历史测试噪音（保留 compare / forever / habits）
  find "$ROOT/tmp_shots" -maxdepth 1 -type f \( \
    -name '_diag_*' -o -name '_probe_*' -o -name '*_smoke*' -o \
    -name 'build_usb_*.log' -o -name 'build_lan_*.log' \
  \) -mtime +0 -delete 2>/dev/null || true
  # 设备侧过期自测 pass/report（不杀正在跑的脚本）
  for host in "mobile@127.0.0.1:-p 2222" "root@192.168.31.166:" "root@192.168.31.171:" "root@192.168.31.149:"; do
    :
  done
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 2222 mobile@127.0.0.1 \
    'sudo rm -f /var/jb/usr/lib/ziyan/var/.ziyan_selftest_* /var/jb/usr/lib/ziyan/var/.ziyan_openfind_* 2>/dev/null; true' 2>/dev/null || true
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@192.168.31.166 \
    'rm -f /usr/lib/ziyan/var/.ziyan_selftest_* /usr/lib/ziyan/var/.ziyan_openfind_* 2>/dev/null; true' 2>/dev/null || true
}

observe_ts() {
  local ip="$1"
  local out="$ROOT/tmp_shots/ts_observe_${ip##*.}.txt"
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 root@"$ip" \
    "echo HOST=$ip; date; cat /private/var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null; ps aux | grep -iE 'TSDaemon|TouchSprite|lua' | grep -v grep | head -8" \
    >"$out" 2>/dev/null || echo "unreachable $ip" >"$out"
}

patch_doc_stamp() {
  local html="$ROOT/子砚触控函数说明.html"
  [[ -f "$html" ]] || return 0
  local stamp
  stamp=$(date '+%Y-%m-%d %H:%M')
  # 更新页脚迭代时间（不改函数正文结构）
  if grep -q '持续迭代中' "$html"; then
    python3 - <<PY 2>/dev/null || true
from pathlib import Path
p=Path("$html")
t=p.read_text(encoding='utf-8')
import re
t=re.sub(r'持续迭代中：[^<]*', '持续迭代中：对比 .171/.149 · 上次心跳 $stamp · ', t, count=1)
p.write_text(t, encoding='utf-8')
PY
  fi
}

run_login_loop_once() {
  # 轻量：仅推脚本（实际玩游戏由 ensure_game_play 保活）
  local script="$ROOT/media_seed/_zy_login_find_tap.lua"
  [[ -f "$script" ]] || return 0
  sshpass -p alpine scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 -P 2222 "$script" \
    mobile@127.0.0.1:/private/var/mobile/Media/ZiYan/_zy_login_find_tap.lua 2>/dev/null || true
  sshpass -p alpine scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$script" \
    root@192.168.31.166:/private/var/mobile/Media/ZiYan/_zy_login_find_tap.lua 2>/dev/null || true
}

ensure_game_play() {
  # 真机必须自己开游测函数；缺进程则拉起 while-true 脚本
  if [[ -x "$ROOT/tools/ziyan_ensure_game_play.sh" ]]; then
    bash "$ROOT/tools/ziyan_ensure_game_play.sh" >>"$ROOT/tmp_shots/forever_game_play.log" 2>&1 || true
  elif [[ -f "$ROOT/tools/ziyan_ensure_game_play.sh" ]]; then
    bash "$ROOT/tools/ziyan_ensure_game_play.sh" >>"$ROOT/tmp_shots/forever_game_play.log" 2>&1 || true
  fi
}

log "FOREVER iterate started pid=$$"
while true; do
  if should_stop; then
    log "STOP file detected — exiting forever loop"
    echo "stopped $(date '+%F %T')" >"$STATUS"
    exit 0
  fi
  ROUND=$((ROUND+1))
  echo "round=$ROUND ts=$(date '+%F %T') pid=$$" >"$STATUS"
  log "=== round $ROUND observe+game ==="
  observe_ts 192.168.31.171
  observe_ts 192.168.31.149
  cleanup_tests
  patch_doc_stamp
  run_login_loop_once
  ensure_game_play
  # 抽样写回游戏心跳到 status
  {
    echo "round=$ROUND ts=$(date '+%F %T') pid=$$"
    echo -n "usb_play="; sshpass -p alpine ssh -o ConnectTimeout=4 -o StrictHostKeyChecking=no -p 2222 mobile@127.0.0.1 \
      "pgrep -f _zy_game_play_forever.lua >/dev/null && echo RUN || echo STOP" 2>/dev/null || echo ERR
    echo -n "lan_play="; sshpass -p alpine ssh -o ConnectTimeout=4 -o StrictHostKeyChecking=no root@192.168.31.166 \
      "pgrep -f _zy_game_play_forever.lua >/dev/null && echo RUN || echo STOP" 2>/dev/null || echo ERR
  } >"$STATUS"
  {
    echo "round=$ROUND"
    echo "---171---"; head -20 "$ROOT/tmp_shots/ts_observe_171.txt" 2>/dev/null
    echo "---149---"; head -20 "$ROOT/tmp_shots/ts_observe_149.txt" 2>/dev/null
  } >>"$ROOT/tmp_shots/forever_compare_tail.txt"
  if [[ -f "$ROOT/tmp_shots/forever_compare_tail.txt" ]]; then
    tail -n 4000 "$ROOT/tmp_shots/forever_compare_tail.txt" >"$ROOT/tmp_shots/forever_compare_tail.txt.tmp" 2>/dev/null || true
    mv "$ROOT/tmp_shots/forever_compare_tail.txt.tmp" "$ROOT/tmp_shots/forever_compare_tail.txt" 2>/dev/null || true
  fi
  log "round $ROUND done; sleep 90s"
  sleep 90
done
