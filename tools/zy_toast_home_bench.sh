#!/usr/bin/env bash
# zy_toast_home_bench.sh — 四机+171：Home/滑关游戏时 toast 几何与找色对拍
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=alpine
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/SURPASS_TS/TOAST_HOME_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"

ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

# ── 确保脚本在跑 ──────────────────────────────────────────
ensure_script() {
  local tag=$1 scheme=$2 script=$3 bid=$4
  ssh_r "192.168.31.$tag" "SCHEME=$scheme SCRIPT=$script BID=$bid bash -s" <<'EOS'
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var; LUA=/var/jb/usr/lib/ziyan/bin/lua5.3; RUN=/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:$PATH; export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
else
  VAR=/usr/lib/ziyan/var; LUA=/usr/lib/ziyan/bin/lua5.3; RUN=/usr/lib/ziyan/lib/lua/ziyan_run.lua
fi
N=$(ps -A -o command=|grep ziyan_run.lua|grep -v grep|wc -l|tr -d ' ')
echo 1 >"$VAR/.ziyan_light"; echo "$BID" >"$VAR/.ziyan_target_bid"
if [ "$N" -lt 1 ]; then
  echo "$BID" >"$VAR/.ziyan_open_app"
  cd /var/mobile/Media/ZiYan
  nohup "$LUA" "$RUN" "/var/mobile/Media/ZiYan/$SCRIPT" >/tmp/${SCRIPT%.lua}_tb.log 2>&1 &
  sleep 2
fi
echo "lua=$(ps -A -o command=|grep ziyan_run|grep -v grep|wc -l|tr -d ' ') front=$(cat $VAR/.ziyan_front_bid)"
EOS
}

ensure_script 53 rootless ios8p.lua com.ljzbbadao.game
ensure_script 101 rootful ios7.lua com.xztl.ios
ensure_script 112 rootful ios7.lua com.xztl.ios
ensure_script 166 rootful ios7.lua com.xztl.ios
sleep 3

sample_zy() {
  local tag=$1 phase=$2
  ssh_r "192.168.31.$tag" "PHASE=$phase bash -s" <<'EOS'
set +e
VAR=/usr/lib/ziyan/var; [ -d /var/jb/usr/lib/ziyan/var ] && VAR=/var/jb/usr/lib/ziyan/var
echo "PHASE=$PHASE"
echo "FRONT=$(cat $VAR/.ziyan_front_bid 2>/dev/null)"
echo "ORIENT=$(cat $VAR/.ziyan_orient 2>/dev/null | tr '\n' ' ')"
echo "TOAST_DBG<<"
cat $VAR/.ziyan_toast_dbg 2>/dev/null | head -20
echo ">>"
# extract key fields
DBG=$(cat $VAR/.ziyan_toast_dbg 2>/dev/null)
echo "$DBG" | tr ';' '\n' | grep -E 'mode=|toastLock=|host=|logic=|label.center=|screenLand=|rawLand=' | head -20
echo "COLOR=$(cat $VAR/.ziyan_color_perf 2>/dev/null | head -1)"
echo "MIN=$(tail -3 $VAR/.ziyan_minimize_log 2>/dev/null | tr '\n' '|')"
EOS
}

sample_ts() {
  local phase=$1
  ssh_r 192.168.31.171 "PHASE=$phase bash -s" <<'EOS'
set +e
echo "PHASE=$PHASE"
echo "STATUS=$(wget -q -O - -T1 http://127.0.0.1:50005/status 2>/dev/null)"
HIT=/var/mobile/Media/TouchSprite/tmp/zy_ts_hit.csv
echo "HIT_TAIL=$(tail -2 $HIT 2>/dev/null | tr '\n' ';')"
ps -A -o %cpu=,command= | grep -iE 'Hades|TSDaemon|xztl' | grep -v grep | head -5
# snapshot bytes as toast-stability proxy (TS keeps drawing)
wget -q -O /tmp/ts_snap_$PHASE.png -T 2 http://127.0.0.1:50005/snapshot 2>/dev/null || true
ls -la /tmp/ts_snap_$PHASE.png 2>/dev/null
EOS
}

echo "======== T0 baseline (game front) ========"
for tag in 53 101 112 166; do
  sample_zy "$tag" t0 >"$OUT/zy${tag}_t0.txt" 2>&1 &
