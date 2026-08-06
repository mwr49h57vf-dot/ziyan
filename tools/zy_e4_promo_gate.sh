#!/usr/bin/env bash
# 刀 E4 晋级（202）：只用 Desktop ios7.lua / ios8p.lua 长跑旁路采样
# 禁生成 _e4_promo.lua；暖机 60s 后 5 点中位数作基线，末段斜率判定
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
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; }

[[ -f "$DESKTOP_IOS7" && -f "$DESKTOP_IOS8P" ]] || {
  echo "FATAL missing Desktop ios7/ios8p"; exit 2
}
SHA7=$(shasum -a 256 "$DESKTOP_IOS7" | awk '{print $1}')
SHA8=$(shasum -a 256 "$DESKTOP_IOS8P" | awk '{print $1}')
echo "OUT=$OUT MIN=$MIN SEC=$SEC hosts=${HOSTS[*]}" | tee "$OUT/OUT_PATH.txt"
echo "SHA256_ios7=$SHA7" | tee -a "$OUT/OUT_PATH.txt"
echo "SHA256_ios8p=$SHA8" | tee -a "$OUT/OUT_PATH.txt"

# 先清场（禁 kickstart -k）
bash "$ROOT/tools/zy_pretest_clean_4phone.sh" 2>&1 | tee "$OUT/pretest_clean.txt" | tail -20

