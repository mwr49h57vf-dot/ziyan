#!/usr/bin/env bash
# 铁律：每次自测前必须四机清场——停脚本、杀业务进程、收僵尸、压内存。
# 202：FC_N!=1 清场后由 launchd 单次重建（禁 kickstart -k / 禁保留最新一个叠跑）
# 用法：bash tools/zy_pretest_clean_4phone.sh
set -euo pipefail
PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o NumberOfPasswordPrompts=1)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

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
      "$VAR/.ziyan_touch_req" "$VAR/.ziyan_open_app" "$VAR/.ziyan_menu_run_trig" \
      "$VAR/.ziyan_vol_menu_sticky" "$VAR/.ziyan_force_recap" "$VAR/.ziyan_frame_req" \
      "$VAR/.ziyan_color_req" "$VAR/.ziyan_color_req.daemon" \
      "$VAR/.ziyan_app_alive" "$VAR/.ziyan_prefer_app_touch" "$VAR/.ziyan_app_touch_ui" \
      "$VAR/.ziyan_allow_sb_relay" "$VAR/.ziyan_force_front_mismatch" \
      "$VAR/.ziyan_app_minimize_req"
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
# 3) FC_N!=1 → 全清后 launchd 单次重建（禁「保留最新一个」）
FC_PIDS=$(ps -A -o pid=,command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | sed 's/^ *//' | cut -d' ' -f1)
FC_N=$(echo "$FC_PIDS" | grep -c '[0-9]' || true)
if [ "${FC_N:-0}" -ne 1 ]; then
  echo "$FC_PIDS" | while read -r p; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  rm -f "$VAR/.ziyan_framecap_serve.lock" "$VAR/.ziyan_framecap_wrap.pid" \
        "$VAR/.ziyan_framecap_owner" "$VAR/.ziyan_framecap_alive" 2>/dev/null
  sleep 1
  # 普通 kickstart（禁 -k）
  # 203：仅 launchd 单次 kickstart（禁 orphan nohup serve）
  launchctl kickstart system/com.ziyan.framecap 2>/dev/null \
    || launchctl kickstart com.ziyan.framecap 2>/dev/null || true
  sleep 2
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
# 6) 确保 embed on、LIGHT 关、单例存活；清 find_sb_banned 免污染业务门禁
rm -f "$VAR/.ziyan_light" "$VAR/.ziyan_embed_off" "$VAR/.ziyan_find_sb_banned"
echo 1 >"$VAR/.ziyan_embed_on"
chmod 666 "$VAR/.ziyan_embed_on" 2>/dev/null
# FC_N==1 时不再 kick；仅当仍为 0 才普通 kick
FC_N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
if [ "${FC_N:-0}" -eq 0 ]; then
  launchctl kickstart system/com.ziyan.framecap 2>/dev/null \
    || launchctl kickstart com.ziyan.framecap 2>/dev/null || true
  sleep 1
fi
# 若仍双开：全杀后单次 kick（不 -k）
FC_N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
if [ "${FC_N:-0}" -gt 1 ]; then
  ps -A -o pid=,command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | sed 's/^ *//' | cut -d' ' -f1 | while read -r p; do
    kill -9 "$p" 2>/dev/null
  done
  rm -f "$VAR/.ziyan_framecap_serve.lock" "$VAR/.ziyan_framecap_wrap.pid" 2>/dev/null
  sleep 1
  launchctl kickstart system/com.ziyan.framecap 2>/dev/null \
    || launchctl kickstart com.ziyan.framecap 2>/dev/null || true
  sleep 2
fi
FC_N=$(ps -A -o command= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | wc -l | tr -d ' ')
Z_N=$(ps -A -o state= 2>/dev/null | grep -c Z || true)
LUA_N=$(ps -A -o command= 2>/dev/null | grep -E 'ziyan_run\.lua|ios7\.lua|ios8p\.lua' | grep -v grep | wc -l | tr -d ' ')
OWNER=$(cat "$VAR/.ziyan_framecap_owner" 2>/dev/null | tr '\n' ' ')
echo "CLEAN_OK tag=$TAG FC_N=$FC_N Z_N=$Z_N LUA_N=$LUA_N owner=$OWNER"
EOS
}

clean_one 53 192.168.31.53 rootless &
clean_one 101 192.168.31.101 rootful &
clean_one 112 192.168.31.112 rootful &
clean_one 166 192.168.31.166 rootful &
wait
echo "======== ALL CLEAN DONE ========"
