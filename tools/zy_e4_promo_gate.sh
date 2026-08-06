#!/usr/bin/env bash
# 刀 E4 晋级：四机 embed 引擎长跑（禁 Desktop 业务色 / phase6）
# 采样：SB pid 环、KEEP、force/toast、color_req、framecap RSS
# 用法: ZY_E4_MIN=30 bash tools/zy_e4_promo_gate.sh
# 可选: ZY_E4_MIN=5 短测；HOSTS 默认 101 112 166 53
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
MIN="${ZY_E4_MIN:-30}"
SEC=$((MIN * 60))
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166 53); else HOSTS=("$@"); fi
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/E4_PROMO_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

echo "OUT=$OUT MIN=$MIN SEC=$SEC hosts=${HOSTS[*]}" | tee "$OUT/OUT_PATH.txt"

# 远程长跑 worker（每机后台）
run_remote() {
  local H="$1"
  local IP="192.168.31.$H"
  local SCHEME=rootful
  [ "$H" = "53" ] && SCHEME=rootless
  echo "==== start .$H (${MIN}min) ===="
  ssh_r "$IP" "SCHEME=$SCHEME SEC=$SEC H=$H bash -s" <<'R' >"$OUT/gate_${H}.txt" 2>&1 &
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var; B=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var; B=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
mkdir -p "$MEDIA" "$V"
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
echo "META host=.$H VER=$VER SEC=$SEC start=$(date +%s)"
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
: >"$V/.ziyan_kill_scripts"; printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 1
rm -f "$V/.ziyan_embed_off" "$V/.ziyan_active" "$V/.ziyan_keep_daemon" \
  "$V/.ziyan_session_keep" "$V/.ziyan_force_recap" "$V/.ziyan_toast_bump" \
  "$V/.ziyan_path_stats" "$V/.ziyan_embed_go" "$V/.ziyan_lua_embedded"
launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || \
  launchctl kickstart -k com.ziyan.framecap 2>/dev/null || true
sleep 1.2

sb_pid() {
  ps -axo pid,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1
}
fc_rss() {
  line=$(ps -axo rss,args 2>/dev/null | grep '[z]iyan_framecap serve' | head -1)
  echo "$line" | sed 's/^ *//' | cut -d' ' -f1
}

SB0=$(sb_pid); SB0=${SB0:-0}
RSS0=$(fc_rss); RSS0=${RSS0:-0}
echo "SB0=$SB0 RSS0=$RSS0"

# 引擎探针：循环找色（白点 ROI，非业务色）；禁 keep 暗补（no_auto_keep）
# 用长脚本：每圈 sleep，总时长约 SEC
cat >"$MEDIA/_e4_promo.lua" <<LUA
local deadline = (os.time() or 0) + $SEC
local n = 0
while (os.time() or 0) < deadline do
  n = n + 1
  if type(findMultiColorInRegionFuzzy) == "function" then
    findMultiColorInRegionFuzzy(0xFFFFFF, "", 90, 0, 0, 60, 60)
  end
  if type(mSleep) == "function" then
    mSleep(200)
  elseif type(ziyan_embed_msleep) == "function" then
    ziyan_embed_msleep(200)
  end
  if (n % 50) == 0 then
    -- 轻心跳：写 pulse 由引擎侧 find 已写
  end
end
LUA
chmod 666 "$MEDIA/_e4_promo.lua"
rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop"
printf 'path=%s/_e4_promo.lua\nstop=0\n' "$MEDIA" >"$V/.ziyan_run_intent"
printf '%s/_e4_promo.lua\n' "$MEDIA" >"$V/.ziyan_embed_script"
echo "nonce=e4_${H}_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_go"

FORCE=0; TOAST=0; SB_CHG=0; KEEP_PEAK=0
end=$(( $(date +%s) + SEC + 30 ))
sample=0
while [ "$(date +%s)" -lt "$end" ]; do
  sample=$((sample + 1))
  if [ -f "$V/.ziyan_force_recap" ]; then FORCE=$((FORCE+1)); rm -f "$V/.ziyan_force_recap"; fi
  if [ -f "$V/.ziyan_toast_bump" ]; then TOAST=$((TOAST+1)); rm -f "$V/.ziyan_toast_bump"; fi
  if [ -f "$V/.ziyan_keep_daemon" ]; then KEEP_PEAK=1; fi
  SB=$(sb_pid); SB=${SB:-0}
  if [ "$SB0" != "0" ] && [ "$SB" != "0" ] && [ "$SB" != "$SB0" ]; then
    SB_CHG=$((SB_CHG + 1))
    echo "SB_RING sample=$sample from=$SB0 to=$SB"
    SB0=$SB
  fi
  # 脚本结束后可提前退
  if [ ! -f "$V/.ziyan_lua_embedded" ] && [ ! -f "$V/.ziyan_embed_alive" ] && [ "$sample" -gt 20 ]; then
    # 等几拍确认结束
    sleep 2
    if [ ! -f "$V/.ziyan_lua_embedded" ] && [ ! -f "$V/.ziyan_embed_alive" ]; then
      echo "EMBED_DONE early sample=$sample"
      break
    fi
  fi
  sleep 2
done

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 2
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon" "$V/.ziyan_session_keep" 2>/dev/null

SB1=$(sb_pid); SB1=${SB1:-0}
RSS1=$(fc_rss); RSS1=${RSS1:-0}
KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0)
STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)
CR=$(echo "$STATS" | sed -n 's/.*via_color_req_find=\([0-9][0-9]*\).*/\1/p')
EM=$(echo "$STATS" | sed -n 's/.*via_embed_find=\([0-9][0-9]*\).*/\1/p')
[ -z "$CR" ] && CR=-1
[ -z "$EM" ] && EM=-1

