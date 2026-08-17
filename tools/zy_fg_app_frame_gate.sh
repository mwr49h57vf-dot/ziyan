#!/usr/bin/env bash
# 前台 App 帧龄门禁（反复最小化/恢复）
# 用法：bash tools/zy_fg_app_frame_gate.sh <53|101|112|166> [bundle_id] [cycles]
#
# 为什么必须有它：
#   Z1 全部门禁都跑在桌面，而桌面恰好是 CARender 唯一能出图的场景。四机门禁全绿，
#   真实业务里却卡死：实测 .101 帧龄 9~14s、.112 2~7s、.166 391s（.ziyan_find_shm_log
#   的 age_ms）。「找色不准」是表象，根因是找色读到冻结旧帧。
#   本门禁把「反复最小化前台 App」这个真实场景做成可复现判据：
#     1. 帧龄 age_ms 必须 < 阈值（默认 1200ms）
#     2. shm_bid 必须等于当前 front_bid（帧属于当前前台，不是旧 App 冻帧）
#     3. 帧 seq 必须在推进（不是同一张老帧反复被读）
#     4. App 前台时的画面必须与桌面画面不同（证明帧真跟着前台切换）
#
# 取证走 HTTP /status（纯 curl，被动读 shm 头，不催帧、不污染帧龄），
# 因此每轮必须先读 /status 再取 /snapshot —— /snapshot 会 force_recap 把帧龄清零。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
TAG="${1:-}"
BID_ARG="${2:-}"
CYCLES="${3:-${ZY_FG_CYCLES:-6}}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/FG_APP_FRAME_${STAMP}_${TAG}"

# 帧龄上限（ms）。触动侧同场景下找色读到的帧基本在百毫秒级；这里留足余量。
AGE_MAX="${ZY_FG_AGE_MAX:-1200}"
# 「桌面画面 vs App 画面」判不同的像素差比例下限
DIFF_MIN="${ZY_FG_DIFF_MIN:-0.05}"
# 每次切换后等待前台稳定的秒数
SETTLE="${ZY_FG_SETTLE:-5}"

case "$TAG" in
  53) IP=192.168.31.53; SCHEME=rootless ;;
  101) IP=192.168.31.101; SCHEME=rootful ;;
  112) IP=192.168.31.112; SCHEME=rootful ;;
  166) IP=192.168.31.166; SCHEME=rootful ;;
  *) echo "usage: $0 <53|101|112|166> [bundle_id] [cycles]"; exit 2 ;;
esac
mkdir -p "$OUT"

# 同一设备的门禁会写同一组 .ziyan_embed_* / .ziyan_find_* 控制文件；并发运行会
# 互相截断证据，得到看似正常、实际不可归因的结果。用原子 mkdir 做本机单例锁。
LOCAL_LOCK="$ROOT/tmp_shots/.fg_app_frame_gate_${TAG}.lock"
if ! mkdir "$LOCAL_LOCK" 2>/dev/null; then
  echo "VERDICT=ERROR reason=gate_already_running tag=$TAG lock=$LOCAL_LOCK"
  exit 75
fi
release_local_lock() { rmdir "$LOCAL_LOCK" 2>/dev/null || true; }
trap release_local_lock EXIT

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12)
# 设备 SSH 配置并不完全一致：多数测试机使用密码，.166 当前仅接受已配置的
# 本机公钥。先在没有 stdin 的探针上确定一种认证方式，之后所有命令固定走该
# 方式。这样 heredoc/base64 的单次传输既不会因失败重试而读空，也不会把认证
# 差异误报为产品门禁失败。
SSH_AUTH=()
init_ssh_auth() {
  if sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" \
       -o PreferredAuthentications=password -o PubkeyAuthentication=no \
       "root@$IP" true >/dev/null 2>&1; then
    SSH_AUTH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" \
              -o PreferredAuthentications=password -o PubkeyAuthentication=no)
    echo "SSH_AUTH=password"
    return 0
  fi
  if ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "root@$IP" true >/dev/null 2>&1; then
    SSH_AUTH=(ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes)
    echo "SSH_AUTH=key"
    return 0
  fi
  echo "VERDICT=ERROR reason=ssh_auth_failed ip=$IP" >&2
  return 1
}
# 越狱机 sshd 在短时间大量连接后会偶发 "Permission denied"（认证限流）。
# 本门禁每轮要开 6 个连接，三机并行时必然撞上；不重试 + set -e 会让脚本在
# 第 4 轮直接退出，看起来像「跑完了」，实际证据缺一半。
ssh_r() {
  local i
  for i in 1 2 3 4; do
    if "${SSH_AUTH[@]}" "root@$IP" "$@"; then
      return 0
    fi
    sleep $((i * 2))
  done
  return 1
}
# 喂 stdin（heredoc / base64）的调用不能重试：第一次尝试已把 stdin 读空，
# 重试会把空脚本送上去，静默什么都不做，比直接失败更难查。
ssh_once() { "${SSH_AUTH[@]}" "root@$IP" "$@"; }
# 但本地 probe 文件可以在每次尝试重新打开并重新编码；.101 的 sshd 偶发认证
# 限流时，旧的单次 base64|ssh 会让整个 P2 在“清场”后直接退出，根本没有开始
# 业务找色。此函数只接受文件路径，故不会复用耗尽的 stdin。
upload_b64_file() { # upload_b64_file <local-file> <remote-command>
  local src="$1" remote_cmd="$2" i
  for i in 1 2 3 4; do
    if base64 <"$src" | "${SSH_AUTH[@]}" "root@$IP" "$remote_cmd"; then
      return 0
    fi
    sleep $((i * 2))
  done
  return 1
}

