#!/bin/sh
# ZiYan ZyDaemon · 业务脚本保活 + 帧 shm 维护 + framecap 护活（8-140 P3）
# 架构依据：REPORT_STABILITY_ARCHITECTURE.md §3 ZyDaemon
# 目标：跑业务脚本时永远不因「脚本死/帧囤在 SB」而重启 SpringBoard
#  - 本进程：KeepAlive；管 Lua 子进程 + .ziyan_frame_shm 权限 + framecap 心跳
#  - 截屏/找色匹配：framecap；SB 仅冷帧配额中继 + 音量/触控/图标硬锁
# 约束：不改 Desktop ios7/ios8p；不碰四大硬锁；不 kill SpringBoard

export PATH="/var/jb/bin:/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

ROOTLESS=0
[ -d /var/jb/usr/lib/ziyan ] && ROOTLESS=1

if [ "$ROOTLESS" = "1" ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  LUA=/var/jb/usr/lib/ziyan/bin/lua5.3
  RUN=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
  FRAMECAP_PLIST=/var/jb/Library/LaunchDaemons/com.ziyan.framecap.plist
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib
else
  VAR=/usr/lib/ziyan/var
  LUA=/usr/lib/ziyan/bin/lua5.3
  RUN=/usr/lib/ziyan/lib/lua/ziyan_run.lua
  FRAMECAP_PLIST=/Library/LaunchDaemons/com.ziyan.framecap.plist
fi

MEDIA=/var/mobile/Media/ZiYan
INTENT="$VAR/.ziyan_run_intent"
COLOR="$VAR/.ziyan_color_perf"
HUNG="$VAR/.ziyan_lua_hung"
LOG="$VAR/.ziyan_zydaemon_log"
PIDF="$VAR/.ziyan_zydaemon.pid"
ALIVE="$VAR/.ziyan_zydaemon_alive"
SHM="$VAR/.ziyan_frame_shm"
FRAMECAP_ALIVE="$VAR/.ziyan_framecap_alive"
PAUSE="$VAR/.ziyan_paused"
STOPF="$VAR/.ziyan_stop"

SLEEP=$(command -v sleep 2>/dev/null || echo /bin/sleep)
PS=$(command -v ps 2>/dev/null || echo /bin/ps)
DATE=$(command -v date 2>/dev/null || echo /bin/date)
LAUNCHCTL=$(command -v launchctl 2>/dev/null || echo /bin/launchctl)

signals="1 2 3 15"
cleanup() {
  code=$?
  trap - $signals
  rm -f "$PIDF" 2>/dev/null
  exit $code
}
trap cleanup $signals

mkdir -p "$VAR" 2>/dev/null
echo $$ >"$PIDF" 2>/dev/null

log() {
  echo "$($DATE '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG" 2>/dev/null
  if [ -f "$LOG" ]; then
    sz=$(wc -c <"$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt 65536 ] 2>/dev/null; then
      tail -c 8192 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
  fi
}

ensure_shm() {
  # 仅保证 inode/权限；像素由 ScreenBridge/framecap 写入。daemon 不截屏。
  if [ ! -f "$SHM" ]; then
    touch "$SHM" 2>/dev/null || true
  fi
  chmod 666 "$SHM" 2>/dev/null || true
  if [ ! -f "$INTENT" ] && [ -f "$SHM" ]; then
    sz=$(wc -c <"$SHM" 2>/dev/null || echo 0)
    if [ "$sz" -gt 33554432 ] 2>/dev/null; then
      # 8-143：禁止 : > 截断活 inode（SB mmap → SIGBUS）；改用临时文件+rename
      tmp="$SHM.clr.$$.tmp"
      : >"$tmp" 2>/dev/null
      mv -f "$tmp" "$SHM" 2>/dev/null || rm -f "$tmp" 2>/dev/null
      chmod 666 "$SHM" 2>/dev/null || true
      log "shm_replace_empty idle oversized"
    fi
  fi
}

# 8-140：护 framecap KeepAlive；心跳文件 >45s 未刷新则 kickstart（不杀 SB）
# 8-146：SB Watchdog 只写 .ziyan_watchdog_framecap_need；本函数消费并 kick
ensure_framecap() {
  # 8-161-45 / 142：已有 framecap 则禁止再 kick（防 unload 杀热路径）
  # 计数用 tr 压成单行，禁 grep -c||echo 双 0 导致误判死
  fc_n=$($PS -A -o command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -vc grep | tr -dc '0-9')
  [ -n "$fc_n" ] || fc_n=0
  need=0
  [ -f "$VAR/.ziyan_watchdog_framecap_need" ] && need=1
  if [ "$fc_n" -ge 1 ] 2>/dev/null; then
    rm -f "$VAR/.ziyan_watchdog_framecap_need" 2>/dev/null
    if [ "$fc_n" -ge 2 ] 2>/dev/null; then
      keep=""
      for pid in $($PS -A -o pid=,command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -v grep | sed 's/^ *//' | cut -d' ' -f1); do
        if [ -z "$keep" ]; then
          keep=$pid
        else
          kill -9 "$pid" 2>/dev/null
          log "framecap_dedupe_kill pid=$pid keep=$keep"
        fi
      done
    fi
    return 0
  fi
  # 进程不在 → kickstart（限频：常态 60s；need 时 15s；禁 unload 活杀）
  now=$($DATE '+%s' 2>/dev/null || echo 0)
  lastf="$VAR/.ziyan_zydaemon_fc_kick"
  last=0
  [ -f "$lastf" ] && last=$(cat "$lastf" 2>/dev/null | tr -dc '0-9')
  [ -n "$last" ] || last=0
  gap=$((now - last))
  min_gap=60
  [ "$need" = "1" ] && min_gap=15
  if [ "$gap" -lt "$min_gap" ] 2>/dev/null; then
    rm -f "$VAR/.ziyan_watchdog_framecap_need" 2>/dev/null
    return 0
  fi
  echo "$now" >"$lastf" 2>/dev/null
  rm -f "$VAR/.ziyan_watchdog_framecap_need" 2>/dev/null
  # 182：kickstart 可能 pending/6MB 杀；短等后仍无进程 → 手搓 orphan serve
  # （framecap 入口 memorystatus 自抬 jetsam；禁 kickstart -k 挂死）
  if [ "$ROOTLESS" = "1" ]; then
    FCBIN=/var/jb/usr/lib/ziyan/bin/ziyan_framecap
  else
    FCBIN=/usr/lib/ziyan/bin/ziyan_framecap
  fi
  if [ -f "$FRAMECAP_PLIST" ]; then
    $LAUNCHCTL kickstart system/com.ziyan.framecap 2>/dev/null \
      || $LAUNCHCTL kickstart com.ziyan.framecap 2>/dev/null \
      || { $LAUNCHCTL load "$FRAMECAP_PLIST" 2>/dev/null; }
    log "framecap_kickstart plist=$FRAMECAP_PLIST need=$need"
    $SLEEP 2
  fi
  fc_n2=$($PS -A -o command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -vc grep | tr -dc '0-9')
  [ -n "$fc_n2" ] || fc_n2=0
  if [ "$fc_n2" -lt 1 ] 2>/dev/null && [ -x "$FCBIN" ]; then
    rm -f "$VAR/.ziyan_framecap_serve.lock" "$VAR/.ziyan_framecap_wrap.pid" 2>/dev/null
    nohup "$FCBIN" serve >/dev/null 2>&1 </dev/null &
    log "framecap_spawn_orphan pid=$! need=$need"
  fi
}

intent_active() {
  [ -f "$INTENT" ] || return 1
  grep -q '^stop=1' "$INTENT" 2>/dev/null && return 1
  [ -f "$STOPF" ] && return 1
  [ -f "$VAR/.ziyan_user_stopped" ] && return 1
  return 0
}

script_path_from_intent() {
  sed -n 's/^path=//p' "$INTENT" 2>/dev/null | head -1
}

lua_running_for() {
  sp="$1"
  base=$(basename "$sp")
  # 8-161-101 Phase2：embed-in-framecap = 存活（对标 TSDaemon；无独立 lua 进程）
  if [ -f "$VAR/.ziyan_lua_embedded" ] || [ -f "$VAR/.ziyan_embed_alive" ]; then
    # embed_alive 过期则不当存活（避免假活挡 revive）
    if [ -f "$VAR/.ziyan_embed_alive" ]; then
      ats=$(sed -n 's/^ts=//p' "$VAR/.ziyan_embed_alive" 2>/dev/null | head -1 | tr -dc '0-9')
      now=$($DATE '+%s' 2>/dev/null || echo 0)
      if [ -n "$ats" ] && [ -n "$now" ] && [ "$now" -gt 0 ] && [ $((now - ats)) -gt 30 ]; then
        : # stale → fall through to process check / miss
      else
        echo "embed:$base"
        return 0
      fi
    elif [ -f "$VAR/.ziyan_lua_embedded" ]; then
      echo "embed:$base"
      return 0
    fi
  fi
  # 142：find_pulse 新鲜 = 业务热扫仍在（对标触动 f01；禁路径抖动误 revive）
  if [ -f "$VAR/.ziyan_find_pulse" ]; then
    pts=$(sed -n 's/^ts=//p' "$VAR/.ziyan_find_pulse" 2>/dev/null | head -1 | tr -dc '0-9')
    now=$($DATE '+%s' 2>/dev/null || echo 0)
    if [ -n "$pts" ] && [ -n "$now" ] && [ "$now" -gt 0 ] && [ $((now - pts)) -le 20 ]; then
      echo "pulse:$base"
      return 0
    fi
  fi
  $PS -A -o pid=,command= 2>/dev/null | grep -F "ziyan_run.lua" | grep -F "$base" | grep -v grep | head -1
}

color_calls() {
  [ -f "$COLOR" ] || { echo ""; return; }
  sed -n 's/.*calls=\([0-9][0-9]*\).*/\1/p' "$COLOR" 2>/dev/null | head -1
}

revive() {
  sp="$1"
  [ -f "$sp" ] || { log "revive_skip missing $sp"; return 1; }
  # 归一到 Media/ZiYan 扁平路径（与 scripts scp / embed Normalize 一致）
  base=$(basename "$sp")
  if [ -f "$MEDIA/$base" ]; then
    sp="$MEDIA/$base"
  fi
  # 8-146：mem_cooldown 只约束 SB 截屏，不挡 lua 拉起（否则故障注入/守护 SLA 永远失败）
  if [ -f "$VAR/.ziyan_sb_mem_cooldown" ]; then
    log "revive_note mem_cooldown_present still_revive script=$base"
    rm -f "$HUNG" 2>/dev/null
    rm -f "$VAR/.ziyan_color_req" 2>/dev/null
  fi
  $PS -A -o pid=,command= 2>/dev/null | grep -F "ziyan_run.lua" | grep -F "$base" | grep -v grep | while read -r pid rest; do
    kill -9 "$pid" 2>/dev/null
  done
  rm -f "$HUNG" 2>/dev/null
  rm -f "$VAR/.ziyan_color_req" "$VAR/.ziyan_color_rep" 2>/dev/null
  # 193 / E1：产品路径只走 embed；无 alive 则等 framecap，禁独立 lua 热路径
  if [ -f "$VAR/.ziyan_embed_off" ]; then
    cd "$MEDIA" || true
    nohup "$LUA" "$RUN" "$sp" >/tmp/ziyan_zydaemon_${base}.log 2>&1 </dev/null &
    log "revive_lua_debug_embed_off $base pid=$!"
    return 0
  fi
  if [ -f "$FRAMECAP_ALIVE" ]; then
    printf '%s\n' "$sp" >"$VAR/.ziyan_embed_script" 2>/dev/null
    echo "nonce=zydaemon_$$" >"$VAR/.ziyan_embed_go" 2>/dev/null
    chmod 666 "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" 2>/dev/null || true
    log "revive_embed $base"
    return 0
  fi
  log "revive_skip_embed_required framecap_not_alive $base"
  return 1
}

heartbeat() {
  echo "$($DATE '+%Y-%m-%d %H:%M:%S') pid=$$ rootless=$ROOTLESS" >"$ALIVE" 2>/dev/null
  chmod 666 "$ALIVE" 2>/dev/null || true
  # 8-142：终稿心跳别名，供 ZiyanProcessWatchdog 统一读
  echo "$($DATE '+%Y-%m-%d %H:%M:%S') pid=$$ rootless=$ROOTLESS" >"$VAR/.ziyan_heartbeat_daemon" 2>/dev/null
  chmod 666 "$VAR/.ziyan_heartbeat_daemon" 2>/dev/null || true
}

PREV_CALLS=""
STUCK=0
LAST_ICON_TICK=0
LAST_BOOT_TS=""
LAST_SB_STATS_TS=""
ICON_PREV_SESSION=0

# 8-147 / P2：Icon 边沿 → 写 hide/restore_req（SB 只执行 UI/Hook）
icon_edge_poll() {
  now=$($DATE '+%s' 2>/dev/null || echo 0)
  gap=$((now - LAST_ICON_TICK))
  [ "$gap" -lt 5 ] 2>/dev/null && return 0
  LAST_ICON_TICK=$now
  sess=0
  [ -f "$VAR/.ziyan_app_session" ] && sess=1
  [ -f "$MEDIA/.ziyan_app_session" ] && sess=1
  [ -f "$MEDIA/ZYCV/res/.ziyan_app_session" ] && sess=1
  hiding=0
  [ -f "$MEDIA/.ziyan_jb_icons_hidden" ] && hiding=1
  [ -f "$MEDIA/ZYCV/res/.ziyan_jb_icons_hidden" ] && hiding=1
  if [ "$sess" = "1" ] && [ "$ICON_PREV_SESSION" = "0" ]; then
    echo 1 >"$VAR/.ziyan_icon_hide_req" 2>/dev/null
    chmod 666 "$VAR/.ziyan_icon_hide_req" 2>/dev/null || true
    log "icon_edge hide_req"
  fi
  if [ "$sess" = "0" ] && [ "$ICON_PREV_SESSION" = "1" ]; then
    echo 1 >"$VAR/.ziyan_icon_restore_req" 2>/dev/null
    chmod 666 "$VAR/.ziyan_icon_restore_req" 2>/dev/null || true
    log "icon_edge restore_req"
  fi
  if [ "$sess" = "1" ] && [ "$hiding" = "0" ]; then
    # 丢边沿兜底
    echo 1 >"$VAR/.ziyan_icon_hide_req" 2>/dev/null
    chmod 666 "$VAR/.ziyan_icon_hide_req" 2>/dev/null || true
  fi
  ICON_PREV_SESSION=$sess
}

# 8-147：SB boot 标记变化 → 清快照/大图（原 BootRecovery.clearExpired）
boot_cleanup_poll() {
  bootf="$VAR/.ziyan_sb_boot_ts"
  [ -f "$bootf" ] || return 0
  cur=$(cat "$bootf" 2>/dev/null | head -1)
  [ -n "$cur" ] || return 0
  if [ "$cur" = "$LAST_BOOT_TS" ]; then
    return 0
  fi
  LAST_BOOT_TS=$cur
  # 损坏快照
  snap="$VAR/.ziyan_run_snapshot.json"
  if [ -f "$snap" ]; then
    # 非 JSON 对象则丢
    head -c 1 "$snap" 2>/dev/null | grep -q '{' || rm -f "$snap" 2>/dev/null
  fi
  echo 1 >"$VAR/.ziyan_release_screen" 2>/dev/null
  # 清过大临时图
  for d in "$MEDIA/ZYCV" "$MEDIA/ZYCV/res"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.png "$d"/*.jpg; do
      [ -f "$f" ] || continue
      sz=$(wc -c <"$f" 2>/dev/null || echo 0)
      if [ "$sz" -gt 262144 ] 2>/dev/null; then
        rm -f "$f" 2>/dev/null
      fi
    done
  done
  echo "ts=$cur ok=1" >"$VAR/.ziyan_boot_cleanup_daemon" 2>/dev/null
  log "boot_cleanup ts=$cur"
}

# 8-147：统计计数仍由 SB toast/HUD 写；daemon 只做镜像备份（防丢）
sb_restart_stats_poll() {
  STATF=/var/mobile/ZiYan/sb_restart_stats.txt
  [ -f "$STATF" ] || return 0
  # 镜像到 var（引擎可读）；不二次累加
  cp -f "$STATF" "$VAR/.ziyan_sb_restart_stats" 2>/dev/null || true
  chmod 666 "$VAR/.ziyan_sb_restart_stats" 2>/dev/null || true
}

# 8-147：性能脉冲（供四机指标）
perf_pulse() {
  now=$($DATE '+%s' 2>/dev/null || echo 0)
  color=$(cat "$COLOR" 2>/dev/null | head -c 160)
  hid=$(cat "$VAR/.ziyan_hid_perf" 2>/dev/null | head -c 80)
  hook=$(cat "$VAR/.ziyan_frame_hook_alive" 2>/dev/null | head -c 80)
  rss=0
  # SB RSS（若可读）
  sbp=$($PS -A -o pid=,rss=,args= 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1)
  # rss 单位 KB
  rss=$(echo "$sbp" | sed 's/^ *//;s/  */ /g' | cut -d' ' -f2)
  [ -z "$rss" ] && rss=0
  echo "ts=$now rss_kb=$rss color={$color} hid={$hid} hook={$hook}" >"$VAR/.ziyan_p2_perf" 2>/dev/null
  chmod 666 "$VAR/.ziyan_p2_perf" 2>/dev/null || true
}

log "zydaemon_start rootless=$ROOTLESS step=8-147"
ensure_shm
ensure_framecap
heartbeat
boot_cleanup_poll
icon_edge_poll

while true; do
  ensure_shm
  ensure_framecap
  heartbeat
  icon_edge_poll
  boot_cleanup_poll
  sb_restart_stats_poll
  perf_pulse
  if [ -f "$PAUSE" ]; then
    $SLEEP 15
    continue
  fi
  if ! intent_active; then
    STUCK=0
    PREV_CALLS=""
    $SLEEP 5
    continue
  fi
  SP=$(script_path_from_intent)
  if [ -z "$SP" ]; then
    # 8-146：intent 活跃但缺 path → 短睡，避免 15s 盲等拖垮故障注入 SLA
    $SLEEP 2
    continue
  fi
  LINE=$(lua_running_for "$SP")
  CALLS=$(color_calls)
  NEED=0
  # 8-142：SB Watchdog 发现 lua 死 → 写 kick 旗，本圈立刻 revive
  if [ -f "$VAR/.ziyan_watchdog_lua_kick" ]; then
    rm -f "$VAR/.ziyan_watchdog_lua_kick" 2>/dev/null
    if [ -z "$LINE" ]; then
      NEED=1
      log "watchdog_lua_kick script=$SP"
    fi
  fi
  if [ -z "$LINE" ]; then
    NEED=1
    log "detect down script=$SP"
  elif [ -f "$HUNG" ]; then
    # 8-140：lua 仍在跑 → 清 hung，禁止误 revive（color_perf 稀疏写假阳性）
    rm -f "$HUNG" 2>/dev/null
    log "hung_clear lua_alive script=$SP"
  elif [ -n "$CALLS" ] && [ "$CALLS" = "$PREV_CALLS" ]; then
    STUCK=$((STUCK + 1))
    # 8-140：3→10 tick（~150s），且仍要求 lua 进程存在时不因 calls 平坦杀进程
    # 仅当 calls 平坦且后续仍无进程才会走 down 分支；此处仅记日志
    if [ "$STUCK" -ge 10 ]; then
      log "color_calls_flat calls=$CALLS script=$SP (no_revive_lua_alive)"
      STUCK=0
    fi
  else
    STUCK=0
  fi
  PREV_CALLS=$CALLS
  if [ "$NEED" = "1" ]; then
    revive "$SP"
    STUCK=0
    PREV_CALLS=""
    # 8-146：revive 后短确认窗（原 8s 易叠加上轮询超过 5s SLA）
    $SLEEP 2
  else
    # 8-146 / P2：intent 活跃时 2s 巡检（原 15s）；空闲仍见上
    $SLEEP 2
  fi
done
