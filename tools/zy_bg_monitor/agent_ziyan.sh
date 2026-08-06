#!/bin/sh
# ZiYan 四机后台监控 Agent（设备内跑，无 awk 依赖）
# JSONL 字段固定，便于四机横向对比。
set +e
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH

TAG="${TAG:-}"
SCHEME="${SCHEME:-}"
SESSION="${SESSION:-}"
INTERVAL="${INTERVAL:-5}"
if [ -z "$TAG" ] || [ -z "$SCHEME" ] || [ -z "$SESSION" ]; then
  echo "FAIL: TAG/SCHEME/SESSION required" >&2
  exit 1
fi

if [ "$SCHEME" = rootless ]; then
  JB=/var/jb
  VAR=/var/jb/usr/lib/ziyan/var
  VOL_DY=$JB/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib
  FR_DY=$JB/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.dylib
  AT_DY=$JB/Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib
else
  VAR=/usr/lib/ziyan/var
  VOL_DY=/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib
  FR_DY=/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.dylib
  AT_DY=/Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib
fi

MEDIA=/var/mobile/Media/ZiYan
OUT="$VAR/monitor/$SESSION"
mkdir -p "$OUT" "$MEDIA/monitor/$SESSION" 2>/dev/null
chmod 777 "$VAR/monitor" "$OUT" 2>/dev/null
echo "$SESSION" >"$VAR/monitor/CURRENT_SESSION"
echo $$ >"$OUT/agent.pid"
echo "role=ziyan tag=$TAG scheme=$SCHEME session=$SESSION interval=$INTERVAL start=$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$OUT/meta.txt"

EVENTS="$OUT/events.jsonl"
SBLOG="$OUT/sb_restarts.jsonl"
SNAP="$OUT/latest.txt"
MEDIA_EV="$MEDIA/monitor/$SESSION/events.jsonl"

json_esc() {
  echo -n "$1" | tr '\n\r\t"\\' '    /' | cut -c1-160
}

# iOS 上可能是 BSD/GNU 混装；只返回纯数字 mtime
file_mtime() {
  f="$1"
  mt=$(date -r "$f" +%s 2>/dev/null)
  case "$mt" in
    ''|*[!0-9]*) ;;
    *) echo "$mt"; return ;;
  esac
  mt=$(stat -c %Y "$f" 2>/dev/null)
  case "$mt" in
    ''|*[!0-9]*) ;;
    *) echo "$mt"; return ;;
  esac
  mt=$(stat -f %m "$f" 2>/dev/null)
  case "$mt" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$mt" ;;
  esac
}

etime_to_sec() {
  e="$1"
  d=0
  h=0
  m=0
  s=0
  case "$e" in
    *-*) d="${e%%-*}"; e="${e#*-}" ;;
  esac
  c1="${e%%:*}"; rest="${e#*:}"
  if [ "$rest" = "$e" ]; then
    s="$e"
  else
    c2="${rest%%:*}"; rest2="${rest#*:}"
    if [ "$rest2" = "$rest" ]; then
      m="$c1"; s="$c2"
    else
      h="$c1"; m="$c2"; s="$rest2"
    fi
  fi
  # 去掉前导 0，避免 bash 把 08/09 当八进制报错
  d=$(echo "$d" | sed 's/^0*//'); [ -z "$d" ] && d=0
  h=$(echo "$h" | sed 's/^0*//'); [ -z "$h" ] && h=0
  m=$(echo "$m" | sed 's/^0*//'); [ -z "$m" ] && m=0
  s=$(echo "$s" | sed 's/^0*//'); [ -z "$s" ] && s=0
  echo $((d * 86400 + h * 3600 + m * 60 + s))
}

count_match() {
  # stdin lines → count
  wc -l 2>/dev/null | tr -d ' '
}

sum_rss_match() {
  # stdin: "RSS COMMAND..." → sum first field
  sum=0
  while read -r r _rest; do
    [ -n "$r" ] || continue
    case "$r" in
      *[!0-9]*) continue ;;
    esac
    sum=$((sum + r))
  done
  echo "$sum"
}

# stdin: "%CPU RSS COMMAND..." → 合计 RSS（KB）
sum_rss_from_cpu_rss_lines() {
  sum=0
  while read -r _cpu r _rest; do
    [ -n "$r" ] || continue
    case "$r" in
      *[!0-9]*) continue ;;
    esac
    sum=$((sum + r))
  done
  echo "$sum"
}

