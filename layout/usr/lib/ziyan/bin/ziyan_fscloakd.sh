#!/var/jb/bin/sh
# ZiYan FsCloakd 8-122 · LOCK_ICON_HIDE（hide-once 性能优化）
# 手签2 锁定语义（不变）：
#   - 开 App（.ziyan_app_session）→ desk_hide 越狱图标（保 ZiYan）一次
#   - Home 最小化 → 保持隐藏（session 粘性；勿因 ps/心跳抖动 desk_SHOW）
#   - 关程序 / willTerminate / 冷启无 session → desk_restore
#   - 禁止 rename afc2d / 禁止 kill lockdownd
# 8-122：已隐藏后禁止每秒 ps/desk_hide/uicache（与找色抢 IO·CPU；用户诊断）

export PATH="/var/jb/bin:/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

FLAG_ROOTFUL="/usr/lib/ziyan/var/.ziyan_fs_cloak"
FLAG_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_fs_cloak"
FLAG_MEDIA="/var/mobile/Media/ZiYan/ZYCV/res/defense_fs_cloak.txt"
FLAG_MEDIA_LEGACY="/var/mobile/Media/ZiYan/defense_fs_cloak.txt"
REQ_RESTORE_ROOTFUL="/usr/lib/ziyan/var/.ziyan_fs_cloak_restore_req"
REQ_RESTORE_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_fs_cloak_restore_req"
REQ_HIDE_ROOTFUL="/usr/lib/ziyan/var/.ziyan_fs_cloak_hide_req"
REQ_HIDE_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_fs_cloak_hide_req"
ICON_HIDE_REQ_ROOTFUL="/usr/lib/ziyan/var/.ziyan_icon_hide_req"
ICON_HIDE_REQ_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_icon_hide_req"
SESSION_ROOTFUL="/usr/lib/ziyan/var/.ziyan_app_session"
SESSION_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_app_session"
SESSION_MEDIA="/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"
SESSION_MEDIA_LEGACY="/var/mobile/Media/ZiYan/.ziyan_app_session"
HIDE_ROOTFUL="/usr/lib/ziyan/var/.ziyan_jb_icons_hidden"
HIDE_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_jb_icons_hidden"
HIDE_MEDIA="/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"
HIDE_MEDIA_LEGACY="/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"
HB_ROOTFUL="/usr/lib/ziyan/var/.ziyan_app_heartbeat"
HB_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_app_heartbeat"
HB_MEDIA="/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_heartbeat"
HB_MEDIA_LEGACY="/var/mobile/Media/ZiYan/.ziyan_app_heartbeat"
APP_FG_ROOTFUL="/usr/lib/ziyan/var/.ziyan_app_fg"
APP_FG_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_app_fg"
LOG_ROOTFUL="/usr/lib/ziyan/var/.ziyan_fs_cloakd_log"
LOG_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_fs_cloakd_log"
LOCK_ROOTFUL="/usr/lib/ziyan/var/.ziyan_fscloakd.lock"
LOCK_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_fscloakd.lock"
USER_CLOSED_ROOTFUL="/usr/lib/ziyan/var/.ziyan_app_user_closed"
USER_CLOSED_ROOTLESS="/var/jb/usr/lib/ziyan/var/.ziyan_app_user_closed"

SLEEP=$(command -v sleep 2>/dev/null || true)
[ -z "$SLEEP" ] && [ -x /var/jb/bin/sleep ] && SLEEP=/var/jb/bin/sleep
[ -z "$SLEEP" ] && SLEEP=/bin/sleep

MV=$(command -v mv 2>/dev/null || true)
[ -z "$MV" ] && [ -x /var/jb/bin/mv ] && MV=/var/jb/bin/mv
[ -z "$MV" ] && MV=/bin/mv

RM=$(command -v rm 2>/dev/null || true)
[ -z "$RM" ] && RM=/bin/rm

PS=$(command -v ps 2>/dev/null || true)
[ -z "$PS" ] && [ -x /bin/ps ] && PS=/bin/ps
[ -z "$PS" ] && [ -x /var/jb/bin/ps ] && PS=/var/jb/bin/ps

DATE=$(command -v date 2>/dev/null || true)
[ -z "$DATE" ] && [ -x /var/jb/bin/date ] && DATE=/var/jb/bin/date
[ -z "$DATE" ] && DATE=/bin/date

UICACHE=$(command -v uicache 2>/dev/null || true)
[ -z "$UICACHE" ] && [ -x /var/jb/usr/bin/uicache ] && UICACHE=/var/jb/usr/bin/uicache
[ -z "$UICACHE" ] && [ -x /usr/bin/uicache ] && UICACHE=/usr/bin/uicache

