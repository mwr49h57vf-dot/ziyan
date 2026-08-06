#!/usr/bin/env bash
# 自测流程 A（用户选定）：
#  1) 运行 Desktop 业务脚本（scp，不改色参）
#  2) 等找色「找到目标」——一直找不到 → FAIL
#  3) 找到后（脚本已点击）等 20s
#  4) 新画面 toast「登录」连续 10 次 → 最小化全部 App → 观察+1
#  5) 新画面 searching（iOS7/iPhone8Plus）连续 2 次 → FAIL
#  6) 最小化后 searching 连续 2 次 → FAIL
#  7) 最小化后若再找到色 → 等点击+20s → 回到 4–5
#  观察≥10 → PASS；任一 bug 立即停
# 找色前用 .ziyan_open_app 写 bid 进游戏（禁 uiopen URL）；最小化后若需再找再 open
# 禁 find_sb_banned / 禁 .171 / 禁改 Desktop 色参
# 用法：bash tools/zy_biz_streak10.sh [all|ios7|53|101|112|166]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
ROUNDS="${ZY_STREAK_ROUNDS:-10}"
WAIT_AFTER_TAP="${ZY_WAIT_LOGIN:-20}"
FIND_TO="${ZY_FIND_TIMEOUT:-120}"
LOGIN_NEED="${ZY_LOGIN_STREAK:-10}"
SEARCH_FAIL_N="${ZY_SEARCH_FAIL:-2}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/BIZ_STREAK10_${STAMP}"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=18
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

[[ -f "$DESKTOP_IOS7" && -f "$DESKTOP_IOS8P" ]] || { echo "FATAL missing Desktop lua"; exit 2; }

echo "OUT=$OUT FLOW=A ROUNDS=$ROUNDS WAIT_AFTER_TAP=${WAIT_AFTER_TAP}s FIND_TO=${FIND_TO}s LOGIN_NEED=$LOGIN_NEED SEARCH_FAIL_N=$SEARCH_FAIL_N" \
  | tee "$OUT/OUT_PATH.txt"
echo "======== PRETEST ========"
bash tools/zy_pretest_clean_4phone.sh 2>&1 | tee "$OUT/pretest.txt" || true

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4" bid="$5"
  echo "[flowA] .$tag $script"
  if [[ "$script" == "ios8p.lua" ]]; then
    scp_r "$DESKTOP_IOS8P" "$ip" /private/var/mobile/Media/ZiYan/ios8p.lua
  else
    scp_r "$DESKTOP_IOS7" "$ip" /private/var/mobile/Media/ZiYan/ios7.lua
  fi
  ssh_r "$ip" "TAG=$tag SCHEME=$scheme SCRIPT=$script BID=$bid ROUNDS=$ROUNDS WAIT_AFTER_TAP=$WAIT_AFTER_TAP FIND_TO=$FIND_TO LOGIN_NEED=$LOGIN_NEED SEARCH_FAIL_N=$SEARCH_FAIL_N bash -s" \
    <<'EOS' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
else
  VAR=/usr/lib/ziyan/var
  BIN=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

toast_tail() { grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -1 | sed 's/^text=//'; }
front() { tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null; }
shm_bid() { tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null; }
# dump 为覆盖写；同文「登录」mtime 未必变 → 用 mtime 事件 + 时间片双计
toast_mtime() {
  local p="$VAR/.ziyan_toast_dump"
  [ -f "$p" ] || { echo 0; return; }
  stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null || echo 0
}

is_find() { echo "$1" | grep -qE '找到目标|tap success|Verify.*tap'; }
is_login() { echo "$1" | grep -q '登录'; }
is_search() { echo "$1" | grep -qE 'iOS7 searching|iPhone8Plus searching|searching'; }

