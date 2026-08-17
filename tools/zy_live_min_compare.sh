#!/usr/bin/env bash
# 三台 rootful 真机的业务负载 Home↔App 回归；不触碰 .53/.149/.171。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
ROUNDS="${ZY_LIVE_ROUNDS:-30}"
HOME_WAIT="${ZY_LIVE_HOME_WAIT:-6}"
APP_WAIT="${ZY_LIVE_APP_WAIT:-8}"
BID="${ZY_LIVE_BID:-com.xztl.ios}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/LIVE_MIN_COMPARE_$STAMP"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o NumberOfPasswordPrompts=1
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=10 -o ServerAliveCountMax=2)

ssh_r() {
  local h="$1"; shift
  if [ "$h" = 166 ] && ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "root@192.168.31.$h" true >/dev/null 2>&1; then
    ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "root@192.168.31.$h" "$@"
    return $?
  fi
  # 认证探针绝不能读取调用方 stdin：start_probe_one 通过 base64 管道上传 Lua，
  # 若 probe 未加 -n 会先吞光脚本再执行实际 ssh，设备侧就只得到 0 字节文件。
  if sshpass -p "$PASS" ssh -n "${SSH_OPTS[@]}" "root@192.168.31.$h" true >/dev/null 2>&1; then
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$h" "$@"
    return $?
  fi
  ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "root@192.168.31.$h" "$@"
}
status_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1 | tr -d '\r'; }

# 长窗必须先确认找色业务一直处于热态。只跑 App/Home 控制而没有内嵌脚本时，
# framecap 会合法进入 idle，随后把空槽当成“卡屏”会污染 P2 结论。
start_probe_one() {
  local h="$1" duration="$2" remote="/private/var/mobile/Media/ZiYan/_p2_30m_probe.lua"
  local lua="$OUT/probe_${h}.lua"
  cat >"$lua" <<LUA
function main()
  init(1)
  local started, n, hits = os.time(), 0, 0
  while os.time() - started < $duration do
    local x, y = findMultiColorInRegionFuzzy(
      "0xffffff", "1|0|0xffffff", 90, 0, 0, -1, -1)
    n = n + 1
    if x and x >= 0 then hits = hits + 1 end
    if n % 20 == 0 then
      local f = io.open("/private/var/mobile/Media/ZiYan/_p2_30m_beat.txt", "w")
      if f then f:write("n=" .. n .. " hits=" .. hits .. " ts=" .. os.time() .. "\\n"); f:close() end
      toast("P2-30M " .. n, 350)
    end
    mSleep(300)
  end
end
LUA
  # 这里必须保留 stdin 给 base64 数据。ssh_r 用于无 stdin 的控制/读取命令，
  # 其 -n 选项若复用到上传会让设备得到空脚本。
  if [ "$h" = 166 ]; then
    base64 <"$lua" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 -o BatchMode=yes "root@192.168.31.$h" \
      "mkdir -p /private/var/mobile/Media/ZiYan && base64 -d >'$remote' && chmod 666 '$remote'"
    upload_rc=${PIPESTATUS[1]}
  else
    base64 <"$lua" | sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no "root@192.168.31.$h" \
      "mkdir -p /private/var/mobile/Media/ZiYan && base64 -d >'$remote' && chmod 666 '$remote'"
    upload_rc=${PIPESTATUS[1]}
  fi
  if [ "${upload_rc:-1}" != 0 ]; then
    printf 'PROBE_START host=.%s result=upload_fail\n' "$h" >>"$OUT/events.log"
    return 1
  fi
  local out
  out="$(ssh_r "$h" "V=/usr/lib/ziyan/var; M=/private/var/mobile/Media/ZiYan; rm -f \"\$V/.ziyan_kill_scripts\" \"\$V/.ziyan_user_stopped\" \"\$V/.ziyan_stop\" \"\$V/.ziyan_embed_off\" \"\$V/.ziyan_no_auto_keep\"; : >\"\$V/.ziyan_find_shm_log\"; : >\"\$V/.ziyan_find_timing_log\"; rm -f \"\$M/_p2_30m_beat.txt\"; printf 'path=%s\\nstop=0\\n' \"$remote\" >\"\$V/.ziyan_run_intent\"; printf '%s\\n' \"$remote\" >\"\$V/.ziyan_embed_script\"; echo 1 >\"\$V/.ziyan_embed_on\"; echo nonce=p2_30m_\$\$ >\"\$V/.ziyan_embed_go\"; chmod 666 \"\$V/.ziyan_run_intent\" \"\$V/.ziyan_embed_script\" \"\$V/.ziyan_embed_on\" \"\$V/.ziyan_embed_go\"; for i in \$(seq 1 40); do [ -s \"\$M/_p2_30m_beat.txt\" ] && { echo STARTED=1; exit 0; }; sleep 0.5; done; echo STARTED=0; exit 1" 2>&1 || true)"
  printf 'PROBE_START host=.%s %s\n' "$h" "$(printf '%s' "$out" | tr '\n' ' ')" >>"$OUT/events.log"
  printf '%s\n' "$out" | grep -q 'STARTED=1'
}

