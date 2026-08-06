#!/bin/sh
# TouchSprite .171/.149 只读观察 Agent —— 禁止部署/改 ZiYan（无 awk）
set +e
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH

TAG="${TAG:-}"
SESSION="${SESSION:-}"
INTERVAL="${INTERVAL:-5}"
if [ -z "$TAG" ] || [ -z "$SESSION" ]; then
  echo "FAIL: TAG/SESSION required" >&2
  exit 1
fi

OUT=/var/mobile/Media/TS_OBS_MONITOR/$SESSION
mkdir -p "$OUT"
chmod 777 /var/mobile/Media/TS_OBS_MONITOR "$OUT" 2>/dev/null
echo "$SESSION" >/var/mobile/Media/TS_OBS_MONITOR/CURRENT_SESSION
echo $$ >"$OUT/agent.pid"
echo "role=ts tag=$TAG session=$SESSION interval=$INTERVAL start=$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$OUT/meta.txt"

EVENTS="$OUT/events.jsonl"
SBLOG="$OUT/sb_restarts.jsonl"
SNAP="$OUT/latest.txt"
TS_ROOT=/var/mobile/Media/TouchSprite

json_esc() {
  echo -n "$1" | tr '\n\r\t"\\' '    /' | cut -c1-160
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
  d=$(echo "$d" | sed 's/^0*//'); [ -z "$d" ] && d=0
  h=$(echo "$h" | sed 's/^0*//'); [ -z "$h" ] && h=0
  m=$(echo "$m" | sed 's/^0*//'); [ -z "$m" ] && m=0
  s=$(echo "$s" | sed 's/^0*//'); [ -z "$s" ] && s=0
  echo $((d * 86400 + h * 3600 + m * 60 + s))
}

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
LAST_HIT=0
LAST_LOG_SZ=0

