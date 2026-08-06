#!/usr/bin/env bash
# 自测：登录 → 全员最小化（不 uiopen）→ 等脚本自己找色/再出登录 ×N
# 对标触动 min 后立刻找回。用法：bash tools/zy_min_selffind.sh [all|53|101|112|166]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
ROUNDS="${ZY_MIN_ROUNDS:-5}"
LOGIN_TO="${ZY_LOGIN_TO:-60}"
AFTER_TO="${ZY_AFTER_TO:-90}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/MIN_SELFFIND_${STAMP}"
mkdir -p "$OUT"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4" bid="$5"
  echo "[min-self] .$tag"
  if [[ "$script" == ios8p.lua ]]; then scp_r "$DESKTOP_IOS8P" "$ip" /private/var/mobile/Media/ZiYan/ios8p.lua
  else scp_r "$DESKTOP_IOS7" "$ip" /private/var/mobile/Media/ZiYan/ios7.lua; fi
  ssh_r "$ip" "TAG=$tag SCHEME=$scheme SCRIPT=$script BID=$bid ROUNDS=$ROUNDS LOGIN_TO=$LOGIN_TO AFTER_TO=$AFTER_TO bash -s" \
    <<'ZYMINSELF_EOF' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var; BIN=/var/jb/usr/lib/ziyan/bin
else
  VAR=/usr/lib/ziyan/var; BIN=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
toast(){ grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -1 | sed 's/^text=//'; }
front(){ tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null; }
is_login(){ echo "$1" | grep -q '登录'; }
is_find(){ echo "$1" | grep -qE '找到目标|tap success'; }
min_all(){
  # 与触动对照一致：挂起前台（不 kill、不 open_app）
  local i F
  rm -f "$VAR/.ziyan_go_home_kill" "$VAR/.ziyan_close_app"
  for i in 1 2 3 4 5 6 8; do
    printf '%s\n' "$BID" >"$VAR/.ziyan_suspend_bid"
    echo 1 >"$VAR/.ziyan_go_home"
    chmod 666 "$VAR/.ziyan_suspend_bid" "$VAR/.ziyan_go_home" 2>/dev/null
    sleep 1.0
    rm -f "$VAR/.ziyan_go_home"
    F=$(front)
    echo "$F" | grep -qi springboard && break
  done
  # 清旧 toast，避免 min 后读到最小化前的「登录」假通过
  : >"$VAR/.ziyan_toast_dump"
  chmod 666 "$VAR/.ziyan_toast_dump" 2>/dev/null
  RET=""
  if [ -f "$VAR/.ziyan_retain_app_frame" ]; then
    RET=$(tr '\n' ' ' <"$VAR/.ziyan_retain_app_frame")
  fi
  echo "MIN front=$(front) toast=$(toast) retain=$RET"
}
# $3=need_game：1=after_min 必须回到游戏前台；0=首次
wait_login(){
  # bash: local 同句求值陷阱 → 分行写
  local phase="$1"
  local to="$2"
  local need_game="$3"
  if [ -z "$need_game" ]; then
    need_game=0
  fi
  local d
  d=$(( $(date +%s) + to ))
  echo "WAIT phase=$phase to=$to need_game=$need_game until=$d now=$(date +%s)"
  local tick=0
  while [ "$(date +%s)" -lt "$d" ]; do
    T=$(toast)
    F=$(front)
    # after_min：必须 toast「登录」+ 游戏前台（禁仅「找到目标」早退 → 下轮 min 不在登录页）
    # first：登录或找到均可（进游戏热身）
    if [ "$need_game" = 1 ]; then
      if is_login "$T"; then
        if echo "$F" | grep -qiF "$BID"; then
          echo "LOGIN_OK phase=$phase toast=$T front=$F"
          return 0
        fi
        tick=$((tick + 1))
        if [ $((tick % 6)) -eq 0 ]; then
          echo "TICK phase=$phase toast=$T front=$F (wait game front after tap)"
        fi
      fi
    elif is_login "$T" || is_find "$T"; then
      echo "LOGIN_OK phase=$phase toast=$T front=$F"
      return 0
    fi
    # after_min 保留帧期勿狂 force（避免冲掉 retain）；仅轻催
    if [ "$need_game" != 1 ]; then
      echo 1 >"$VAR/.ziyan_force_recap" 2>/dev/null
      echo 1 >"$VAR/.ziyan_frame_req" 2>/dev/null
    fi
    tick=$((tick + 1))
    if [ $((tick % 8)) -eq 0 ]; then
      FL=$(tail -1 "$VAR/.ziyan_find_shm_log" 2>/dev/null)
      echo "TICK phase=$phase toast=$T front=$F shm=$(tr -d '\r\n' <$VAR/.ziyan_shm_front_bid 2>/dev/null) find=$FL"
    fi
    sleep 0.45
  done
  echo "LOGIN_TIMEOUT phase=$phase last=$(toast) front=$(front) shm=$(tr -d '\r\n' <$VAR/.ziyan_shm_front_bid 2>/dev/null)"
  echo -n "FIND_TAIL="; tail -3 "$VAR/.ziyan_find_shm_log" 2>/dev/null | tr '\n' ';'; echo
  echo -n "CAP_TAIL="; tail -8 "$VAR/.ziyan_framecap_log" 2>/dev/null | tr '\n' ';'; echo
  return 1
}
echo "META VER=$VER SCRIPT=$SCRIPT BID=$BID ROUNDS=$ROUNDS"
mkdir -p "$VAR"; chmod 777 "$VAR"
rm -f "$VAR/.ziyan_stop" "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_embed_off" "$VAR/.ziyan_light"
rm -f "$VAR/.ziyan_find_sb_banned" "$VAR/.ziyan_framecap_off"
echo 1 >"$VAR/.ziyan_embed_on"; echo 1 >"$VAR/.ziyan_bbframe_on"
# 166：只走 launchd KeepAlive（禁 killall+nohup 与 wrap 双开 → duplicate 风暴 / empty_shm）
rm -f "$VAR/.ziyan_framecap_off"
if [ -f /var/jb/Library/LaunchDaemons/com.ziyan.framecap.plist ]; then
  launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null \
    || launchctl kickstart -k com.ziyan.framecap 2>/dev/null || true