# 进游戏：只写 bid 到 .ziyan_open_app（禁 uiopen）
open_game_bid() {
  local want="$1" to="${2:-45}" i F
  # 清「关闭程序」粘性，否则 open_app 会被 SB 吞掉
  rm -f "$VAR/.ziyan_app_user_closed" "$VAR/.ziyan_user_closed" 2>/dev/null
  for i in 1 2 3 4 5 6; do
    F=$(front)
    echo "$F" | grep -qiF "$want" && {
      echo "OPEN_GAME_OK bid=$want front=$F try=$i"
      return 0
    }
    printf '%s\n' "$want" >"$VAR/.ziyan_open_app"
    chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
    echo "OPEN_GAME_REQ bid=$want try=$i front=$F"
    sleep 2.5
  done
  local d1=$(( $(date +%s) + to ))
  while [ "$(date +%s)" -lt "$d1" ]; do
    F=$(front)
    echo "$F" | grep -qiF "$want" && {
      echo "OPEN_GAME_OK bid=$want front=$F"
      return 0
    }
    sleep 0.5
  done
  echo "OPEN_GAME_FAIL bid=$want front=$(front)"
  return 1
}

go_home_hard() {
  local i F
  # 153/156：Home + 软挂起 bid；禁 kill（.53 冷启必丢登录 → after_min 永久 searching）
  # 156：软挂起失败改 open SpringBoard（保活游戏进程）
  rm -f "$VAR/.ziyan_go_home_kill" "$VAR/.ziyan_close_app" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 12 14 16 18; do
    if [ -n "${BID:-}" ]; then
      printf '%s\n' "$BID" >"$VAR/.ziyan_suspend_bid"
      chmod 666 "$VAR/.ziyan_suspend_bid" 2>/dev/null
    fi
    echo 1 >"$VAR/.ziyan_go_home"
    chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
    if command -v activator >/dev/null 2>&1; then
      activator send libactivator.system.homebutton 2>/dev/null || true
    fi
    sleep 1.05
    rm -f "$VAR/.ziyan_go_home"
    F=$(front)
    echo "$F" | grep -qi springboard && {
      echo "MIN_OK via=home+suspend front=$F try=$i"
      return 0
    }
  done
  # 156/157：激活桌面（不 terminate）；suspend 与 go_home 错开，避免连写
  echo "MIN_FALLBACK_OPEN_SB front=$(front)"
  for i in 1 2 3 4 5 6 8; do
    if [ -n "${BID:-}" ]; then
      printf '%s\n' "$BID" >"$VAR/.ziyan_suspend_bid"
      chmod 666 "$VAR/.ziyan_suspend_bid" 2>/dev/null
      sleep 0.55
    fi
    printf '%s\n' "com.apple.springboard" >"$VAR/.ziyan_open_app"
    chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
    sleep 0.55
    echo 1 >"$VAR/.ziyan_go_home"
    chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
    if command -v activator >/dev/null 2>&1; then
      activator send libactivator.system.homebutton 2>/dev/null || true
    fi
    sleep 1.2
    rm -f "$VAR/.ziyan_go_home"
    F=$(front)
    echo "$F" | grep -qi springboard && {
      echo "MIN_OK via=open_sb front=$F try=$i"
      return 0
    }
  done
  echo "MIN_FAIL front=$(front)"
  return 1
}

# 等「找到目标」或已在「登录」；期间脉冲合帧
# 154：登录只认当前 toast_tail（禁 HIST 误命中：曾闪「登录」后已 searching 仍 LOGIN_HIT）
wait_find_tap() {
  local phase="$1" to="$2" LAST="" T HIST tick=0
  local d1=$(( $(date +%s) + to ))
  : >"$VAR/.ziyan_toast_dump" 2>/dev/null || true
  while [ "$(date +%s)" -lt "$d1" ]; do
    T=$(toast_tail)
    [ -n "$T" ] && [ "$T" != "$LAST" ] && echo "TOAST=$T front=$(front) phase=$phase" && LAST=$T
    HIST=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -40)
    if is_find "$T" || is_find "$HIST"; then
      echo "FIND_TAP_OK phase=$phase toast=$(toast_tail)"
      return 0
    fi
    if is_login "$T"; then
      echo "LOGIN_HIT_OK phase=$phase toast=$T"
      return 0
    fi
    tick=$((tick + 1))
    if [ $((tick % 2)) -eq 0 ]; then
      echo 1 >"$VAR/.ziyan_force_recap"
      echo 1 >"$VAR/.ziyan_frame_req"
    fi
    sleep 0.5
  done
  echo "FIND_TIMEOUT phase=$phase last=$(toast_tail) front=$(front)"
  return 1
}

