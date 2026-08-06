#!/usr/bin/env bash
# ziyan_self_iterate.sh — 自我迭代闭环驱动（完整一轮才 ROUND_PASS）
#
# 一轮必须全部完成：
#   1) 硬缺口修复探测：绝对零 SB / carender_surf_nil + F4/F5/F6/F7/F8/F9/F11/F12
#   2) 拉取 .149/.171 触动找色效率与稳定性日志，写入对比优化证据
#   3) Desktop ios7.lua / ios8p.lua 仅 scp 到 .53/.101/.112/.166 自测
#   4) 门禁：inject + HOT20 + 脚本功能/性能有效（四机全过）
#
# 已移除：24h /「超越触动」人工审核跳过（改为 TS 日志驱动优化 + VERDICT 证据）
#
# 用法：
#   tools/ziyan_self_iterate.sh status
#   tools/ziyan_self_iterate.sh build
#   tools/ziyan_self_iterate.sh deploy [53|101|112|166|all]
#   tools/ziyan_self_iterate.sh scripts [53|101|112|166|all]   # scp Desktop lua + 拉起
#   tools/ziyan_self_iterate.sh selftest [53|101|112|166|all]  # 脚本功能/性能自测
#   tools/ziyan_self_iterate.sh gate [53|101|112|166|all]      # inject + HOT20
#   tools/ziyan_self_iterate.sh gap-carender                   # 绝对零合帧探测
#   tools/ziyan_self_iterate.sh gap-fx                         # F4–F12 硬缺口探测
#   tools/ziyan_self_iterate.sh ts-pull                        # .149/.171 触动日志
#   tools/ziyan_self_iterate.sh features [53|101|112|166|all]  # 全功能完整性
#   tools/ziyan_self_iterate.sh 开始迭代                       # 完整一轮（全过才 ROUND_PASS）
#
# 修复规则：最多 3 轮；同方案不重复测；架构问题先出方案分析；禁无意义调参。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
export THEOS="${THEOS:-$HOME/theos}"
DEVICES="${ROOT}/DEVICES.txt"
OUT_ROOT="${ROOT}/tmp_shots/SELF_ITERATE"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${OUT_ROOT}/${STAMP}"
PASS=alpine
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
FEATURE_LUA="${ROOT}/tools/zy_feature_completeness.lua"
FIX_STATE="${OUT_ROOT}/FIX_ROUND.state"
MAX_FIX_ROUNDS=3
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=4 -o ServerAliveCountMax=2)

# 整轮裁决位（0=过 / 1=败）
RC_BUILD=0
RC_DEPLOY=0
RC_SCRIPTS=0
RC_SELFTEST=0
RC_GATE=0
RC_FEATURES=0
RC_CARENDER=0
RC_FX=0
RC_TS=0

ssh_r() {
  local ip="$1"; shift
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@"
}
scp_r() {
  local src="$1" ip="$2" dst="$3"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$src" "root@$ip:$dst"
}

