#!/usr/bin/env bash
# 铁律：每次自测前必须四机清场——停脚本、杀业务进程、收僵尸、压内存。
# 202：FC_N!=1 清场后由 launchd 单次重建（禁 kickstart -k / 禁保留最新一个叠跑）
# 用法：bash tools/zy_pretest_clean_4phone.sh
set -euo pipefail
PASS="${ZY_SSH_PASS:-alpine}"
SSH_COMMON=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=12)
ssh_r() {
  local host="$1"
  shift
  # 四机已部署公钥时优先无密码通道；仅在密钥不可用时回退 alpine。
  if ssh "${SSH_COMMON[@]}" -o BatchMode=yes "root@$host" "$@"; then
    return 0
  fi
  sshpass -p "$PASS" ssh "${SSH_COMMON[@]}" \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 "root@$host" "$@"
}

clean_one() {
  local tag="$1" ip="$2" scheme="$3"
  echo "======== CLEAN .$tag ($ip $scheme) ========"
  ssh_r "$ip" "SCHEME=$scheme TAG=$tag bash -s" <<'EOS'
set +e
if [ "$SCHEME" = rootless ]; then
  VAR=/var/jb/usr/lib/ziyan/var
  BIN=/var/jb/usr/lib/ziyan/bin
  export PATH=/var/jb/usr/lib/ziyan/bin:/var/jb/bin:/var/jb/usr/bin:$PATH
else
  VAR=/usr/lib/ziyan/var
  BIN=/usr/lib/ziyan/bin
  export PATH=/usr/lib/ziyan/bin:/bin:/usr/bin:$PATH
fi
mkdir -p "$VAR"
# 1) 停脚本意图
echo stop=1 >"$VAR/.ziyan_stop"
rm -f "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_go" "$VAR/.ziyan_embed_script" \
      "$VAR/.ziyan_active" "$VAR/.ziyan_lua_run.pid" "$VAR/.ziyan_te_running" \
      "$VAR/.ziyan_chat_fixture_ready" \
      "$VAR/.ziyan_touch_req" "$VAR/.ziyan_open_app" "$VAR/.ziyan_menu_run_trig" \
      "$VAR/.ziyan_vol_menu_sticky" "$VAR/.ziyan_force_recap" "$VAR/.ziyan_frame_req" \
      "$VAR/.ziyan_color_req" "$VAR/.ziyan_color_req.daemon" \
      "$VAR/.ziyan_app_alive" "$VAR/.ziyan_prefer_app_touch" "$VAR/.ziyan_app_touch_ui" \
      "$VAR/.ziyan_allow_sb_relay" "$VAR/.ziyan_force_front_mismatch" \
      "$VAR/.ziyan_app_minimize_req" "$VAR/.ziyan_app_suspend_trig" \
      "$VAR/.ziyan_app_run_trig" "$VAR/.ziyan_app_stop_trig"
rm -f "$VAR/.ziyan_no_relay"   # 允许 SB UICreate 冷备（.53 IOMFB 拒权）
echo 1 >"$VAR/.ziyan_bbframe_on"
chmod 666 "$VAR/.ziyan_bbframe_on" 2>/dev/null
# 清场期间暂禁 SB 找色；收尾前清除，避免污染 RUN1
echo 1 >"$VAR/.ziyan_find_sb_banned"
chmod 666 "$VAR/.ziyan_find_sb_banned" 2>/dev/null
# 2) 杀业务 / 游戏 / 多余 lua（framecap 由下方按 FC_N 重建）
for pat in 'ziyan_run\.lua' 'lua5\.3' 'ios7\.lua' 'ios8p\.lua'; do
  ps -A -o pid=,command= 2>/dev/null | grep -E "$pat" | grep -v grep | while read -r p rest; do
    kill -9 "$p" 2>/dev/null
  done
done
for app in ZiYan ceshi com.xztl.ios com.ljzbbadao.game com.ychj.hlhjlygr com.zsyxs180.game; do
  killall -9 "$app" 2>/dev/null
done
ps -A -o pid=,command= 2>/dev/null | grep -iE 'xztl|ljzbbadao|ZiYan\.app|ceshi' | grep -v grep | while read -r p rest; do
  kill -9 "$p" 2>/dev/null
done
# 3) FC_N!=1 → 全清后由 zydaemon 单次重建（禁 6MB launchd 槽位）
FC_PIDS=$(ps -A -o pid=,command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | sed 's/^ *//' | cut -d' ' -f1)
FC_N=$(echo "$FC_PIDS" | grep -c '[0-9]' || true)
if [ "${FC_N:-0}" -ne 1 ]; then
  echo "$FC_PIDS" | while read -r p; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  rm -f "$VAR/.ziyan_framecap_serve.lock" "$VAR/.ziyan_framecap_wrap.pid" \
        "$VAR/.ziyan_framecap_owner" "$VAR/.ziyan_framecap_alive" 2>/dev/null
  sleep 1
  echo zydaemon >"$VAR/.ziyan_framecap_owner_mode"
  echo 1 >"$VAR/.ziyan_watchdog_framecap_need"
  chmod 666 "$VAR/.ziyan_framecap_owner_mode" "$VAR/.ziyan_watchdog_framecap_need" 2>/dev/null
  sleep 4
fi
# 4) 僵尸收割：对 Z 态父发 SIGCHLD
ps -A -o pid=,ppid=,state=,command= 2>/dev/null | while read -r z pp st rest; do
  case "$st" in *Z*) kill -CHLD "$pp" 2>/dev/null ;; esac