# 点击后：先等 WAIT_AFTER_TAP，再计「登录」满 LOGIN_NEED → 立刻最小化
# 计数修复：旧逻辑 T!=LAST 导致同文「登录」永远只计 1 次（你数到 30 也不 min）
# 现用：dump mtime 变化计 1 次；同文仍在则按 TOAST_TICK_SEC（对齐桥接 minGap≈1.5s）再计
# 返回：0=登录满额可最小化；1=searching 连满 FAIL；2=超时其它 FAIL
# 154/155：
#  - 未见过登录前：searching 只记日志不 FAIL（防 first_already 闪一下后抖 searching×2）
#  - 已计登录后：ignore_search 最多 IGNORE_SEARCH_MAX，超则归零并重回 search_grace（禁秒杀）
#  - 155：仅 front==BID 计「登录」；丢前台则复开游戏+合帧（禁 SB 脏 toast 充数）
#  - 循环内脉冲合帧，防脏帧导致永久 searching
wait_post_tap_outcome() {
  local phase="$1"
  local LOGIN_STREAK=0 SEARCH_STREAK=0 T MT PREV_MT=0 NOW LAST_TICK=0 F
  local TOAST_TICK_SEC=1
  local IGNORE_SEARCH_MAX=8 IGNORE_N=0 SEEN_LOGIN=0 tick=0
  echo "WAIT_AFTER_TAP ${WAIT_AFTER_TAP}s phase=$phase front=$(front)"
  sleep "$WAIT_AFTER_TAP"
  # 155：计登录前确保游戏前台
  F=$(front)
  if [ -n "${BID:-}" ] && ! echo "$F" | grep -qiF "$BID"; then
    echo "FRONT_LOST_BEFORE_COUNT front=$F → reopen $BID"
    open_game_bid "$BID" 45 || true
    echo 1 >"$VAR/.ziyan_force_recap"
    echo 1 >"$VAR/.ziyan_frame_req"
    sleep 1.2
  fi
  PREV_MT=$(toast_mtime)
  # 不清 dump：避免抹掉已在播的「登录」；从当前文案开始计
  T=$(toast_tail)
  F=$(front)
  if is_login "$T" && [ -n "${BID:-}" ] && echo "$F" | grep -qiF "$BID"; then
    LOGIN_STREAK=1
    SEEN_LOGIN=1
    LAST_TICK=$(date +%s)
    echo "TOAST=$T front=$F phase=$phase login_streak=$LOGIN_STREAK (seed)"
  elif is_login "$T"; then
    LAST_TICK=$(date +%s)
    echo "TOAST=$T front=$F phase=$phase login_skip (not game front)"
  elif is_search "$T"; then
    # 未见登录：不 seed search_streak（避免开局 searching×2 秒杀）
    LAST_TICK=$(date +%s)
    echo "TOAST=$T front=$F phase=$phase search_grace (no login yet)"
  fi
  [ "$LOGIN_STREAK" -ge "$LOGIN_NEED" ] && {
    echo "LOGIN_STREAK_OK need=$LOGIN_NEED phase=$phase"
    return 0
  }

  local d2=$(( $(date +%s) + FIND_TO ))
  while [ "$(date +%s)" -lt "$d2" ]; do
    T=$(toast_tail)
    F=$(front)
    MT=$(toast_mtime)
    NOW=$(date +%s)
    # 丢前台：复开，不推进 search FAIL
    if [ -n "${BID:-}" ] && ! echo "$F" | grep -qiF "$BID"; then
      if [ $((tick % 8)) -eq 0 ]; then
        echo "FRONT_LOST front=$F phase=$phase → reopen (keep login_streak=$LOGIN_STREAK)"
        open_game_bid "$BID" 30 || true
        echo 1 >"$VAR/.ziyan_force_recap"
        echo 1 >"$VAR/.ziyan_frame_req"
      fi
      tick=$((tick + 1))
      sleep 0.35
      continue
    fi
    local bumped=0
    if [ -n "$T" ] && [ "$MT" != "$PREV_MT" ] && [ "$MT" != 0 ]; then
      PREV_MT=$MT
      bumped=1
    elif [ -n "$T" ] && [ $((NOW - LAST_TICK)) -ge "$TOAST_TICK_SEC" ]; then
      # 同文覆盖写：mtime 可能不变，按秒片计连续提示
      bumped=1
    fi
    if [ "$bumped" = 1 ]; then
      LAST_TICK=$NOW
      if is_login "$T"; then
        LOGIN_STREAK=$((LOGIN_STREAK + 1))
        SEARCH_STREAK=0
        IGNORE_N=0
        SEEN_LOGIN=1
        echo "TOAST=$T front=$F phase=$phase login_streak=$LOGIN_STREAK search_streak=0"
        if [ "$LOGIN_STREAK" -ge "$LOGIN_NEED" ]; then
          echo "LOGIN_STREAK_OK need=$LOGIN_NEED phase=$phase → will min_all"
          return 0
        fi
      elif is_search "$T"; then
        if [ "$LOGIN_STREAK" -gt 0 ]; then
          IGNORE_N=$((IGNORE_N + 1))
          if [ "$IGNORE_N" -le "$IGNORE_SEARCH_MAX" ]; then
            echo "TOAST=$T front=$F phase=$phase login_keep=$LOGIN_STREAK ignore_search=$IGNORE_N/$IGNORE_SEARCH_MAX"
          else
            # 155：归零后重回 grace（.101 能找回；.112/.166 曾被 search×2 秒杀）
            echo "TOAST=$T front=$F phase=$phase login_reset→grace ignore_exhausted=$IGNORE_SEARCH_MAX"
            LOGIN_STREAK=0
            IGNORE_N=0
            SEARCH_STREAK=0
            SEEN_LOGIN=0
            echo 1 >"$VAR/.ziyan_force_recap"
            echo 1 >"$VAR/.ziyan_frame_req"
          fi
        elif [ "$SEEN_LOGIN" = 0 ]; then
          echo "TOAST=$T front=$F phase=$phase search_grace (await login)"
        else
          SEARCH_STREAK=$((SEARCH_STREAK + 1))
          echo "TOAST=$T front=$F phase=$phase login_streak=0 search_streak=$SEARCH_STREAK"
          if [ "$SEARCH_STREAK" -ge "$SEARCH_FAIL_N" ]; then
            echo "SEARCH_STREAK_FAIL n=$SEARCH_FAIL_N phase=$phase"
            return 1
          fi
        fi
      fi
    fi
    tick=$((tick + 1))
    if [ $((tick % 4)) -eq 0 ]; then
      echo 1 >"$VAR/.ziyan_force_recap"
      echo 1 >"$VAR/.ziyan_frame_req"
      chmod 666 "$VAR/.ziyan_force_recap" 2>/dev/null
    fi
    sleep 0.25
  done
  echo "POST_TAP_TIMEOUT phase=$phase login_streak=$LOGIN_STREAK search_streak=$SEARCH_STREAK last=$(toast_tail)"
  return 2
}

