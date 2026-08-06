#!/usr/bin/env bash
# zy_bg_monitor_ctl.sh — 四机 ZiYan + .171 触动 后台监控
#
# 用法：
#   tools/zy_bg_monitor_ctl.sh start          # 部署并启动（共用 SESSION）
#   tools/zy_bg_monitor_ctl.sh status
#   tools/zy_bg_monitor_ctl.sh stop
#   tools/zy_bg_monitor_ctl.sh pull           # 用户下令后拉取 → tmp_shots/QUAD_MONITOR/
#   tools/zy_bg_monitor_ctl.sh compare <dir>  # 对已拉取目录出对比表
#
# 日志字段（JSONL v=1）对齐，便于横比 SB 重启 / 注入 / 性能 / 脚本存活。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZIYAN_SSH_PASS:-alpine}"
INTERVAL="${MONITOR_INTERVAL:-5}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

# tag ip scheme role
DEVICES=(
  "53|192.168.31.53|rootless|zy"
  "101|192.168.31.101|rootful|zy"
  "112|192.168.31.112|rootful|zy"
  "166|192.168.31.166|rootful|zy"
  "171|192.168.31.171|observe|ts"
)

SESSION_FILE="$ROOT/tmp_shots/QUAD_MONITOR/CURRENT_SESSION"
mkdir -p "$ROOT/tmp_shots/QUAD_MONITOR"

cmd="${1:-}"
shift || true

case "$cmd" in
start)
  SESSION="${MONITOR_SESSION:-MON_$(date '+%Y%m%d_%H%M%S')}"
  echo "$SESSION" | tee "$SESSION_FILE"
  echo "interval=$INTERVAL" >"$ROOT/tmp_shots/QUAD_MONITOR/${SESSION}_start.txt"
  date >>"$ROOT/tmp_shots/QUAD_MONITOR/${SESSION}_start.txt"

  for ent in "${DEVICES[@]}"; do
    IFS='|' read -r tag ip scheme role <<<"$ent"
    echo "[start] .$tag $role $ip"
    if [ "$role" = zy ]; then
      ssh_r "$ip" "mkdir -p /var/mobile/Media/ZiYan/monitor /tmp/zy_mon 2>/dev/null; true"
      scp_r "$ROOT/tools/zy_bg_monitor/agent_ziyan.sh" "$ip" "/tmp/zy_mon/agent_ziyan.sh"
      ssh_r "$ip" "TAG=$tag SCHEME=$scheme SESSION=$SESSION INTERVAL=$INTERVAL bash -s" <<'EOS'
set +e
chmod 755 /tmp/zy_mon/agent_ziyan.sh
if [ "$SCHEME" = rootless ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
# rootless 无 /bin/bash
if [ -x /var/jb/usr/bin/bash ]; then RBASH=/var/jb/usr/bin/bash
elif [ -x /bin/bash ]; then RBASH=/bin/bash
else RBASH=/bin/sh
fi
pkill -9 -f 'agent_ziyan.sh' 2>/dev/null
sleep 0.3
mkdir -p "$VAR/monitor/$SESSION"
nohup env TAG="$TAG" SCHEME="$SCHEME" SESSION="$SESSION" INTERVAL="$INTERVAL" \
  "$RBASH" /tmp/zy_mon/agent_ziyan.sh >"$VAR/monitor/$SESSION/agent.stdout" 2>&1 &
echo $! >"$VAR/monitor/$SESSION/agent.pid"
sleep 1.2
echo "STARTED tag=$TAG bash=$RBASH pid=$(cat $VAR/monitor/$SESSION/agent.pid) session=$SESSION"
head -1 "$VAR/monitor/$SESSION/events.jsonl" 2>/dev/null || { echo "WAIT_FIRST_LINE"; cat "$VAR/monitor/$SESSION/agent.stdout" 2>/dev/null | head -5; }
EOS
    else
      # .171 只读：仅 Media 目录 + agent，不碰 ZiYan
      ssh_r "$ip" "mkdir -p /var/mobile/Media/TS_OBS_MONITOR /tmp/zy_mon 2>/dev/null; true"
      scp_r "$ROOT/tools/zy_bg_monitor/agent_ts.sh" "$ip" "/tmp/zy_mon/agent_ts.sh"
      ssh_r "$ip" "TAG=$tag SESSION=$SESSION INTERVAL=$INTERVAL bash -s" <<'EOS'
set +e
chmod 755 /tmp/zy_mon/agent_ts.sh
if [ -x /bin/bash ]; then RBASH=/bin/bash
elif [ -x /var/jb/usr/bin/bash ]; then RBASH=/var/jb/usr/bin/bash
else RBASH=/bin/sh
fi
pkill -9 -f 'agent_ts.sh' 2>/dev/null
sleep 0.3
OUT=/var/mobile/Media/TS_OBS_MONITOR/$SESSION
mkdir -p "$OUT"
nohup env TAG="$TAG" SESSION="$SESSION" INTERVAL="$INTERVAL" \
  "$RBASH" /tmp/zy_mon/agent_ts.sh >"$OUT/agent.stdout" 2>&1 &
echo $! >"$OUT/agent.pid"
sleep 1.2
echo "STARTED tag=$TAG bash=$RBASH pid=$(cat $OUT/agent.pid) session=$SESSION role=ts"
head -1 "$OUT/events.jsonl" 2>/dev/null || { echo "WAIT_FIRST_LINE"; cat "$OUT/agent.stdout" 2>/dev/null | head -5; }
EOS
    fi
  done
  echo "OK SESSION=$SESSION  → 等你下令 pull 后再对比"
  ;;

status)
  SESSION="${MONITOR_SESSION:-$(cat "$SESSION_FILE" 2>/dev/null || true)}"
  echo "SESSION=${SESSION:-none}"
  for ent in "${DEVICES[@]}"; do
    IFS='|' read -r tag ip scheme role <<<"$ent"
    echo "---- .$tag ($role) ----"
    if [ "$role" = zy ]; then
      ssh_r "$ip" "SCHEME=$scheme SESSION=$SESSION bash -s" <<'EOS' || echo "SSH_FAIL"