# 僵尸 session 慢检：热路径短睡后按拍计数（约 15s）
ORPHAN_CHECK_EVERY=30
ORPHAN_TICK=0

# 8-161-47：单实例（.53 曾双 fscloakd 抢 rename）
acquire_lock() {
  lock=""
  [ -d "/var/jb/usr/lib/ziyan/var" ] && lock="$LOCK_ROOTLESS"
  [ -z "$lock" ] && [ -d "/usr/lib/ziyan/var" ] && lock="$LOCK_ROOTFUL"
  [ -n "$lock" ] || return 0
  # shell flock 不可用时用 mkdir 原子锁
  if mkdir "${lock}.d" 2>/dev/null; then
    echo $$ >"$lock" 2>/dev/null || true
    return 0
  fi
  old=$(cat "$lock" 2>/dev/null || echo)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    log "fscloakd_exit duplicate pid=$old"
    exit 0
  fi
  rm -rf "${lock}.d" "$lock" 2>/dev/null || true
  mkdir "${lock}.d" 2>/dev/null || exit 0
  echo $$ >"$lock" 2>/dev/null || true
}

log() {
  line="$1"
  for L in "$LOG_ROOTLESS" "$LOG_ROOTFUL"; do
    dir=$(dirname "$L")
    [ -d "$dir" ] || continue
    echo "$line" >>"$L" 2>/dev/null || true
    break
  done
}

has_session() {
  [ -f "$SESSION_ROOTLESS" ] || [ -f "$SESSION_ROOTFUL" ] || \
    [ -f "$SESSION_MEDIA" ] || [ -f "$SESSION_MEDIA_LEGACY" ]
}

has_hide_flag() {
  [ -f "$HIDE_ROOTLESS" ] || [ -f "$HIDE_ROOTFUL" ] || \
    [ -f "$HIDE_MEDIA" ] || [ -f "$HIDE_MEDIA_LEGACY" ]
}

clear_afc_flags() {
  "$RM" -f "$FLAG_ROOTFUL" "$FLAG_ROOTLESS" "$FLAG_MEDIA" "$FLAG_MEDIA_LEGACY" \
    "$REQ_RESTORE_ROOTFUL" "$REQ_RESTORE_ROOTLESS" 2>/dev/null || true
}

clear_session_and_hide_flags() {
  "$RM" -f "$SESSION_ROOTFUL" "$SESSION_ROOTLESS" "$SESSION_MEDIA" "$SESSION_MEDIA_LEGACY" \
    "$HIDE_ROOTFUL" "$HIDE_ROOTLESS" "$HIDE_MEDIA" "$HIDE_MEDIA_LEGACY" \
    "$HB_ROOTFUL" "$HB_ROOTLESS" "$HB_MEDIA" "$HB_MEDIA_LEGACY" 2>/dev/null || true
  if [ -d "/var/jb/usr/lib/ziyan/var" ]; then
    echo 0 >"$APP_FG_ROOTLESS" 2>/dev/null || true
  elif [ -d "/usr/lib/ziyan/var" ]; then
    echo 0 >"$APP_FG_ROOTFUL" 2>/dev/null || true
  fi
  ORPHAN_TICK=0
}

# .53 rootless：plain `ps` 常空；优先 ps auxww / axww，再 pgrep
ziyan_ps_out() {
  if [ -n "$PS" ]; then
    out=$("$PS" auxww 2>/dev/null || true)
    [ -n "$out" ] && { echo "$out"; return 0; }
    out=$("$PS" axww 2>/dev/null || true)
    [ -n "$out" ] && { echo "$out"; return 0; }
    out=$("$PS" -A 2>/dev/null || true)
    [ -n "$out" ] && { echo "$out"; return 0; }
    out=$("$PS" ax 2>/dev/null || true)
    [ -n "$out" ] && { echo "$out"; return 0; }
  fi
  return 1
}

ziyan_process_alive() {
  out=$(ziyan_ps_out || true)
  if [ -n "$out" ]; then
    echo "$out" | grep -F 'ZiYan.app/ZiYan' >/dev/null 2>&1 && return 0
    echo "$out" | grep -E 'Applications/ZiYan\.app|/ZiYan\.app/ZiYan' >/dev/null 2>&1 && return 0
    echo "$out" | grep -v 'fscloakd' | grep -v 'ziyan_fscloakd' | \
      grep -E '[[:space:]]ZiYan$| /ZiYan$' >/dev/null 2>&1 && return 0
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'ZiYan\.app/ZiYan' >/dev/null 2>&1 && return 0
    pgrep -x ZiYan >/dev/null 2>&1 && return 0
  fi
  if command -v launchctl >/dev/null 2>&1; then
    launchctl list 2>/dev/null | grep -F 'com.ziyan.ziyan' >/dev/null 2>&1 && return 0
  fi
  return 1
}