# 复开后：持续合帧直到登录/找到目标。searching 只打日志，不中途 FAIL（软挂起后需等页回）
# 仅整段超时仍无登录/找色 → return 2（bug）
wait_after_min() {
  local T LAST="" tick=0
  local d1=$(( $(date +%s) + FIND_TO ))
  : >"$VAR/.ziyan_toast_dump" 2>/dev/null || true
  while [ "$(date +%s)" -lt "$d1" ]; do
    T=$(toast_tail)
    if [ -n "$T" ] && [ "$T" != "$LAST" ]; then
      echo "TOAST=$T front=$(front) shm=$(shm_bid) phase=after_min"
      LAST=$T
    fi
    if is_find "$T" || is_login "$T"; then
      echo "FIND_AFTER_MIN_OK toast=$T"
      return 0
    fi
    if grep -qE '找到目标|tap success|^text=登录' "$VAR/.ziyan_toast_dump" 2>/dev/null; then
      echo "FIND_AFTER_MIN_OK via_dump"
      return 0
    fi
    tick=$((tick + 1))
    if [ $((tick % 2)) -eq 0 ]; then
      echo 1 >"$VAR/.ziyan_force_recap"
      echo 1 >"$VAR/.ziyan_frame_req"
      chmod 666 "$VAR/.ziyan_force_recap" 2>/dev/null
    fi
    sleep 0.4
  done
  echo "AFTER_MIN_TIMEOUT last=$(toast_tail) front=$(front) (no login/find)"
  return 2
}