echo "STATS=$STATS"
echo "SB_CHG=$SB_CHG FORCE_HITS=$FORCE TOAST_BUMP=$TOAST KEEP_PEAK=$KEEP_PEAK"
echo "END ACTIVE=$ACTIVE KEEP=$KEEP SB1=$SB1 RSS1=$RSS1"
echo "via_embed_find=$EM via_color_req_find=$CR"

OK=1
echo "$VER" | grep -qE '19[5-9]|19[6-9]|198' || { echo "FAIL ver_not_195plus"; OK=0; }
[ "$SB_CHG" = "0" ] || { echo "FAIL sb_ring=$SB_CHG"; OK=0; }
[ "$KEEP" = "0" ] || { echo "FAIL sticky_keep"; OK=0; }
[ "$ACTIVE" = "0" ] || { echo "FAIL sticky_active"; OK=0; }
[ "$CR" = "0" ] || [ "$CR" = "-1" ] || { echo "FAIL color_req=$CR"; OK=0; }
# 长跑应有 embed 找色；若 -1 可能脚本未起
[ "$EM" -gt 10 ] 2>/dev/null || { echo "FAIL embed_find_low=$EM"; OK=0; }
# force：30min 稳态允许少量切前台；上限按分钟放宽
FMAX=$(( MIN * 2 + 5 ))
[ "$FORCE" -le "$FMAX" ] 2>/dev/null || { echo "FAIL force_storm=$FORCE max=$FMAX"; OK=0; }
[ "$TOAST" = "0" ] || { echo "FAIL toast_bump=$TOAST"; OK=0; }

if [ "$OK" = 1 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
echo "META end=$(date +%s)"
R
  echo $! >"$OUT/pid_${H}.txt"
}

for H in "${HOSTS[@]}"; do
  run_remote "$H"
done

echo "waiting ${MIN}min workers…"
wait || true

PASS_N=0
FAIL_N=0
for H in "${HOSTS[@]}"; do
  echo "---- .$H ----"
  tail -20 "$OUT/gate_${H}.txt" || true
  if grep -q 'VERDICT=PASS' "$OUT/gate_${H}.txt" 2>/dev/null; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done

{
  echo "# E4 promo gate (engine only)"
  echo "stamp=$STAMP min=$MIN hosts=${HOSTS[*]}"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  if [ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -eq "${#HOSTS[@]}" ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -eq "${#HOSTS[@]}" ]
