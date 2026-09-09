#!/usr/bin/env bash
# Z1-MEM 资源门禁：只用 Desktop ios7.lua / ios8p.lua 长跑旁路采样
# 禁生成 _e4_promo.lua；暖机 60s 后 5 点中位数作基线，末段中位数判定
# 用法: ZY_E4_MIN=30 bash tools/zy_e4_promo_gate.sh
# 可选: ZY_E4_MIN=5 短测；HOSTS 默认 101 112 166 53
#
# ── 斜率口径（Z0-METRIC 修正）────────────────────────────────────────
# 旧版把「整窗差值 END-BASE」直接与「Δ/100s 预算」比较，导致 ZY_E4_MIN=5
# 与 =30 套同一阈值时严格程度相差 6 倍。现统一归一化为 KB/100s：
#   PER100 = (END - BASE) * 100 / SEC
# 阈值必须有实测出处，不得发明；来源见 tmp_shots/TS_OBS/*/TS_RSS_SLOPE.md
# （触动 .171 TSDaemon 同协议同口径实测），预算 = 触动实测 × 容差。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
MIN="${ZY_E4_MIN:-30}"
SEC=$((MIN * 60))

# 斜率预算（KB/100s）。
# 出处：tmp_shots/TS_OBS/20260807_022020/TS_RSS_SLOPE.md
#   触动 .171（iPhone7 找色长跑参考机）5min 同口径实测 = 58 KB/100s
#   触动 .149 同期 = 122 KB/100s（非找色脚本，仅作旁证）
# 结论：触动自身斜率并非 0，「趋近于零」是伪目标，按「不劣于触动」定预算。
#   rootful = 58 × 2 ≈ 120（容差覆盖测量噪声与机型差异）
#   rootless .53 = @3x 像素量更大，再放宽一倍 = 240
# 旧的 512/1024「整窗差值」预算无实测出处，已作废。
RMAX100_RF="${ZY_E4_RMAX100_RF:-120}"
RMAX100_R53="${ZY_E4_RMAX100_R53:-240}"

# 帧龄预算（ms）。判据：找色读到的帧有多旧（.ziyan_find_shm_log 的 age_ms）。
# 出处：实测 .101 9000~14000、.112 2000~7000、.166 391000 —— 供帧塌到冻帧，
# 而 RSS/CPU/keep 全部合规，旧门禁桌面场景下照过。中位数管日常节奏，
# 硬上限管「塌成冻帧」。业务圈速 ~300ms，一圈内换帧则中位数应在千毫秒内。
AGEMED_MAX="${ZY_E4_AGE_MED_MAX:-1200}"
AGEHARD_MAX="${ZY_E4_AGE_HARD_MAX:-5000}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166 53); else HOSTS=("$@"); fi
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/E4_PROMO_${STAMP}"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
SSH_KEY_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes
              -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
              -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
ssh_r() {
  if ssh "${SSH_KEY_OPTS[@]}" "root@$1" "${@:2}"; then
    return 0
  fi
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"
}
# 越狱机 sshd 在短时间大量连接后会偶发 "Permission denied"（认证限流）。
# 单次传输失败不得中断整场多机长跑，退避重试后仍失败才跳过该机。
scp_r() {
  local i
  local -a SCP_KEY_OPTS=(
    -o BatchMode=yes
    -o PasswordAuthentication=no
    -o PubkeyAuthentication=yes
    -o PreferredAuthentications=publickey
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=12
    -o ServerAliveInterval=20
    -o ServerAliveCountMax=6
  )
  for i in 1 2 3 4 5; do
    if scp "${SCP_KEY_OPTS[@]}" "$1" "root@$2:$3"; then
      echo "SCP_AUTH=public_key host=$2"
      return 0
    fi
    echo "WARN scp public-key failed retry $i/5 → $2:$3"
    if sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@$2:$3"; then
      echo "SCP_AUTH=password host=$2"
      return 0
    fi
    echo "WARN scp password retry $i/5 → $2:$3"
    sleep $((i * 4))
  done
  return 1
}

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
echo "POST_CLEAN_WAIT_SEC=60" | tee -a "$OUT/pretest_clean.txt"
sleep 60

