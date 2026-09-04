#!/usr/bin/env bash
# 刀 RUN1：按 Desktop 脚本逻辑验收（认「找到目标」+tap，不拆链等登录）
#   Home → embed ios7/ios8p → ≤90s 「找到目标」/Verify → 离开 SB
#   「登录」仅附加观察，不挡 PASS；一直「色点A未找到」= FAIL_NO_FIND
#   FAIL 机落盘：Home GC/FIND 色点A + toast_hist（不擅自改色）
# 用法: bash tools/zy_run1_script_logic_gate.sh [all|53|101|112|166]
# 默认四机；禁 .171；不关 CAP53；保持 199
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')_${WANT}_$$"
OUT="${ROOT}/tmp_shots/RUN1_GATE_${STAMP}"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
SSH_KEY_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
              -o BatchMode=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
SSH_AUTH_KIND=""

# 测试机均已安装本机公钥。优先密钥可避免密码限流；密码只保留为兼容回退。
# 认证通道不是产品能力，必须在门禁开始前固定下来，避免把 SSH 拒绝误记成业务 FAIL。
init_ssh_auth() {
  local ip="$1"
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    SSH_AUTH_KIND=key
  elif sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    SSH_AUTH_KIND=password
  else
    echo "FATAL ssh_auth_failed ip=$ip" >&2
    return 1
  fi
  echo "SSH_AUTH=$SSH_AUTH_KIND ip=$ip"
}

ssh_r() {
  local ip="$1"; shift
  if [ "$SSH_AUTH_KIND" = password ]; then
    # 某些设备会短暂接受一次密码探测、随后拒绝密码登录（限流/sshd
    # 策略），但已授权的本机密钥仍可用。认证不是产品结论：本次
    # 操作必须回退密钥，不能把传输失败写成业务 FAIL。
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@" ||
      ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    # 禁止 -n：密钥路径若丢弃 stdin，heredoc 的 bash -s 会空跑，
    # 主机只能写出 INVALID_RUN，并被误当成业务失败。
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  fi
}

scp_r() {
  local src="$1" ip="$2" dst="$3"
  if [ "$SSH_AUTH_KIND" = password ]; then
    sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$src" "root@$ip:$dst" ||
      scp "${SSH_KEY_OPTS[@]}" "$src" "root@$ip:$dst"
  else
    scp "${SSH_KEY_OPTS[@]}" "$src" "root@$ip:$dst"
  fi
}

scp_from() {
  local ip="$1" src="$2" dst="$3"
  if [ "$SSH_AUTH_KIND" = password ]; then
    sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "root@$ip:$src" "$dst" ||
      scp "${SSH_KEY_OPTS[@]}" "root@$ip:$src" "$dst"
  else
    scp "${SSH_KEY_OPTS[@]}" "root@$ip:$src" "$dst"
  fi
}

[[ -f "$DESKTOP_IOS7" && -f "$DESKTOP_IOS8P" ]] || {
  echo "FATAL missing Desktop ios7/ios8p"; exit 2
}
SHA7=$(shasum -a 256 "$DESKTOP_IOS7" | awk '{print $1}')
SHA8=$(shasum -a 256 "$DESKTOP_IOS8P" | awk '{print $1}')
echo "OUT=$OUT" | tee "$OUT/OUT_PATH.txt"
echo "WANT=$WANT" | tee -a "$OUT/OUT_PATH.txt"
echo "SHA256_ios7=$SHA7" | tee -a "$OUT/OUT_PATH.txt"
echo "SHA256_ios8p=$SHA8" | tee -a "$OUT/OUT_PATH.txt"