done
sample_ts t0 >"$OUT/ts171_t0.txt" 2>&1 &
wait

echo "======== T1 physical Home x3 ========"
for tag in 53 101 112 166; do
  ssh_r "192.168.31.$tag" 'bash -s' <<'EOS'
VAR=/usr/lib/ziyan/var; [ -d /var/jb/usr/lib/ziyan/var ] && VAR=/var/jb/usr/lib/ziyan/var
for i in 1 2 3; do echo 1 >"$VAR/.ziyan_go_home"; sleep 0.25; done
EOS
done
# TS: kill game + reopen cycle (simulate home)
ssh_r 192.168.31.171 'killall -9 com.xztl.ios 2>/dev/null; sleep 0.5; uiopen "com.xztl.ios://" >/dev/null 2>&1; true' || true
sleep 2

for tag in 53 101 112 166; do
  sample_zy "$tag" t1_home >"$OUT/zy${tag}_t1.txt" 2>&1 &
done
sample_ts t1_home >"$OUT/ts171_t1.txt" 2>&1 &
wait

echo "======== T2 swipe-close game (kill) x2 ========"
for tag in 53 101 112 166; do
  ssh_r "192.168.31.$tag" 'bash -s' <<'EOS'
VAR=/usr/lib/ziyan/var; [ -d /var/jb/usr/lib/ziyan/var ] && VAR=/var/jb/usr/lib/ziyan/var
BID=$(cat "$VAR/.ziyan_target_bid" 2>/dev/null)
# 滑关等价：杀游戏进程（不杀脚本）
killall -9 com.xztl.ios com.ljzbbadao.game 2>/dev/null
sleep 0.4
# 再杀一次模拟连滑
killall -9 com.xztl.ios com.ljzbbadao.game 2>/dev/null
sleep 0.8
echo "front_now=$(cat $VAR/.ziyan_front_bid)"
EOS
done
ssh_r 192.168.31.171 'killall -9 com.xztl.ios 2>/dev/null; sleep 0.8; true' || true
sleep 1

for tag in 53 101 112 166; do
  sample_zy "$tag" t2_kill >"$OUT/zy${tag}_t2.txt" 2>&1 &
done
sample_ts t2_kill >"$OUT/ts171_t2.txt" 2>&1 &
wait

echo "======== T3 after auto-resume settle ========"
sleep 3
for tag in 53 101 112 166; do
  sample_zy "$tag" t3_settle >"$OUT/zy${tag}_t3.txt" 2>&1 &
done
# TS: relaunch game for fair continue
ssh_r 192.168.31.171 'uiopen "com.xztl.ios://" >/dev/null 2>&1; sleep 1; true' || true
sample_ts t3_settle >"$OUT/ts171_t3.txt" 2>&1 &
wait

# ── VERDICT ───────────────────────────────────────────────
{
  echo "# VERDICT TOAST_HOME $STAMP"
  echo
  echo "## 目标"
  echo "- 触动 .171：任意 Home/关游戏，toast 位置不变"
  echo "- 子砚：会话内 toastLock=1 / mode=sessionLock_portraitHost，关游戏不改 host"
  echo
  echo "## 各阶段 toast 关键字段"
  for tag in 53 101 112 166; do
    echo "### .$tag"
    for ph in t0 t1 t2 t3; do
      f="$OUT/zy${tag}_${ph}.txt"
      echo "- **$ph**: front=$(grep '^FRONT=' "$f" 2>/dev/null | head -1)"
      grep -E 'toastLock=|mode=sessionLock|mode=|host=' "$f" 2>/dev/null | head -4 | sed 's/^/  /'
    done
    echo
  done
  echo "## .171"
  for ph in t0 t1 t2 t3; do
    echo "- $ph: $(grep STATUS= "$OUT/ts171_${ph}.txt" 2>/dev/null | head -1) $(grep HIT_TAIL= "$OUT/ts171_${ph}.txt" 2>/dev/null | head -1)"
  done
  echo
  echo "## 判定"
  echo "- t0→t2 若 toastLock 恒为 1 且 host 尺寸不变 → PASS（对齐触动不跳位）"
  echo "- 证据目录: \`$OUT\`"
} | tee "$OUT/VERDICT.md"

echo "DONE $OUT/VERDICT.md"
