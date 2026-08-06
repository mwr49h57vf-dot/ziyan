#!/bin/sh
# ziyan_framecap_wrap.sh — LaunchDaemon 入口（8-161-110 Phase1-R / 182）
# 目的：argv0 用常驻 sh；禁 launchd 直接盯 package binary（缺文件会 panic）
# 182：以 ps 判活为准（禁僵 PIDF 清掉活人 flock）；仍 exec serve（二进制内抬 jetsam）
# rootless：daemon PATH 常无 /var/jb/usr/bin → 禁止依赖裸 grep/sleep
set +e
ROOT="/usr/lib/ziyan"
[ -d /var/jb/usr/lib/ziyan ] && ROOT="/var/jb/usr/lib/ziyan"
BIN="$ROOT/bin/ziyan_framecap"
VAR="$ROOT/var"
PIDF="$VAR/.ziyan_framecap_wrap.pid"
LOCKF="$VAR/.ziyan_framecap_serve.lock"
mkdir -p "$VAR" 2>/dev/null || true

# 保证本脚本内工具可见（LaunchDaemon 默认 PATH=/usr/bin:/bin 在 .53 不够）
PATH="/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

PS=$(command -v ps 2>/dev/null || echo /bin/ps)

if [ ! -x "$BIN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') wrap_skip missing_bin" >>"$VAR/.ziyan_framecap_log" 2>/dev/null || true
  exit 0
fi

# 182：任何 ziyan_framecap serve 活着 → 同步 PIDF 后退出（禁双开/清活人锁）
live_pid=""
for pid in $($PS -A -o pid=,command= 2>/dev/null | grep -F "ziyan_framecap serve" | grep -v grep | sed 's/^ *//' | cut -d' ' -f1); do
  case "$pid" in
    *[!0-9]*|"") ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        live_pid=$pid
        break
      fi
      ;;
  esac
done
if [ -n "$live_pid" ]; then
  echo "$live_pid" >"$PIDF" 2>/dev/null || true
  chmod 666 "$PIDF" 2>/dev/null || true
  echo "$(date '+%Y-%m-%d %H:%M:%S') wrap_skip already_running pid=$live_pid" >>"$VAR/.ziyan_framecap_log" 2>/dev/null || true
  exit 0
fi

# PIDF 残留但进程已死
if [ -f "$PIDF" ]; then
  oldpid=$(cat "$PIDF" 2>/dev/null)
  case "$oldpid" in
    *[!0-9]*|"") rm -f "$PIDF" 2>/dev/null || true ;;
    *)
      if ! kill -0 "$oldpid" 2>/dev/null; then
        rm -f "$PIDF" 2>/dev/null || true
      fi
      ;;
  esac
fi

# 150/182：serve flock；仅确认无活人后再清僵锁
touch "$LOCKF" 2>/dev/null || true
chmod 666 "$LOCKF" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  if ! flock -n "$LOCKF" true 2>/dev/null; then
    # 无 serve 进程却锁在 → 僵锁
    rm -f "$LOCKF" "$PIDF" 2>/dev/null || true
    touch "$LOCKF" 2>/dev/null || true
    chmod 666 "$LOCKF" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') wrap_stale_lock_cleared" >>"$VAR/.ziyan_framecap_log" 2>/dev/null || true
  fi
fi

# 记录将要 exec 的壳 pid；exec 后同 pid 为 serve（二进制入口抬 jetsam）
echo "$$" >"$PIDF" 2>/dev/null || true
chmod 666 "$PIDF" 2>/dev/null || true
echo "$(date '+%Y-%m-%d %H:%M:%S') wrap_exec serve pid=$$" >>"$VAR/.ziyan_framecap_log" 2>/dev/null || true
exec "$BIN" serve