done
# 5) 释帧 / Home / 内存压力
echo 1 >"$VAR/.ziyan_release_screen"
echo 1 >"$VAR/.ziyan_go_home"
echo 1 >"$VAR/.ziyan_dismiss_menu"
rm -f "$VAR/.ziyan_keep_daemon"
sync 2>/dev/null
sleep 2
rm -f "$VAR/.ziyan_go_home" "$VAR/.ziyan_stop"
# 必须确认真的回到桌面：只写一次旗、等 2s 就走，前台常常还停在上一次测试打开的
# App。桌面脚本 ios7/ios8p 期望 SpringBoard 在前台，前台错位会让 embed 一路
# bid_mismatch 催帧，30min 长跑被判 force_storm（实测 .166 FORCE_HITS=280，
# 诊断 front=com.xztl.ios shm_bid=stale），把测试环境问题误报成代码缺陷。
i=0
while [ "$i" -lt 6 ]; do
  FB=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  case "$FB" in *springboard*) break ;; esac
  # 仅按 Home 不够：App 只是被切到后台，iOS 会把它再拉回前台
  # （实测 .53 清场时已是 springboard，30min 长跑却又变回 com.ljzbbadao.game）。
  # 桌面脚本必须在桌面上跑，这里把被测期间打开的 App 真正结束掉。
  if [ -n "$FB" ]; then
    # 第三方 App 主程序位于 /var/containers/Bundle/Application；旧逻辑只
    # 匹配 /Applications，导致游戏跨 sbreload 存活并继续持有已删除的 shm。
    # 测试机清场允许结束全部容器 App（包括 ZiYan 控制 App），系统进程不在此树。
    for p in $(ps -axo pid=,args= 2>/dev/null |
                 grep -E '/var/containers/Bundle/Application/|/Applications/' \
                 | grep -v '[S]pringBoard' | sed 's/^ *//' | cut -d' ' -f1); do
      BUNDLE=$(ps -p "$p" -o args= 2>/dev/null)
      case "$BUNDLE" in
        /var/containers/Bundle/Application/*|/Applications/*)
          kill -9 "$p" 2>/dev/null
          ;;
      esac
    done
    # 容器路径里不含 bundle id 的场景：按 SB 前台记录直接杀同名进程
    killall -9 "${FB##*.}" 2>/dev/null || true
  fi
  echo 1 >"$VAR/.ziyan_go_home"
  sleep 2
  rm -f "$VAR/.ziyan_go_home"
  i=$((i + 1))
done
echo "FRONT_AFTER_CLEAN=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)"
# 6) 确保 embed on、LIGHT 关、单例存活；清 find_sb_banned 免污染业务门禁
rm -f "$VAR/.ziyan_light" "$VAR/.ziyan_embed_off" "$VAR/.ziyan_find_sb_banned"
echo 1 >"$VAR/.ziyan_embed_on"
chmod 666 "$VAR/.ziyan_embed_on" 2>/dev/null
# FC_N==1 时不再触碰活实例；仅当仍为 0 才请求 zydaemon
FC_N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
if [ "${FC_N:-0}" -eq 0 ]; then
  echo zydaemon >"$VAR/.ziyan_framecap_owner_mode"
  echo 1 >"$VAR/.ziyan_watchdog_framecap_need"
  sleep 4
fi
# 若仍双开：全杀后交给 zydaemon 重建
FC_N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
if [ "${FC_N:-0}" -gt 1 ]; then
  ps -A -o pid=,command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | sed 's/^ *//' | cut -d' ' -f1 | while read -r p; do
    kill -9 "$p" 2>/dev/null
  done
  rm -f "$VAR/.ziyan_framecap_serve.lock" "$VAR/.ziyan_framecap_wrap.pid" 2>/dev/null
  sleep 1
  echo zydaemon >"$VAR/.ziyan_framecap_owner_mode"
  echo 1 >"$VAR/.ziyan_watchdog_framecap_need"
  sleep 4
fi
FC_N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
Z_N=$(ps -A -o state= 2>/dev/null | grep -c Z || true)
LUA_N=$(ps -A -o command= 2>/dev/null | grep -E 'ziyan_run\.lua|ios7\.lua|ios8p\.lua' | grep -v grep | wc -l | tr -d ' ')
OWNER=$(cat "$VAR/.ziyan_framecap_owner" 2>/dev/null | tr '\n' ' ')
echo "CLEAN_OK tag=$TAG FC_N=$FC_N Z_N=$Z_N LUA_N=$LUA_N owner=$OWNER"
EOS
}

clean_one 53 192.168.31.53 rootless &
P53=$!
clean_one 101 192.168.31.101 rootful &
P101=$!
clean_one 112 192.168.31.112 rootful &
P112=$!
clean_one 166 192.168.31.166 rootful &
P166=$!
FAIL=0
for pid in "$P53" "$P101" "$P112" "$P166"; do
  wait "$pid" || FAIL=1
done
if [ "$FAIL" -ne 0 ]; then
  echo "======== CLEAN FAILED ========" >&2
  exit 1
fi
echo "======== ALL CLEAN DONE ========"
