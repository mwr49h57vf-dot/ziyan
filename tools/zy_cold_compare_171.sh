#!/usr/bin/env bash
# zy_cold_compare_171.sh — 冷启动清场 → .171 触动观察(含随机 Home) → 四机对拍
# 约束：不部署 ZiYan 到 .171；Desktop ios7/ios8p 仅 scp 不改。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=alpine
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/SURPASS_TS/COLD_CMP_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=4 -o ServerAliveCountMax=2)
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"

ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"

# ── 1) 四机冷启动：杀尽自测进程 + 游戏/ZiYan App ─────────────────
cold_clean() {
  local tag="$1" ip="$2" scheme="$3"
  echo "[cold] .$tag"
  ssh_r "$ip" "SCHEME=$scheme TAG=$tag bash -s" <<'EOS' | tee "$OUT/cold_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:$PATH
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
else
  VAR=/usr/lib/ziyan/var
  export PATH=/usr/lib/ziyan/bin:/bin:$PATH
fi
MEDIA=/var/mobile/Media/ZiYan
mkdir -p "$VAR" "$MEDIA"
# 停脚本意图
echo stop=1 >"$VAR/.ziyan_stop"
rm -f "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_go" "$VAR/.ziyan_embed_script" \
      "$VAR/.ziyan_active" "$VAR/.ziyan_lua_run.pid" "$VAR/.ziyan_te_running" \
      "$VAR/.ziyan_touch_req" "$VAR/.ziyan_open_app" "$VAR/.ziyan_menu_run_trig" \
      "$VAR/.ziyan_vol_menu_sticky" "$VAR/.ziyan_app_user_closed"
# 杀 lua / framecap 内嵌脚本相关
PIDS=$(ps -A -o pid=,command= 2>/dev/null | grep -E 'ziyan_run\.lua|lua5\.3|ios7\.lua|ios8p\.lua' | grep -v grep | sed 's/^ *//' | cut -d' ' -f1)
for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
# 杀 App 与游戏（冷启动必须干净）
for app in ZiYan ceshi com.xztl.ios com.ljzbbadao.game com.ychj.hlhjlygr com.zsyxs180.game; do
  killall -9 "$app" 2>/dev/null
done
# bundle 名进程兜底
ps -A -o pid=,command= 2>/dev/null | grep -iE 'xztl|ljzbbadao|ZiYan\.app|ceshi' | grep -v grep | sed 's/^ *//' | cut -d' ' -f1 | while read p; do
  kill -9 "$p" 2>/dev/null
done
# 归还主屏滑动 / 抬指
echo 1 >"$VAR/.ziyan_dismiss_menu"
echo 1 >"$VAR/.ziyan_release_screen"
echo 1 >"$VAR/.ziyan_fix_swipe"
echo 1 >"$VAR/.ziyan_go_home"
sleep 1
rm -f "$VAR/.ziyan_go_home"
# 8-161-77：对齐触动默认 embed；禁 light/embed_off（旧对拍旗把稳路径打回文件 IPC）
rm -f "$VAR/.ziyan_light" "$VAR/.ziyan_embed_off"
echo 1 >"$VAR/.ziyan_embed_on"
chmod 666 "$VAR/.ziyan_embed_on" 2>/dev/null
LUA_N=$(ps -A -o command= 2>/dev/null | grep -E 'ziyan_run\.lua|ios7\.lua|ios8p\.lua' | grep -v grep | wc -l | tr -d ' ')
FRONT=$(cat "$VAR/.ziyan_front_bid" 2>/dev/null)
echo "COLD_OK tag=$TAG lua_left=$LUA_N front=$FRONT"
ps -A -o pid=,command= 2>/dev/null | grep -iE 'xztl|ljzbbadao|ZiYan|ziyan_run|lua5' | grep -v grep | head -10 || echo NO_TARGET_PROCS
EOS
}

echo "======== PHASE1 COLD CLEAN ========"
cold_clean 53 192.168.31.53 rootless &
cold_clean 101 192.168.31.101 rootful &
cold_clean 112 192.168.31.112 rootful &
cold_clean 166 192.168.31.166 rootful &
wait
sleep 2