sample_one() {
  local h="$1" phase="$2" round="$3" st front shm ack findline fc lua diag
  local port st0
  for port in 50005 50015; do
    st0="$(curl -sS -m 5 "http://192.168.31.$h:$port/status" 2>/dev/null || true)"
    if printf '%s\n' "$st0" | grep -qE '^(zy1|engine=ZiYan)'; then st="$st0"; break; fi
  done
  st="${st:-}"
  if [ -n "$st" ]; then
    printf 'STATUS round=%s phase=%s host=.%s http=ok session=%s seq=%s age_ms=%s status=%s front=%s shm=%s provider=%s\n' \
      "$round" "$phase" "$h" "$(status_field "$st" session)" \
      "$(status_field "$st" frame_seq)" "$(status_field "$st" frame_age_ms)" \
      "$(status_field "$st" frame_status)" "$(status_field "$st" front_bid)" \
      "$(status_field "$st" shm_bid)" "$(status_field "$st" frame_provider)" >>"$OUT/status.log"
  else
    printf 'STATUS round=%s phase=%s host=.%s http=timeout\n' "$round" "$phase" "$h" >>"$OUT/status.log"
  fi
  local remote
  remote="$(ssh_r "$h" 'V=/usr/lib/ziyan/var; printf "front=%s\n" "$(tr -d "\r\n" <"$V/.ziyan_front_bid" 2>/dev/null)"; printf "shm=%s\n" "$(tr -d "\r\n" <"$V/.ziyan_shm_front_bid" 2>/dev/null)"; printf "ack=%s\n" "$(cat "$V/.ziyan_frame_ack" 2>/dev/null | tr "\n" " ")"; printf "find=%s\n" "$(tail -1 "$V/.ziyan_find_shm_log" 2>/dev/null)"; printf "fc=%s\n" "$(ps -A -o pid=,rss=,%cpu=,etime=,command= 2>/dev/null | grep "[z]iyan_framecap serve" | head -1 | tr "\n" " ")"; printf "sb=%s\n" "$(ps -A -o pid=,rss=,%cpu=,etime=,command= 2>/dev/null | grep "SpringBoard.app/SpringBoard" | grep -v grep | head -1 | tr "\n" " ")"; printf "daemon=%s\n" "$(ps -A -o pid=,rss=,%cpu=,etime=,command= 2>/dev/null | grep "[z]iyadaemond" | head -1 | tr "\n" " ")"; printf "toast=%s\n" "$(cat "$V/.ziyan_toast_dump" 2>/dev/null | tr "\n" " ")"; printf "diag=%s\n" "$(cat "$V/.ziyan_cap_diag" 2>/dev/null | tr "\n" " ")"' 2>/dev/null || true)"
  printf 'REMOTE round=%s phase=%s host=.%s %s\n' "$round" "$phase" "$h" "$(printf '%s\n' "$remote" | tr '\n' ' ')" >>"$OUT/remote.log"
}

go_home_one() {
  local h="$1" bid="$2" out
  out="$(ssh_r "$h" "BID=$bid bash -s" <<'EOS'
set +e
V=/usr/lib/ziyan/var
rm -f "$V/.ziyan_go_home" "$V/.ziyan_open_app"
printf '%s\n' "$BID" >"$V/.ziyan_suspend_bid"
chmod 666 "$V/.ziyan_suspend_bid" 2>/dev/null
echo 1 >"$V/.ziyan_go_home"
chmod 666 "$V/.ziyan_go_home" 2>/dev/null
i=0
while [ "$i" -lt 14 ]; do
  sleep 0.5
  rm -f "$V/.ziyan_go_home" 2>/dev/null
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "HOME_POLL=$i FRONT=$F"
  echo "$F" | grep -qi springboard && { echo HOME_OK; exit 0; }
  i=$((i+1))
done
# SpringBoard activation fallback; this does not terminate the game.
printf 'com.apple.springboard\n' >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null
sleep 0.7
echo 1 >"$V/.ziyan_go_home"
i=0
while [ "$i" -lt 10 ]; do
  sleep 0.5
  rm -f "$V/.ziyan_go_home" "$V/.ziyan_open_app" 2>/dev/null
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "HOME_FALLBACK_POLL=$i FRONT=$F"
  echo "$F" | grep -qi springboard && { echo HOME_OK_FALLBACK; exit 0; }
  i=$((i+1))
done
echo "HOME_FAIL FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)"
exit 1
EOS
  )"
  printf 'HOME host=.%s %s\n' "$h" "$(printf '%s\n' "$out" | tr '\n' ' ')" >>"$OUT/events.log"
}