list_targets() {
  local want="${1:-all}"
  while IFS='|' read -r tag ip _pass scheme script _; do
    [[ "$tag" =~ ^#|^$ ]] && continue
    [[ "$scheme" == "ts" ]] && continue
    if [[ "$want" == "all" || "$want" == "$tag" ]]; then
      echo "$tag|$ip|$scheme|${script:-}"
    fi
  done < "$DEVICES"
}

list_ts() {
  while IFS='|' read -r tag ip _pass scheme _; do
    [[ "$tag" =~ ^#|^$ ]] && continue
    [[ "$scheme" == "ts" ]] || continue
    echo "$tag|$ip"
  done < "$DEVICES"
}

var_for() { [[ "$1" == rootless ]] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var; }
bin_for() { [[ "$1" == rootless ]] && echo /var/jb/usr/lib/ziyan/bin || echo /usr/lib/ziyan/bin; }
lua_for() { [[ "$1" == rootless ]] && echo /var/jb/usr/lib/ziyan/bin/lua5.3 || echo /usr/lib/ziyan/bin/lua5.3; }
run_for() { [[ "$1" == rootless ]] && echo /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua || echo /usr/lib/ziyan/lib/lua/ziyan_run.lua; }
mod_for() { [[ "$1" == rootless ]] && echo /var/jb/usr/lib/ziyan/lib/lua/modules || echo /usr/lib/ziyan/lib/lua/modules; }

cmd_status() {
  mkdir -p "$OUT"
  echo "=== AUDIT head ==="
  head -45 "${ROOT}/逆向学习/方案归档/终稿/AUDIT_方案完成度_20260729.md" || true
  echo "=== control Version ==="
  grep '^Version:' "${ROOT}/control" || true
  echo "=== hard gaps（本轮必须修完才 ROUND_PASS）==="
  cat <<EOF
1. 绝对零 SB / carender_surf_nil：.53 禁 FrameRelay + .ziyan_no_relay 仍能合帧
2. F4 HTTP：Zy.HttpCtl + ziyan_httpctl_serve.sh 本机 /status 可用
3. F8 性能门禁：Zy.PerfGate.export → .ziyan_perf_gate
4. F5 Thread：协程模块可 require
5. F6 AppDump：脱壳/IPA 流水线模块+探测
6. F7 AntiDetect：反越狱检测绕过模块+探测
7. F9 Sandbox：Lua 脚本沙箱模块+探测
8. F11 FrameHook：游戏引擎帧回调 Hook 模块+探测
9. F12 AutoInject：Mach-O 自动 dylib 注入模块+探测
10. Desktop ios7/ios8p 四机自测：功能正常·性能稳定·函数有效
11. 全功能完整性 features：Zy 全模块加载 + 核心 API 冒烟（四机）
12. .149/.171 触动找色效率/稳定性日志拉取 + 对比优化证据
（已移除：24h/「超越触动」人工审核跳过）
修复上限：最多 ${MAX_FIX_ROUNDS} 轮；架构问题先分析；禁止同方案复测
EOF
  echo "OUT=$OUT"
}

cmd_build() {
  mkdir -p "$OUT"
  echo "[build] rootful..."
  if ! make package 2>&1 | tee "$OUT/build_rf.log" | tail -8; then
    RC_BUILD=1; echo BUILD_FAIL_RF; return 1
  fi
  echo "[build] rootless..."
  if ! THEOS_PACKAGE_SCHEME=rootless make clean package 2>&1 | tee "$OUT/build_rl.log" | tail -8; then
    RC_BUILD=1; echo BUILD_FAIL_RL; return 1
  fi
  ls -t packages/com.ziyan.ziyan_*_iphoneos-arm.deb | head -1 | tee "$OUT/deb_rf.path"
  ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb | head -1 | tee "$OUT/deb_rl.path"
  echo BUILD_OK
}

latest_deb() {
  local scheme="$1"
  if [[ "$scheme" == rootless ]]; then
    ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb | head -1
  else
    ls -t packages/com.ziyan.ziyan_*_iphoneos-arm.deb | head -1
  fi
}

cmd_deploy() {
  local want="${1:-all}"
  mkdir -p "$OUT"
  local fail=0
  while IFS='|' read -r tag ip scheme _; do
    local deb; deb="$(latest_deb "$scheme")"
    echo "[deploy] .$tag $ip $scheme <- $(basename "$deb")"
    if ! scp_r "$deb" "$ip" /var/mobile/Media/ziyan_iter.deb; then
      echo "DEPLOY_SCP_FAIL .$tag"; fail=1; continue
    fi
    if ! ssh_r "$ip" "bash -s" <<EOS 2>&1 | tee -a "$OUT/deploy_${tag}.log"
set +e
dpkg -i /var/mobile/Media/ziyan_iter.deb >/tmp/zy_iter.out 2>&1
tail -8 /tmp/zy_iter.out
VAR=/usr/lib/ziyan/var; DL=/Library/MobileSubstrate/DynamicLibraries; BIN=/usr/lib/ziyan/bin
if [ -d /var/jb/usr/lib/ziyan ]; then
  VAR=/var/jb/usr/lib/ziyan/var; DL=/var/jb/Library/MobileSubstrate/DynamicLibraries; BIN=/var/jb/usr/lib/ziyan/bin
fi
rm -f "\$VAR/.ziyan_zero_sb_full_off" "\$VAR/.ziyan_zero_sb_inject_off"
rm -f "\$VAR/.ziyan_framecap_off" "\$VAR/.ziyan_stop" "\$VAR/.ziyan_user_stopped"
rm -f "\$VAR/.ziyan_allow_sb_relay"
rm -f "\$VAR/.ziyan_no_relay"   # 137：允许 IOMFB 失败后 SB UICreate 冷备（.53 必需）
echo 1 > "\$VAR/.ziyan_zero_sb_full"; echo 1 > "\$VAR/.ziyan_zero_sb_inject"
# 177：禁部署写死 find_sb_banned（桌面图标找色冷；ServeLoop 自管）
rm -f "\$VAR/.ziyan_find_sb_banned"
echo 1 > "\$VAR/.ziyan_bbframe_on"   # backboardd 全局合帧
# 166：IOMFB 默认 BGRA→RGBA swap；落盘旗防误判 noswap（.101 登录色串）
echo 1 > "\$VAR/.ziyan_iomfb_swap"
rm -f "\$VAR/.ziyan_iomfb_noswap"
chmod 666 "\$VAR/.ziyan_find_sb_banned" "\$VAR/.ziyan_bbframe_on" "\$VAR/.ziyan_iomfb_swap" 2>/dev/null
# 确保 BBFrame plist 启用（若曾被 off）
if [ -f "\$DL/ZiYanBBFrame.plist.ziyan_off" ] && [ ! -f "\$DL/ZiYanBBFrame.plist" ]; then
  mv -f "\$DL/ZiYanBBFrame.plist.ziyan_off" "\$DL/ZiYanBBFrame.plist"
fi
[ -f "\$DL/ZiYanVol.plist" ] && mv -f "\$DL/ZiYanVol.plist" "\$DL/ZiYanVol.plist.ziyan_off"
killall -9 ziyadaemond ziyan_framecap 2>/dev/null
# 179-1：清僵锁/僵 pid；.101 曾 pagein 坏 inode → 强制换新二进制后再 bootstrap
rm -f "\$VAR/.ziyan_framecap_serve.lock" "\$VAR/.ziyan_framecap_wrap.pid" 2>/dev/null
rm -f /tmp/ziyan_framecap_179 /tmp/fc_signed 2>/dev/null
"\$BIN/ziyadaemond" >/dev/null 2>&1 &
LD=/Library/LaunchDaemons; [ -d /var/jb/Library/LaunchDaemons ] && LD=/var/jb/Library/LaunchDaemons
launchctl bootout system "\$LD/com.ziyan.framecap.plist" >/dev/null 2>&1 || true
launchctl unload "\$LD/com.ziyan.framecap.plist" >/dev/null 2>&1 || true
launchctl bootstrap system "\$LD/com.ziyan.framecap.plist" >/dev/null 2>&1 \
  || launchctl load -w "\$LD/com.ziyan.framecap.plist" >/dev/null 2>&1 || true
# 182：禁 kickstart -k（真机可挂死 SSH）；先普通 kick，再短等，仍无则 orphan serve
# （framecap 入口 memorystatus 自抬 jetsam，launchd 6MB 不再必杀）
launchctl kickstart system/com.ziyan.framecap 2>/dev/null \
  || launchctl kickstart com.ziyan.framecap 2>/dev/null || true
sleep 2
if ! ps -A -o command= 2>/dev/null | grep -q '[z]iyan_framecap serve'; then
  rm -f "\$VAR/.ziyan_framecap_serve.lock" "\$VAR/.ziyan_framecap_wrap.pid" 2>/dev/null
  "\$BIN/ziyan_framecap" serve >/dev/null 2>&1 &
fi
rm -f "\$VAR/.ziyan_force_recap" 2>/dev/null || true
echo com.ziyan.ziyan > "\$VAR/.ziyan_open_app" 2>/dev/null || true
command -v sbreload >/dev/null && sbreload || killall -9 SpringBoard
echo DEPLOY_OK
EOS
    then
      echo "DEPLOY_SSH_FAIL .$tag"; fail=1; continue
    fi
    grep -q DEPLOY_OK "$OUT/deploy_${tag}.log" || fail=1
  done < <(list_targets "$want")
  echo "[deploy] wait SB 25s..."; sleep 25
  RC_DEPLOY=$fail
  if [[ "$fail" == 0 ]]; then echo DEPLOY_ALL_OK; else echo DEPLOY_PARTIAL_OR_FAIL; return 1; fi
}

# Desktop lua 仅 scp（禁止改内容）+ 拉起自测脚本
cmd_scripts() {
  local want="${1:-all}"
  mkdir -p "$OUT"
  if [[ ! -f "$DESKTOP_IOS7" || ! -f "$DESKTOP_IOS8P" ]]; then
    echo "FATAL missing Desktop scripts: $DESKTOP_IOS7 / $DESKTOP_IOS8P"
    RC_SCRIPTS=1; return 1
  fi
  local fail=0
  while IFS='|' read -r tag ip scheme script; do
    [[ -n "$script" ]] || script="ios7.lua"
    local src="$DESKTOP_IOS7"
    [[ "$script" == "ios8p.lua" ]] && src="$DESKTOP_IOS8P"
    local VAR BIN LUA RUN MEDIA
    VAR="$(var_for "$scheme")"; BIN="$(bin_for "$scheme")"
    LUA="$(lua_for "$scheme")"; RUN="$(run_for "$scheme")"
    MEDIA=/var/mobile/Media/ZiYan
    echo "[scripts] .$tag scp $script (Desktop→device, no edit)"
    if ! scp_r "$src" "$ip" "$MEDIA/$script"; then
      echo "SCRIPT_SCP_FAIL .$tag"; fail=1; continue
    fi
    # 远端 setsid 脱离 SSH 会话，避免 nohup 子进程拖死 ssh；本机 timeout 防挂死
    LUALIB="${RUN%/ziyan_run.lua}"
    if ! sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" -o ConnectTimeout=15 \
      "root@$ip" "SCHEME=$scheme SCRIPT=$script VAR=$VAR LUA=$LUA RUN=$RUN LUALIB=$LUALIB MEDIA=$MEDIA bash -s" <<'EOS' 2>&1 \
      | tee "$OUT/scripts_${tag}.log"
set +e
# rootless 部分机无 awk：用 sed/cut
PIDS=$(ps -A -o pid=,command= 2>/dev/null | grep 'ziyan_run.lua' | grep "$SCRIPT" | grep -v grep | sed 's/^ *//' | cut -d' ' -f1)
for p in $PIDS; do kill -9 $p 2>/dev/null; done
mkdir -p "$VAR" "$MEDIA"
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_run_intent"
chmod 666 "$VAR/.ziyan_run_intent" 2>/dev/null
rm -f "$VAR/.ziyan_lua_hung" "$VAR/.ziyan_stop" "$VAR/.ziyan_user_stopped" 2>/dev/null
# 140：对齐触动 TSDaemon——默认 embed-in-framecap；禁再写 light/embed_off（会打回独立 lua、pulse 假死）
rm -f "$VAR/.ziyan_light" "$VAR/.ziyan_embed_off" 2>/dev/null
echo 1 >"$VAR/.ziyan_embed_on" 2>/dev/null
echo 1 >"$VAR/.ziyan_keep_daemon" 2>/dev/null
chmod 666 "$VAR/.ziyan_embed_on" "$VAR/.ziyan_keep_daemon" 2>/dev/null
# 优先 framecap 内嵌（对齐 TSDaemon）；失败才回退独立 lua5.3
FC_ALIVE=0
if [ -f "$VAR/.ziyan_framecap_alive" ]; then
  FC_ALIVE=1
fi
if ps -A -o command= 2>/dev/null | grep -q 'ziyan_framecap serve'; then
  FC_ALIVE=1
fi
if [ "$FC_ALIVE" = 1 ]; then
  # 143：默认不锁游戏前台（对标触动：桌面/任意 App 都可找色）
  # 仅 ZY_OPEN_GAME=1 时才写 open_app（旧对拍可选）
  rm -f "$VAR/.ziyan_open_app" 2>/dev/null
  if [ "${ZY_OPEN_GAME:-0}" = "1" ]; then
    BID=com.xztl.ios
    case "$SCRIPT" in ios8p.lua) BID=com.ljzbbadao.game ;; esac
    printf '%s\n' "$BID" >"$VAR/.ziyan_open_app"
    chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
    sleep 2
  else
    # 回桌面再 embed，验证 SB 找色；业务脚本自己点进 App 不由此锁死
    echo 1 >"$VAR/.ziyan_go_home"
    chmod 666 "$VAR/.ziyan_go_home" 2>/dev/null
    sleep 1
    rm -f "$VAR/.ziyan_go_home" 2>/dev/null
  fi
  rm -f "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_lua_embedded" 2>/dev/null
  printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$VAR/.ziyan_embed_script"
  echo "nonce=scripts_$$" >"$VAR/.ziyan_embed_go"
  chmod 666 "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" 2>/dev/null
  ok=0
  i=0
  while [ $i -lt 50 ]; do
    i=$((i+1))
    sleep 0.1
    if [ -f "$VAR/.ziyan_lua_embedded" ] || grep -q 'ok=1' "$VAR/.ziyan_embed_ack" 2>/dev/null; then
      ok=1
      break
    fi
    if grep -q 'ok=0' "$VAR/.ziyan_embed_ack" 2>/dev/null; then
      break
    fi
  done
  echo EMBED_TRY=1 ACK="$(cat "$VAR/.ziyan_embed_ack" 2>/dev/null | tr '\n' ' ')" FRONT="$(cat "$VAR/.ziyan_front_bid" 2>/dev/null)"
  if [ "$ok" = 1 ]; then
    echo LUA_N=embed BID=anyfront
    echo SCRIPT_LAUNCH_OK
    exit 0
  fi
  echo EMBED_FALLBACK=1
fi
if [ "$SCHEME" = rootless ]; then
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:$PATH
fi
# 143：禁自测强制 App.launch 游戏；前台随用户/脚本走
rm -f "$VAR/.ziyan_open_app" 2>/dev/null
rm -f "$VAR/.ziyan_touch_req" "$VAR/.ziyan_touch_rep" 2>/dev/null
LOGF="/tmp/${SCRIPT%.lua}_nohup.log"
cd "$MEDIA" || exit 1
# setsid：彻底脱离 sshd 会话，防止 SCRIPT_LAUNCH_OK 后 ssh 仍挂起
if command -v setsid >/dev/null 2>&1; then
  setsid "$LUA" "$RUN" "$MEDIA/$SCRIPT" >"$LOGF" 2>&1 </dev/null &
else
  nohup "$LUA" "$RUN" "$MEDIA/$SCRIPT" >"$LOGF" 2>&1 </dev/null &
fi
disown >/dev/null 2>&1 || true
sleep 2
N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_run.lua' | grep "$SCRIPT" | grep -v grep | wc -l | tr -d ' ')
echo LUA_N=$N BID=anyfront FRONT="$(cat "$VAR/.ziyan_front_bid" 2>/dev/null)"
if [ "$N" -ge 1 ]; then echo SCRIPT_LAUNCH_OK; else echo SCRIPT_LAUNCH_FAIL; fi
exit 0
EOS
    then
      echo "SCRIPT_SSH_FAIL .$tag"; fail=1; continue
    fi
    grep -q SCRIPT_LAUNCH_OK "$OUT/scripts_${tag}.log" || fail=1
  done < <(list_targets "$want")
  echo "[scripts] warm 12s..."; sleep 12
  RC_SCRIPTS=$fail
  if [[ "$fail" == 0 ]]; then echo SCRIPTS_OK; else echo SCRIPTS_PARTIAL_OR_FAIL; return 1; fi
}

# 真机产品自测（53/101/112/166）：SB 残留 / 图标 / 音量 / 脚本 / while / 找色toast / 稳性
cmd_selftest() {
  local want="${1:-all}"
  mkdir -p "$OUT"
  local fail=0
  local -a targets=()
  while IFS= read -r line; do [[ -n "$line" ]] && targets+=("$line"); done < <(list_targets "$want")
  local entry tag ip scheme script
  for entry in "${targets[@]}"; do
    IFS='|' read -r tag ip scheme script <<<"$entry"
    [[ -n "$script" ]] || script="ios7.lua"
    echo "[selftest] .$tag $script"
    if ! ssh_r "$ip" "SCHEME=$scheme SCRIPT=$script bash -s" <<'EOS' 2>&1 | tee "$OUT/selftest_${tag}.log"
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  DL=/var/jb/Library/MobileSubstrate/DynamicLibraries
  APP=/var/jb/Applications/ZiYan.app
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:$PATH
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
  S=/var/jb/bin/sleep
  UIOPEN=/var/jb/usr/bin/uiopen
else
  VAR=/usr/lib/ziyan/var
  DL=/Library/MobileSubstrate/DynamicLibraries
  APP=/Applications/ZiYan.app
  export PATH=/usr/lib/ziyan/bin:/bin:$PATH
  export DYLD_LIBRARY_PATH=/usr/lib/ziyan/lib
  S=/bin/sleep
  UIOPEN=/usr/bin/uiopen
fi
MEDIA=/var/mobile/Media/ZiYan
ok=1
# ---1 SB 注入残留（产品：Vol 必须 OFF；FrameRelay 允许残留但须标明）---
VOL_ON=0; [ -f "$DL/ZiYanVol.plist" ] && VOL_ON=1
RELAY_ON=0; [ -f "$DL/ZiYanFrameRelay.plist" ] && RELAY_ON=1
FULL=0; [ -f "$VAR/.ziyan_zero_sb_full" ] && FULL=1
echo "T1_SB VOL_FILTER=$VOL_ON RELAY_FILTER=$RELAY_ON ZERO_FULL=$FULL"
[ "$VOL_ON" = 0 ] || ok=0
[ "$FULL" = 1 ] || ok=0

# ---2 开 App → 隐藏越狱图标（产品：session 边沿 / hide_req）---
# rootful uiopen 仅认 URL；rootless 支持 --bundleid / -b
launch_app() {
  if [ -x "$UIOPEN" ]; then
    if $UIOPEN --help 2>&1 | grep -q bundleid; then
      $UIOPEN --bundleid com.ziyan.ziyan >/dev/null 2>&1 || $UIOPEN -b com.ziyan.ziyan >/dev/null 2>&1
    else
      $UIOPEN 'com.ziyan.ziyan://' >/dev/null 2>&1
    fi
  fi
  echo "com.ziyan.ziyan" > "$VAR/.ziyan_open_app"
}
launch_app
# 等 session/心跳（最多 12s）
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -f "$VAR/.ziyan_app_session" ] || [ -f "$VAR/.ziyan_app_heartbeat" ] && break
  $S 1
done
echo 1 > "$VAR/.ziyan_icon_hide_req"; chmod 666 "$VAR/.ziyan_icon_hide_req" 2>/dev/null
# daemon 快拍消费 req；最多等 3s
HIDE=0
for _i in 1 2 3 4 5 6; do
  [ -f "$VAR/.ziyan_jb_icons_hidden" ] && HIDE=1
  [ -f "$MEDIA/.ziyan_jb_icons_hidden" ] && HIDE=1
  [ -f "$MEDIA/ZYCV/res/.ziyan_jb_icons_hidden" ] && HIDE=1
  [ "$HIDE" = 1 ] && break
  $S 0.5
done
echo "T2_HIDE=$HIDE"
[ "$HIDE" = 1 ] || ok=0

# ---3 关程序 → 恢复图标（必须无 session；产品硬语义）---
killall -9 ZiYan 2>/dev/null
killall -9 ceshi 2>/dev/null
rm -f "$VAR/.ziyan_app_session" "$MEDIA/.ziyan_app_session" "$MEDIA/ZYCV/res/.ziyan_app_session"
rm -f "$VAR/.ziyan_app_heartbeat"
echo 1 > "$VAR/.ziyan_icon_restore_req"; chmod 666 "$VAR/.ziyan_icon_restore_req" 2>/dev/null
HIDE2=1
for _i in 1 2 3 4 5 6; do
  HIDE2=0
  [ -f "$VAR/.ziyan_jb_icons_hidden" ] && HIDE2=1
  [ -f "$MEDIA/.ziyan_jb_icons_hidden" ] && HIDE2=1
  [ -f "$MEDIA/ZYCV/res/.ziyan_jb_icons_hidden" ] && HIDE2=1
  [ "$HIDE2" = 0 ] && break
  $S 0.5
done
echo "T3_RESTORE_HIDE=$HIDE2"
[ "$HIDE2" = 0 ] || ok=0

# ---4/5/6 音量 − 菜单 / + 录制语义 / 冲突（须 App 存活）---
launch_app
for _i in 1 2 3 4 5 6 7 8; do
  [ -f "$VAR/.ziyan_app_heartbeat" ] && break
  $S 1
done
# 再藏回（产品运行态）
echo 1 > "$VAR/.ziyan_icon_hide_req"
rm -f "$VAR/.ziyan_app_vol_menu_req" "$VAR/.ziyan_app_vol_evt" "$VAR/.ziyan_record_req"
echo 1 > "$VAR/.ziyan_app_vol_menu_req"
$S 1.2
MENU_CONSUMED=1; [ -f "$VAR/.ziyan_app_vol_menu_req" ] && MENU_CONSUMED=0
echo down > "$VAR/.ziyan_app_vol_evt"
# + ：录制/暂停语义（daemon_app_cmd + evt）
printf 'vol_up\n' > "$VAR/.ziyan_daemon_app_cmd"
$S 0.5
echo up > "$VAR/.ziyan_app_vol_evt"
VOL_UP_OK=0
[ -f "$VAR/.ziyan_daemon_app_cmd" ] || VOL_UP_OK=1
if [ -f "$VAR/.ziyan_record_flag" ] || [ -f "$VAR/.ziyan_script_paused" ] || [ -f "$VAR/.ziyan_app_vol_evt" ]; then
  VOL_UP_OK=1
fi
# 冲突：menu_req 已消费且 evt 非空
CONFLICT_OK=0
if [ "$MENU_CONSUMED" = 1 ] && [ -f "$VAR/.ziyan_app_vol_evt" ]; then
  CONFLICT_OK=1
fi
echo "T4_VOL_MINUS menu_consumed=$MENU_CONSUMED"
echo "T5_VOL_PLUS ok=$VOL_UP_OK evt=$(cat $VAR/.ziyan_app_vol_evt 2>/dev/null | tr -d '\n')"
echo "T6_VOL_CONFLICT ok=$CONFLICT_OK"
[ "$MENU_CONSUMED" = 1 ] || ok=0
[ "$VOL_UP_OK" = 1 ] || ok=0
[ "$CONFLICT_OK" = 1 ] || ok=0

# ---7 Desktop 脚本 + ---10 while 存活（SB 不得无故换 pid 在 T10）---
SAFE=0; [ -f /var/mobile/.eksafemode ] && SAFE=1
LUA_N=$(ps -A -o command= | grep 'ziyan_run.lua' | grep "$SCRIPT" | grep -v grep | wc -l | tr -d ' ')
HB1=$(stat -c %Y "$VAR/.ziyan_heartbeat_lua5.3" 2>/dev/null || stat -f %m "$VAR/.ziyan_heartbeat_lua5.3" 2>/dev/null || echo 0)
$S 3
HB2=$(stat -c %Y "$VAR/.ziyan_heartbeat_lua5.3" 2>/dev/null || stat -f %m "$VAR/.ziyan_heartbeat_lua5.3" 2>/dev/null || echo 0)
case "$HB1" in ''|*[!0-9]*) HB1=0 ;; esac
case "$HB2" in ''|*[!0-9]*) HB2=0 ;; esac
WHILE_OK=0
[ "$LUA_N" -ge 1 ] && WHILE_OK=1
echo "T7_SCRIPT LUA_N=$LUA_N SAFE=$SAFE"
echo "T10_WHILE=$WHILE_OK hb=$HB1->$HB2"
[ "$SAFE" = 0 ] || ok=0
[ "$LUA_N" -ge 1 ] || ok=0
[ "$WHILE_OK" = 1 ] || ok=0

# ---8 找色 + toast---
rm -f $VAR/.ziyan_color_rep $VAR/.ziyan_find_via
printf 'nonce=selftest\nforce=1\n' > $VAR/.ziyan_frame_req
$S 1.2
printf 'findMulti\n[16777215]\n90\n0\n0\n400\n400\nst1\n' > $VAR/.ziyan_color_req
ticks=0; via=timeout
while [ $ticks -lt 250 ]; do
  if [ -f $VAR/.ziyan_color_rep ]; then
    via=$(cat $VAR/.ziyan_find_via 2>/dev/null | tr -d '\n'); [ -n "$via" ] || via=daemon
    break
  fi
  $S 0.002; ticks=$((ticks+1))
done
ms=$((ticks*2))
printf 'toast\nselftest_ok\n800\n' > "$VAR/.ziyan_overlay_toast"
$S 0.5
TOAST_LEFT=0; [ -f "$VAR/.ziyan_overlay_toast" ] && TOAST_LEFT=1
echo "T8_FIND ms=$ms via=$via toast_pending=$TOAST_LEFT"
[ "$ms" -le 80 ] || ok=0
case "$via" in daemon|ncnn|local|carender|relay) ;; *) ok=0 ;; esac