elif [ -f /Library/LaunchDaemons/com.ziyan.framecap.plist ]; then
  launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null \
    || launchctl kickstart -k com.ziyan.framecap 2>/dev/null || true
fi
sleep 1.8
if ! ps -A -o command= 2>/dev/null | grep -q '[z]iyan_framecap serve'; then
  # 冷机兜底：仍禁并行 nohup；先确保无残留再单拉
  killall -9 ziyan_framecap 2>/dev/null
  sleep 0.4
  nohup "$BIN/ziyan_framecap" serve >/dev/null 2>&1 &
  sleep 1.2
fi
N=$(ps -A -o command= 2>/dev/null | grep -c '[z]iyan_framecap serve' || true)
echo "FC_SERVE_N=$N"
: >"$VAR/.ziyan_toast_dump"; chmod 666 "$VAR/.ziyan_toast_dump"
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
echo "nonce=minself_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_"* 2>/dev/null
# 只开一次游戏进登录；之后全靠脚本自己点（禁 min 后再 open_app）
rm -f "$VAR/.ziyan_app_user_closed" "$VAR/.ziyan_user_closed"
echo 1 >"$VAR/.ziyan_unlock_req"
OPEN_OK=0
for i in 1 2 3 4 5 6; do
  F=$(front)
  echo "$F" | grep -qiF "$BID" && { echo "OPEN_GAME_OK try=$i front=$F"; OPEN_OK=1; break; }
  printf '%s\n' "$BID" >"$VAR/.ziyan_open_app"; chmod 666 "$VAR/.ziyan_open_app"
  echo "OPEN_GAME_REQ try=$i front=$F"
  sleep 2.2
done
[ "$OPEN_OK" = 1 ] || { echo OPEN_GAME_FAIL front=$(front); echo MINSELF_FAIL first; exit 1; }
for _i in 1 2 3 4; do
  echo 1 >"$VAR/.ziyan_force_recap"; echo 1 >"$VAR/.ziyan_frame_req"
  sleep 0.55
done
OK=0
if ! wait_login first "$LOGIN_TO" 0; then echo MINSELF_FAIL first; exit 1; fi
for r in $(seq 1 "$ROUNDS"); do
  echo "==== ROUND $r/$ROUNDS ===="
  min_all
  # 禁止再写 open_app —— 等找色点击并回到游戏前台再出登录（对标触动）
  if wait_login "after_min_$r" "$AFTER_TO" 1; then
    OK=$((OK+1))
    echo "PASS_ROUND $r ok=$OK"
  else
    echo "FAIL_ROUND $r"
    echo MINSELF_FAIL
    exit 1
  fi
done
echo "MINSELF_PASS ok=$OK/$ROUNDS"
ZYMINSELF_EOF
}

case "$WANT" in
  all) run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game || true
       run_one 101 192.168.31.101 rootful ios7.lua com.xztl.ios || true
       run_one 112 192.168.31.112 rootful ios7.lua com.xztl.ios || true
       run_one 166 192.168.31.166 rootful ios7.lua com.xztl.ios || true ;;
  53) run_one 53 192.168.31.53 rootless ios8p.lua com.ljzbbadao.game || true ;;
  101) run_one 101 192.168.31.101 rootful ios7.lua com.xztl.ios || true ;;
  112) run_one 112 192.168.31.112 rootful ios7.lua com.xztl.ios || true ;;
  166) run_one 166 192.168.31.166 rootful ios7.lua com.xztl.ios || true ;;
  *) echo bad; exit 2 ;;
esac
{
  echo "# MIN SELFFIND · 161"
  ALL=1
  for t in 53 101 112 166; do
    [ -f "$OUT/gate_${t}.txt" ] || continue
    echo "## .$t"
    grep -E 'PASS_|FAIL_|MINSELF|LOGIN_|FIND_|MIN |META' "$OUT/gate_${t}.txt" || true
    grep -q MINSELF_PASS "$OUT/gate_${t}.txt" || ALL=0
    echo
  done
  [ "$ALL" = 1 ] && echo "## OVERALL=PASS" || echo "## OVERALL=FAIL"
} | tee "$OUT/VERDICT.md"
cp -f "$OUT/VERDICT.md" "$ROOT/tmp_shots/MIN_SELFFIND_VERDICT.md"
echo "VERDICT -> $OUT/VERDICT.md"