if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
M=/private/var/mobile/Media/ZiYan
init_ssh_auth

# ---- 目标 App：优先入参，否则从 uicache 挑一个第三方 App ----
BID="$BID_ARG"
if [ -z "$BID" ]; then
  BID=$(ssh_r "uicache -l 2>/dev/null" | awk -F' : ' '{print $1}' \
        | grep -vE '^(com\.apple\.|com\.saurik\.|com\.ziyan\.|kjc\.|$)' | head -1 | tr -d '\r')
fi
[ -n "$BID" ] || { echo "VERDICT=FAIL reason=no_target_app_found"; exit 1; }

PORT_FILE=$(ssh_r "cat $V/.ziyan_snap_http_port 2>/dev/null" | tr -dc '0-9')
# framecap 在升级/看门狗交接时可能由短命旧实例最后写入端口文件：真实监听
# 仍在 50005，而文件残留 50015。P2 若只信这个提示文件会把“监控盲区”写成
# 帧龄失败。以 /status 的实际响应选择端口；端口文件仅作为候选之一。
PORT=""
for candidate in "$PORT_FILE" 50005 50015; do
  [ -n "$candidate" ] || continue
  [ "$candidate" = "$PORT" ] && continue
  probe=$(curl -s -m 3 "http://$IP:$candidate/status" 2>/dev/null || true)
  if [ -n "$probe" ] && { grep -q '^zy1' <<<"$probe" || grep -q '^engine=ZiYan' <<<"$probe"; }; then
    PORT="$candidate"
    break
  fi
done
[ -n "$PORT" ] || { echo "VERDICT=ERROR reason=snapshot_http_unreachable port_file=${PORT_FILE:-none}"; exit 1; }
echo "META tag=$TAG scheme=$SCHEME bid=$BID cycles=$CYCLES snap_port=$PORT age_max=${AGE_MAX}ms"

# ---- /status 探针：被动读 shm 头，不催帧 ----
status_line() { curl -s -m 8 "http://$IP:$PORT/status" 2>/dev/null || true; }
st_get() { sed -n "s/^$2=\(.*\)$/\1/p" <<<"$1" | head -1 | tr -d '\r'; }

snap() {  # snap <outfile>；会 force_recap，只在读完 /status 之后调用
  local dst="$1" i r
  for i in 1 2 3 4 5; do
    r=$(curl -s -m 20 -o "$dst" -w '%{http_code}' "http://$IP:$PORT/snapshot" || echo 000)
    # /snapshot 在没有有效帧时也可能返回 HTTP 200 + 短错误正文。只检查非空会
    # 把该正文保存成 .png，最后在 PIL 中异常退出，既没有 VERDICT，也把真正的
    # 首帧失败掩盖成测试工具崩溃。必须同时校验 PNG 8 字节魔数。
    sig=$(od -An -tx1 -N8 "$dst" 2>/dev/null | tr -d ' \n')
    [ "$r" = "200" ] && [ "$sig" = "89504e470d0a1a0a" ] && return 0
    sleep 2
  done
  return 1
}

go_home() {
  ssh_r "set +e; echo 1 >'$V/.ziyan_go_home'; chmod 666 '$V/.ziyan_go_home' 2>/dev/null; \
         sleep 1.5; rm -f '$V/.ziyan_go_home'" >/dev/null 2>&1 || true
}