open_app_one() {
  local h="$1" bid="$2" out
  out="$(ssh_r "$h" "BID=$bid bash -s" <<'EOS'
set +e
V=/usr/lib/ziyan/var
rm -f "$V/.ziyan_open_app"
printf '%s\n' "$BID" >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null
i=0
while [ "$i" -lt 20 ]; do
  sleep 0.5
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "OPEN_POLL=$i FRONT=$F"
  echo "$F" | grep -qiF "$BID" && { rm -f "$V/.ziyan_open_app"; echo OPEN_OK; exit 0; }
  i=$((i+1))
done
rm -f "$V/.ziyan_open_app"
echo "OPEN_FAIL FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)"
exit 1
EOS
  )"
  printf 'OPEN host=.%s %s\n' "$h" "$(printf '%s\n' "$out" | tr '\n' ' ')" >>"$OUT/events.log"
}

ts_sample() {
  local h="$1" role="$2" out
  out="$(ssh_r "$h" 'ps -A -o pid=,rss=,%cpu=,etime=,state=,command= 2>/dev/null | grep -Ei "TSDaemon|Hades|SpringBoard.app/SpringBoard" | grep -v grep | head -6' 2>/dev/null || true)"
  printf 'TS role=%s host=.%s %s\n' "$role" "$h" "$(printf '%s\n' "$out" | tr '\n' ';')" >>"$OUT/touchsprite.log"
}

echo "OUT=$OUT ROUNDS=$ROUNDS BID=$BID" | tee "$OUT/OUT_PATH.txt"
echo "START=$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$OUT/meta.txt"
HOSTS=(${ZY_LIVE_HOSTS:-101 112 166})
HOST_COUNT="${#HOSTS[@]}"
PROBE_DURATION=$(( ROUNDS * ${ZY_LIVE_INTERVAL_S:-60} + 180 ))
for h in "${HOSTS[@]}"; do start_probe_one "$h" "$PROBE_DURATION" & done
wait
if [ "$(grep -c 'STARTED=1' "$OUT/events.log" 2>/dev/null || true)" != "$HOST_COUNT" ]; then
  echo "ABORT=probe_not_running_on_all_devices" | tee -a "$OUT/meta.txt"
  exit 2
fi
round=0
while [ "$round" -lt "$ROUNDS" ]; do
  round=$((round+1))
  cycle_started=$(date +%s)
  printf 'CYCLE round=%s phase=before ts=%s\n' "$round" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >>"$OUT/events.log"
  for h in "${HOSTS[@]}"; do sample_one "$h" before "$round" & done
  wait
  for h in "${HOSTS[@]}"; do go_home_one "$h" "$BID" & done
  wait
  sleep "$HOME_WAIT"
  for h in "${HOSTS[@]}"; do sample_one "$h" home "$round" & done
  wait
  for h in "${HOSTS[@]}"; do open_app_one "$h" "$BID" & done
  wait
  sleep "$APP_WAIT"
  for h in "${HOSTS[@]}"; do sample_one "$h" app "$round" & done
  ts_sample 171 ts171 &
  wait
  printf 'CYCLE round=%s phase=done ts=%s\n' "$round" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >>"$OUT/events.log"
  # P2 长窗统一为每分钟一个观测点。切换和采样时间计入该分钟，避免每轮
  # 结束后又固定 sleep 60 秒而把“30 分钟”扩成 40 分钟以上。
  interval="${ZY_LIVE_INTERVAL_S:-60}"
  elapsed=$(( $(date +%s) - cycle_started ))
  remain=$(( interval - elapsed ))
  [ "$remain" -gt 0 ] && sleep "$remain"
done
printf 'END=%s ROUNDS=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$round" >>"$OUT/meta.txt"
{
  echo "# LIVE MIN COMPARE $STAMP"
  echo
  echo "- rounds=$round"
  echo "- target_bundle=$BID"
  echo "- HTTP timeouts: $(grep -c 'http=timeout' "$OUT/status.log" 2>/dev/null || echo 0)"
  echo "- HOME_FAIL events: $(grep -c 'HOME_FAIL' "$OUT/events.log" 2>/dev/null || echo 0)"
  echo "- OPEN_FAIL events: $(grep -c 'OPEN_FAIL' "$OUT/events.log" 2>/dev/null || echo 0)"
  echo "- stale samples: $(grep -c 'shm=stale' "$OUT/remote.log" 2>/dev/null || echo 0)"
  echo
  if grep -qE 'http=timeout|HOME_FAIL|OPEN_FAIL|shm=stale' "$OUT/status.log" "$OUT/events.log" "$OUT/remote.log" 2>/dev/null; then
    echo 'OVERALL=FAIL'
  else
    echo 'OVERALL=PASS'
  fi
} | tee "$OUT/VERDICT.md"