set +e
if [ "$SCHEME" = rootless ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
S=${SESSION:-$(cat $VAR/monitor/CURRENT_SESSION 2>/dev/null)}
PID=$(cat "$VAR/monitor/$S/agent.pid" 2>/dev/null)
ALIVE=0; [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && ALIVE=1
N=$(wc -l <"$VAR/monitor/$S/events.jsonl" 2>/dev/null | tr -d ' ')
SB_N=$(wc -l <"$VAR/monitor/$S/sb_restarts.jsonl" 2>/dev/null | tr -d ' ')
echo "session=$S agent_pid=$PID alive=$ALIVE lines=${N:-0} sb_restarts=${SB_N:-0}"
cat "$VAR/monitor/$S/latest.txt" 2>/dev/null | head -6
EOS
    else
      ssh_r "$ip" "SESSION=$SESSION bash -s" <<'EOS' || echo "SSH_FAIL"
set +e
S=${SESSION:-$(cat /var/mobile/Media/TS_OBS_MONITOR/CURRENT_SESSION 2>/dev/null)}
OUT=/var/mobile/Media/TS_OBS_MONITOR/$S
PID=$(cat "$OUT/agent.pid" 2>/dev/null)
ALIVE=0; [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && ALIVE=1
N=$(wc -l <"$OUT/events.jsonl" 2>/dev/null | tr -d ' ')
SB_N=$(wc -l <"$OUT/sb_restarts.jsonl" 2>/dev/null | tr -d ' ')
echo "session=$S agent_pid=$PID alive=$ALIVE lines=${N:-0} sb_restarts=${SB_N:-0}"
cat "$OUT/latest.txt" 2>/dev/null | head -6
EOS
    fi
  done
  ;;

stop)
  for ent in "${DEVICES[@]}"; do
    IFS='|' read -r tag ip scheme role <<<"$ent"
    echo "[stop] .$tag"
    if [ "$role" = zy ]; then
      ssh_r "$ip" "SCHEME=$scheme bash -s" <<'EOS' || true
set +e
if [ "$SCHEME" = rootless ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
pkill -f 'agent_ziyan.sh' 2>/dev/null
rm -f "$VAR/monitor/"*/agent.pid 2>/dev/null
echo STOPPED
EOS
    else
      ssh_r "$ip" 'pkill -f agent_ts.sh 2>/dev/null; echo STOPPED' || true
    fi
  done
  ;;

pull)
  SESSION="${MONITOR_SESSION:-$(cat "$SESSION_FILE" 2>/dev/null || true)}"
  if [ -z "$SESSION" ]; then
    echo "FAIL: no SESSION；请先 start 或 MONITOR_SESSION=..." >&2
    exit 1
  fi
  STAMP="$(date '+%Y%m%d_%H%M%S')"
  OUT="$ROOT/tmp_shots/QUAD_MONITOR/${SESSION}_PULL_${STAMP}"
  mkdir -p "$OUT"
  echo "PULL_OUT=$OUT SESSION=$SESSION" | tee "$OUT/PULL_META.txt"

  for ent in "${DEVICES[@]}"; do
    IFS='|' read -r tag ip scheme role <<<"$ent"
    D="$OUT/d${tag}"
    mkdir -p "$D"
    echo "[pull] .$tag"
    if [ "$role" = zy ]; then
      ssh_r "$ip" "SCHEME=$scheme SESSION=$SESSION bash -s" <<'EOS' >"$D/remote_snapshot.txt" 2>&1 || true
set +e
if [ "$SCHEME" = rootless ]; then VAR=/var/jb/usr/lib/ziyan/var; JB=/var/jb; else VAR=/usr/lib/ziyan/var; JB=; fi
S=$SESSION
echo "== meta =="; cat "$VAR/monitor/$S/meta.txt" 2>/dev/null
echo "== latest =="; cat "$VAR/monitor/$S/latest.txt" 2>/dev/null
echo "== procs =="; ps -axo pid,etime,rss,command 2>/dev/null | grep -E 'SpringBoard|ziyan_|lua5' | grep -v grep | head -20
echo "== hooks =="; cat "$VAR/.ziyan_hooks" 2>/dev/null
echo "== color_perf =="; cat "$VAR/.ziyan_color_perf" 2>/dev/null
echo "== toast =="; head -5 "$VAR/.ziyan_toast_dump" 2>/dev/null
echo "== crash_tail =="; tail -20 "$VAR/.ziyan_crash_log.jsonl" 2>/dev/null
echo "== sb_restart_stats =="; cat "$VAR/.ziyan_sb_restart_stats" 2>/dev/null; cat /var/mobile/ZiYan/sb_restart_stats.txt 2>/dev/null
EOS
      if [ "$scheme" = rootless ]; then
        RMON="/var/jb/usr/lib/ziyan/var/monitor/$SESSION"
      else
        RMON="/usr/lib/ziyan/var/monitor/$SESSION"
      fi
      sshpass -p "$PASS" scp "${SSH_OPTS[@]}" -r \
        "root@$ip:$RMON/." "$D/" 2>/dev/null || true
      # Media 镜像兜底
      sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
        "root@$ip:/var/mobile/Media/ZiYan/monitor/$SESSION/events.jsonl" \
        "$D/events_media.jsonl" 2>/dev/null || true
    else
      ssh_r "$ip" "SESSION=$SESSION bash -s" <<'EOS' >"$D/remote_snapshot.txt" 2>&1 || true
set +e
S=$SESSION
OUT=/var/mobile/Media/TS_OBS_MONITOR/$S
echo "== meta =="; cat "$OUT/meta.txt" 2>/dev/null
echo "== latest =="; cat "$OUT/latest.txt" 2>/dev/null
echo "== procs =="; ps -axo pid,etime,rss,command 2>/dev/null | grep -E 'SpringBoard|TSDaemon|Hades|TouchSprite' | grep -v grep | head -20
echo "== status =="; wget -q -O - -T 1 http://127.0.0.1:50005/status 2>/dev/null; echo
echo "== run.cfg =="; cat /var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null
echo "== hit_tail =="; tail -15 /var/mobile/Media/TouchSprite/tmp/zy_ts_hit.csv 2>/dev/null
echo "== log_tail =="; tail -40 /var/mobile/Media/TouchSprite/log/log.txt 2>/dev/null
EOS
      sshpass -p "$PASS" scp "${SSH_OPTS[@]}" -r \
        "root@$ip:/var/mobile/Media/TS_OBS_MONITOR/$SESSION/." "$D/" 2>/dev/null || true
      # 同步到 TS_OBS 约定目录
      TS_OBS="$ROOT/tmp_shots/TS_OBS/${STAMP}_171"
      mkdir -p "$TS_OBS"
      cp -R "$D/." "$TS_OBS/" 2>/dev/null || true
      echo "$TS_OBS" >"$OUT/TS_OBS_PATH.txt"
    fi
  done

  # 自动对比
  bash "$ROOT/tools/zy_bg_monitor_ctl.sh" compare "$OUT"
  echo "DONE $OUT"
  echo "$OUT" >"$ROOT/tmp_shots/QUAD_MONITOR/LAST_PULL"
  ;;

compare)
  DIR="${1:-}"
  if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "usage: $0 compare <PULL_DIR>" >&2
    exit 1
  fi
  REP="$DIR/COMPARE.md"
  {
    echo "# QUAD_MONITOR 对比 $(basename "$DIR")"
    echo
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')"
    echo
    echo "## 字段说明（events.jsonl）"
    echo "- \`ev=hb|sb_restart\`：心跳 / SB 进程 pid 变化"
    echo "- \`sb.pid/etime/sec/rss/cpu\`：SpringBoard 稳定性 + CPU%"
    echo "- \`lua.n/rss/cpu\`（zy）或 TSDaemon（ts）：脚本引擎"
    echo "- \`fc.n/rss/cpu\`（zy=framecap / ts=Hades）"
    echo "- \`perf\` + \`perf_age\`：找色/触动 hit 效率"
    echo "- \`inject.vol_live\`：Vol 是否与当前 SB pid 对齐（注入存活）"
    echo "- \`flags.te/active/thin\`：脚本会话"
    echo
    echo "## 总表"
    echo
    echo "| 机 | role | lines | sb_restarts | sb_pid | sb_etime | sb_sec | lua/ts_n | fc/hades | perf_age | inj_vol | load1 |"
    echo "|----|------|------:|------------:|-------:|---------:|-------:|---------:|---------:|---------:|--------:|------:|"
    for tag in 53 101 112 166 171; do
      D="$DIR/d${tag}"
      EV="$D/events.jsonl"
      [ -f "$EV" ] || EV="$D/events_media.jsonl"
      if [ ! -f "$EV" ]; then
        echo "| .$tag | ? | 0 | - | - | - | - | - | - | - | - | - |"
        continue
      fi
      LINES=$(wc -l <"$EV" | tr -d ' ')
      SB_R=0
      [ -f "$D/sb_restarts.jsonl" ] && SB_R=$(wc -l <"$D/sb_restarts.jsonl" | tr -d ' ')
      # 取最后一行关键字段（粗解析）
      LAST=$(tail -1 "$EV")
      role=$(echo "$LAST" | sed -n 's/.*"role":"\([^"]*\)".*/\1/p')
      sb_pid=$(echo "$LAST" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p' | head -1)
      sb_etime=$(echo "$LAST" | sed -n 's/.*"etime":"\([^"]*\)".*/\1/p' | head -1)
      sb_sec=$(echo "$LAST" | sed -n 's/.*"sec":\([0-9]*\).*/\1/p' | head -1)
      lua_n=$(echo "$LAST" | sed -n 's/.*"lua":{"n":\([0-9]*\).*/\1/p')
      fc_n=$(echo "$LAST" | sed -n 's/.*"fc":{"n":\([0-9]*\).*/\1/p')
      perf_age=$(echo "$LAST" | sed -n 's/.*"perf_age":\([0-9]*\).*/\1/p')
      inj=$(echo "$LAST" | sed -n 's/.*"vol_live":\([-0-9]*\).*/\1/p')
      load1=$(echo "$LAST" | sed -n 's/.*"load1":"\([^"]*\)".*/\1/p')
      echo "| .$tag | ${role:-?} | $LINES | $SB_R | ${sb_pid:-?} | ${sb_etime:-?} | ${sb_sec:-?} | ${lua_n:-?} | ${fc_n:-?} | ${perf_age:-?} | ${inj:-?} | ${load1:-?} |"
    done
    echo
    echo "## SB 重启明细"
    echo
    for tag in 53 101 112 166 171; do
      F="$DIR/d${tag}/sb_restarts.jsonl"
      echo "### .$tag"
      if [ -f "$F" ] && [ -s "$F" ]; then
        cat "$F"
      else
        echo "_无 sb_restart 事件_"
      fi
      echo
    done
    echo "## 各机 latest 快照"
    echo
    for tag in 53 101 112 166 171; do
      echo "### .$tag"
      echo '```'
      cat "$DIR/d${tag}/latest.txt" 2>/dev/null || echo MISSING
      echo '```'
      echo
    done
    echo "## 分析提示（给 Agent）"
    echo "1. 先比 \`sb_restarts\` 与 \`sb.sec\`（.171 应为长 etime 基线）"
    echo "2. 再比 \`lua.n\`/\`fc.n\` 与 \`perf_age\`（脚本是否空转/找色卡住）"
    echo "3. \`inject.vol_live=0\` 且 hooks 的 sb_pid≠当前 → 注入丢失"
    echo "4. toast 有文案但用户看不见 → 查 toast 桥，勿误判脚本死"
    echo "5. 禁止把 .171 写成 ZiYan PASS"
  } >"$REP"
  echo "COMPARE → $REP"
  ;;

*)
  cat <<'EOF'
usage:
  tools/zy_bg_monitor_ctl.sh start
  tools/zy_bg_monitor_ctl.sh status
  tools/zy_bg_monitor_ctl.sh stop
  tools/zy_bg_monitor_ctl.sh pull      # 你下令后再跑
  tools/zy_bg_monitor_ctl.sh compare <PULL_DIR>
EOF
  exit 1
  ;;
esac