open_app() {  # 仅走 bundle IPC；iOS13 的 uiopen 只接受 URL，不能当 bundle launcher
  ssh_r "set +e; rm -f '$V/.ziyan_app_user_closed'; \
         printf '%s\n' '$BID' >'$V/.ziyan_open_app'; \
         printf '%s\n' '$BID' >'$M/.ziyan_open_app'; \
         chmod 666 '$V/.ziyan_open_app' '$M/.ziyan_open_app' 2>/dev/null" \
    >/dev/null 2>&1 || true
}

front_bid() { ssh_r "tr -d '\r\n' <'$V/.ziyan_front_bid' 2>/dev/null" 2>/dev/null || true; }

wait_front() {  # wait_front <bid> <max_sec>
  local want="$1" lim="$2" i=0 f
  while [ "$i" -lt "$lim" ]; do
    f=$(front_bid)
    [ "$f" = "$want" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ---- 清场：停旧脚本、确保守护在跑 ----
echo "==== 清场 ===="
ssh_once "V='$V' M='$M' ZY_FG_BBFRAME='${ZY_FG_BBFRAME:-0}' bash -s" <<'EOS' | tee "$OUT/setup.txt"
set +e
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; sleep 1
# 旧 embed 的 Lua hook 可能需要数十秒才退出。直接删除 alive 标记会让门禁
# 误以为清场完成，随后新 embed_go 被仍在退出的旧线程吞掉。先等待真实线程
# 清理 `.ziyan_lua_embedded/.ziyan_embed_alive`，最多 60 秒；超时仍继续并由
# EMBED_STARTED=0 明确判 FAIL。
for i in $(seq 1 120); do
  [ ! -e "$V/.ziyan_lua_embedded" ] && [ ! -e "$V/.ziyan_embed_alive" ] && break
  sleep 0.5
done
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_off" "$V/.ziyan_active" "$V/.ziyan_lua_embedded" \
  "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" "$V/.ziyan_embed_script" \
  "$V/.ziyan_embed_on" "$V/.ziyan_embed_alive" "$V/.ziyan_find_pulse" \
  "$V/.ziyan_keep_daemon" "$V/.ziyan_app_user_closed" \
  "$V/.ziyan_app_suspend_trig" "$V/.ziyan_app_run_trig" \
  "$V/.ziyan_app_stop_trig" "$V/.ziyan_app_minimize_req" \
  "$M/_fg_gate_beat.txt"
# zydaemon 会根据旧 run_intent 在约一秒后 revive 作者业务脚本；上述清理
# 必须在 kill 后留出一次轮询窗口，否则 gate probe 与 ios7.lua 同时运行，
# 造成 Home 回弹、embed_started=0 等“测试自身污染”的假失败。
sleep 1
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null
# BBFrame 默认 off（冷启动卡死根因）；仅 ZY_FG_BBFRAME=1 时 opt-in。
# 供帧主路径：守护 UICreate（provider=7），SB 中继冷备。
if [ "${ZY_FG_BBFRAME:-0}" = "1" ]; then
  echo 1 >"$V/.ziyan_bbframe_on"; chmod 666 "$V/.ziyan_bbframe_on" 2>/dev/null
  rm -f "$V/.ziyan_bbframe_no_sustain"
else
  rm -f "$V/.ziyan_bbframe_on"
fi
: >"$V/.ziyan_find_shm_log"; chmod 666 "$V/.ziyan_find_shm_log" 2>/dev/null
: >"$V/.ziyan_find_timing_log"; chmod 666 "$V/.ziyan_find_timing_log" 2>/dev/null
FC=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)
if [ "${FC:-0}" -eq 0 ]; then
  echo zydaemon >"$V/.ziyan_framecap_owner_mode"
  echo 1 >"$V/.ziyan_watchdog_framecap_need"
  chmod 666 "$V/.ziyan_framecap_owner_mode" "$V/.ziyan_watchdog_framecap_need" 2>/dev/null || true
  sleep 4
fi
echo "FC_N=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep)"
EOS

# ---- 常驻找色脚本：业务真实节奏（每 300ms 一次全屏找色）----
# 没有它，守护会进冷闲态，帧龄天然很大，门禁就测不到「业务在跑时读到的帧有多旧」。
# 每轮实际开销远大于 settle*2：open_app 等前台最多 15s、两次 /snapshot 最多各 20s、
# 加 SSH 重试。按 45s/轮 + 120s 余量给，否则找色脚本会在门禁跑完前先退出，
# 后几轮帧龄失去意义（实测 132s 的估算让 .101/.166 第 4 轮就断证）。
# 换前台失败最多重发 3 次 open_app，每次 25s 等待 + settle，故按 70s/轮估。
DUR=$(( CYCLES * 70 + 150 ))
cat >"$OUT/probe.lua" <<LUA
function main()
  init(1)
  local t0 = os.time()
  local n, hit = 0, 0
  while os.time() - t0 < $DUR do
    local x, y = findMultiColorInRegionFuzzy(
      "0xffffff", "1|0|0xffffff", 90, 0, 0, -1, -1)
    n = n + 1
    if x and x >= 0 then hit = hit + 1 end
    if n % 10 == 0 then
      local f = io.open("$M/_fg_gate_beat.txt", "w")
      if f then f:write("n=" .. n .. " hit=" .. hit .. " ts=" .. os.time() .. "\n"); f:close() end
    end
    mSleep(300)
  end
end
LUA
upload_b64_file "$OUT/probe.lua" "mkdir -p '$M' && base64 -d >'$M/_fg_gate_probe.lua' && \
  chmod 666 '$M/_fg_gate_probe.lua'"

echo "==== 起常驻找色（${DUR}s）===="
ssh_once "V='$V' M='$M' bash -s" <<'EOS' | tee -a "$OUT/setup.txt"
set +e
STARTED=0
for r in 1 2 3; do
  printf 'path=%s/_fg_gate_probe.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
  printf '%s/_fg_gate_probe.lua\n' "$M" >"$V/.ziyan_embed_script"
  echo 1 >"$V/.ziyan_embed_on"
  echo "nonce=fggate_${r}_$$" >"$V/.ziyan_embed_go"
  chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" \
    "$V/.ziyan_embed_on" "$V/.ziyan_embed_go" 2>/dev/null
  # `.101` 实测软停后的新 embed 最慢约 50 秒才进入 start；给足 60 秒，
  # 避免实际已启动却被测试工具提前写成 EMBED_STARTED=0。
  for i in $(seq 1 120); do
    if [ -s "$M/_fg_gate_beat.txt" ] || [ -s "$V/.ziyan_find_shm_log" ]; then STARTED=1; break; fi
    sleep 0.5
  done
  [ "$STARTED" = 1 ] && break
  echo "WARN embed_start_retry=$r"
done
echo "EMBED_STARTED=$STARTED"
EOS

STARTED=$(sed -n 's/^EMBED_STARTED=\([0-9]*\).*/\1/p' "$OUT/setup.txt" | head -1)

cleanup() {
  ssh_r "set +e; printf 'ts=1\n' >'$V/.ziyan_kill_scripts'; sleep 1; \
    rm -f '$V/.ziyan_kill_scripts' '$V/.ziyan_run_intent' '$V/.ziyan_embed_go' \
      '$V/.ziyan_embed_script' '$V/.ziyan_active' '$V/.ziyan_keep_daemon' \
      '$V/.ziyan_app_suspend_trig' '$V/.ziyan_app_run_trig' \
      '$V/.ziyan_app_stop_trig' '$V/.ziyan_app_minimize_req' \
      '$M/_fg_gate_probe.lua' '$M/_fg_gate_beat.txt'; \
    echo 1 >'$V/.ziyan_go_home'; sleep 2; rm -f '$V/.ziyan_go_home'" >/dev/null 2>&1 || true
  release_local_lock
}
trap cleanup EXIT

# ---- 基线：桌面画面 ----
echo "==== 桌面基线 ===="
go_home
sleep "$SETTLE"
HOME_ST=$(status_line)
echo "HOME_STATUS age=$(st_get "$HOME_ST" frame_age_ms) prov=$(st_get "$HOME_ST" frame_provider) \
front=$(st_get "$HOME_ST" front_bid) shm=$(st_get "$HOME_ST" shm_bid)"
snap "$OUT/home.png" || echo "WARN home_snapshot_failed"

# ---- 反复最小化 / 恢复 ----
FAILS=0
PREV_SEQ=-1
: >"$OUT/cycles.txt"
for c in $(seq 1 "$CYCLES"); do
  echo "==== 第 $c 轮：恢复 $BID ===="
  # 冷启动首轮 App 可能起到一半又被打回桌面（实测 .112 前两轮 front 仍是
  # springboard），此时采到的帧龄衡量的是「桌面帧多旧」，与本门禁要测的东西无关。
  # 因此换前台失败要重发 open_app，而不是直接记一笔帧断言失败。
  FRONT_OK=0
  for a in 1 2 3; do
    open_app
    wait_front "$BID" 25 || true
    sleep "$SETTLE"
    # settle 之后复核：wait_front 只看到过一瞬间的目标前台不算数
    if [ "$(front_bid)" = "$BID" ]; then
      FRONT_OK=1
      break
    fi
    echo "cycle=$c open_app_retry=$a front=$(front_bid)"
    go_home
    sleep 1
  done
  if [ "$FRONT_OK" != 1 ]; then
    echo "cycle=$c FAIL open_app_front_mismatch front=$(front_bid)" | tee -a "$OUT/cycles.txt"
    FAILS=$((FAILS + 1))
    go_home; sleep "$SETTLE"
    continue
  fi

  # 先被动读帧龄，再取图（取图会 force_recap 清零帧龄）
  ST=$(status_line)
  AGE=$(st_get "$ST" frame_age_ms)
  SEQ=$(st_get "$ST" frame_seq)
  PROV=$(st_get "$ST" frame_provider)
  FST=$(st_get "$ST" frame_status)
  FRONT=$(st_get "$ST" front_bid)
  SHM=$(st_get "$ST" shm_bid)
  AGE="${AGE:--1}"; SEQ="${SEQ:--1}"

  LINE="cycle=$c age_ms=$AGE seq=$SEQ provider=$PROV status=$FST front=$FRONT shm_bid=$SHM"

  if [ "$AGE" -lt 0 ] 2>/dev/null || [ "$AGE" -gt "$AGE_MAX" ] 2>/dev/null; then
    LINE="$LINE FAIL:stale_frame(>${AGE_MAX}ms)"
    FAILS=$((FAILS + 1))
  fi
  if [ "$SHM" != "$FRONT" ]; then
    # 帧属于旧 App 就等于在 Home 上扫游戏冻帧，违 fg-always-vision
    LINE="$LINE FAIL:shm_bid_mismatch"
    FAILS=$((FAILS + 1))
  fi
  # seq 回绕到更小值：守护冷回收 / 工作集重建会把 seq 重置，只要帧龄新鲜
  # 就不是「冻帧反复被读」。.53 实测 cycle6 seq 21→1 且 age=51ms，旧判据误杀。
  if [ "$PREV_SEQ" -ge 0 ] 2>/dev/null && [ "$SEQ" -le "$PREV_SEQ" ] 2>/dev/null; then
    if [ "$AGE" -ge 0 ] 2>/dev/null && [ "$AGE" -le "$AGE_MAX" ] 2>/dev/null; then
      LINE="$LINE NOTE:seq_reset(prev=$PREV_SEQ age_ok)"
    else
      LINE="$LINE FAIL:seq_not_advancing(prev=$PREV_SEQ)"
      FAILS=$((FAILS + 1))
    fi
  fi
  PREV_SEQ="$SEQ"

  if ! snap "$OUT/app_${c}.png"; then
    LINE="$LINE FAIL:snapshot_invalid"
    FAILS=$((FAILS + 1))
  fi
  echo "$LINE" | tee -a "$OUT/cycles.txt"

  echo "---- 最小化 ----"
  go_home
  sleep "$SETTLE"
  HST=$(status_line)
  echo "cycle=$c home_age_ms=$(st_get "$HST" frame_age_ms) home_front=$(st_get "$HST" front_bid) \
home_shm=$(st_get "$HST" shm_bid)" | tee -a "$OUT/cycles.txt"
done

BEAT=$(ssh_r "tr -d '\r\n' <'$M/_fg_gate_beat.txt' 2>/dev/null" 2>/dev/null || true)
ssh_r "tail -40 '$V/.ziyan_find_shm_log' 2>/dev/null" >"$OUT/find_shm_log.txt" 2>/dev/null || true
ssh_r "cat '$V/.ziyan_find_timing' 2>/dev/null" >"$OUT/find_timing.txt" 2>/dev/null || true
ssh_r "cat '$V/.ziyan_find_timing_log' 2>/dev/null" >"$OUT/find_timing_log.txt" 2>/dev/null || true
ssh_r "cat '$V/.ziyan_cap_diag' 2>/dev/null" >"$OUT/cap_diag.txt" 2>/dev/null || true
# 某些嵌入 Lua 兼容层禁止 io.open 写 Media 文件，导致业务找色确实在跑、但 probe
# 心跳文件为空。find_shm 是 framecap 自己在每次实际找色后写的证据；setup 前已截断，
# 因而可作为等价的存活判据，不能把它误报成「脚本没在圈」。
FIND_TRACE_N=$(grep -c 'event=find_shm' "$OUT/find_shm_log.txt" 2>/dev/null || true)
FIND_TRACE_LAST=$(tail -1 "$OUT/find_shm_log.txt" 2>/dev/null | tr '\n' ' ')
if [ -z "$BEAT" ] && [ "${FIND_TRACE_N:-0}" -gt 0 ] 2>/dev/null; then
  BEAT="find_shm_n=$FIND_TRACE_N"
fi

# ---- App 画面必须区别于桌面画面：证明帧真跟着前台走 ----
DIFFS=""
HOME_PNG_SIG=$(od -An -tx1 -N8 "$OUT/home.png" 2>/dev/null | tr -d ' \n')
if [ "$HOME_PNG_SIG" = "89504e470d0a1a0a" ]; then
  for f in "$OUT"/app_*.png; do
    [ -s "$f" ] || continue
    APP_PNG_SIG=$(od -An -tx1 -N8 "$f" 2>/dev/null | tr -d ' \n')
    [ "$APP_PNG_SIG" = "89504e470d0a1a0a" ] || continue
    d=$(python3 - "$OUT/home.png" "$f" <<'PY'
import sys
from PIL import Image, ImageChops
a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
if a.size != b.size:
    print("1.0")
    raise SystemExit
diff = ImageChops.difference(a, b).convert("L")
n = sum(1 for p in diff.getdata() if p > 24)
print(f"{n / float(a.size[0] * a.size[1]):.4f}")
PY
)
    DIFFS="$DIFFS $(basename "$f")=$d"
  done
fi

{
  echo "# 前台 App 帧龄门禁 .$TAG"
  echo "bid=$BID cycles=$CYCLES age_max=${AGE_MAX}ms scheme=$SCHEME"
  echo "embed_started=${STARTED:-0} beat=[${BEAT:-none}]"
  echo
  cat "$OUT/cycles.txt"
  echo
  echo "home_vs_app_pixel_diff:$DIFFS （阈值 $DIFF_MIN）"
  echo "find_trace_n=${FIND_TRACE_N:-0} last=${FIND_TRACE_LAST:-none}"
  echo "find_timing: $(tr '\n' ' ' <"$OUT/find_timing.txt" 2>/dev/null)"
  echo "find_timing_slow_n=$(wc -l <"$OUT/find_timing_log.txt" 2>/dev/null | tr -d ' ') last=$(tail -1 "$OUT/find_timing_log.txt" 2>/dev/null | tr '\n' ' ')"
  echo "cap_diag: $(head -c 400 "$OUT/cap_diag.txt" 2>/dev/null | tr '\n' ' ')"
  echo

  OK=1
  [ "${STARTED:-0}" = "1" ] || { echo "FAIL embed_not_started（无常驻找色，帧龄无意义）"; OK=0; }
  if [ -z "$BEAT" ]; then
    echo "FAIL probe_no_heartbeat（找色脚本没在圈）"
    OK=0
  fi
  [ "$FAILS" -eq 0 ] || { echo "FAIL frame_assertions=$FAILS 处（见上）"; OK=0; }
  if [ "$HOME_PNG_SIG" != "89504e470d0a1a0a" ]; then
    echo "FAIL home_snapshot_invalid（无有效桌面 PNG，不能证明画面跟随前台）"
    OK=0
  fi

  # 有一轮 App 画面与桌面几乎相同 → 帧没跟前台切
  SAME=0
  for kv in $DIFFS; do
    v="${kv#*=}"
    if python3 -c "import sys;sys.exit(0 if float('$v') < float('$DIFF_MIN') else 1)"; then
      SAME=$((SAME + 1))
    fi
  done
  if [ -n "$DIFFS" ] && [ "$SAME" -gt 0 ]; then
    echo "FAIL frame_not_following_fg：$SAME 轮 App 画面与桌面画面几乎相同"
    OK=0
  fi

  [ "$OK" = 1 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
} | tee "$OUT/VERDICT.md"

echo "OUT=$OUT"
grep -q 'VERDICT=PASS' "$OUT/VERDICT.md"
