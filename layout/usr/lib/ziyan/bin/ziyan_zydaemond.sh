#!/bin/sh
# ZiYan ZyDaemon · 业务脚本保活 + 帧 shm 维护 + framecap 护活（8-140 P3）
# 架构依据：REPORT_STABILITY_ARCHITECTURE.md §3 ZyDaemon
# 目标：跑业务脚本时永远不因「脚本死/帧囤在 SB」而重启 SpringBoard
#  - 本进程：KeepAlive；管 Lua 子进程 + .ziyan_frame_shm 权限 + framecap 心跳
#  - 截屏/找色匹配：framecap；SB 仅冷帧配额中继 + 音量/触控/图标硬锁
# 约束：不改 Desktop ios7/ios8p；不碰四大硬锁；不 kill SpringBoard

export PATH="/var/jb/bin:/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

ROOT=/usr/lib/ziyan
for helper in /usr/lib/ziyan/bin/ziyan_runtime_root.sh \
              /var/jb/usr/lib/ziyan/bin/ziyan_runtime_root.sh; do
  [ -r "$helper" ] || continue
  . "$helper"
  break
done
ROOT="${ZIYAN_RUNTIME_ROOT:-$ROOT}"
ROOTLESS=0
case "$ROOT" in /var/jb/*) ROOTLESS=1 ;; esac
VAR="$ROOT/var"
LUA="$ROOT/bin/lua5.3"
RUN="$ROOT/lib/lua/ziyan_run.lua"
if [ "$ROOTLESS" = "1" ]; then
  FRAMECAP_PLIST=/var/jb/Library/LaunchDaemons/com.ziyan.framecap.plist
else
  FRAMECAP_PLIST=/Library/LaunchDaemons/com.ziyan.framecap.plist
fi
export DYLD_LIBRARY_PATH="$ROOT/lib"

MEDIA=/var/mobile/Media/ZiYan
INTENT="$VAR/.ziyan_run_intent"
COLOR="$VAR/.ziyan_color_perf"
HUNG="$VAR/.ziyan_lua_hung"
LOG="$VAR/.ziyan_zydaemon_log"
PIDF="$VAR/.ziyan_zydaemon.pid"
ALIVE="$VAR/.ziyan_zydaemon_alive"
LOCKDIR="$VAR/.ziyan_zydaemon.lock"
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
  rmdir "$LOCKDIR" 2>/dev/null || true
  exit $code
}
trap cleanup $signals

mkdir -p "$VAR" 2>/dev/null
# launchd KeepAlive can briefly start a second copy while the first one is
# still unwinding.  Use an atomic mkdir lock (available on the minimal
# rootful images) so only one daemon may own revive/framecap decisions.  A
# SIGKILL/Jetsam bypasses cleanup(), however, so a lock is valid only if its
# recorded PID is still alive; otherwise reclaim that stale lock once.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  existing=""
  [ -f "$PIDF" ] && existing=$(cat "$PIDF" 2>/dev/null | head -1)
  case "$existing" in
    ''|*[!0-9]*) alive=0 ;;
    *) kill -0 "$existing" 2>/dev/null && alive=1 || alive=0 ;;
  esac
  if [ "${alive:-0}" = "1" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') zydaemon_duplicate_exit existing_pid=$existing" >>"$LOG" 2>/dev/null || true
    exit 0
  fi
  rmdir "$LOCKDIR" 2>/dev/null || true
  rm -f "$PIDF" 2>/dev/null || true
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') zydaemon_lock_reclaim_failed stale_pid=${existing:-unknown}" >>"$LOG" 2>/dev/null || true
    exit 0
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') zydaemon_stale_lock_reclaimed stale_pid=${existing:-unknown}" >>"$LOG" 2>/dev/null || true
fi
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

# framecap 不能直接由 iOS 13 的 LaunchDaemon 槽位启动：该槽位在 dyld/Objective-C
# 初始化前就有 6MB jetsam 上限。由 zydaemon 唯一拉起子进程，禁 launchd 竞争。
framecap_heartbeat_fresh() {
  ts=$(sed -n 's/^ts=\([0-9][0-9]*\).*/\1/p' "$FRAMECAP_ALIVE" 2>/dev/null | head -1 | tr -dc '0-9')
  now_hb=$($DATE '+%s' 2>/dev/null || echo 0)
  [ -n "$ts" ] && [ -n "$now_hb" ] && [ "$now_hb" -gt 0 ] && \
    [ $((now_hb - ts)) -le 45 ] 2>/dev/null
}

