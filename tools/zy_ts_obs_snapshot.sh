#!/usr/bin/env bash
# 只读观察 .149/.171 触动：TSDaemon/SB RSS、脚本态、IOSurface 线索
# 禁止部署 ZiYan、禁止改触动脚本；本脚本只读 ps/vm_stat，不在观察机落任何文件。
#
# 用法:
#   bash tools/zy_ts_obs_snapshot.sh                 # 单点快照（.149 + .171）
#   ZY_TS_MIN=5  bash tools/zy_ts_obs_snapshot.sh    # 快照 + Z0-TS 定时采样（默认 .171）
#   ZY_TS_MIN=30 ZY_TS_SAMPLE_HOSTS="171 149" bash tools/zy_ts_obs_snapshot.sh
#
# Z0-TS 采样口径与 tools/zy_e4_promo_gate.sh 完全一致，便于同窗对照：
#   暖机 60s → 采 5 点(间隔 2s)取中位数为 BASE → 每 2s 采样 SEC 秒
#   → 末 5 点中位数为 END → DELTA = END - BASE（整窗差值，单位 KB）
#   额外输出 PER100 = DELTA*100/SEC（KB/100s），消除窗口长度差异。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/TS_OBS/${STAMP}"
TS_MIN="${ZY_TS_MIN:-0}"
TS_SAMPLE_HOSTS="${ZY_TS_SAMPLE_HOSTS:-171}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

snap() {
  local H="$1"
  local IP="192.168.31.$H"
  echo "==== TS obs .$H ===="
  ssh_r "$IP" bash -s >"$OUT/ts_${H}.txt" 2>&1 <<'R' || echo "SSH_FAIL .$H" | tee -a "$OUT/ts_${H}.txt"
set +e
echo "host=$(hostname) date=$(date +%s)"
echo "---- procs ----"
ps -axo pid,rss,%cpu,etime,args 2>/dev/null | grep -E 'TSDaemon|SpringBoard.app/SpringBoard|TouchSprite' | grep -v grep | head -20
echo "---- TS paths ----"
for p in /var/mobile/Media/TouchSprite/log /var/mobile/Media/TouchSprite \
  /var/mobile/Library/TouchSprite /usr/local/TouchSprite; do
  [ -e "$p" ] && ls -la "$p" 2>/dev/null | head -8
done
echo "---- vm_stat ----"
vm_stat 2>/dev/null | head -12
echo "---- iosurface_hint ----"
# 无 Frida：仅从 vmmap/heap 线索粗看（可能无权限）
PID=$(ps -axo pid,args 2>/dev/null | grep '[T]SDaemon -server' | head -1 | sed 's/^ *//' | cut -d' ' -f1)
echo "TSDaemon_pid=${PID:-0}"
if [ -n "${PID:-}" ] && [ "$PID" != "0" ]; then
  # footprint 类：若有 malloc_history/vmmap
  which vmmap >/dev/null 2>&1 && vmmap "$PID" 2>/dev/null | grep -iE 'IOSurface|TOTAL|dirty' | head -20
  ls -la /tmp 2>/dev/null | grep -iE 'touch|ts|sprite' | head -10
fi
echo "---- done ----"
R
}

for H in 149 171; do snap "$H"; done
{
  echo "# TS observe snapshot (read-only)"
  echo "stamp=$STAMP"
  echo "hosts=149 171"
  for H in 149 171; do
    echo ""
    echo "## .$H"
    grep -E 'TSDaemon|SpringBoard|TSDaemon_pid|host=' "$OUT/ts_${H}.txt" | head -20 || true
  done
} | tee "$OUT/SUMMARY.md"