# ios7 色点A（与 Desktop 同步，仅用于 FAIL 取证）
IOS7_A_PTS='[{"c":10304105,"dx":0,"dy":0,"b":0},{"c":9253480,"dx":0,"dy":4,"b":0}]'
IOS7_A_ROI="390 195 410 210 90"
# ios8p 色点A
IOS8_A_PTS='[{"c":16645615,"dx":0,"dy":0,"b":0},{"c":16711423,"dx":1,"dy":2,"b":0},{"c":16777200,"dx":2,"dy":3,"b":0},{"c":16645601,"dx":2,"dy":7,"b":0}]'
IOS8_A_ROI="2011 283 2013 290 90"

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4"
  local sha="$SHA7"
  [[ "$script" == "ios8p.lua" ]] && sha="$SHA8"
  echo "[run1] .$tag $script (script logic: 找到目标+tap)"
  # 传输/认证异常不属于视觉结果。必须落一份标准 gate 文件，既让
  # 汇总正确记 FAIL，也避免 set -e 让整轮无证据中断。
  if ! init_ssh_auth "$ip"; then
    {
      echo "META TAG=$tag SCRIPT=$script"
      echo "TRANSPORT=AUTH_FAILED"
      echo "VERDICT=FAIL_TRANSPORT"
      echo "TYPED=TRANSPORT_BLOCKED"
    } | tee "$OUT/gate_${tag}.txt"
    return 0
  fi
  if [[ "$script" == "ios8p.lua" ]]; then
    if ! scp_r "$DESKTOP_IOS8P" "$ip" /private/var/mobile/Media/ZiYan/ios8p.lua; then
      {
        echo "META TAG=$tag SCRIPT=$script"
        echo "TRANSPORT=SCRIPT_COPY_FAILED"
        echo "VERDICT=FAIL_TRANSPORT"
        echo "TYPED=TRANSPORT_BLOCKED"
      } | tee "$OUT/gate_${tag}.txt"
      return 0
    fi
  else
    if ! scp_r "$DESKTOP_IOS7" "$ip" /private/var/mobile/Media/ZiYan/ios7.lua; then
      {
        echo "META TAG=$tag SCRIPT=$script"
        echo "TRANSPORT=SCRIPT_COPY_FAILED"
        echo "VERDICT=FAIL_TRANSPORT"
        echo "TYPED=TRANSPORT_BLOCKED"
      } | tee "$OUT/gate_${tag}.txt"
      return 0
    fi
  fi
  bash "$ROOT/tools/zy_miss_fuse_emergency.sh" "$tag" 2>&1 | tee -a "$OUT/fuse_${tag}.txt" | tail -2 || true

  ssh_r "$ip" "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:\$PATH; TAG=$tag SCHEME=$scheme SCRIPT=$script SHA=$sha bash -s" <<'EOS' | tee "$OUT/gate_${tag}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
else
  VAR=/usr/lib/ziyan/var
  BIN=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
