#!/bin/bash
# 确保 USB / LAN166 上「玩游戏」脚本一直在跑；缺则拉起
set -u
ROOT="/Users/mac/Desktop/ZiYan_副本"
SCRIPT_SRC="$ROOT/media_seed/_zy_game_play_forever.lua"
SCRIPT_DST=/private/var/mobile/Media/ZiYan/_zy_game_play_forever.lua

ensure_usb() {
  sshpass -p alpine scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 -P 2222 \
    "$SCRIPT_SRC" "mobile@127.0.0.1:$SCRIPT_DST" || {
    echo USB_SCP_FAIL
    return 1
  }
  # 先把远端脚本写到 /tmp，再用 sudo bash 执行（避免 sudo -S 吃掉 heredoc）
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p 2222 mobile@127.0.0.1 \
    'cat > /tmp/zy_ensure_play.sh && echo alpine | sudo -S bash /tmp/zy_ensure_play.sh' <<'EOF'
#!/bin/bash
VAR=/var/jb/usr/lib/ziyan/var
ZROOT=/var/jb/usr/lib/ziyan
SCRIPT=/private/var/mobile/Media/ZiYan/_zy_game_play_forever.lua
alive=0
# 只认本脚本进程；多实例则清掉只留无
pids=$(pgrep -f '_zy_game_play_forever.lua' 2>/dev/null || true)
np=$(echo "$pids" | wc -w | tr -d ' ')
if [[ -n "$pids" && "$np" == "1" ]]; then alive=1; fi
if [[ -n "$pids" && "$np" != "1" ]]; then
  echo USB_MULTI_KILL count=$np
  pkill -9 -f '_zy_game_play_forever.lua' 2>/dev/null || true
  killall -9 lua5.3 2>/dev/null || true
  alive=0
  sleep 1
fi
# 仅进程消失才拉起；心跳陈旧(>360s)才判定卡死重启，避免 OCR 中途误杀
if [[ "$alive" == 1 ]]; then
  if [[ -f "$VAR/.ziyan_game_play_alive" ]]; then
    t=$(cat "$VAR/.ziyan_game_play_alive" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ $((now - t)) -gt 360 ]]; then
      echo USB_STALE_RESTART age=$((now - t))
      pkill -9 -f '_zy_game_play_forever.lua' 2>/dev/null || true
      killall -9 lua5.3 2>/dev/null || true
      alive=0
    else
      echo USB_ALREADY_RUNNING
      exit 0
    fi
  else
    echo USB_ALREADY_RUNNING
    exit 0
  fi
fi
# 项目未启动时不对系统解锁；解锁由脚本启动后（ziyan_run 写 project_active）自行处理
pkill -9 -f '_zy_game_play_forever.lua' 2>/dev/null || true
pkill -9 -f 'ziyan_run.lua.*_zy_game_play' 2>/dev/null || true
sleep 1
export DYLD_LIBRARY_PATH="$ZROOT/lib"
nohup "$ZROOT/bin/lua5.3" "$ZROOT/lib/lua/ziyan_run.lua" "$SCRIPT" \
  >"$VAR/.ziyan_game_play_runner.log" 2>&1 &
echo USB_STARTED_pid=$!
EOF
}

ensure_lan() {
  sshpass -p alpine scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "$SCRIPT_SRC" "root@192.168.31.166:$SCRIPT_DST" || {
    echo LAN_SCP_FAIL
    return 1
  }
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@192.168.31.166 \
    'bash -s' <<'EOF'
VAR=/usr/lib/ziyan/var
ZROOT=/usr/lib/ziyan
SCRIPT=/private/var/mobile/Media/ZiYan/_zy_game_play_forever.lua
alive=0
if pgrep -f '_zy_game_play_forever.lua' >/dev/null 2>&1; then alive=1; fi
if [[ "$alive" == 1 ]]; then
  if [[ -f "$VAR/.ziyan_game_play_alive" ]]; then
    t=$(cat "$VAR/.ziyan_game_play_alive" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ $((now - t)) -gt 360 ]]; then
      echo LAN_STALE_RESTART age=$((now - t))
      pkill -9 -f '_zy_game_play_forever.lua' 2>/dev/null || true
      alive=0
    else
      echo LAN_ALREADY_RUNNING
      exit 0
    fi
  else
    echo LAN_ALREADY_RUNNING
    exit 0
  fi
fi
# 项目未启动不对系统解锁；由 ziyan_run 标记 project_active 后脚本内再 unlock
pkill -9 -f '_zy_game_play_forever.lua' 2>/dev/null || true
pkill -9 -f 'ziyan_run.lua.*_zy_game_play' 2>/dev/null || true
sleep 1
export DYLD_LIBRARY_PATH="$ZROOT/lib"
nohup "$ZROOT/bin/lua5.3" "$ZROOT/lib/lua/ziyan_run.lua" "$SCRIPT" \
  >"$VAR/.ziyan_game_play_runner.log" 2>&1 &
echo LAN_STARTED_pid=$!
EOF
}

ensure_usb
ensure_lan
exit 0