while true; do
  SEQ=$((SEQ + 1))
  EP=$(date +%s)
  ISO=$(date '+%Y-%m-%dT%H:%M:%S%z')
  LOAD=$(uptime 2>/dev/null | sed -n 's/.*load average: //p' | tr -d ' ')
  LOAD1=$(echo "$LOAD" | cut -d, -f1)
  UP=$(uptime 2>/dev/null | cut -c1-80)
  UP_ESC=$(json_esc "$UP")

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
    printf '{"v":1,"ep":%s,"iso":"%s","tag":"%s","role":"ts","ev":"sb_restart","from_pid":%s,"to_pid":%s,"to_etime":"%s","seq":%s}\n' \
      "$EP" "$ISO" "$TAG" "$LAST_SB_PID" "$SB_PID" "$SB_ETIME" "$SEQ" >>"$SBLOG"
  fi
  LAST_SB_PID=$SB_PID

  TS_LINES=$(ps -A -o %cpu,rss,command 2>/dev/null | grep -E 'TSDaemon|TouchSprite' | grep -v grep)
  TS_N=$(printf '%s\n' "$TS_LINES" | grep -c . 2>/dev/null || echo 0)
  TS_N=$(echo "$TS_N" | tr -d ' ')
  TS_CPU=$(printf '%s\n' "$TS_LINES" | grep TSDaemon | sum_cpu_from_cpu_rss_lines)
  TS_RSS=$(printf '%s\n' "$TS_LINES" | grep TSDaemon | sum_rss_from_cpu_rss_lines)

  HADES_LINES=$(ps -A -o %cpu,rss,command 2>/dev/null | grep '/Hades' | grep -v grep)
  HADES_N=$(printf '%s\n' "$HADES_LINES" | grep -c . 2>/dev/null || echo 0)
  HADES_N=$(echo "$HADES_N" | tr -d ' ')
  HADES_CPU=$(printf '%s\n' "$HADES_LINES" | sum_cpu_from_cpu_rss_lines)
  HADES_RSS=$(printf '%s\n' "$HADES_LINES" | sum_rss_from_cpu_rss_lines)
  TS_ETIME=$(ps -A -o etime,command 2>/dev/null | grep 'TSDaemon -server' | grep -v grep | head -1)
  set -- $TS_ETIME
  TS_ETIME=${1:-}

  STATUS=$(wget -q -O - -T 1 http://127.0.0.1:50005/status 2>/dev/null)
  STATUS=$(json_esc "$STATUS")

  HIT="$TS_ROOT/tmp/zy_ts_hit.csv"
  HIT_N=$(wc -l <"$HIT" 2>/dev/null | tr -d ' ')
  HIT_N=${HIT_N:-0}
  HIT_DELTA=$((HIT_N - LAST_HIT))
  LAST_HIT=$HIT_N

  LOG_SZ=0
  if [ -f "$TS_ROOT/log/log.txt" ]; then
    LOG_SZ=$(wc -c <"$TS_ROOT/log/log.txt" 2>/dev/null | tr -d ' ')
    LOG_SZ=${LOG_SZ:-0}
  fi
  LOG_DELTA=$((LOG_SZ - LAST_LOG_SZ))
  LAST_LOG_SZ=$LOG_SZ

  RUN_CFG=$(json_esc "$(cat "$TS_ROOT/config/run.cfg" 2>/dev/null | tr '\n' ';' | cut -c1-120)")
  NOTE_ESC=$(json_esc "$NOTE")

  printf '{"v":2,"ep":%s,"iso":"%s","tag":"%s","role":"ts","scheme":"observe","session":"%s","ev":"%s","seq":%s,"sb":{"pid":%s,"etime":"%s","sec":%s,"rss":%s,"cpu":%s},"lua":{"n":%s,"rss":%s,"cpu":%s},"fc":{"n":%s,"rss":%s,"cpu":%s},"front":"","perf":"hit=%s delta=%s","perf_age":0,"toast":"","flags":{"te":0,"active":0,"paused":0,"thin":0},"inject":{"vol_file":0,"fr_file":0,"at_file":0,"vol_live":0},"hooks":"ts_status=%s","cmd_age":0,"load1":"%s","ts":{"hades_n":%s,"hades_rss":%s,"hades_cpu":%s,"ts_etime":"%s","log_sz":%s,"log_delta":%s,"run_cfg":"%s","uptime":"%s"},"note":"%s"}\n' \
    "$EP" "$ISO" "$TAG" "$SESSION" "$EV" "$SEQ" \
    "$SB_PID" "$SB_ETIME" "$SB_SEC" "$SB_RSS" "$SB_CPU" \
    "$TS_N" "$TS_RSS" "$TS_CPU" "$HADES_N" "$HADES_RSS" "$HADES_CPU" \
    "$HIT_N" "$HIT_DELTA" \
    "$STATUS" "$LOAD1" \
    "$HADES_N" "$HADES_RSS" "$HADES_CPU" "$TS_ETIME" "$LOG_SZ" "$LOG_DELTA" "$RUN_CFG" "$UP_ESC" \
    "$NOTE_ESC" >>"$EVENTS"

  {
    echo "tag=$TAG role=ts ep=$EP ev=$EV sb=$SB_PID/$SB_ETIME cpu=$SB_CPU rss=$SB_RSS"
    echo "tsdaemon_n=$TS_N rss=$TS_RSS cpu=$TS_CPU hades=$HADES_N/$HADES_RSS/$HADES_CPU etime=$TS_ETIME"
    echo "status=$STATUS hit=$HIT_N delta=$HIT_DELTA log_sz=$LOG_SZ dlog=$LOG_DELTA"
    echo "load1=$LOAD1 up=$UP_ESC"
  } >"$SNAP"

  SZ=$(wc -c <"$EVENTS" 2>/dev/null | tr -d ' ')
  if [ "${SZ:-0}" -gt 8000000 ]; then
    mv "$EVENTS" "$OUT/events_${EP}.jsonl"
    : >"$EVENTS"
  fi

  sleep "$INTERVAL"
done