# ---9 App 性能心跳 / ---10 SB 稳 / ---11 AI 模块---
SB1=$(ps -A -o pid=,command= | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
$S 5
SB2=$(ps -A -o pid=,command= | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
APP_HB=0; [ -f "$VAR/.ziyan_app_heartbeat" ] && APP_HB=1
AI_OK=0
if [ -f /var/jb/usr/lib/ziyan/lib/lua/modules/AI.lua ] || [ -f /usr/lib/ziyan/lib/lua/modules/AI.lua ]; then AI_OK=1; fi
echo "T9_APP_HB=$APP_HB"
echo "T10_SB sb=$SB1->$SB2"
echo "T11_AI=$AI_OK"
[ -n "$SB1" ] && [ "$SB1" = "$SB2" ] || ok=0
[ "$APP_HB" = 1 ] || ok=0
[ "$AI_OK" = 1 ] || ok=0

FC=$(test -f $VAR/.ziyan_framecap_alive && echo 1 || echo 0)
DA=$(test -f $VAR/.ziyan_zydaemon_alive && echo 1 || echo 0)
[ "$FC" = 1 ] || ok=0
[ "$DA" = 1 ] || ok=0
echo "ACK=$(cat $VAR/.ziyan_frame_ack 2>/dev/null | tr '\n' ';')"
[ "$ok" = 1 ] && echo SELFTEST_PASS || echo SELFTEST_FAIL
EOS
    then
      echo "SELFTEST_SSH_FAIL .$tag"; fail=1; continue
    fi
    grep -q SELFTEST_PASS "$OUT/selftest_${tag}.log" || fail=1
  done
  RC_SELFTEST=$fail
  if [[ "$fail" == 0 ]]; then echo SELFTEST_ALL_OK; else echo SELFTEST_PARTIAL_OR_FAIL; return 1; fi
}

hot20_one() {
  local ip="$1" scheme="$2" tag="$3"
  ssh_r "$ip" "SCHEME=$scheme bash -s" <<'EOS'
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:$PATH
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
  S=/var/jb/bin/sleep
else
  VAR=/usr/lib/ziyan/var
  export PATH=/usr/lib/ziyan/bin:/bin:$PATH
  export DYLD_LIBRARY_PATH=/usr/lib/ziyan/lib
  S=/bin/sleep
fi
rm -f $VAR/.ziyan_color_req $VAR/.ziyan_color_rep $VAR/.ziyan_color_req.tmp
printf 'nonce=iter_warm\nforce=1\n' > $VAR/.ziyan_frame_req
$S 2
# 184-5：tmp+mv 原子落盘——禁 printf> 的 O_TRUNC 空窗被 color_offload 抢走
zy_put_req() {
  printf 'findMulti\n[16777215]\n90\n0\n0\n300\n300\n%s\n' "$1" >"$VAR/.ziyan_color_req.tmp"
  mv -f "$VAR/.ziyan_color_req.tmp" "$VAR/.ziyan_color_req"
}
for w in 1 2 3; do
  N=w$w; rm -f $VAR/.ziyan_color_rep
  zy_put_req "$N"
  for t in $(seq 1 400); do [ -f $VAR/.ziyan_color_rep ] && break; $S 0.002; done
  $S 0.04
done
ok=0;sum=0;max=0
for i in $(seq 1 20); do
  N=h$i; rm -f $VAR/.ziyan_color_rep $VAR/.ziyan_find_via
  zy_put_req "$N"
  ticks=0; via=timeout
  while [ $ticks -lt 200 ]; do
    if [ -f $VAR/.ziyan_color_rep ]; then
      via=$(cat $VAR/.ziyan_find_via 2>/dev/null|tr -d '\n'); [ -n "$via" ] || via=daemon; break
    fi
    $S 0.002; ticks=$((ticks+1))
  done
  ms=$((ticks*2)); sum=$((sum+ms)); [ $ms -gt $max ] && max=$ms
  if [ $ms -le 15 ] && { [ "$via" = ncnn ] || [ "$via" = daemon ]; }; then ok=$((ok+1)); else echo FAIL $i $ms $via; fi
  $S 0.03
done
echo HOT20 ok=$ok avg=$((sum/20)) max=$max
echo CAP=$(cat $VAR/.ziyan_frame_ack 2>/dev/null | tr '\n' ';')
EOS
}

cmd_gate() {
  local want="${1:-all}"
  mkdir -p "$OUT"
  local all_pass=1
  # mapfile：避免子进程 ssh 吞掉 while-stdin 导致只测第一台却 GATE_PASS
  local -a targets=()
  while IFS= read -r line; do [[ -n "$line" ]] && targets+=("$line"); done < <(list_targets "$want")
  local entry tag ip scheme _
  for entry in "${targets[@]}"; do
    IFS='|' read -r tag ip scheme _ <<<"$entry"
    echo "[gate] inject .$tag"
    if ! "${ROOT}/tools/device_inject_gate.sh" "$ip" "$scheme" 2>&1 | tee "$OUT/gate_${tag}.log"; then
      all_pass=0
    fi
    echo "[gate] HOT20 .$tag"
    if ! hot20_one "$ip" "$scheme" "$tag" 2>&1 | tee "$OUT/hot20_${tag}.log"; then
      echo "HOT20_SSH_FAIL .$tag" | tee -a "$OUT/hot20_${tag}.log"
      all_pass=0
    fi
    grep -q 'HOT20 ok=20' "$OUT/hot20_${tag}.log" || all_pass=0
  done
  local n=${#targets[@]}
  [[ "$n" -ge 4 || "$want" != "all" ]] || { echo "GATE_FAIL expected>=4 got=$n"; all_pass=0; }
  RC_GATE=$((1-all_pass))
  if [[ "$all_pass" == 1 ]]; then echo GATE_PASS devices=$n; else echo GATE_PARTIAL_OR_FAIL devices=$n; return 1; fi
}

# 绝对零探测：临时卸 FrameRelay，禁 RequestSbRelay，看本机合帧能否活
cmd_gap_carender() {
  mkdir -p "$OUT"
  local ip=192.168.31.53
  echo "[gap-carender] probe .53 with FrameRelay OFF + no_relay flag"
  if ! ssh_r "$ip" 'bash -s' <<'EOS' 2>&1 | tee "$OUT/gap_carender_53.log"
set +e
VAR=/var/jb/usr/lib/ziyan/var
DL=/var/jb/Library/MobileSubstrate/DynamicLibraries
BIN=/var/jb/usr/lib/ziyan/bin
if [ -f "$DL/ZiYanFrameRelay.plist" ]; then
  mv -f "$DL/ZiYanFrameRelay.plist" "$DL/ZiYanFrameRelay.plist.ziyan_off_test"
  echo RELAY_FILTER=OFF
fi
echo 1 > "$VAR/.ziyan_no_relay"
killall -9 SpringBoard 2>/dev/null
sleep 8
killall -9 ziyan_framecap 2>/dev/null
$BIN/ziyan_framecap serve >/dev/null 2>&1 &
sleep 1
rm -f $VAR/.ziyan_frame_ack
printf 'nonce=norelay\nforce=1\n' > $VAR/.ziyan_frame_req
sleep 3
echo ACK=$(cat $VAR/.ziyan_frame_ack 2>/dev/null | tr '\n' ';')
echo HOOKS=$(cat $VAR/.ziyan_hooks 2>/dev/null | tr '\n' ' ')
if [ -f "$DL/ZiYanFrameRelay.plist.ziyan_off_test" ]; then
  mv -f "$DL/ZiYanFrameRelay.plist.ziyan_off_test" "$DL/ZiYanFrameRelay.plist"
  echo RELAY_FILTER=RESTORED
fi
rm -f "$VAR/.ziyan_no_relay"
killall -9 SpringBoard 2>/dev/null
echo PROBE_DONE
EOS
  then
    RC_CARENDER=1
    echo "RESULT: SSH fail"
    return 2
  fi
  if grep -qE 'via=(local|carender)' "$OUT/gap_carender_53.log" && grep -q 'ok=1' "$OUT/gap_carender_53.log"; then
    echo "RESULT: local/carender capture OK without relay — absolute zero candidate PASS"
    RC_CARENDER=0
    return 0
  fi
  if grep -q 'via=relay' "$OUT/gap_carender_53.log"; then
    echo "RESULT: still depends on relay (absolute zero NOT ready)"
  else
    echo "RESULT: capture FAIL without relay"
  fi
  RC_CARENDER=1
  return 2
}

# F4–F12 硬缺口探测（本地模块存在性 + .53 冒烟）
cmd_gap_fx() {
  mkdir -p "$OUT"
  local report="$OUT/gap_fx.md"
  local fail=0
  {
    echo "# gap-fx 硬缺口探测 $STAMP"
    echo
  } >"$report"

  check_local() {
    local id="$1" path="$2" note="$3"
    if [[ -f "$ROOT/$path" ]]; then
      echo "| $id | LOCAL_OK | \`$path\` | $note |" >>"$report"
      echo "[gap-fx] $id LOCAL_OK $path"
    else
      echo "| $id | LOCAL_FAIL | missing \`$path\` | $note |" >>"$report"
      echo "[gap-fx] $id LOCAL_FAIL missing $path"
      fail=1
    fi
  }

  {
    echo "## 本地模块/工具"
    echo "| ID | 结果 | 路径 | 说明 |"
    echo "|----|------|------|------|"
  } >>"$report"

  check_local F4 "lua/modules/HttpCtl.lua" "HTTP 管理"
  check_local F4s "layout/usr/lib/ziyan/bin/ziyan_httpctl_serve.sh" "HTTP serve"
  check_local F5 "lua/modules/Thread.lua" "协程"
  check_local F6 "lua/modules/AppDump.lua" "脱壳+IPA"
  check_local F7 "lua/modules/AntiDetect.lua" "反越狱绕过"
  check_local F8 "lua/modules/PerfGate.lua" "性能门禁"
  check_local F9 "lua/modules/Sandbox.lua" "脚本沙箱"
  check_local F11 "lua/modules/FrameHook.lua" "帧回调 Hook"
  check_local F12 "lua/modules/AutoInject.lua" "Mach-O 自动注入"

  echo >>"$report"
  echo "## .53 冒烟（F4/F5/F8）" >>"$report"
  local ip=192.168.31.53
  if ssh_r "$ip" 'bash -s' <<'EOS' 2>&1 | tee "$OUT/gap_fx_53.log"
set +e
MOD=/var/jb/usr/lib/ziyan/lib/lua/modules
BIN=/var/jb/usr/lib/ziyan/bin
VAR=/var/jb/usr/lib/ziyan/var
LUA=/var/jb/usr/lib/ziyan/bin/lua5.3
export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
export PATH=$BIN:/var/jb/bin:$PATH

# F4：拉起 httpctl 并打 /status（若 nc/curl 不可用则看 alive 旗）
killall -9 ziyan_httpctl_serve.sh 2>/dev/null
nohup $BIN/ziyan_httpctl_serve.sh >/tmp/zy_httpctl.log 2>&1 &
sleep 1
ALIVE=$(test -f $VAR/.ziyan_httpctl_alive && echo 1 || echo 0)
STAT=""
if command -v curl >/dev/null 2>&1; then
  STAT=$(curl -s -m 2 http://127.0.0.1:18080/status 2>/dev/null | head -c 200)
fi
echo F4_ALIVE=$ALIVE
echo F4_STAT=${STAT:-none}

# F5/F8：lua require 冒烟
$LUA -e '
package.path="/var/jb/usr/lib/ziyan/lib/lua/modules/?.lua;"..package.path
local ok5, t5 = pcall(require, "Thread")
print("F5_REQUIRE=" .. (ok5 and "OK" or ("FAIL:"..tostring(t5))))
local ok8, t8 = pcall(require, "PerfGate")
print("F8_REQUIRE=" .. (ok8 and "OK" or ("FAIL:"..tostring(t8))))
if ok8 and type(t8.export)=="function" then
  local okx, err = pcall(t8.export)
  print("F8_EXPORT=" .. (okx and "OK" or ("FAIL:"..tostring(err))))
else
  print("F8_EXPORT=SKIP")
end
' 2>&1

# F6/F7/F9/F11/F12 设备端模块存在性
for m in AppDump AntiDetect Sandbox FrameHook AutoInject; do
  if [ -f "$MOD/$m.lua" ]; then echo "DEV_${m}=OK"; else echo "DEV_${m}=MISSING"; fi
done
EOS
  then
    {
      echo
      echo '```'
      cat "$OUT/gap_fx_53.log"
      echo '```'
    } >>"$report"
    grep -q 'F4_ALIVE=1' "$OUT/gap_fx_53.log" || fail=1
    grep -q 'F5_REQUIRE=OK' "$OUT/gap_fx_53.log" || fail=1
    grep -q 'F8_REQUIRE=OK' "$OUT/gap_fx_53.log" || fail=1
    grep -q 'DEV_AppDump=OK' "$OUT/gap_fx_53.log" || fail=1
    grep -q 'DEV_AntiDetect=OK' "$OUT/gap_fx_53.log" || fail=1
    grep -q 'DEV_Sandbox=OK' "$OUT/gap_fx_53.log" || fail=1
    grep -q 'DEV_FrameHook=OK' "$OUT/gap_fx_53.log" || fail=1
    grep -q 'DEV_AutoInject=OK' "$OUT/gap_fx_53.log" || fail=1
  else
    echo "gap-fx SSH fail" | tee -a "$report"
    fail=1
  fi

  RC_FX=$fail
  if [[ "$fail" == 0 ]]; then
    echo "GAP_FX_PASS" | tee -a "$report"
  else
    echo "GAP_FX_FAIL（缺模块或冒烟未过；未完成 ≠ 通过）" | tee -a "$report"
    return 1
  fi
}

# 拉取触动 .149/.171 找色效率与稳定性日志，结合本轮 ZiYan HOT20 写优化证据
cmd_ts_pull() {
  mkdir -p "$OUT/ts"
  local fail=0
  local cmp="$OUT/ts/COMPARE_OPTIMIZE.md"
  {
    echo "# TouchSprite vs ZiYan 找色/稳定性对比 $STAMP"
    echo
    echo "> 只读观察 .149/.171；禁止部署 ZiYan 到触动机。"
    echo "> 「超越触动」须本对比 + 四机门禁证据，禁止口头宣称。"
    echo
  } >"$cmp"

  while IFS='|' read -r tag ip; do
    echo "[ts-pull] .$tag $ip"
    if ! ssh_r "$ip" 'bash -s' <<'EOS' 2>&1 | tee "$OUT/ts/ts_${tag}.log"
set +e
echo ===HOST===; hostname; date
echo ===UPTIME===; uptime
echo ===TSDaemon===
ps -A -o pid=,etime=,rss=,command= | grep '[T]SDaemon' | head -3
echo ===TS_LOG_META===
LOG=/var/mobile/Media/TouchSprite/log/ts.log
if [ -f "$LOG" ]; then
  wc -l "$LOG"
  ls -la "$LOG"
  echo ===TS_LOG_TAIL===
  tail -n 200 "$LOG"
  echo ===TS_FINDCOLOR_GREP===
  grep -iE 'findcolor|findMulti|ms=|cost=|耗时|timeout|crash|restart' "$LOG" | tail -n 80
else
  echo NO_TS_LOG
fi
echo ===TS_DAY_LOG===
ls -lt /var/mobile/Media/TouchSprite/log/ 2>/dev/null | head -15
EOS
    then
      echo "TS_PULL_FAIL .$tag" | tee -a "$cmp"
      fail=1
      continue
    fi
    {
      echo "## .$tag ($ip)"
      echo
      echo '```'
      # 摘要：daemon + 找色相关行
      grep -E '===|TSDaemon|NO_TS_LOG|findcolor|findMulti|ms=|cost=|耗时' "$OUT/ts/ts_${tag}.log" | head -60
      echo '```'
      echo
    } >>"$cmp"
  done < <(list_ts)

  {
    echo "## ZiYan 本轮 HOT20（若已跑 gate）"
    echo
    for f in "$OUT"/hot20_*.log; do
      [[ -f "$f" ]] || continue
      echo "- $(basename "$f"): $(grep '^HOT20' "$f" | tail -1)"
    done
    echo
    echo "## 优化方向（结合触动日志）"
    echo "1. 找色 P50/P99：对齐触动日志耗时字段（若无 ms 字段则记「触动未暴露」+ 用稳定性 uptime/daemon 作对照）"
    echo "2. 长稳：TSDaemon etime vs ZiYan SpringBoard/framecap/lua hung"
    echo "3. 合帧路径：绝对零 SB 未过前，FrameRelay 成本必须计入对比"
    echo "4. 产出下一轮代码改动清单，禁止无证据宣称超越"
  } >>"$cmp"

  RC_TS=$fail
  if [[ "$fail" == 0 ]]; then
    echo "TS_PULL_OK → $cmp"
  else
    echo "TS_PULL_PARTIAL_OR_FAIL → $cmp"
    return 1
  fi
}

# 全功能完整性：四机跑 zy_feature_completeness.lua
cmd_features() {
  local want="${1:-all}"
  mkdir -p "$OUT"
  [[ -f "$FEATURE_LUA" ]] || { echo "MISSING $FEATURE_LUA"; RC_FEATURES=1; return 1; }
  local fail=0
  local -a targets=()
  while IFS= read -r line; do [[ -n "$line" ]] && targets+=("$line"); done < <(list_targets "$want")
  local entry tag ip scheme _
  for entry in "${targets[@]}"; do
    IFS='|' read -r tag ip scheme _ <<<"$entry"
    local VAR LUA RUN MEDIA
    VAR="$(var_for "$scheme")"; LUA="$(lua_for "$scheme")"; RUN="$(run_for "$scheme")"
    MEDIA=/var/mobile/Media/ZiYan
    echo "[features] .$tag"
    if ! scp_r "$FEATURE_LUA" "$ip" "$MEDIA/zy_feature_completeness.lua"; then
      echo "FEATURES_SCP_FAIL .$tag"; fail=1; continue
    fi
    if ! ssh_r "$ip" "SCHEME=$scheme VAR=$VAR LUA=$LUA RUN=$RUN MEDIA=$MEDIA bash -s" <<'EOS' 2>&1 | tee "$OUT/features_${tag}.log"
set +e
if [ "$SCHEME" = rootless ]; then
  export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib:/var/jb/usr/lib
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:$PATH
fi
rm -f "$VAR/.ziyan_feature_completeness"
# 停掉同名残留后单次跑完（setsid 防 ssh 挂死）
PIDS=$(ps -A -o pid=,command= 2>/dev/null | grep 'zy_feature_completeness' | grep -v grep | sed 's/^ *//' | cut -d' ' -f1)
for p in $PIDS; do kill -9 $p 2>/dev/null; done
cd "$MEDIA" || exit 1
if command -v setsid >/dev/null 2>&1; then
  setsid "$LUA" "$RUN" "$MEDIA/zy_feature_completeness.lua" >/tmp/zy_features_out.log 2>&1 </dev/null &
else
  nohup "$LUA" "$RUN" "$MEDIA/zy_feature_completeness.lua" >/tmp/zy_features_out.log 2>&1 </dev/null &
fi
disown >/dev/null 2>&1 || true
# 等结果文件（最长 90s）
ok=0
for i in $(seq 1 90); do
  if [ -f "$VAR/.ziyan_feature_completeness" ]; then
    head -1 "$VAR/.ziyan_feature_completeness"
    grep -E 'FEATURES_(PASS|FAIL)|FEATURES pass=' /tmp/zy_features_out.log 2>/dev/null | tail -5
    if grep -q '^FEATURES_PASS' /tmp/zy_features_out.log 2>/dev/null \
       || grep -q 'fail=0' "$VAR/.ziyan_feature_completeness" 2>/dev/null; then
      # fail=0 在首行 pass=N fail=0
      if head -1 "$VAR/.ziyan_feature_completeness" | grep -q 'fail=0'; then
        echo FEATURES_PASS; ok=1; break
      fi
    fi
    if grep -q 'fail=[1-9]' "$VAR/.ziyan_feature_completeness" 2>/dev/null; then
      echo FEATURES_FAIL; break
    fi
  fi
  sleep 1
done
[ "$ok" = 1 ] || { echo FEATURES_FAIL_OR_TIMEOUT; cat /tmp/zy_features_out.log 2>/dev/null | tail -30; }
EOS
    then
      echo "FEATURES_SSH_FAIL .$tag"; fail=1; continue
    fi
    grep -q FEATURES_PASS "$OUT/features_${tag}.log" || fail=1
  done
  RC_FEATURES=$fail
  if [[ "$fail" == 0 ]]; then echo FEATURES_ALL_OK; else echo FEATURES_PARTIAL_OR_FAIL; return 1; fi
}

write_iterlog() {
  local verdict="$1"
  {
    echo "# ITERLOG $STAMP"
    echo
    echo "- control: $(grep '^Version:' control | head -1)"
    echo "- OUT: \`$OUT\`"
    echo "- verdict: **$verdict**"
    echo "- fix_round: $(cat "$FIX_STATE" 2>/dev/null || echo 0)/$MAX_FIX_ROUNDS"
    echo
    echo "## 一轮检查清单"
    echo "| 步骤 | RC | 说明 |"
    echo "|------|----|------|"
    echo "| build | $RC_BUILD | rootful+rootless |"
    echo "| deploy | $RC_DEPLOY | 四机装包 |"
    echo "| scripts | $RC_SCRIPTS | Desktop ios7/ios8p 仅 scp+拉起 |"
    echo "| selftest | $RC_SELFTEST | T1–T8 真机产品清单 |"
    echo "| gate | $RC_GATE | inject+HOT20 四机 |"
    echo "| features | $RC_FEATURES | 全功能完整性 |"
    echo "| gap-carender | $RC_CARENDER | 绝对零 SB |"
    echo "| gap-fx | $RC_FX | F4/F5/F6/F7/F8/F9/F11/F12 |"
    echo "| ts-pull | $RC_TS | .149/.171 触动对比优化 |"
    echo
    echo "## 产物"
    echo "- features_*.log / gap_carender_53.log / gap_fx.md / ts/COMPARE_OPTIMIZE.md"
    echo
    echo "> 任一项 RC≠0 → ROUND_FAIL。修复≤${MAX_FIX_ROUNDS}轮；架构问题先分析停改。"
  } | tee "$OUT/ITERLOG.md"
  echo "WROTE $OUT/ITERLOG.md"
}

bump_fix_round_or_stop() {
  mkdir -p "$OUT_ROOT"
  local n=0
  [[ -f "$FIX_STATE" ]] && n=$(cat "$FIX_STATE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" >"$FIX_STATE"
  if [[ "$n" -gt "$MAX_FIX_ROUNDS" ]]; then
    {
      echo "# STOP_AFTER_${MAX_FIX_ROUNDS}_FIX_ROUNDS"
      echo
      echo "## 架构/硬缺口分析（停止盲目修改）"
      echo "1. **F6/F7/F9/F11/F12**：缺真实模块（架构落地），禁止空 stub。"
      echo "2. **HOT20 非 .53**：热机/合帧抖动 — 勿拧 15ms 阈值装通过。"
      echo "3. **T1–T8**：图标/音量依赖 App Overlay；Vol 已卸，FrameRelay 可残留。"
      echo "4. **超越触动**：须 COMPARE_OPTIMIZE + 四机证据，禁止口头。"
      echo
      echo "证据目录：\`$OUT\`"
    } | tee "$OUT/STOP_ANALYSIS.md"
    echo "STOP: fix_round=$n > $MAX_FIX_ROUNDS → $OUT/STOP_ANALYSIS.md"
    return 2
  fi
  echo "FIX_ROUND=$n/$MAX_FIX_ROUNDS"
  return 0
}

cmd_start_iterate() {
  cmd_status
  if [[ -f "$FIX_STATE" ]]; then
    local cur; cur=$(cat "$FIX_STATE" 2>/dev/null || echo 0)
    if [[ "$cur" -ge "$MAX_FIX_ROUNDS" ]]; then
      echo "已达修复上限 $MAX_FIX_ROUNDS，拒绝继续盲目迭代。先读 STOP_ANALYSIS / 换架构方案。"
      cmd_gap_carender || true
      write_iterlog "ROUND_STOP (fix_cap)"
      return 2
    fi
  fi

  cmd_build || true
  cmd_deploy all || true
  cmd_scripts all || true
  cmd_gate all || true
  cmd_selftest all || true
  cmd_features all || true
  cmd_gap_carender || true
  cmd_gap_fx || true
  cmd_ts_pull || true

  local sum=$((RC_BUILD+RC_DEPLOY+RC_SCRIPTS+RC_SELFTEST+RC_GATE+RC_FEATURES+RC_CARENDER+RC_FX+RC_TS))
  if [[ "$sum" -eq 0 ]]; then
    rm -f "$FIX_STATE"
    write_iterlog "ROUND_PASS"
    echo "===== ROUND_PASS $OUT ====="
    return 0
  fi
  write_iterlog "ROUND_FAIL (sum_rc=$sum)"
  # 架构级：绝对零 + 缺 F6-12 → 直接分析，计入 1 轮但不鼓励小修
  if [[ "$RC_CARENDER" -ne 0 || "$RC_FX" -ne 0 ]]; then
    {
      echo "# ARCH_BLOCKERS $STAMP"
      echo "- RC_CARENDER=$RC_CARENDER（本机合帧/entitlement 架构）"
      echo "- RC_FX=$RC_FX（F6/F7/F9/F11/F12 模块架构缺失；F4 serve 若 ALIVE=0 另查拉起）"
      echo "- RC_FEATURES=$RC_FEATURES（依赖上列模块）"
      echo "- 建议：先出合帧与模块落地设计，禁止空文件过 gap-fx / 反复拧 selftest ms"
    } | tee "$OUT/ARCH_ANALYSIS.md"
  fi
  bump_fix_round_or_stop || true
  echo "===== ROUND_FAIL sum_rc=$sum $OUT ====="
  return 1
}

usage() {
  cat <<EOF
usage: $0 {status|build|deploy|scripts|selftest|gate|features|gap-carender|gap-fx|ts-pull|开始迭代} [target]

「开始迭代」=
  build→deploy→scripts→gate→selftest→features→gap-carender→gap-fx→ts-pull
  全过 ROUND_PASS；修复≤${MAX_FIX_ROUNDS}轮后 STOP+分析
EOF
}

main() {
  local cmd="${1:-status}"; shift || true
  case "$cmd" in
    status) cmd_status ;;
    build) cmd_build ;;
    deploy) cmd_deploy "${1:-all}" ;;
    scripts) cmd_scripts "${1:-all}" ;;
    selftest) cmd_selftest "${1:-all}" ;;
    gate) cmd_gate "${1:-all}" ;;
    features) cmd_features "${1:-all}" ;;
    gap-carender) cmd_gap_carender ;;
    gap-fx) cmd_gap_fx ;;
    ts-pull) cmd_ts_pull ;;
    开始迭代) cmd_start_iterate ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"