VER=$(dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\([^ ]*\).*/\1/p')
FAIL=0
FIND_TAP=0
CLICK=0
NO_FIND=0
LOGIN_SEEN=0
START_TS=$(date +%s)
SB0=$(ps -axo pid=,args= 2>/dev/null | while read -r pid args; do
  case "$args" in */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo "$pid"; break ;; esac
done)
RID="run1_${TAG}_${START_TS}_$$"
VD="$MEDIA/verdicts"
FINAL="$VD/${RID}.txt"
mkdir -p "$VD"
persist() {
  {
    echo "run_id=$RID"
    echo "host=.$TAG"
    echo "scheme=$SCHEME"
    echo "pkg=$VER"
    echo "script=$SCRIPT"
    echo "script_sha=$SHA"
    echo "session_id=$RID"
    echo "request_id=$RID"
    echo "phase=$1"
    echo "started_ts=$START_TS"
    echo "updated_ts=$(date +%s)"
    echo "FIND_TAP=$FIND_TAP"
    echo "CLICK=$CLICK"
    echo "FAIL=$FAIL"
    echo "NO_FIND=$NO_FIND"
    echo "LOGIN_SEEN=$LOGIN_SEEN"
    [ -n "${2:-}" ] && echo "$2"
  } >"$FINAL.tmp"
  mv "$FINAL.tmp" "$FINAL"
  chmod 666 "$FINAL" 2>/dev/null || true
}
persist started "TYPED=RUNNING"
if [ "$SCRIPT" = "ios8p.lua" ]; then
  TAP_X1=2011; TAP_X2=2013; TAP_Y1=283; TAP_Y2=290
else
  TAP_X1=1010; TAP_X2=1010; TAP_Y1=294; TAP_Y2=300
fi
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

toast_hist() {
  if [ -s "$VAR/.ziyan_toast_hist" ]; then
    tr '\n' '|' <"$VAR/.ziyan_toast_hist" 2>/dev/null
  else
    tr '\n' '|' <"$VAR/.ziyan_toast_dump" 2>/dev/null
  fi
}
echo "META VER=$VER SCRIPT=$SCRIPT RUN1=1 RULE=find_tap_typed_verdict RUN_ID=$RID FINAL=$FINAL"
mkdir -p "$VAR" "$MEDIA"
REMOTE_SHA=""
if command -v sha256sum >/dev/null 2>&1; then
  REMOTE_SHA=$(sha256sum "$MEDIA/$SCRIPT" 2>/dev/null | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  REMOTE_SHA=$(shasum -a 256 "$MEDIA/$SCRIPT" 2>/dev/null | cut -d' ' -f1)
fi
echo "REMOTE_SHA=$REMOTE_SHA EXPECT=$SHA"
[ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" = "$SHA" ] && echo "SHA_OK=1" || echo "SHA_OK=0"
echo 1 >"$VAR/.ziyan_no_auto_keep"; chmod 666 "$VAR/.ziyan_no_auto_keep" 2>/dev/null || true
rm -f "$VAR/.ziyan_open_app" "$VAR/.ziyan_embed_off" "$VAR/.ziyan_user_stopped" \
  "$VAR/.ziyan_keep_daemon" "$VAR/.ziyan_session_keep" "$VAR/.ziyan_active" \
  "$VAR/.ziyan_find_sb_banned" "$VAR/.ziyan_light" "$VAR/.ziyan_force_front_mismatch" \
  "$VAR/.ziyan_app_alive" "$VAR/.ziyan_prefer_app_touch"
rm -f "$VAR/.ziyan_toast_dump" "$VAR/.ziyan_toast_hist" \
  "$VAR/.ziyan_verify_log" "$VAR/.ziyan_biz_tapped" "$VAR/.ziyan_tap_gate"
: >"$VAR/.ziyan_toast_dump"
: >"$VAR/.ziyan_toast_hist"
: >"$VAR/.ziyan_verify_log"
chmod 666 "$VAR/.ziyan_toast_dump" "$VAR/.ziyan_toast_hist" \
  "$VAR/.ziyan_verify_log" 2>/dev/null

# 202：framecap 由 zydaemon 唯一监督。framecap LaunchDaemon 按设计 Disabled，
# 因此缺实例时只注册/唤醒监督者，不能直接 kickstart framecap。
FC0=$(ps -A -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
[ -n "$FC0" ] || FC0=0
if [ "$FC0" -eq 0 ]; then
  if [ "$SCHEME" = rootless ]; then
    ZYD_PLIST=/var/jb/Library/LaunchDaemons/com.ziyan.zydaemon.plist
  else
    ZYD_PLIST=/Library/LaunchDaemons/com.ziyan.zydaemon.plist
  fi
  if ! launchctl print system/com.ziyan.zydaemon >/dev/null 2>&1; then
    launchctl bootstrap system "$ZYD_PLIST" 2>/dev/null || true
  fi
  launchctl enable system/com.ziyan.zydaemon 2>/dev/null || true
  echo 1 >"$VAR/.ziyan_watchdog_framecap_need"
  chmod 666 "$VAR/.ziyan_watchdog_framecap_need" 2>/dev/null || true
  sleep 2.0
fi

# A0：装包后 SB 可能锁屏。thin Home 对 lock state=1 直接 skip。
# 解锁需要 session 标记，否则 unlock_req 被忽略。
date +%s >"$VAR/.ziyan_project_active"
chmod 666 "$VAR/.ziyan_project_active" 2>/dev/null
rm -f "$VAR/.ziyan_unlock_rep"
echo 1 >"$VAR/.ziyan_unlock_req"
chmod 666 "$VAR/.ziyan_unlock_req" 2>/dev/null
u=0
while test "$u" -lt 30; do
  if [ -s "$VAR/.ziyan_unlock_rep" ] && grep -q '^ok$' "$VAR/.ziyan_unlock_rep"; then
    echo "A0_UNLOCK=ok t=$u"
    break
  fi
  sleep 0.5
  u=$((u+1))
done
[ "$u" -ge 30 ] && echo "A0_UNLOCK=timeout"
rm -f "$VAR/.ziyan_unlock_req"
# Home 期间挡住 zydaemon revive（intent 可能仍是上一轮 stop=0）
echo 1 >"$VAR/.ziyan_user_stopped"
chmod 666 "$VAR/.ziyan_user_stopped" 2>/dev/null
printf 'stop=1\n' >"$VAR/.ziyan_run_intent"
chmod 666 "$VAR/.ziyan_run_intent" 2>/dev/null
rm -f "$VAR/.ziyan_open_app" "$VAR/.ziyan_embed_go"

# A0 不再要求设备预先位于桌面；业务脚本从当前真实前台直接开始。
# 这里仅记录当前前台，不拦截、不写 PRE_BLOCKED、不改变业务脚本。
FRONT0=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "A0 FRONT=$FRONT0"
SEQ0=$(sed -n 's/.*seq=\([0-9][0-9]*\).*/\1/p' "$VAR/.ziyan_resident_bytes" 2>/dev/null | head -1)
SEQ0=${SEQ0:-0}
echo "A0_SEQ=$SEQ0"

for t in $(seq 1 20); do
  echo 1 >"$VAR/.ziyan_force_recap"; chmod 666 "$VAR/.ziyan_force_recap" 2>/dev/null
  # framecap 会原子消费该请求；chmod 与消费之间存在正常竞态，缺文件
  # 不是帧失败也不应污染门禁输出。
  echo "nonce=run1_a0_$t" >"$VAR/.ziyan_frame_req"; chmod 666 "$VAR/.ziyan_frame_req" 2>/dev/null || true
  sleep 1
  L=$(tail -1 "$VAR/.ziyan_framecap_log" 2>/dev/null)
  echo "$L" | grep -qE 'ok=1 via=' && { echo "A0_FRAME t=$t"; break; }
done

# A1 embed Desktop（脚本自己找色+tap）
# 启动 ACK ≠ 帧新鲜。旧实现 sleep 3 只看 lua_embedded；prewarm 最多 8s，
# Home 释帧后会把已接受的脚本判 A1 FAIL，再一票否决 BUSINESS_PASS。
rm -f "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded" "$VAR/.ziyan_embed_alive" \
  "$VAR/.ziyan_ready_ack" "$VAR/.ziyan_run_ack"
# 新 run：先写 intent stop=0，再清 user_stopped。反过来 zydaemon 会 revive。
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
chmod 666 "$VAR/.ziyan_run_intent" 2>/dev/null
rm -f "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_stop" "$VAR/.ziyan_kill_scripts"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
printf '1\n' >"$VAR/.ziyan_embed_on"
date +%s >"$VAR/.ziyan_project_active"
RID="run1_${TAG}_$$"
printf 'nonce=%s\nrequest_id=%s\nsession_id=%s\n' "$RID" "$RID" "$RID" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_on" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_project_active" 2>/dev/null
EMB=0
A1_HOW=""
A1_T=0
for t in $(seq 1 30); do
  A1_T=$t
  if [ -f "$VAR/.ziyan_lua_embedded" ]; then EMB=1; A1_HOW=lua_embedded; break; fi
  if [ -f "$VAR/.ziyan_embed_alive" ]; then EMB=1; A1_HOW=embed_alive; break; fi
  if grep -q 'ok=1' "$VAR/.ziyan_embed_ack" 2>/dev/null; then EMB=1; A1_HOW=embed_ack; break; fi
  if grep -q 'accepted=1' "$VAR/.ziyan_run_ack" 2>/dev/null; then EMB=1; A1_HOW=run_ack; break; fi
  if grep -q 'state=running' "$VAR/.ziyan_session" 2>/dev/null; then EMB=1; A1_HOW=session; break; fi
  sleep 0.5
done
echo "A1_HOW=$A1_HOW t=$A1_T EMB=$EMB"
[ "$EMB" = 1 ] && pass A1_embed || fail A1_embed
persist a1_embed "A1_HOW=$A1_HOW EMB=$EMB"

# A2 等「找到目标」/Verify — 不以「登录」为成功
deadline=$(( $(date +%s) + 90 ))
LAST=""
tap_gate_is_current() {
  local g ts x y
  [ -f "$VAR/.ziyan_tap_gate" ] || return 1
  g=$(tr '\n' ' ' <"$VAR/.ziyan_tap_gate" 2>/dev/null)
  ts=$(sed -n 's/.*ts=\([0-9][0-9]*\).*/\1/p' <<<"$g" | head -1)
  x=$(sed -n 's/.*x=\([0-9][0-9]*\).*/\1/p' <<<"$g" | head -1)
  y=$(sed -n 's/.*y=\([0-9][0-9]*\).*/\1/p' <<<"$g" | head -1)
  [ -n "$ts" ] && [ "$ts" -ge "$START_TS" ] 2>/dev/null && \
    [ -n "$x" ] && [ -n "$y" ] && \
    [ "$x" -ge "$TAP_X1" ] 2>/dev/null && [ "$x" -le "$TAP_X2" ] 2>/dev/null && \
    [ "$y" -ge "$TAP_Y1" ] 2>/dev/null && [ "$y" -le "$TAP_Y2" ] 2>/dev/null
}
while [ "$(date +%s)" -lt "$deadline" ]; do
  T=$(grep '^text=' "$VAR/.ziyan_toast_dump" 2>/dev/null | tail -1 | sed 's/^text=//')
  [ -n "$T" ] && [ "$T" != "$LAST" ] && echo "TOAST=$T" && LAST=$T
  H=$(toast_hist)
  # toast_hist 是滚动历史，脚本命中后紧接着切进 App 时可能已被下一条
  # “searching” 覆盖；当前 toast_dump 则已经看到了业务脚本自己的 Verify 成功。
  # 两者都属于同一轮、在本门禁清空后产生的证据，必须同等认定，随后仍由 A3
  # 验证确实离开桌面，避免把单纯 toast 当业务成功。
  echo "$T" | grep -qE '找到目标|tap success|iOS7 tap|iPhone8Plus tap' && FIND_TAP=1
  echo "$T" | grep -q '登录' && LOGIN_SEEN=1
  echo "$T" | grep -q '色点A未找到' && NO_FIND=1
  echo "$H" | grep -qE '找到目标' && FIND_TAP=1
  echo "$H" | grep -q '登录' && LOGIN_SEEN=1
  echo "$H" | grep -q '色点A未找到' && NO_FIND=1
  grep -qE 'tap success|iOS7 tap|iPhone8Plus tap' "$VAR/.ziyan_verify_log" 2>/dev/null && FIND_TAP=1
  [ -f "$VAR/.ziyan_biz_tapped" ] && FIND_TAP=1
  # 即时 toast 与滚动历史均可能在 500ms 循环里被下一条 searching 覆盖；
  # .ziyan_tap_gate 是触控层写出的结构化本轮证据。启动前已清除旧值，并要求
  # 时间戳和坐标都落在该 Desktop 脚本的原始目标 ROI 内，之后仍由 A3 判前台变化。
  if [ "$FIND_TAP" != 1 ] && tap_gate_is_current; then
    echo "OBS_CURRENT_TAP_GATE=$(tr '\n' ' ' <"$VAR/.ziyan_tap_gate" 2>/dev/null)"
    FIND_TAP=1
  fi
  [ "$FIND_TAP" = 1 ] && break
  sleep 1
done

echo "TOAST_HIST=$(toast_hist | tail -c 600)"
echo "FIND_TAP=$FIND_TAP LOGIN_SEEN=$LOGIN_SEEN NO_FIND=$NO_FIND"
FRONT_A2=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "FRONT_A2=$FRONT_A2"

if [ "$FIND_TAP" = 1 ]; then
  pass A2_FIND_TAP
else
  fail A2_FAIL_NO_FIND
  echo "NOTE=script_ran_but_colorA_miss_on_home (not waiting_login)"
fi

# A3：触控证据（离桌 / touch_rep=ok / 同前台新帧）；不认裸 Verify.request
TOUCH_REP_OK=0
TAP_GATE=$(tr '\n' ' ' <"$VAR/.ziyan_tap_gate" 2>/dev/null)
echo "TAP_GATE=$TAP_GATE"
if [ "$FIND_TAP" = 1 ]; then
  d1=$(( $(date +%s) + 45 ))
  while [ "$(date +%s)" -lt "$d1" ]; do
    F=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
    echo "A3 FRONT=$F"
    if ! echo "$F" | grep -qi springboard; then
      CLICK=1
      break
    fi
    if grep -qE '^ok$|ok=1|status=ok' "$VAR/.ziyan_touch_rep" 2>/dev/null \
      || grep -qiE 'ok' "$VAR/.ziyan_touch_rep" 2>/dev/null; then
      TOUCH_REP_OK=1
    fi
    SEQ1=$(sed -n 's/.*seq=\([0-9][0-9]*\).*/\1/p' "$VAR/.ziyan_resident_bytes" 2>/dev/null | head -1)
    SEQ1=${SEQ1:-0}
    # 同前台仍在 SB：若 touch_rep 已 ok 且帧前进，记 TOUCH_SENT；仍要求离桌才 BUSINESS_PASS
    if [ "$TOUCH_REP_OK" = 1 ] && [ "$SEQ1" -gt "$SEQ0" ] 2>/dev/null; then
      echo "OBS_TOUCH_REP_OK seq0=$SEQ0 seq1=$SEQ1"
    fi
    sleep 1
  done
  [ "$CLICK" = 1 ] && pass A3_CLICK || fail A3_still_home
else
  echo "SKIP A3 (no find/tap)"
fi

[ "$LOGIN_SEEN" = 1 ] && echo "OBS_LOGIN=1" || echo "OBS_LOGIN=0"
LAST_CLASS=$(sed -n 's/.*class=\([^ ]*\).*/\1/p' "$VAR/.ziyan_last_find" 2>/dev/null | head -1)
echo "LAST_FIND_CLASS=$LAST_CLASS TOUCH_REP_OK=$TOUCH_REP_OK"

printf 'stop=1\n' >"$VAR/.ziyan_run_intent"
echo 1 >"$VAR/.ziyan_user_stopped"
printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"; chmod 666 "$VAR/.ziyan_kill_scripts" 2>/dev/null || true
sleep 2
rm -f "$VAR/.ziyan_active" "$VAR/.ziyan_keep_daemon" 2>/dev/null

FRONT_END=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo "FIND_TAP=$FIND_TAP CLICK=$CLICK FAIL=$FAIL FRONT_END=$FRONT_END"
# 202 typed verdict：视觉 / 触控分离；不绑固定 GAME_BID
TYPED=FAIL
VLINE=FAIL
if [ "$FIND_TAP" = 1 ] && [ "$CLICK" = 1 ] && [ "$FAIL" = 0 ]; then
  VLINE=PASS
  TYPED=BUSINESS_PASS
elif [ "$FIND_TAP" = 1 ] && [ "$CLICK" = 0 ]; then
  VLINE=FAIL_FIND_HIT_TOUCH
  TYPED=TOUCH_SENT_NO_UI_CHANGE
  echo "NOTE=vision_hit_but_still_home; open touch/HID/icon only — do_not_change_find"
elif [ "$FIND_TAP" = 0 ]; then
  VLINE=FAIL_NO_FIND
  if echo "$LAST_CLASS" | grep -qiE 'front_mismatch|stale'; then
    TYPED=VISION_STALE
  else
    TYPED=VISION_MISS
  fi
  echo "LAST_FIND=$(tr '\n' ' ' <"$VAR/.ziyan_last_find" 2>/dev/null | tail -c 240)"
  echo "CONTRACT=$(tr '\n' ' ' <"$VAR/.ziyan_find_contract" 2>/dev/null | tail -c 240)"
fi
echo "VERDICT=$VLINE"
echo "TYPED=$TYPED"
SB1=$(ps -axo pid=,args= 2>/dev/null | while read -r pid args; do
  case "$args" in */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo "$pid"; break ;; esac
done)
FC_N=$(ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
KEEP=$(test -f "$VAR/.ziyan_keep_daemon" && echo 1 || echo 0)
ACTIVE=$(test -f "$VAR/.ziyan_active" && echo 1 || echo 0)
EMBED=$(test -f "$VAR/.ziyan_embed_alive" -o -f "$VAR/.ziyan_lua_embedded" && echo 1 || echo 0)
SESS=$(tr '\n' ' ' <"$VAR/.ziyan_session" 2>/dev/null)
SB_CHG=0
[ -n "$SB0" ] && [ -n "$SB1" ] && [ "$SB0" != "$SB1" ] && SB_CHG=1
echo "FC_N=$FC_N SB0=$SB0 SB1=$SB1 SB_CHG=$SB_CHG KEEP_AFTER=$KEEP ACTIVE=$ACTIVE EMBED=$EMBED SESSION=$SESS"
echo "META end=$(date +%s)"
persist final "VERDICT=$VLINE
TYPED=$TYPED
FC_N=$FC_N
SB0=$SB0
SB1=$SB1
SB_CHG=$SB_CHG
KEEP_AFTER_STOP=$KEEP
ACTIVE=$ACTIVE
EMBED=$EMBED
SESSION=$SESS
FRONT_END=$FRONT_END
final=1"
EOS

  # 主机 SSH 输出只是便利数据。断线后重连拉设备端 final，不得把空输出写成 VISION_MISS。
  mkdir -p "$OUT/device"
  latest=$(ssh_r "$ip" "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:\$PATH; bash -c 'ls -t /private/var/mobile/Media/ZiYan/verdicts/run1_${tag}_*.txt 2>/dev/null | head -1'" | tr -d '\r\n')
  echo "DEVICE_FINAL_PATH=$latest" | tee "$OUT/device/${tag}_latest.path"
  if [ -n "$latest" ]; then
    scp_from "$ip" "$latest" "$OUT/device/${tag}_final.txt" 2>/dev/null || true
  fi
  if ! grep -qE '^TYPED=' "$OUT/gate_${tag}.txt" 2>/dev/null; then
    if grep -q '^final=1' "$OUT/device/${tag}_final.txt" 2>/dev/null; then
      echo "RECOVERED_FROM_DEVICE=1" >>"$OUT/gate_${tag}.txt"
      cat "$OUT/device/${tag}_final.txt" >>"$OUT/gate_${tag}.txt"
    else
      {
        echo "VERDICT=FAIL_TRANSPORT"
        echo "TYPED=INVALID_RUN"
        echo "NOTE=no_host_typed_and_no_device_final"
      } >>"$OUT/gate_${tag}.txt"
    fi
  fi

  # FAIL 取证：Home 上色点A GC/FIND
  if ! grep -q 'VERDICT=PASS' "$OUT/gate_${tag}.txt" 2>/dev/null; then
    local pts roi x1 y1 x2 y2 deg
    if [[ "$script" == "ios8p.lua" ]]; then
      pts="$IOS8_A_PTS"
      read -r x1 y1 x2 y2 deg <<<"$IOS8_A_ROI"
    else
      pts="$IOS7_A_PTS"
      read -r x1 y1 x2 y2 deg <<<"$IOS7_A_ROI"
    fi
    echo "[run1] dig colorA on Home .$tag" | tee -a "$OUT/dig_${tag}.txt"
    ssh_r "$ip" "SCHEME=$scheme X1=$x1 Y1=$y1 X2=$x2 Y2=$y2 DEG=$deg bash -s" <<R | tee -a "$OUT/dig_${tag}.txt"
set +e
if [ "\$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
for i in 1 2 3 4 5 6; do
  echo 1 >"\$V/.ziyan_go_home"; sleep 0.8; rm -f "\$V/.ziyan_go_home"
  echo "\$(tr -d '\\r\\n' <\$V/.ziyan_front_bid)" | grep -qi springboard && break
done
echo 1 >"\$V/.ziyan_force_recap"
echo "nonce=run1_dig" >"\$V/.ziyan_frame_req"
sleep 2
echo FRONT=\$(tr -d '\\r\\n' <\$V/.ziyan_front_bid)
echo SHM=\$(tr -d '\\r\\n' <\$V/.ziyan_shm_front_bid)
echo ORIENT=\$(tr '\\n' ' ' <\$V/.ziyan_orient 2>/dev/null)
echo TOAST_HIST=\$(tr '\\n' '|' <\$V/.ziyan_toast_hist 2>/dev/null | tail -c 400)
rm -f "\$V/.ziyan_color_rep"
printf 'getColor\\n%s\\n%s\\ngc\\n' "\$X1" "\$Y1" >"\$V/.ziyan_color_req"
for i in \$(seq 1 60); do [ -f "\$V/.ziyan_color_rep" ] && break; sleep 0.05; done
echo GC=\$(tr '\\n' '|' <\$V/.ziyan_color_rep)
rm -f "\$V/.ziyan_color_rep"
printf '%s\\n' findMulti '$pts' "\$DEG" "\$X1" "\$Y1" "\$X2" "\$Y2" digA >"\$V/.ziyan_color_req"
for i in \$(seq 1 80); do [ -f "\$V/.ziyan_color_rep" ] && break; sleep 0.05; done
echo FIND=\$(tr '\\n' '|' <\$V/.ziyan_color_rep)
R
  fi
}

run_serial() {
  local tag="$1" ip="$2" scheme="$3" script="$4"
  local clean_log="$OUT/pretest_${tag}.txt"
  echo "[run1] mandatory four-device pretest before .$tag"
  if ! bash "$ROOT/tools/zy_pretest_clean_4phone.sh" >"$clean_log" 2>&1; then
    echo "PRETEST_FAILED .$tag; stopping before device action" | tee -a "$OUT/STOP_REASON.txt"
    return 1
  fi
  run_one "$tag" "$ip" "$scheme" "$script"
  if ! grep -q 'VERDICT=PASS' "$OUT/gate_${tag}.txt" 2>/dev/null; then
    echo "SERIAL_STOP_FIRST_FAILURE .$tag" | tee -a "$OUT/STOP_REASON.txt"
    return 1
  fi
  return 0
}

case "$WANT" in
  all)
    # Required ZiYan validation order: .101 → .112 → .166 → .53.
    run_serial 101 192.168.31.101 rootful ios7.lua || true
    if [ -f "$OUT/STOP_REASON.txt" ]; then WANT_STOP=1; else WANT_STOP=0; fi
    if [ "$WANT_STOP" = 0 ]; then run_serial 112 192.168.31.112 rootful ios7.lua || true; fi
    if [ "$WANT_STOP" = 0 ] && [ ! -f "$OUT/STOP_REASON.txt" ]; then run_serial 166 192.168.31.166 rootful ios7.lua || true; fi
    if [ "$WANT_STOP" = 0 ] && [ ! -f "$OUT/STOP_REASON.txt" ]; then run_serial 53 192.168.31.53 rootless ios8p.lua || true; fi
    ;;
  53) run_serial 53 192.168.31.53 rootless ios8p.lua || true ;;
  101) run_serial 101 192.168.31.101 rootful ios7.lua || true ;;
  112) run_serial 112 192.168.31.112 rootful ios7.lua || true ;;
  166) run_serial 166 192.168.31.166 rootful ios7.lua || true ;;
  *) echo "usage: $0 [all|53|101|112|166]"; exit 2 ;;
esac

PASS_H=0; FAIL_H=0
for f in "$OUT"/gate_*.txt; do
  [ -f "$f" ] || continue
  echo "---- $(basename "$f") ----"
  tail -25 "$f"
  if grep -q 'VERDICT=PASS' "$f"; then PASS_H=$((PASS_H+1)); else FAIL_H=$((FAIL_H+1)); fi
done
{
  echo "# RUN1 script-logic gate"
  echo "stamp=$STAMP want=$WANT"
  echo "PASS_HOSTS=$PASS_H FAIL_HOSTS=$FAIL_H"
  echo "RULE=embed Desktop; PASS=找到目标+tap; login toast not required"
  if [ "$FAIL_H" = 0 ] && [ "$PASS_H" -gt 0 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