# 8-140：护 framecap KeepAlive；心跳文件 >45s 未刷新则由本守护重启（不杀 SB）
# 8-146：SB Watchdog 只写 .ziyan_watchdog_framecap_need；本函数消费。
ensure_framecap() {
  # 已有 framecap 时先去重；只有“明确请求 + 心跳过期”才重启。
  # 计数用 tr 压成单行，禁 grep -c||echo 双 0 导致误判死
  fc_n=$($PS -A -o command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -vc grep | tr -dc '0-9')
  [ -n "$fc_n" ] || fc_n=0
  need=0
  [ -f "$VAR/.ziyan_watchdog_framecap_need" ] && need=1
  if [ "$fc_n" -ge 1 ] 2>/dev/null; then
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
    if [ "$need" != "1" ] || framecap_heartbeat_fresh; then
      rm -f "$VAR/.ziyan_watchdog_framecap_need" 2>/dev/null
      return 0
    fi
    stale_pid=$($PS -A -o pid=,command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
    case "$stale_pid" in
      *[!0-9]*|"") log "framecap_stale_need_no_pid" ;;
      *)
        log "framecap_stale_restart pid=$stale_pid"
        kill "$stale_pid" 2>/dev/null || true
        $SLEEP 2
        kill -0 "$stale_pid" 2>/dev/null && kill -9 "$stale_pid" 2>/dev/null || true
        $SLEEP 1
        ;;
    esac
    fc_n=$($PS -A -o command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -vc grep | tr -dc '0-9')
    [ -n "$fc_n" ] || fc_n=0
    [ "$fc_n" -ge 1 ] 2>/dev/null && return 0
  fi
  # 进程不在 → 拉子进程（限频：常态 60s；need 时 15s）。
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
  FCBIN="$ROOT/bin/ziyan_framecap"
  FCBOOT="${FCBIN%/*}/ziyan_framecap_bootstrap"
  if [ -x "$FCBIN" ]; then
    rm -f "$VAR/.ziyan_framecap_serve.lock" "$VAR/.ziyan_framecap_wrap.pid" 2>/dev/null
    if [ -x "$FCBOOT" ]; then
      nohup "$FCBOOT" "$FCBIN" serve >>"$VAR/.ziyan_framecap_out" 2>>"$VAR/.ziyan_framecap_err" </dev/null &
    else
      nohup "$FCBIN" serve >>"$VAR/.ziyan_framecap_out" 2>>"$VAR/.ziyan_framecap_err" </dev/null &
    fi
    echo "pid=$! ts=$now owner=zydaemon" >"$VAR/.ziyan_framecap_owner" 2>/dev/null || true
    echo "zydaemon" >"$VAR/.ziyan_framecap_owner_mode" 2>/dev/null || true
    chmod 666 "$VAR/.ziyan_framecap_owner" "$VAR/.ziyan_framecap_owner_mode" 2>/dev/null || true
    log "framecap_spawn_zydaemon pid=$! need=$need"
    $SLEEP 2
    fc_n2=$($PS -A -o command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -vc grep | tr -dc '0-9')
    [ -n "$fc_n2" ] || fc_n2=0
    if [ "$fc_n2" -lt 1 ] 2>/dev/null; then
      echo 1 >"$VAR/.ziyan_watchdog_framecap_need" 2>/dev/null
      log "framecap_spawn_pending still_dead need_rewritten=1"
    fi
  else
    log "framecap_spawn_skip missing_bin=$FCBIN"
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
  raw=$(sed -n 's/^path=//p' "$INTENT" 2>/dev/null | head -1)
  [ -n "$raw" ] || return 0
  # Canonicalize /private/var and the historical lua/ mirror to one real
  # Media/ZiYan file.  Keep the original only when no canonical copy exists.
  case "$raw" in /private/var/*) raw="/var/${raw#/private/var/}" ;; esac
  base=${raw##*/}
  for candidate in "$MEDIA/$base" "$MEDIA/lua/$base" "$raw" "/private$raw"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate" >"$VAR/.ziyan_run_canonical" 2>/dev/null || true
      chmod 666 "$VAR/.ziyan_run_canonical" 2>/dev/null || true
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$raw"
}