echo "META VER=$VER SCRIPT=$SCRIPT BID=$BID ROUNDS=$ROUNDS WAIT_AFTER_TAP=$WAIT_AFTER_TAP FIND_TO=$FIND_TO LOGIN_NEED=$LOGIN_NEED SEARCH_FAIL_N=$SEARCH_FAIL_N"
echo "FLOW=A embed→open_game(bid)→wait_find→tap+${WAIT_AFTER_TAP}s→login×${LOGIN_NEED}|search×${SEARCH_FAIL_N}→min→reopen→… observe×${ROUNDS}"

killall -9 ziyan_framecap 2>/dev/null; sleep 1
mkdir -p "$VAR"
rm -f "$VAR/.ziyan_find_sb_banned" "$VAR/.ziyan_allow_sb_find" \
  "$VAR/.ziyan_embed_off" "$VAR/.ziyan_light" \
  "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_open_app" \
  "$VAR/.ziyan_user_closed" "$VAR/.ziyan_app_user_closed"
echo 1 >"$VAR/.ziyan_sb_cold_relay"
echo 1 >"$VAR/.ziyan_bbframe_on"
echo 1 >"$VAR/.ziyan_keep_daemon"
nohup "$BIN/ziyan_framecap" serve >/dev/null 2>&1 &
sleep 2

# 1) 运行脚本
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
printf '1\n' >"$VAR/.ziyan_embed_on"
date +%s >"$VAR/.ziyan_project_active"
rm -f "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded"
echo "nonce=flowA_${TAG}_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_on" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_project_active" 2>/dev/null
sleep 3
EMB=0
[ -f "$VAR/.ziyan_lua_embedded" ] && EMB=1
grep -q 'ok=1' "$VAR/.ziyan_embed_ack" 2>/dev/null && EMB=1
[ "$EMB" = 1 ] && pass H0_embed || fail H0_embed
[ "$FAIL" = 1 ] && { echo STREAK10_FAIL; exit 1; }

echo 1 >"$VAR/.ziyan_unlock_req"; chmod 666 "$VAR/.ziyan_unlock_req" 2>/dev/null; sleep 0.5
: >"$VAR/.ziyan_toast_dump" 2>/dev/null || true
chmod 666 "$VAR/.ziyan_toast_dump" 2>/dev/null || true

OBSERVE=0
echo "======== FLOW_A start (open_game by bid; no uiopen) ========"

# 找色前必须进游戏前台（否则 SB 帧对游戏色必 miss）
if open_game_bid "$BID" 60; then
  pass H_open_game
else
  fail "H_open_game front=$(front)"
  echo STREAK10_FAIL
  exit 1
fi
# 进游戏后强制合帧几轮（禁吃 SB/黑/脏旧帧）
rm -f "$VAR/.ziyan_display_locked" "$VAR/.ziyan_find_sb_banned"
echo 1 >"$VAR/.ziyan_bbframe_on"
for _i in 1 2 3 4 5; do
  echo 1 >"$VAR/.ziyan_force_recap"
  echo 1 >"$VAR/.ziyan_frame_req"
  chmod 666 "$VAR/.ziyan_force_recap" "$VAR/.ziyan_frame_req" 2>/dev/null
  sleep 0.7
done
sleep 2

# 2–3) 首次找色或已在登录（wait_find_tap 内已认登录）
SKIP_FIRST_WAIT20=0
if wait_find_tap first "$FIND_TO"; then
  if is_login "$(toast_tail)" && ! is_find "$(toast_tail)"; then
    echo "NOTE first_already_login → enter login×${LOGIN_NEED} then min"
    pass first_already_on_login_screen
    SKIP_FIRST_WAIT20=1
  else
    pass first_find_tap
  fi
else
  fail "first_find_miss_bug last=$(toast_tail) front=$(front)"
  echo STREAK10_FAIL
  exit 1
fi