heartbeat_fresh() {
  now=$("$DATE" +%s 2>/dev/null || echo 0)
  for hb in "$HB_MEDIA" "$HB_MEDIA_LEGACY" "$HB_ROOTLESS" "$HB_ROOTFUL"; do
    [ -f "$hb" ] || continue
    ts=$(cat "$hb" 2>/dev/null | tr -cd '0-9')
    [ -z "$ts" ] && continue
    if [ "$ts" -gt 1000000000000 ]; then
      ts=$((ts / 1000))
    fi
    d=$((now - ts))
    if [ "$d" -ge 0 ] && [ "$d" -le 180 ]; then
      return 0
    fi
  done
  return 1
}

# 8-122：主路径只认 session 文件（开 App 写、关程序清）。
# Home 挂起 session 仍在 → 保持隐藏，无需每秒 ps。
want_desk_hide() {
  # 8-161-46/47：用户「关闭程序」粘性 → 禁止继续 hide，强制走 restore
  if [ -f "$USER_CLOSED_ROOTLESS" ] || [ -f "$USER_CLOSED_ROOTFUL" ]; then
    return 1
  fi
  if has_session; then
    return 0
  fi
  return 1
}

has_pending_req() {
  [ -f "$REQ_RESTORE_ROOTLESS" ] || [ -f "$REQ_RESTORE_ROOTFUL" ] || \
    [ -f "$REQ_HIDE_ROOTLESS" ] || [ -f "$REQ_HIDE_ROOTFUL" ]
}

# 慢路径：仅已隐藏态偶尔确认僵尸 session（崩溃未清文件）
maybe_clear_orphan_session() {
  ORPHAN_TICK=$((ORPHAN_TICK + 1))
  if [ "$ORPHAN_TICK" -lt "$ORPHAN_CHECK_EVERY" ]; then
    return 0
  fi
  ORPHAN_TICK=0
  if ziyan_process_alive; then
    return 0
  fi
  if heartbeat_fresh; then
    return 0
  fi
  log "orphan_session_clear no_proc_no_hb"
  clear_session_and_hide_flags
  return 1
}

RESTORE_AFC="\
/usr/libexec/afc2d \
/var/jb/usr/libexec/afc2d \
/usr/libexec/afc2dSupport \
/Library/MobileSubstrate/DynamicLibraries/afc2dService.dylib \
/Library/MobileSubstrate/DynamicLibraries/afc2dService.plist \
/var/jb/Library/MobileSubstrate/DynamicLibraries/afc2dService.dylib \
/var/jb/Library/MobileSubstrate/DynamicLibraries/afc2dService.plist \
"

ensure_restore_afc() {
  for b in $RESTORE_AFC; do
    if [ -f "${b}.ziyan_cloaked" ]; then
      "$MV" -f "${b}.ziyan_cloaked" "$b" 2>/dev/null && log "afc_restore $b"
    fi
  done
}

run_uicache_unregister() {
  # 隐藏前：对仍存在的 .app 路径 -u，否则改名后 SpringBoard 残留幽灵图标
  [ -n "$UICACHE" ] || return 0
  for p in "$@"; do
    [ -d "$p" ] || continue
    "$UICACHE" -u "$p" >/dev/null 2>&1 || true
  done
}

run_uicache_paths() {
  # 恢复后：对还原的 .app 做 -p 注册（禁止对 .ziyan_desk_hidden 调 -p）
  [ -n "$UICACHE" ] || return 0
  n=0
  for p in "$@"; do
    case "$p" in
      *.ziyan_desk_hidden) continue ;;
    esac
    [ -d "$p" ] || continue
    "$UICACHE" -p "$p" >/dev/null 2>&1 && n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    "$UICACHE" >/dev/null 2>&1 || true
  fi
}

JB_APP_NAMES="Cydia.app Sileo.app Zebra.app Filza.app Filza64.app NewTerm.app NewTerm2.app Dopamine.app TrollStore.app TrollStoreLite.app"

app_dirs() {
  seen=""
  for dir in /Applications /var/jb/Applications; do
    [ -d "$dir" ] || continue
    real=$(readlink -f "$dir" 2>/dev/null || echo "$dir")
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    echo "$real"
  done
}