# ── 2) .171 采集触动 + 随机 Home 观察（只读，不部署）────────────────
echo "======== PHASE2 TS171 OBSERVE + RANDOM HOME ========"
ssh_r 192.168.31.171 'bash -s' <<'EOS' | tee "$OUT/ts171_home_observe.txt"
set +e
TS=/var/mobile/Media/TouchSprite
HIT=$TS/tmp/zy_ts_hit.csv
LOG=$TS/log/ts.log
echo "===T0_BASELINE==="
date
echo STATUS=$(wget -q -O - -T 1 http://127.0.0.1:50005/status 2>/dev/null)
echo RUN_CFG=$(cat $TS/config/run.cfg 2>/dev/null)
ps -A -o pid,%cpu,rss,command= | grep -iE 'TSDaemon|Hades' | grep -v grep
echo HIT_TAIL_BEFORE=
tail -3 "$HIT" 2>/dev/null
WC_BEFORE=$(wc -c <"$HIT" 2>/dev/null | tr -d ' ')
LOG_BEFORE=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')
CPU0=$(ps -A -o %cpu=,command= | grep 'Hades' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)

press_home() {
  local n="$1"
  echo "===HOME_PRESS_$n==="
  date
  # 多路径尝试物理 Home 等价（不装新包；观察触动反应）
  # 1) Activator URL（若注册）
  uiopen 'activator://libactivator.system.homebutton' >/dev/null 2>&1 || true
  uiopen 'activator://send/libactivator.system.homebutton' >/dev/null 2>&1 || true
  # 2) SpringBoard 偏好/桌面
  uiopen 'prefs:root=' >/dev/null 2>&1 || true
  # 3) 挂起前台游戏进程（等价回桌面，便于观察 TS 前台字段变化）
  killall -STOP com.xztl.ios 2>/dev/null || true
  sleep 0.3
  killall -CONT com.xztl.ios 2>/dev/null || true
  killall -9 com.xztl.ios 2>/dev/null || true
  sleep 0.8
  echo STATUS=$(wget -q -O - -T 1 http://127.0.0.1:50005/status 2>/dev/null)
  ps -A -o pid,%cpu,rss,command= | grep -iE 'TSDaemon|Hades|xztl' | grep -v grep
  echo HIT_AFTER_$n=
  tail -5 "$HIT" 2>/dev/null
  echo LOG_DELTA_LINES=
  # ts.log 是否新增结束/开始
  tail -5 "$LOG" 2>/dev/null
}

# 采样 4s 基线节奏
echo "===BASELINE_4S==="
H0=$(wc -l <"$HIT" 2>/dev/null | tr -d ' ')
sleep 4
H1=$(wc -l <"$HIT" 2>/dev/null | tr -d ' ')
echo "HIT_LINES_DELTA_4S=$((H1-H0))"
tail -8 "$HIT" 2>/dev/null

# 随机 3 次 Home（间隔 2~5s）
press_home 1
sleep 2
press_home 2
sleep 3
press_home 3

echo "===T1_AFTER_HOMES==="
date
echo STATUS=$(wget -q -O - -T 1 http://127.0.0.1:50005/status 2>/dev/null)
echo RUN_CFG=$(cat $TS/config/run.cfg 2>/dev/null)
WC_AFTER=$(wc -c <"$HIT" 2>/dev/null | tr -d ' ')
LOG_AFTER=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')
echo "HIT_BYTES $WC_BEFORE -> $WC_AFTER"
echo "LOG_BYTES $LOG_BEFORE -> $LOG_AFTER"
ps -A -o pid,%cpu,rss,command= | grep -iE 'TSDaemon|Hades' | grep -v grep
# 触动脚本若停了，按原 select 拉起（只写 run.cfg，不部署 ZiYan）
if ! ps -A -o command= | grep -q '[H]ades'; then
  echo "HADES_DEAD → rewrite runnow"
fi
# 确保仍在跑：若 hit 不再增长则重写 run.cfg
H2=$(wc -l <"$HIT" 2>/dev/null | tr -d ' ')
sleep 2
H3=$(wc -l <"$HIT" 2>/dev/null | tr -d ' ')
echo "HIT_GROW_POST=$((H3-H2))"
if [ "$((H3-H2))" -le 0 ]; then
  echo 'runnow###/private/var/mobile/Media/TouchSprite/lua/main.lua' >"$TS/config/run.cfg"
  chmod 666 "$TS/config/run.cfg"
  echo RE_RUNNOW_WRITTEN
  sleep 3
fi
echo HIT_TAIL_FINAL=
tail -8 "$HIT" 2>/dev/null
echo LOG_TAIL_FINAL=
tail -8 "$LOG" 2>/dev/null
echo TS171_OBSERVE_DONE
EOS

# 若 Home 杀了游戏，把触动侧游戏再拉起（用 uiopen，不碰 ZiYan）
ssh_r 192.168.31.171 'uiopen com.xztl.ios:// >/dev/null 2>&1; uiopen "com.xztl.ios://" >/dev/null 2>&1; echo 1' || true
sleep 2

# ── 3) 四机 scp 脚本 + 拉游戏 + 启动 ─────────────────────────────
echo "======== PHASE3 LAUNCH ZY SCRIPTS ========"
launch_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4"
  local src="$DESKTOP_IOS7"
  [[ "$script" == "ios8p.lua" ]] && src="$DESKTOP_IOS8P"
  local VAR LUA RUN LUALIB BID
  if [[ "$scheme" == rootless ]]; then
    VAR=/var/jb/usr/lib/ziyan/var
    LUA=/var/jb/usr/lib/ziyan/bin/lua5.3
    RUN=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
    LUALIB=/var/jb/usr/lib/ziyan/lib/lua
  else
    VAR=/usr/lib/ziyan/var
    LUA=/usr/lib/ziyan/bin/lua5.3
    RUN=/usr/lib/ziyan/lib/lua/ziyan_run.lua
    LUALIB=/usr/lib/ziyan/lib/lua
  fi
  BID=com.xztl.ios
  [[ "$script" == "ios8p.lua" ]] && BID=com.ljzbbadao.game
  echo "[launch] .$tag $script bid=$BID"
  scp_r "$src" "$ip" "/var/mobile/Media/ZiYan/$script"
  ssh_r "$ip" "SCHEME=$scheme SCRIPT=$script VAR=$VAR LUA=$LUA RUN=$RUN LUALIB=$LUALIB BID=$BID bash -s" <<'EOS' | tee "$OUT/launch_${tag}.txt"
set +e
MEDIA=/var/mobile/Media/ZiYan
if [ "$SCHEME" = rootless ]; then
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:$PATH
fi
# 清 stop，写 intent
rm -f "$VAR/.ziyan_stop" "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_app_user_closed"
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
rm -f "$VAR/.ziyan_light" "$VAR/.ziyan_embed_off"
echo 1 >"$VAR/.ziyan_embed_on"
chmod 666 "$VAR/.ziyan_embed_on" "$VAR/.ziyan_run_intent" 2>/dev/null
# 清桌面假命中残留
rm -f "$VAR/.ziyan_touch_req" /var/mobile/Media/ZiYan/.ziyan_touch_req
# 先 SB respring 仅 .166 若 AppTouch 缺失时由外层处理；此处拉游戏
"$LUA" -e "
package.path='$LUALIB/?.lua;$LUALIB/?/init.lua;$LUALIB/modules/?.lua;'..package.path
_G.ZIYAN_VAR='$VAR'; _G.ZIYAN_LUA='$LUALIB'
pcall(function()
  local App=require('modules.App')
  if App and App.launch then App.launch('$BID', 2000) end
end)
" >/dev/null 2>&1 || true
sleep 2
# 确保 AppTouch：写 open + 再 launch
echo "$BID" >"$VAR/.ziyan_open_app"
chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
sleep 1
LOGF="/tmp/${SCRIPT%.lua}_cold.log"
cd "$MEDIA" || exit 1
if command -v nohup >/dev/null 2>&1; then
  nohup "$LUA" "$RUN" "$MEDIA/$SCRIPT" >"$LOGF" 2>&1 </dev/null &
else
  nohup "$LUA" "$RUN" "$MEDIA/$SCRIPT" >"$LOGF" 2>&1 </dev/null &
fi
disown >/dev/null 2>&1 || true
sleep 2
N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_run.lua' | grep "$SCRIPT" | grep -v grep | wc -l | tr -d ' ')
echo "LUA_N=$N FRONT=$(cat $VAR/.ziyan_front_bid 2>/dev/null) APP_FG=$(test -f $VAR/.ziyan_app_fg && echo YES || echo NO)"
[ "$N" -ge 1 ] && echo LAUNCH_OK || echo LAUNCH_FAIL
EOS
}

launch_one 53 192.168.31.53 rootless ios8p.lua &
launch_one 101 192.168.31.101 rootful ios7.lua &
launch_one 112 192.168.31.112 rootful ios7.lua &
launch_one 166 192.168.31.166 rootful ios7.lua &
wait
echo "[warm] 15s for game+AppTouch..."
sleep 15

# .166 若仍无 AppTouch：SB 重载 + 重开游戏（禁 backboardd）
ssh_r 192.168.31.166 'bash -s' <<'EOS' | tee "$OUT/fixup_166_apptouch.txt"
set +e
VAR=/usr/lib/ziyan/var
FG=$(cat "$VAR/.ziyan_app_fg" 2>/dev/null)
ALIVE=$(cat "$VAR/.ziyan_app_alive" 2>/dev/null)
FRONT=$(cat "$VAR/.ziyan_front_bid" 2>/dev/null)
echo "pre FRONT=$FRONT FG_FILE=$(test -f $VAR/.ziyan_app_fg && ls -la $VAR/.ziyan_app_fg)"
# 新鲜 app_fg < 3s？
NOW=$(date +%s)
MT=$(stat -c %Y "$VAR/.ziyan_app_fg" 2>/dev/null || stat -f %m "$VAR/.ziyan_app_fg" 2>/dev/null || echo 0)
AGE=$((NOW-MT))
echo "app_fg_age=$AGE"
if [ ! -f "$VAR/.ziyan_app_fg" ] || [ "$AGE" -gt 5 ] || [ "$FRONT" = "com.apple.springboard" ]; then
  echo NEED_SB_AND_RELAUNCH
  killall -9 SpringBoard
  sleep 6
  echo com.xztl.ios >"$VAR/.ziyan_open_app"
  # relaunch via lua helper if present
  /usr/lib/ziyan/bin/lua5.3 -e "
package.path='/usr/lib/ziyan/lib/lua/?.lua;/usr/lib/ziyan/lib/lua/?/init.lua;/usr/lib/ziyan/lib/lua/modules/?.lua;'..package.path
_G.ZIYAN_VAR='$VAR'; _G.ZIYAN_LUA='/usr/lib/ziyan/lib/lua'
pcall(function() require('modules.App').launch('com.xztl.ios', 2000) end)
" >/dev/null 2>&1 || true
  sleep 4
  # 若脚本死了再拉
  N=$(ps -A -o command= | grep 'ziyan_run.lua' | grep ios7 | grep -v grep | wc -l | tr -d ' ')
  if [ "$N" -lt 1 ]; then
    cd /var/mobile/Media/ZiYan
    nohup /usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua /var/mobile/Media/ZiYan/ios7.lua >/tmp/ios7_cold.log 2>&1 </dev/null &
    sleep 2
  fi
fi
echo "post FRONT=$(cat $VAR/.ziyan_front_bid 2>/dev/null) LUA=$(ps -A -o command= | grep ziyan_run | grep -v grep | wc -l | tr -d ' ')"
EOS

sleep 8

# ── 4) 20s 并行对拍采样 ───────────────────────────────────────────
echo "======== PHASE4 20s PARALLEL SAMPLE ========"
sample_zy() {
  local tag="$1" ip="$2" scheme="$3"
  ssh_r "$ip" "SCHEME=$scheme TAG=$tag bash -s" <<'EOS' >"$OUT/zy${tag}.txt" 2>&1
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
else
  VAR=/usr/lib/ziyan/var
fi
echo "ZY.$TAG"
date
echo "FRONT=$(cat $VAR/.ziyan_front_bid 2>/dev/null)"
echo "APP_FG=$(test -f $VAR/.ziyan_app_fg && echo YES || echo NO)"
echo "LUA=$(ps -A -o command= | grep ziyan_run.lua | grep -v grep | wc -l | tr -d ' ')"
PERF=$VAR/.ziyan_p2_perf
COLOR=$VAR/.ziyan_color_perf
TOAST=$VAR/.ziyan_toast_dbg
# 优先 cycle/hit csv（若脚本写了）
HIT=/var/mobile/Media/ZiYan/tmp/zy_hit.csv
[ -f "$HIT" ] || HIT=$VAR/.ziyan_hit.csv
C0=$(wc -l <"$HIT" 2>/dev/null | tr -d ' '); C0=${C0:-0}
P0=$(wc -c <"$PERF" 2>/dev/null | tr -d ' '); P0=${P0:-0}
sleep 20
C1=$(wc -l <"$HIT" 2>/dev/null | tr -d ' '); C1=${C1:-0}
echo "DELTA_HIT_LINES=$((C1-C0))"
echo "TOAST=$(head -c 160 $TOAST 2>/dev/null | tr '\n' ' ')"
echo "TOUCH_STUCK=$(test -f $VAR/.ziyan_touch_req && echo YES || echo no)"
echo "LOG=$(tail -1 $VAR/.ziyan_touch_log 2>/dev/null)"
echo "PERF_TAIL="
tail -5 "$PERF" 2>/dev/null
echo "COLOR_PERF="
cat "$COLOR" 2>/dev/null | head -3
echo "P2="
cat "$PERF" 2>/dev/null | head -3
# 通用：从 framecap / init sync 估圈
echo "INIT=$(cat $VAR/.ziyan_init_sync 2>/dev/null)"
echo "FIND_VIA=$(cat $VAR/.ziyan_find_via 2>/dev/null)"
EOS
}

sample_ts() {
  ssh_r 192.168.31.171 'bash -s' <<'EOS' >"$OUT/ts171.txt" 2>&1
set +e
echo TS171
date
echo STATUS=$(wget -q -O - -T 1 http://127.0.0.1:50005/status 2>/dev/null)
HIT=/var/mobile/Media/TouchSprite/tmp/zy_ts_hit.csv
H0=$(wc -l <"$HIT" 2>/dev/null | tr -d ' '); H0=${H0:-0}
sleep 20
H1=$(wc -l <"$HIT" 2>/dev/null | tr -d ' '); H1=${H1:-0}
echo "DELTA=$((H1-H0))"
tail -12 "$HIT" 2>/dev/null
echo RUN_CFG=$(cat /var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null)
ps -A -o pid,%cpu,rss,command= | grep -iE 'TSDaemon|Hades' | grep -v grep
EOS
}

sample_zy 53 192.168.31.53 rootless &
sample_zy 101 192.168.31.101 rootful &
sample_zy 112 192.168.31.112 rootful &
sample_zy 166 192.168.31.166 rootful &
sample_ts &
wait

# ── 5) VERDICT ───────────────────────────────────────────────────
{
  echo "# VERDICT COLD_CMP $STAMP"
  echo
  echo "## 协议"
  echo "1. 四机冷启动：杀尽 lua/ZiYan/游戏 App + stop 标志"
  echo "2. .171 只读采集 + 随机 Home×3 观察触动变化（未部署 ZiYan）"
  echo "3. 四机 scp Desktop 脚本 → 拉游戏 → 20s 对拍"
  echo
  echo "## .171 Home 观察摘要"
  grep -E 'HOME_PRESS|STATUS=|HIT_LINES|HIT_GROW|RE_RUNNOW|HADES|LOG_BYTES|HIT_BYTES|TS171_OBSERVE' \
    "$OUT/ts171_home_observe.txt" | head -40
  echo
  echo "## 20s 对拍快照"
  for f in ts171 zy53 zy101 zy112 zy166; do
    echo "### $f"
    head -20 "$OUT/${f}.txt" 2>/dev/null || echo MISSING
    echo
  done
  echo "## 人工观察门槛"
  echo "- 四机 FRONT 须为游戏（非 SpringBoard）；APP_FG=YES"
  echo "- 对照 .171 DELTA 与 find ms；ZiYan 找色应不慢于触动"
  echo "- 证据目录：\`$OUT\`"
} | tee "$OUT/VERDICT.md"

echo "DONE VERDICT=$OUT/VERDICT.md"