# 进入：等20s → 判登录×10 / searching×2 → 立刻最小化 → 观察+1 → …
while [ "$OBSERVE" -lt "$ROUNDS" ]; do
  echo "---- OBSERVE round=$((OBSERVE + 1))/$ROUNDS front=$(front) shm=$(shm_bid) ----"

  if [ "$SKIP_FIRST_WAIT20" = 1 ]; then
    _saved_wait=$WAIT_AFTER_TAP
    WAIT_AFTER_TAP=0
    wait_post_tap_outcome "post_tap_obs$((OBSERVE + 1))"
    rc=$?
    WAIT_AFTER_TAP=$_saved_wait
    SKIP_FIRST_WAIT20=0
  else
    wait_post_tap_outcome "post_tap_obs$((OBSERVE + 1))"
    rc=$?
  fi
  if [ "$rc" = 1 ]; then
    fail "search_streak${SEARCH_FAIL_N}_after_tap"
    break
  fi
  if [ "$rc" = 2 ]; then
    fail "post_tap_no_login${LOGIN_NEED}_timeout"
    break
  fi
  pass "login_x${LOGIN_NEED}"

  echo "MIN_ALL now (login_streak reached ${LOGIN_NEED})"
  if go_home_hard; then
    pass "min_after_login10"
  else
    fail "min_front=$(front)"
    break
  fi
  echo "AFTER_MIN front=$(front) shm=$(shm_bid)"

  OBSERVE=$((OBSERVE + 1))
  echo "OBSERVE_COUNT=$OBSERVE"
  if [ "$OBSERVE" -ge "$ROUNDS" ]; then
    pass "FLOW_A_observe_${ROUNDS}"
    echo STREAK10_PASS
    echo "FINAL observe=$OBSERVE"
    exit 0
  fi

  # 6–7) 软挂起后复开：应仍在登录页；持续合帧等到登录/找色
  if ! open_game_bid "$BID" 60; then
    fail "reopen_after_min front=$(front)"
    break
  fi
  wait_after_min
  rc=$?
  if [ "$rc" != 0 ]; then
    fail "after_min_no_login_timeout front=$(front) last=$(toast_tail)"
    break
  fi
  pass find_after_min
  # 复开已在登录：下一轮直接计登录，免再空等 20s
  if is_login "$(toast_tail)"; then
    SKIP_FIRST_WAIT20=1
  fi
done

echo "FLOW_A_STOPPED observe=$OBSERVE fail=$FAIL"
if [ "$OBSERVE" -ge "$ROUNDS" ] && [ "$FAIL" = 0 ]; then
  echo STREAK10_PASS
else
  echo STREAK10_FAIL
fi
EOS
}

echo "======== BIZ STREAK10 FLOW_A ========"
# 单机 FAIL 时远端 exit 1；勿因 set -e 中断后续机与 VERDICT
case "$WANT" in
  all)
    run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game || true
    run_one 101 192.168.31.101 rootful ios7.lua com.xztl.ios || true
    run_one 112 192.168.31.112 rootful ios7.lua com.xztl.ios || true
    run_one 166 192.168.31.166 rootful ios7.lua com.xztl.ios || true
    ;;
  ios7)
    run_one 101 192.168.31.101 rootful ios7.lua com.xztl.ios || true
    run_one 112 192.168.31.112 rootful ios7.lua com.xztl.ios || true
    run_one 166 192.168.31.166 rootful ios7.lua com.xztl.ios || true
    ;;
  53) run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game || true ;;
  101) run_one 101 192.168.31.101 rootful ios7.lua com.xztl.ios || true ;;
  112) run_one 112 192.168.31.112 rootful ios7.lua com.xztl.ios || true ;;
  166) run_one 166 192.168.31.166 rootful ios7.lua com.xztl.ios || true ;;
  *) echo "bad $WANT"; exit 2 ;;
esac

{
  echo "# BIZ STREAK10 · 流程 A · 157"
  echo
  ALL=1
  ANY=0
  for t in 53 101 112 166; do
    [ -f "$OUT/gate_${t}.txt" ] || continue
    ANY=1
    echo "## .$t"
    grep -E 'PASS |FAIL |STREAK|TOAST=|OBSERVE|FLOW=|FIND_|LOGIN_|SEARCH_|MIN_|ignore_|search_grace|login_reset' "$OUT/gate_${t}.txt" || true
    grep -q STREAK10_PASS "$OUT/gate_${t}.txt" || ALL=0
    echo
  done
  if [ "$ANY" = 0 ]; then echo "## OVERALL=FAIL (no gates)"; elif [ "$ALL" = 1 ]; then echo "## OVERALL=PASS"; else echo "## OVERALL=FAIL"; fi
} | tee "$OUT/VERDICT.md"
cp -f "$OUT/VERDICT.md" "$ROOT/tmp_shots/BIZ_STREAK10_VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