run_remote() {
  local H="$1"
  local IP="192.168.31.$H"
  local SCHEME=rootful
  local SCRIPT=ios7.lua
  local LOCAL="$DESKTOP_IOS7"
  local SHA="$SHA7"
  local RMAX100="$RMAX100_RF"
  [ "$H" = "53" ] && SCHEME=rootless && SCRIPT=ios8p.lua && LOCAL="$DESKTOP_IOS8P" && SHA="$SHA8" && RMAX100="$RMAX100_R53"
  echo "==== start .$H script=$SCRIPT (${MIN}min) ===="
  if ! scp_r "$LOCAL" "$IP" "/private/var/mobile/Media/ZiYan/$SCRIPT"; then
    echo "SKIP .$H scp_failed_after_retry" | tee "$OUT/gate_${H}.txt"
    return 0
  fi
  # MIN 必须显式传进远端：漏传时远端 FMAX=$((MIN*2+5)) 里 MIN 为空，
  # 恒等于 5，30min 长跑也只允许 5 次催帧，正常节奏就被判 force_storm。
  ssh_r "$IP" "SCHEME=$SCHEME SEC=$SEC MIN=$MIN H=$H SCRIPT=$SCRIPT SHA=$SHA RMAX100=$RMAX100 AGEMED_MAX=$AGEMED_MAX AGEHARD_MAX=$AGEHARD_MAX bash -s" <<'R' >"$OUT/gate_${H}.txt" 2>&1 &
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
# 守护会 fork 出短命子进程（同 argv、RSS 仅几百 KB~5MB），按名字 grep + head -1
# 会随机抓到它们。实测 .101 基线 15 点里混进 5104 / 1344 / 720，尾窗中位数
# 被带偏后算出 -831 KB/100s 的假斜率。锁定常驻 PID 采样，与 TS 采样器同法。
fc_pid() {
  ps -axo pid,args 2>/dev/null | grep '[z]iyan_framecap serve' | head -1 | sed 's/^ *//' | cut -d' ' -f1
}
FC_PID=$(fc_pid)
fc_rss_kb() {
  local r=""
  if [ -n "$FC_PID" ]; then
    r=$(ps -p "$FC_PID" -o rss= 2>/dev/null | tr -d ' ')
  fi
  if [ -z "$r" ]; then
    FC_PID=$(fc_pid)
    [ -n "$FC_PID" ] && r=$(ps -p "$FC_PID" -o rss= 2>/dev/null | tr -d ' ')
  fi
  echo "${r:-0}"
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
# 基线取 15 点（约 30s）中位数。
# 不能只取 5 点/10s：framecap RSS 在合帧期是周期约 60s、振幅约 3MB 的锯齿
# （触动 .171 同期摆幅 3168KB，同量级），10s 窗口测 60s 周期信号属于混叠，
# 测到的是采样相位而不是趋势。
BASE_SAMPLES=""
for i in $(seq 1 15); do
  FR=$(fc_rss_kb); FR=${FR:-0}
  BASE_SAMPLES="$BASE_SAMPLES $FR"
  sleep 2
done
# 无 awk（部分越狱机无）：15 点取第 8 个为中位数
RSS_BASE=$(echo "$BASE_SAMPLES" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '8p')
RSS_BASE=${RSS_BASE:-0}
WS0=$(tr '\n' ' ' <"$V/.ziyan_workset_bytes" 2>/dev/null | sed 's/[^0-9].*//' | tr -dc '0-9')
[ -n "$WS0" ] || WS0=0
echo "WARM_BASE_RSS_KB=$RSS_BASE samples=$BASE_SAMPLES WORKSET0=$WS0"

end=$(( $(date +%s) + SEC ))
sample=0
FC_RSS_MAX=$RSS_BASE
FC_RSS_MIN=$RSS_BASE
TAIL_BUF=""
# 帧龄采样：age_ms 是 embed 每次 find 时记的「这张帧有多旧」。
# 本轮回归（.166 帧龄 391s、.101 9~14s，找色读冻结旧帧）本该被这条一眼拦下，
# 而旧门禁只看 RSS/CPU/keep，桌面场景下全绿照过。
: >"$V/.ziyan_e4_age.txt"
while [ "$(date +%s)" -lt "$end" ]; do
  sample=$((sample + 1))
  AGE_S=$(sed -n 's/.*age_ms=\(-*[0-9][0-9]*\).*/\1/p' "$V/.ziyan_find_shm_log" 2>/dev/null | tail -1)
  case "$AGE_S" in
    ''|*[!0-9-]*) ;;
    *) echo "$AGE_S" >>"$V/.ziyan_e4_age.txt" ;;
  esac
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
  FC_R=$(fc_rss_kb); FC_R=${FC_R:-0}
  [ "$FC_N" -gt "$FC_N_MAX" ] 2>/dev/null && FC_N_MAX=$FC_N
  [ "$FC_R" -gt "$FC_RSS_MAX" ] 2>/dev/null && FC_RSS_MAX=$FC_R
  if [ "$FC_RSS_MIN" = "0" ] || [ "$FC_R" -lt "$FC_RSS_MIN" ] 2>/dev/null; then FC_RSS_MIN=$FC_R; fi
  SB_RSS=$(ps -axo rss,args 2>/dev/null | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | tr -s ' ' | cut -d' ' -f1)
  SB_RSS=${SB_RSS:-0}
  KEEP_NOW=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
  LIFE=""; [ -f "$V/.ziyan_frame_lifecycle" ] && LIFE=$(tr -d '\r\n' <"$V/.ziyan_frame_lifecycle" | head -c 48)
  echo -e "$(date +%s)\t${FC_N:-0}\t${FC_R}\t${SB_RSS}\t${KEEP_NOW}\t${LIFE}" >>"$V/.ziyan_e4_resource.tsv"
  TAIL_BUF="$TAIL_BUF $FC_R"
  # 末段保留 15 点（约 30s），与基线同宽，抗锯齿混叠
  TAIL_BUF=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | tail -15 | tr '\n' ' ')
  sleep 2