# stdin: "%CPU RSS COMMAND..." → 合计 %CPU（一位小数）
sum_cpu_from_cpu_rss_lines() {
  tenths=0
  while read -r c _rss _rest; do
    [ -n "$c" ] || continue
    case "$c" in
      ''|*[!0-9.]*) continue ;;
    esac
    whole=${c%.*}
    frac=${c#*.}
    if [ "$frac" = "$c" ]; then
      frac=0
    else
      frac=$(echo "$frac" | cut -c1)
      [ -z "$frac" ] && frac=0
    fi
    whole=$((whole + 0))
    frac=$((frac + 0))
    tenths=$((tenths + whole * 10 + frac))
  done
  echo "$((tenths / 10)).$((tenths % 10))"
}

LAST_SB_PID=""
SEQ=0

while true; do
  SEQ=$((SEQ + 1))
  EP=$(date +%s)
  ISO=$(date '+%Y-%m-%dT%H:%M:%S%z')
  LOAD=$(uptime 2>/dev/null | sed -n 's/.*load average: //p' | tr -d ' ')
  LOAD1=$(echo "$LOAD" | cut -d, -f1)

  # pid %cpu etime rss command
  SB_LINE=$(ps -A -o pid,%cpu,etime,rss,command 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1)
  set -- $SB_LINE
  SB_PID=${1:-0}
  SB_CPU=${2:-0}
  SB_ETIME=${3:-0}
  SB_RSS=${4:-0}
  SB_SEC=0
  if [ -n "$SB_ETIME" ] && [ "$SB_ETIME" != 0 ] && [ "$SB_ETIME" != "?" ]; then
    SB_SEC=$(etime_to_sec "$SB_ETIME")
  fi

  EV=hb
  NOTE=
  if [ -n "$LAST_SB_PID" ] && [ "$SB_PID" != 0 ] && [ "$SB_PID" != "$LAST_SB_PID" ]; then
    EV=sb_restart
    NOTE="sb_pid $LAST_SB_PID->$SB_PID"
    printf '{"v":1,"ep":%s,"iso":"%s","tag":"%s","role":"zy","ev":"sb_restart","from_pid":%s,"to_pid":%s,"to_etime":"%s","seq":%s}\n' \
      "$EP" "$ISO" "$TAG" "$LAST_SB_PID" "$SB_PID" "$SB_ETIME" "$SEQ" >>"$SBLOG"
  fi
  LAST_SB_PID=$SB_PID

  LUA_LINES=$(ps -A -o %cpu,rss,command 2>/dev/null | grep -E 'ziyan_run\.lua|lua5\.3 .*/ZiYan/|ios7\.lua|ios8p\.lua' | grep -v grep)
  LUA_N=$(printf '%s\n' "$LUA_LINES" | grep -c . 2>/dev/null || echo 0)
  LUA_N=$(echo "$LUA_N" | tr -d ' ')
  LUA_CPU=$(printf '%s\n' "$LUA_LINES" | sum_cpu_from_cpu_rss_lines)
  LUA_RSS=$(printf '%s\n' "$LUA_LINES" | sum_rss_from_cpu_rss_lines)

  FC_LINES=$(ps -A -o %cpu,rss,command 2>/dev/null | grep 'ziyan_framecap' | grep -v grep)
  FC_N=$(printf '%s\n' "$FC_LINES" | grep -c . 2>/dev/null || echo 0)
  FC_N=$(echo "$FC_N" | tr -d ' ')
  FC_CPU=$(printf '%s\n' "$FC_LINES" | sum_cpu_from_cpu_rss_lines)
  FC_RSS=$(printf '%s\n' "$FC_LINES" | sum_rss_from_cpu_rss_lines)

  FRONT=$(cat "$VAR/.ziyan_front_bid" 2>/dev/null | tr -d '\n\r' | cut -c1-80)
  [ -z "$FRONT" ] && FRONT=$(cat "$VAR/front_app" 2>/dev/null | tr -d '\n\r' | cut -c1-80)
  FRONT=$(json_esc "$FRONT")

  PERF=$(cat "$VAR/.ziyan_color_perf" 2>/dev/null | head -1 | tr -d '\n\r')
  PERF_ESC=$(json_esc "$PERF")
  PERF_AGE=99999
  if [ -f "$VAR/.ziyan_color_perf" ]; then
    MT=$(file_mtime "$VAR/.ziyan_color_perf")
    [ -n "$MT" ] && PERF_AGE=$((EP - MT))
  fi

  TOAST=$(head -1 "$VAR/.ziyan_toast_dump" 2>/dev/null | sed 's/^text=//' | tr -d '\n\r')
  TOAST=$(json_esc "$TOAST")

  TE=0; [ -f "$VAR/.ziyan_te_running" ] && TE=1
  ACTIVE=0; [ -f "$VAR/.ziyan_active" ] && ACTIVE=1
  PAUSED=0; [ -f "$VAR/.ziyan_paused" ] && PAUSED=1
  THIN=0; [ -f "$VAR/.ziyan_sb_vol_thin_active" ] && THIN=1

  VOL=0; [ -f "$VOL_DY" ] && VOL=1
  FR=0; [ -f "$FR_DY" ] && FR=1
  AT=0; [ -f "$AT_DY" ] && AT=1
  INJ_VOL=-1
  if [ "$SB_PID" != 0 ] && [ -f "$VAR/.ziyan_hooks" ]; then
    HOOK_PID=$(sed -n 's/.*sb_pid=\([0-9][0-9]*\).*/\1/p' "$VAR/.ziyan_hooks" | head -1)
    if [ -n "$HOOK_PID" ] && [ "$HOOK_PID" = "$SB_PID" ]; then INJ_VOL=1; else INJ_VOL=0; fi
  fi

  HOOKS=$(json_esc "$(cat "$VAR/.ziyan_hooks" 2>/dev/null | tr '\n' ' ' | cut -c1-120)")
  CMD_AGE=99999
  if [ -f "$VAR/.ziyan_cmd" ]; then
    MT=$(file_mtime "$VAR/.ziyan_cmd")
    [ -n "$MT" ] && CMD_AGE=$((EP - MT))
  fi

  NOTE_ESC=$(json_esc "$NOTE")
  # v=2：sb/lua/fc 增加 cpu（%CPU），便于 CPU 曲线与内存释放同表对比
  LINE=$(printf '{"v":2,"ep":%s,"iso":"%s","tag":"%s","role":"zy","scheme":"%s","session":"%s","ev":"%s","seq":%s,"sb":{"pid":%s,"etime":"%s","sec":%s,"rss":%s,"cpu":%s},"lua":{"n":%s,"rss":%s,"cpu":%s},"fc":{"n":%s,"rss":%s,"cpu":%s},"front":"%s","perf":"%s","perf_age":%s,"toast":"%s","flags":{"te":%s,"active":%s,"paused":%s,"thin":%s},"inject":{"vol_file":%s,"fr_file":%s,"at_file":%s,"vol_live":%s},"hooks":"%s","cmd_age":%s,"load1":"%s","note":"%s"}\n' \
    "$EP" "$ISO" "$TAG" "$SCHEME" "$SESSION" "$EV" "$SEQ" \
    "$SB_PID" "$SB_ETIME" "$SB_SEC" "$SB_RSS" "$SB_CPU" \
    "$LUA_N" "$LUA_RSS" "$LUA_CPU" "$FC_N" "$FC_RSS" "$FC_CPU" \
    "$FRONT" "$PERF_ESC" "$PERF_AGE" "$TOAST" \
    "$TE" "$ACTIVE" "$PAUSED" "$THIN" \
    "$VOL" "$FR" "$AT" "$INJ_VOL" \
    "$HOOKS" "$CMD_AGE" "$LOAD1" "$NOTE_ESC")
  echo "$LINE" >>"$EVENTS"
  echo "$LINE" >>"$MEDIA_EV" 2>/dev/null

  {
    echo "tag=$TAG ep=$EP ev=$EV sb=$SB_PID/$SB_ETIME cpu=$SB_CPU rss=$SB_RSS lua=$LUA_N/$LUA_RSS/$LUA_CPU fc=$FC_N/$FC_RSS/$FC_CPU"
    echo "front=$FRONT te=$TE active=$ACTIVE thin=$THIN inj_vol=$INJ_VOL"
    echo "perf_age=${PERF_AGE}s perf=$PERF_ESC"
    echo "toast=$TOAST load1=$LOAD1"
  } >"$SNAP"

  SZ=$(wc -c <"$EVENTS" 2>/dev/null | tr -d ' ')
  if [ "${SZ:-0}" -gt 8000000 ]; then
    mv "$EVENTS" "$OUT/events_${EP}.jsonl"
    : >"$EVENTS"
  fi

  sleep "$INTERVAL"
done
