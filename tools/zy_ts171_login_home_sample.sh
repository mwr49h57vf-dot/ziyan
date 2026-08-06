#!/usr/bin/env bash
# .171 触动只读采样（禁部署 ZiYan / 禁改 TS 包）
# 流程：观察 toast/日志出现「登录」→ 最小化前台 → 采状态；反复 N 次
# 用法：bash tools/zy_ts171_login_home_sample.sh [rounds=10]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
ROUNDS="${1:-10}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/TS171_LOGIN_HOME_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.171" "$@"; }

echo "OUT=$OUT ROUNDS=$ROUNDS (observe-only .171)" | tee "$OUT/OUT_PATH.txt"

# 连通重试
OK=0
for t in 1 2 3 4 5 6; do
  if ssh_r 'echo TS171_OK' 2>/dev/null | grep -q TS171_OK; then OK=1; break; fi
  sleep 3
done
if [ "$OK" != 1 ]; then
  echo "FAIL: .171 SSH unreachable" | tee "$OUT/FAIL.txt"
  exit 2
fi

ssh_r "ROUNDS=$ROUNDS bash -s" <<'EOS' | tee "$OUT/sample.txt"
set +e
TS=/var/mobile/Media/TouchSprite
echo META_TS_LUA=$(ls -lt "$TS/lua" 2>/dev/null | head -6)
echo RUN_CFG=$(cat "$TS/config/run.cfg" 2>/dev/null)
echo TSDaemon=$(ps -A 2>/dev/null | grep -v grep | grep TSDaemon | head -1)

# 触动 toast「登录」默认不写 ts.log；兼容：
#  A) log/tmp 文本  B) 旁路文件 $TS/tmp/zy_ts_toast.txt（若你批准给 main.lua 加一行写文件）
#  C) 色参代理：登录 ROI getColor 接近 0x90643b（无截图像素工具时跳过）
TOAST_BYPASS="$TS/tmp/zy_ts_toast.txt"
seen_login() {
  grep -a '登录' "$TS/log/ts.log" "$TS/log/err.log" "$TOAST_BYPASS" "$TS/tmp"/* 2>/dev/null | tail -5
  find "$TS/tmp" -type f -mmin -30 2>/dev/null | while read f; do
    grep -aq '登录' "$f" 2>/dev/null && echo "HIT_FILE=$f $(tail -c 200 "$f" | tr '\n' ' ')"
  done
}
login_marker() {
  # 旁路文件最后一行是登录且 mtime 近 15s
  if [ -f "$TOAST_BYPASS" ]; then
    local age mt now
    mt=$(stat -f %m "$TOAST_BYPASS" 2>/dev/null || stat -c %Y "$TOAST_BYPASS" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$mt" ] && [ $((now - mt)) -le 15 ]; then
      tail -1 "$TOAST_BYPASS" 2>/dev/null | grep -q '登录' && return 0
    fi
  fi
  grep -aq '登录' "$TS/log/ts.log" 2>/dev/null && return 0
  grep -aqR '登录' "$TS/tmp" 2>/dev/null && return 0
  return 1
}

go_home_ts() {
  # 只读观察机：用系统 Home（无 ZiYan go_home）；优先 activator / uiopen SpringBoard
  if command -v activator >/dev/null 2>&1; then
    activator send libactivator.system.homebutton 2>/dev/null || true
  fi
  # 再试 hid 模拟不可靠时：写触动常见 home 请求（若存在）
  [ -d "$TS/tmp" ] && echo 1 >"$TS/tmp/.zy_observe_home_req" 2>/dev/null || true
  sleep 1.2
}

R=0
while [ "$R" -lt "$ROUNDS" ]; do
  R=$((R + 1))
  echo "==== TS_ROUND $R/$ROUNDS ===="
  # 等「登录」（最多 90s）
  LOGIN=0
  d=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$d" ]; do
    if login_marker; then
      LOGIN=1
      echo "LOGIN_SEEN=1"
      seen_login | head -5
      break
    fi
    sleep 2
  done
  if [ "$LOGIN" != 1 ]; then
    echo "TS_ROUND_${R}_LOGIN_TIMEOUT"
    echo "HINT=toast不进ts.log；批准后可在main.lua toast(\"登录\")旁加写 $TOAST_BYPASS"
    echo TS_LOG_TAIL=$(tail -8 "$TS/log/ts.log" 2>/dev/null | tr '\n' '|')
    echo TS_COLORS="first=0xbd8216@1009,330 login=0x90643b@652,443"
    continue
  fi
  # 最小化
  go_home_ts
  sleep 1
  FRONT=$(cat /var/mobile/Library/Preferences/.front_bid 2>/dev/null)
  # front 备选
  FRONT2=$(ls -l /var/mobile/Library/SpringBoard 2>/dev/null | head -1)
  echo "AFTER_HOME round=$R"
  echo "TS_CPU=$(ps -A -o %cpu,command 2>/dev/null | grep TSDaemon | grep -v grep | head -1)"
  echo "HADES=$(ps -A 2>/dev/null | grep -v grep | grep Hades | head -1)"
  echo "LOG_SZ=$(ls -l "$TS/log/ts.log" 2>/dev/null | tr -s ' ' | cut -d' ' -f5)"
  echo "HIT_CSV=$(ls -l "$TS/tmp"/zy_ts_hit.csv "$TS/tmp"/*hit* 2>/dev/null | head -3)"
  # 采样窗口 8s
  sleep 8
  echo "SAMPLE_DONE round=$R"
done
echo TS171_SAMPLE_DONE
EOS

{
  echo "# TS171 LOGIN→HOME SAMPLE"
  echo
  grep -E 'TS_ROUND|LOGIN_SEEN|SAMPLE_DONE|TIMEOUT|TS171_' "$OUT/sample.txt" || true
} | tee "$OUT/VERDICT.md"
cp -f "$OUT/VERDICT.md" "$ROOT/tmp_shots/TS171_LOGIN_HOME_VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