done

# 末段 15 点中位数（无 awk）
RSS_END=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '8p')
RSS_END=${RSS_END:-0}
FC_DELTA=$(( RSS_END - RSS_BASE ))
FC_PEAK_DELTA=$(( FC_RSS_MAX - RSS_BASE ))
[ "$FC_DELTA" -lt 0 ] 2>/dev/null && FC_SLOPE_ABS=$(( 0 - FC_DELTA )) || FC_SLOPE_ABS=$FC_DELTA
# 归一化到 KB/100s，使 5min 与 30min 窗口可直接对照，也可与触动实测同轴比较
FC_PER100=$(( FC_DELTA * 100 / SEC ))
[ "$FC_PER100" -lt 0 ] 2>/dev/null && FC_PER100_ABS=$(( 0 - FC_PER100 )) || FC_PER100_ABS=$FC_PER100

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
echo "FC_SLOPE_PER100_KB=$FC_PER100 window_sec=$SEC budget_per100=$RMAX100"

# 帧龄统计：中位数判「日常读到的帧有多旧」，最大值判「有没有塌到冻帧」
AGE_N=$(grep -cE '^-*[0-9]+$' "$V/.ziyan_e4_age.txt" 2>/dev/null | tr -dc '0-9')
[ -n "$AGE_N" ] || AGE_N=0
AGE_MED=-1; AGE_MAX=-1
if [ "$AGE_N" -gt 0 ] 2>/dev/null; then
  AGE_MED=$(grep -E '^-*[0-9]+$' "$V/.ziyan_e4_age.txt" | sort -n | sed -n "$(( AGE_N / 2 + 1 ))p")
  AGE_MAX=$(grep -E '^-*[0-9]+$' "$V/.ziyan_e4_age.txt" | sort -n | tail -1)
  AGE_MED=${AGE_MED:--1}; AGE_MAX=${AGE_MAX:--1}
fi
echo "FRAME_AGE_MED_MS=$AGE_MED FRAME_AGE_MAX_MS=$AGE_MAX samples=$AGE_N budget_med=$AGEMED_MAX budget_max=$AGEHARD_MAX"
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
# 斜率：按 KB/100s 判定，预算由 Z0-TS 触动实测派生（见脚本顶部）。
# 只判「涨」：本门禁要挡的是泄漏，RSS 下降说明回收在工作，取绝对值会把
# -831 / -321 这类回落也判成 FAIL（.101/.112 30min 实测即此）。
if [ "$FC_PER100" -gt "$RMAX100" ] 2>/dev/null; then
  echo "FAIL fc_rss_slope_per100=$FC_PER100 max=$RMAX100 (raw_delta=$FC_DELTA over ${SEC}s)"
  OK=0
elif [ "$FC_PER100" -lt 0 ] 2>/dev/null; then
  echo "NOTE fc_rss_slope_per100=$FC_PER100（下降，视为通过）"
fi
# 帧龄：找色必须跑在新鲜帧上。中位数管日常，硬上限管「塌到冻帧」。
if [ "$AGE_N" -lt 10 ] 2>/dev/null; then
  echo "WARN frame_age_samples=$AGE_N（样本过少，帧龄未判）"
elif [ "$AGE_MED" -gt "$AGEMED_MAX" ] 2>/dev/null; then
  echo "FAIL frame_age_median=$AGE_MED max=$AGEMED_MAX（找色读的是旧帧）"
  OK=0
elif [ "$AGE_MAX" -gt "$AGEHARD_MAX" ] 2>/dev/null; then
  echo "FAIL frame_age_peak=$AGE_MAX max=$AGEHARD_MAX（供帧塌到冻帧）"
  OK=0
fi
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
  # 单机启动失败不得让整场多机长跑退出（set -e）；该机记 SKIP 后继续
  run_remote "$H" || echo "WARN launch_failed .$H"
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
  echo "# Z1-MEM resource gate (Desktop ios7/ios8p only)"
  echo "stamp=$STAMP min=$MIN hosts=${HOSTS[*]}"
  echo "slope_budget_per100_kb: rootful=$RMAX100_RF rootless53=$RMAX100_R53"
  echo "budget_source: tmp_shots/TS_OBS/*/TS_RSS_SLOPE.md (触动 .171 同口径实测 × 容差)"
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