# ---- Z0-TS：TSDaemon RSS 时间序列（与 E4 同口径）----
sample_host() {
  local H="$1"
  local IP="192.168.31.$H"
  local SEC=$(( TS_MIN * 60 ))
  echo "==== TS rss sample .$H (${TS_MIN}min) ===="
  # 远端只读循环；样本经 stdout 回传，观察机不落文件
  ssh_r "$IP" "SEC=$SEC H=$H bash -s" >"$OUT/rss_${H}.txt" 2>&1 <<'R' || echo "SSH_FAIL .$H" >>"$OUT/rss_${H}.txt"
set +e
# TSDaemon 会 fork 出短命子进程（同 argv、RSS 仅 2MB 量级），按名字 grep + head -1
# 会随机抓到子进程导致样本跳变。只认带 -server 的常驻守护，并锁定 PID 采样。
ts_pid() {
  ps -axo pid,args 2>/dev/null | grep '[T]SDaemon -server' | head -1 | sed 's/^ *//' | cut -d' ' -f1
}
ts_rss() {
  ps -p "$1" -o rss= 2>/dev/null | tr -d ' '
}
ts_cpu() {
  ps -p "$1" -o %cpu= 2>/dev/null | tr -d ' '
}
sb_rss() {
  ps -axo rss,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | tr -s ' ' | cut -d' ' -f1
}
PID0=$(ts_pid); PID0=${PID0:-0}
PID_PIN=$PID0
echo "META host=.$H SEC=$SEC TSDAEMON_PID=$PID0 start=$(date +%s)"
echo "PROC_START=$(ps -axo pid,rss,%cpu,etime,args 2>/dev/null | grep -E '[T]SDaemon|[S]pringBoard.app/SpringBoard' | head -4 | tr '\n' '|')"
if [ "$PID0" = "0" ]; then
  echo "FATAL tsdaemon_not_running"
  echo "VERDICT=NO_DATA"
  exit 0
fi

# 暖机 60s（对齐 E4；触动侧脚本应已在圈，本脚本不启停任何触动脚本）
sleep 60
# 5 点基线，间隔 2s，取中位数
BASE_SAMPLES=""
for i in 1 2 3 4 5; do
  R0=$(ts_rss "$PID_PIN"); R0=${R0:-0}
  BASE_SAMPLES="$BASE_SAMPLES $R0"
  sleep 2
done
RSS_BASE=$(echo "$BASE_SAMPLES" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '3p')
RSS_BASE=${RSS_BASE:-0}
echo "WARM_BASE_RSS_KB=$RSS_BASE samples=$BASE_SAMPLES"

end=$(( $(date +%s) + SEC ))
TAIL_BUF=""
RSS_MAX=$RSS_BASE
RSS_MIN=$RSS_BASE
PID_CHG=0
while [ "$(date +%s)" -lt "$end" ]; do
  TR=$(ts_rss "$PID_PIN"); TR=${TR:-0}
  TC=$(ts_cpu "$PID_PIN"); TC=${TC:-0}
  # 守护进程若重启，PID 会变；重新锁定并计数，避免把重启当成 RSS 回落
  if [ "$TR" = "0" ] || [ -z "$TR" ]; then
    P=$(ts_pid); P=${P:-0}
    if [ "$P" != "0" ] && [ "$P" != "$PID_PIN" ]; then
      PID_CHG=$((PID_CHG + 1))
      echo "TS_RESTART from=$PID_PIN to=$P at=$(date +%s)"
      PID_PIN=$P
      TR=$(ts_rss "$PID_PIN"); TR=${TR:-0}
      TC=$(ts_cpu "$PID_PIN"); TC=${TC:-0}
    fi
  fi
  [ "$TR" -gt "$RSS_MAX" ] 2>/dev/null && RSS_MAX=$TR
  if [ "$RSS_MIN" = "0" ] || [ "$TR" -lt "$RSS_MIN" ] 2>/dev/null; then RSS_MIN=$TR; fi
  echo "SAMPLE $(date +%s) $TR $TC $(sb_rss)"
  TAIL_BUF="$TAIL_BUF $TR"
  TAIL_BUF=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | tail -5 | tr '\n' ' ')
  sleep 2
done

RSS_END=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '3p')
RSS_END=${RSS_END:-0}
DELTA=$(( RSS_END - RSS_BASE ))
PER100=$(( DELTA * 100 / SEC ))
echo "RSS_BASE=$RSS_BASE RSS_END=$RSS_END RSS_MAX=$RSS_MAX RSS_MIN=$RSS_MIN"
echo "TS_DELTA_KB=$DELTA TS_PER100_KB=$PER100 TS_RESTARTS=$PID_CHG"
echo "PROC_END=$(ps -axo pid,rss,%cpu,etime,args 2>/dev/null | grep -E '[T]SDaemon|[S]pringBoard.app/SpringBoard' | head -4 | tr '\n' '|')"
echo "META end=$(date +%s)"
echo "VERDICT=DATA_OK"
R
}

if [ "$TS_MIN" -gt 0 ] 2>/dev/null; then
  for H in $TS_SAMPLE_HOSTS; do sample_host "$H" & done
  wait || true
  {
    echo "# Z0-TS · 触动 TSDaemon RSS 同口径时间序列"
    echo ""
    echo "stamp=$STAMP min=$TS_MIN hosts=$TS_SAMPLE_HOSTS"
    echo "口径：与 tools/zy_e4_promo_gate.sh 一致（暖机60s → 5点中位基线 → 每2s采样 → 末5点中位数）"
    echo "DELTA = END - BASE（整窗差值 KB）；PER100 = DELTA*100/SEC（KB/100s）"
    echo ""
    for H in $TS_SAMPLE_HOSTS; do
      echo "## .$H"
      grep -E '^(META|WARM_BASE_RSS_KB|RSS_BASE|TS_DELTA_KB|TS_RESTART|FATAL|VERDICT)' \
        "$OUT/rss_${H}.txt" 2>/dev/null || echo "(no data)"
      echo ""
      echo "样本数: $(grep -c '^SAMPLE ' "$OUT/rss_${H}.txt" 2>/dev/null || echo 0)"
      echo ""
    done
    echo "## 用途"
    echo "本文件是 Z1-MEM 内存预算的唯一实测出处。"
    echo "若触动自身 PER100 明显大于 0，则子砚不得沿用「趋近于零」目标，"
    echo "应改判「不劣于触动」，并据此重设 zy_e4_promo_gate.sh 的斜率阈值。"
  } | tee "$OUT/TS_RSS_SLOPE.md"
fi

echo "OUT=$OUT"