# Missing script: one log + idle/stop, never revive-spin.
retire_missing_intent() {
  sp="$1"
  base=$(basename "$sp")
  mark="$VAR/.ziyan_intent_stale_missing"
  prev=$(cat "$mark" 2>/dev/null | head -1)
  if [ "$prev" != "$sp" ]; then
    log "stale_intent_missing $sp"
    printf '%s\n' "$sp" >"$mark" 2>/dev/null || true
    chmod 666 "$mark" 2>/dev/null || true
  fi
  printf 'stop=1\nstate=idle\nreason=stale_intent_missing\npath=%s\n' "$sp" >"$INTENT" 2>/dev/null || true
  chmod 666 "$INTENT" 2>/dev/null || true
  printf 'state=idle\npath=\norient=-1\n' >"$VAR/.ziyan_session" 2>/dev/null || true
  case "$base" in
    _zy_page_entry_selftest.lua|_cursor_run_smoke.lua)
      emb=$(cat "$VAR/.ziyan_embed_script" 2>/dev/null | head -1)
      embbase=$(basename "$emb")
      if [ "$embbase" = "$base" ]; then
        rm -f "$VAR/.ziyan_embed_go" "$VAR/.ziyan_embed_script" \
          "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded" \
          "$VAR/.ziyan_page_selftest_req" "$VAR/.ziyan_page_selftest_log" \
          2>/dev/null || true
      fi
      ;;
  esac
}

lua_running_for() {
  sp="$1"
  base=$(basename "$sp")
  # 心跳格式会带其它数字，例如 "ts=... pid=..."、"ts=... n=..."。
  # 只能捕获 ts 的首个整数；tr -dc 会把 pid/n 拼进去，得到未来时间戳，
  # 从而把死掉的 embed/pulse 永久误判为存活，业务脚本不会被 revive。
  read_ts() {
    sed -n 's/^ts=\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1
  }
  # 8-161-101 Phase2：embed-in-framecap = 存活（对标 TSDaemon；无独立 lua 进程）
  if [ -f "$VAR/.ziyan_lua_embedded" ] || [ -f "$VAR/.ziyan_embed_alive" ]; then
    # embed_alive 过期则不当存活（避免假活挡 revive）
    if [ -f "$VAR/.ziyan_embed_alive" ]; then
      ats=$(read_ts "$VAR/.ziyan_embed_alive")
      now=$($DATE '+%s' 2>/dev/null || echo 0)
      if [ -n "$ats" ] && [ -n "$now" ] && [ "$now" -gt 0 ] && \
          [ "$now" -ge "$ats" ] 2>/dev/null && [ $((now - ats)) -le 30 ] 2>/dev/null; then
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
    pts=$(read_ts "$VAR/.ziyan_find_pulse")
    now=$($DATE '+%s' 2>/dev/null || echo 0)
    if [ -n "$pts" ] && [ -n "$now" ] && [ "$now" -gt 0 ] && \
        [ "$now" -ge "$pts" ] 2>/dev/null && [ $((now - pts)) -le 20 ] 2>/dev/null; then
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
  canonical=$(cat "$VAR/.ziyan_run_canonical" 2>/dev/null | head -1)
  if [ -n "$canonical" ] && [ -f "$canonical" ] && [ "$(basename "$canonical")" = "$base" ]; then
    sp="$canonical"
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
    # Do not enqueue another go while the same VM/request is still alive.
    if lua_running_for "$sp" >/dev/null 2>&1; then
      log "revive_skip already_alive script=$base"
      return 0
    fi
    nonce="zydaemon_$$_$($DATE '+%s')"
    printf '%s\n' "$sp" >"$VAR/.ziyan_embed_script" 2>/dev/null
    printf 'nonce=%s\nrequest_id=%s\nsession_id=%s\n' "$nonce" "$nonce" "$nonce" >"$VAR/.ziyan_embed_go" 2>/dev/null
    echo "nonce=$nonce script=$sp" >"$VAR/.ziyan_embed_last_go" 2>/dev/null
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
  if [ ! -f "$SP" ]; then
    retire_missing_intent "$SP"
    STUCK=0
    PREV_CALLS=""
    $SLEEP 5
    continue
  fi
  rm -f "$VAR/.ziyan_intent_stale_missing" 2>/dev/null || true
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