run_remote() {
  local H="$1"
  local IP="192.168.31.$H"
  local SCHEME=rootful
  local SCRIPT=ios7.lua
  local LOCAL="$DESKTOP_IOS7"
  local SHA="$SHA7"
  [ "$H" = "53" ] && SCHEME=rootless && SCRIPT=ios8p.lua && LOCAL="$DESKTOP_IOS8P" && SHA="$SHA8"
  echo "==== start .$H script=$SCRIPT (${MIN}min) ===="
  scp_r "$LOCAL" "$IP" "/private/var/mobile/Media/ZiYan/$SCRIPT"
  ssh_r "$IP" "SCHEME=$SCHEME SEC=$SEC H=$H SCRIPT=$SCRIPT SHA=$SHA bash -s" <<'R' >"$OUT/gate_${H}.txt" 2>&1 &
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var; B=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var; B=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
mkdir -p "$MEDIA" "$V"
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
echo "META host=.$H VER=$VER SEC=$SEC SCRIPT=$SCRIPT SHA=$SHA start=$(date +%s)"
# 校验机上脚本 hash
REMOTE_SHA=""
if command -v sha256sum >/dev/null 2>&1; then
  REMOTE_SHA=$(sha256sum "$MEDIA/$SCRIPT" 2>/dev/null | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  REMOTE_SHA=$(shasum -a 256 "$MEDIA/$SCRIPT" 2>/dev/null | cut -d' ' -f1)
fi
echo "REMOTE_SHA=$REMOTE_SHA"
[ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" = "$SHA" ] && echo "SHA_OK=1" || echo "SHA_OK=0 WARN=script_hash_mismatch"
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
rm -f "$V/.ziyan_light" "$V/.ziyan_find_sb_banned" "$V/.ziyan_force_front_mismatch"
rm -f "$V/.ziyan_embed_off" "$V/.ziyan_active" "$V/.ziyan_keep_daemon" \
  "$V/.ziyan_session_keep" "$V/.ziyan_force_recap" "$V/.ziyan_toast_bump" \
  "$V/.ziyan_path_stats" "$V/.ziyan_embed_go" "$V/.ziyan_lua_embedded" \
  "$MEDIA/_e4_promo.lua"
# 仅 FC_N=0 时普通 kickstart（禁 -k）
FC0=$(ps -A -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
[ -n "$FC0" ] || FC0=0
if [ "$FC0" -eq 0 ]; then
  launchctl kickstart system/com.ziyan.framecap 2>/dev/null || \
    launchctl kickstart com.ziyan.framecap 2>/dev/null || true
  sleep 1.2
fi

sb_pid() {
  ps -axo pid,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1
}
fc_rss_line() {
  ps -axo rss,args 2>/dev/null | grep '[z]iyan_framecap serve' | head -1 | sed 's/^ *//' | tr -s ' '
}

SB0=$(sb_pid); SB0=${SB0:-0}
echo "SB0=$SB0"

# 启动 Desktop 业务脚本（自带 while true）
rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop"
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" >"$V/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
echo "nonce=e4_${H}_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_go" "$V/.ziyan_embed_on"

FORCE=0; TOAST=0; SB_CHG=0; KEEP_PEAK=0; FC_N_MAX=0; RELAY=0
: >"$V/.ziyan_e4_resource.tsv"
echo -e "t\tfc_n\tfc_rss\tsb_rss\tkeep\tlife" >>"$V/.ziyan_e4_resource.tsv"

# 暖机 60s：先让业务跑起来
sleep 60
# 203：基线前强制一次合帧，避免「暖机未灌工作集 → 随后 RSS+3MB 被当成泄漏」
echo 1 >"$V/.ziyan_force_recap" 2>/dev/null || true
sleep 3
rm -f "$V/.ziyan_force_recap" 2>/dev/null || true
sleep 2
# 采 5 点基线中位数（此时工作集应已常驻）
BASE_SAMPLES=""
for i in 1 2 3 4 5; do
  FR=$(fc_rss_line | cut -d' ' -f1); FR=${FR:-0}
  BASE_SAMPLES="$BASE_SAMPLES $FR"
  sleep 2
done
# 无 awk（部分越狱机无）：5 点取第 3 个为中位数
RSS_BASE=$(echo "$BASE_SAMPLES" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '3p')
RSS_BASE=${RSS_BASE:-0}
WS0=$(tr '\n' ' ' <"$V/.ziyan_workset_bytes" 2>/dev/null | sed 's/[^0-9].*//' | tr -dc '0-9')
[ -n "$WS0" ] || WS0=0
echo "WARM_BASE_RSS_KB=$RSS_BASE samples=$BASE_SAMPLES WORKSET0=$WS0"

end=$(( $(date +%s) + SEC ))
sample=0
FC_RSS_MAX=$RSS_BASE
FC_RSS_MIN=$RSS_BASE
TAIL_BUF=""
while [ "$(date +%s)" -lt "$end" ]; do
  sample=$((sample + 1))
  if [ -f "$V/.ziyan_force_recap" ]; then FORCE=$((FORCE+1)); rm -f "$V/.ziyan_force_recap"; fi
  if [ -f "$V/.ziyan_toast_bump" ]; then TOAST=$((TOAST+1)); rm -f "$V/.ziyan_toast_bump"; fi
  if [ -f "$V/.ziyan_relay_req" ]; then RELAY=$((RELAY+1)); rm -f "$V/.ziyan_relay_req"; fi
  if [ -f "$V/.ziyan_keep_daemon" ]; then KEEP_PEAK=1; fi
  SB=$(sb_pid); SB=${SB:-0}
  if [ "$SB0" != "0" ] && [ "$SB" != "0" ] && [ "$SB" != "$SB0" ]; then
    SB_CHG=$((SB_CHG + 1))
    echo "SB_RING sample=$sample from=$SB0 to=$SB"
    SB0=$SB
  fi
  # 只计真实 serve 进程行（禁空行/误计把 FC_N 抬到 2）
  FC_N=$(ps -axo pid=,args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
  [ -n "$FC_N" ] || FC_N=0
  FC_LINES=$(ps -axo pid,rss,args 2>/dev/null | grep '[z]iyan_framecap serve' || true)
  FC_R=$(echo "$FC_LINES" | head -1 | sed 's/^ *//' | tr -s ' ' | cut -d' ' -f2)
  FC_R=${FC_R:-0}
  [ "$FC_N" -gt "$FC_N_MAX" ] 2>/dev/null && FC_N_MAX=$FC_N
  [ "$FC_R" -gt "$FC_RSS_MAX" ] 2>/dev/null && FC_RSS_MAX=$FC_R
  if [ "$FC_RSS_MIN" = "0" ] || [ "$FC_R" -lt "$FC_RSS_MIN" ] 2>/dev/null; then FC_RSS_MIN=$FC_R; fi
  SB_RSS=$(ps -axo rss,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | tr -s ' ' | cut -d' ' -f1)
  SB_RSS=${SB_RSS:-0}
  KEEP_NOW=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
  LIFE=""; [ -f "$V/.ziyan_frame_lifecycle" ] && LIFE=$(tr -d '\r\n' <"$V/.ziyan_frame_lifecycle" | head -c 48)
  echo -e "$(date +%s)\t${FC_N:-0}\t${FC_R}\t${SB_RSS}\t${KEEP_NOW}\t${LIFE}" >>"$V/.ziyan_e4_resource.tsv"
  TAIL_BUF="$TAIL_BUF $FC_R"
  # 只保留末段约 5 点用于斜率
  TAIL_BUF=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | tail -5 | tr '\n' ' ')
  sleep 2
done

# 末段 5 点中位数（无 awk）
RSS_END=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '3p')
RSS_END=${RSS_END:-0}
FC_DELTA=$(( RSS_END - RSS_BASE ))
FC_PEAK_DELTA=$(( FC_RSS_MAX - RSS_BASE ))
[ "$FC_DELTA" -lt 0 ] 2>/dev/null && FC_SLOPE_ABS=$(( 0 - FC_DELTA )) || FC_SLOPE_ABS=$FC_DELTA

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 2
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon" "$V/.ziyan_session_keep" 2>/dev/null
sleep 1.2
KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0)
STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)
CR=$(echo "$STATS" | sed -n 's/.*via_color_req_find=\([0-9][0-9]*\).*/\1/p')
EM=$(echo "$STATS" | sed -n 's/.*via_embed_find=\([0-9][0-9]*\).*/\1/p')
[ -z "$CR" ] && CR=-1
[ -z "$EM" ] && EM=-1
OWNER=$(tr '\n' ' ' <"$V/.ziyan_framecap_owner" 2>/dev/null)
WS=$(tr '\n' ' ' <"$V/.ziyan_workset_bytes" 2>/dev/null)

echo "STATS=$STATS"
echo "SB_CHG=$SB_CHG FORCE_HITS=$FORCE TOAST_BUMP=$TOAST KEEP_PEAK=$KEEP_PEAK RELAY_HITS=$RELAY"
echo "FC_N_MAX=$FC_N_MAX RSS_BASE=$RSS_BASE RSS_END=$RSS_END FC_RSS_MAX=$FC_RSS_MAX"
echo "FC_SLOPE_KB=$FC_DELTA FC_PEAK_DELTA_KB=$FC_PEAK_DELTA"
echo "OWNER=$OWNER WORKSET=$WS"
echo "KEEP_AFTER_STOP=$KEEP_AFTER ACTIVE=$ACTIVE KEEP=$KEEP"
echo "via_embed_find=$EM via_color_req_find=$CR"

OK=1
echo "$VER" | grep -qE '20[0-9]' || { echo "FAIL ver_not_202plus"; OK=0; }
[ "$SB_CHG" = "0" ] || { echo "FAIL sb_ring=$SB_CHG"; OK=0; }
[ "$KEEP" = "0" ] || { echo "FAIL sticky_keep"; OK=0; }
[ "$KEEP_AFTER" = "0" ] || { echo "FAIL keep_after_stop"; OK=0; }
# 203：视觉工作集硬限 ≤6MB（.ziyan_workset_bytes 首字段）
WS_N=$(echo "$WS" | sed 's/[^0-9].*//' | tr -dc '0-9')
[ -n "$WS_N" ] || WS_N=0
if [ "$WS_N" -gt 6291456 ] 2>/dev/null; then
  echo "FAIL workset_over_6mb=$WS_N"
  OK=0
fi
[ "${FC_N_MAX:-0}" -le 1 ] 2>/dev/null || { echo "FAIL fc_n_max=$FC_N_MAX"; OK=0; }
[ "$ACTIVE" = "0" ] || { echo "FAIL sticky_active"; OK=0; }
[ "$CR" = "0" ] || [ "$CR" = "-1" ] || { echo "FAIL color_req=$CR"; OK=0; }
[ "$EM" -gt 10 ] 2>/dev/null || { echo "FAIL embed_find_low=$EM"; OK=0; }
[ "$FC_N_MAX" -le 1 ] 2>/dev/null || { echo "FAIL fc_n=$FC_N_MAX"; OK=0; }
# 斜率：rootful ≤512KB；.53 ≤1024KB（相对暖机基线）
RMAX=512
[ "$H" = "53" ] && RMAX=1024
[ "$FC_SLOPE_ABS" -le "$RMAX" ] 2>/dev/null || { echo "FAIL fc_rss_slope=$FC_DELTA max=$RMAX"; OK=0; }
FMAX=$(( MIN * 2 + 5 ))
[ "$FORCE" -le "$FMAX" ] 2>/dev/null || { echo "FAIL force_storm=$FORCE max=$FMAX"; OK=0; }
[ "$TOAST" = "0" ] || { echo "FAIL toast_bump=$TOAST"; OK=0; }

if [ "$OK" = 1 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
echo "META end=$(date +%s)"
echo "DIAG_LAST_FIND=$(tr '\n' ' ' <"$V/.ziyan_last_find" 2>/dev/null | tail -c 200)"
tail -5 "$V/.ziyan_e4_resource.tsv" 2>/dev/null | sed 's/^/DIAG_RES /'
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
  tail -30 "$OUT/gate_${H}.txt" || true
  if grep -q 'VERDICT=PASS' "$OUT/gate_${H}.txt" 2>/dev/null; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done

{
  echo "# E4 promo gate (Desktop ios7/ios8p only)"
  echo "stamp=$STAMP min=$MIN hosts=${HOSTS[*]}"
  echo "SHA256_ios7=$SHA7"
  echo "SHA256_ios8p=$SHA8"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  if [ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -eq "${#HOSTS[@]}" ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -eq "${#HOSTS[@]}" ]