desk_hide_apps() {
  did=0
  to_unreg=""
  for dir in $(app_dirs); do
    [ -d "$dir" ] || continue
    for name in $JB_APP_NAMES; do
      src="$dir/$name"
      dst="$dir/${name}.ziyan_desk_hidden"
      if [ -d "$src" ] && [ ! -d "$dst" ]; then
        to_unreg="$to_unreg $src"
      fi
    done
  done
  # 先 -u 再 mv（.53：对 hidden 路径 -p 会 Unable to register，幽灵图标不消）
  # shellcheck disable=SC2086
  run_uicache_unregister $to_unreg
  for dir in $(app_dirs); do
    [ -d "$dir" ] || continue
    for name in $JB_APP_NAMES; do
      src="$dir/$name"
      dst="$dir/${name}.ziyan_desk_hidden"
      if [ -d "$src" ] && [ ! -d "$dst" ]; then
        if "$MV" -f "$src" "$dst" 2>/dev/null; then
          did=1
          log "desk_hide $src"
        fi
      fi
    done
  done
  [ "$did" -eq 1 ] && log "desk_hide_done unreg_first=1"
}

desk_restore_apps() {
  did=0
  changed=""
  for dir in $(app_dirs); do
    [ -d "$dir" ] || continue
    for hidden in "$dir"/*.ziyan_desk_hidden; do
      [ -d "$hidden" ] || continue
      orig="${hidden%.ziyan_desk_hidden}"
      if [ ! -d "$orig" ]; then
        if "$MV" -f "$hidden" "$orig" 2>/dev/null; then
          did=1
          changed="$changed $orig"
          log "desk_restore $orig"
        fi
      fi
    done
  done
  if [ "$did" -eq 1 ]; then
    # shellcheck disable=SC2086
    run_uicache_paths $changed
  fi
}

any_desk_hidden() {
  for dir in $(app_dirs); do
    for hidden in "$dir"/*.ziyan_desk_hidden; do
      [ -d "$hidden" ] && return 0
    done
  done
  return 1
}

acquire_lock
log "fscloakd_start v8147 icon_fast"
ensure_restore_afc
clear_afc_flags
if want_desk_hide; then
  log "boot_keep_session_alive"
  desk_hide_apps
  LAST=1
else
  clear_session_and_hide_flags
  desk_restore_apps
  log "boot_force_desk_and_afc_clean"
  LAST=0
fi

while true; do
  ensure_restore_afc

  # 磁盘真相同步 LAST（防外部 restore 后 LAST=1 永不再 hide）
  if any_desk_hidden; then
    LAST=1
  elif [ "$LAST" -eq 1 ] && ! has_hide_flag; then
    LAST=0
  fi

  # 显式 restore_req（关程序）→ 立即 desk_restore
  if [ -f "$REQ_RESTORE_ROOTLESS" ] || [ -f "$REQ_RESTORE_ROOTFUL" ]; then
    "$RM" -f "$REQ_RESTORE_ROOTLESS" "$REQ_RESTORE_ROOTFUL" 2>/dev/null || true
    clear_session_and_hide_flags
    desk_restore_apps
    LAST=0
    log "desk=SHOW fs_cloak_restore_req"
  fi

  # 显式 hide_req（开 App / daemon emit）→ 立即 desk_hide
  if [ -f "$REQ_HIDE_ROOTLESS" ] || [ -f "$REQ_HIDE_ROOTFUL" ]; then
    "$RM" -f "$REQ_HIDE_ROOTLESS" "$REQ_HIDE_ROOTFUL" 2>/dev/null || true
    if want_desk_hide || has_hide_flag || has_session; then
      desk_hide_apps
      LAST=1
      log "desk=HIDE hide_req_edge"
    fi
  fi

  if want_desk_hide; then
    # 边沿：磁盘未隐藏则立刻 hide（不依赖 LAST 内存）
    if ! any_desk_hidden; then
      desk_hide_apps
      log "desk=HIDE session_edge"
      LAST=1
      ORPHAN_TICK=0
    else
      LAST=1
      if ! maybe_clear_orphan_session; then
        LAST=0
        desk_restore_apps
        log "desk=SHOW orphan_cleared"
      fi
    fi
  else
    if has_hide_flag || any_desk_hidden || has_session; then
      clear_session_and_hide_flags
      desk_restore_apps
    fi
    if [ "$LAST" -ne 0 ]; then
      log "desk=SHOW clean"
      LAST=0
    fi
  fi
  # 8-161-113 Phase1-R CPU：有 req 0.15s；有 session 0.5s；全冷闲 1.5s（审计 fscloak 曾占 1～2%）
  if has_pending_req; then
    "$SLEEP" 0.15
  elif has_session || want_desk_hide; then
    "$SLEEP" 0.5
  else
    "$SLEEP" 1.5
  fi
done
