#!/usr/bin/env bash
# E48 非 Agent 迁移样本矩阵；默认保持 .112，其他设备通过显式环境变量选择。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_TAG="${E48_DEVICE_TAG:-112}"
IP="${E48_DEVICE_IP:-192.168.31.112}"
PASS="${ZY_SSH_PASS:-alpine}"
REMOTE_USER="${E48_REMOTE_USER:-root}"
# 传输默认走已部署的授权公钥（BatchMode 不触发密码尝试，也不会撞 MaxAuthTries）。
# 2026-09-11 实测：五机各 20+ 次密码认证后 sshd 开始限流，表现为矩阵跑到一半
# rc=255 且 stderr 只有 known_hosts 警告（.101 8/9、.112 0/9、.166 4/9、.53 0/9）；
# 同一时段密钥通道全程稳定，.61 用密钥跑完 9/9。只有显式
# E48_TRANSPORT=password 才回退旧密码路径（供未部署密钥的机器使用）。
if [ "${E48_TRANSPORT:-key}" = password ]; then
  # 密码模式禁止先枚举本地密钥：部分机器的 MaxAuthTries 会在密码尝试前断开。
  SSH_OPTS=(-o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12)
  SSH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$IP")
  SCP=(sshpass -p "$PASS" scp "${SSH_OPTS[@]}")
else
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12)
  SSH=(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$IP")
  SCP=(scp "${SSH_OPTS[@]}")
fi
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${E48_OUT:-$ROOT/tmp_shots/E48_DEVICE${DEVICE_TAG}_${STAMP}}"
MEDIA=/var/mobile/Media/ZiYan
# .112/.101/.166 use the rootful path; .53/.61 override both values for rootless.
BID="${E48_BID:-com.xztl.ios}"
VAR="${E48_VAR:-/usr/lib/ziyan/var}"
DEVICE_LABEL=".${DEVICE_TAG}"
CASE_FILTER="${E48_CASES:-}"
mkdir -p "$OUT/cases" "$OUT/device_verdicts" "$OUT/screenshots"
SAMPLE="$OUT/e48_non_agent_business.lua"
sed "s/local BID = os.getenv(\"ZIYAN_SAMPLE_BID\") or \"com.xztl.ios\"/local BID = \"$BID\"/" "$ROOT/tests/touchsprite_migration/ziyan_business_sample.lua" > "$SAMPLE"
ASSET="$ROOT/tests/touchsprite_migration/source/2015528121953696.jpg"
cp "$ASSET" "$OUT/approved_asset.jpg"
SAMPLE_SHA="$(shasum -a 256 "$SAMPLE" | awk '{print $1}')"
ASSET_SHA="$(shasum -a 256 "$OUT/approved_asset.jpg" | awk '{print $1}')"
PKG="${E48_PKG:-$ROOT/packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-98+debug-10-38-17-147+debug_iphoneos-arm.deb}"
PKG_SHA="$(shasum -a 256 "$PKG" | awk '{print $1}')"
PKG_VER="${E48_PKG_VER:-0.0.92-8-161-205-C-65.11-98+debug-10-38-17-147+debug}"
printf 'out=%s\ndevice=.112\npackage=%s\npackage_sha256=%s\npackage_version=%s\nbase_sample_sha256=%s\napproved_asset_sha256=%s\nstarted=%s\n' \
  "$OUT" "$PKG" "$PKG_SHA" "$PKG_VER" "$SAMPLE_SHA" "$ASSET_SHA" "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  | sed "s/device=.112/device=$DEVICE_LABEL/" > "$OUT/matrix_metadata.txt"
printf '%s  %s\n' "$PKG_SHA" "$PKG" > "$OUT/package_sha256.txt"
printf '%s  %s\n' "$SAMPLE_SHA" "$ROOT/tests/touchsprite_migration/ziyan_business_sample.lua" > "$OUT/sample_sha256.txt"
printf '%s  %s\n' "$ASSET_SHA" "$OUT/approved_asset.jpg" > "$OUT/resource_sha256.txt"

# 只读取得设备端前置状态，之后由每个 case 自己形成 device-side final。
"${SSH[@]}" "VAR='$VAR' bash -s" > "$OUT/pre_state.txt" 2>"$OUT/pre_state.stderr" <<'PRE'
V="$VAR"
printf 'PKG='
dpkg-query -W -f='${Version} ${Architecture}' com.ziyan.ziyan 2>/dev/null || true
printf '\nFRONT='
tr -d '\r\n' < "$V/.ziyan_front_bid" 2>/dev/null || true
printf '\nSESSION='
tr '\n' ' ' < "$V/.ziyan_session" 2>/dev/null || true
printf '\nFC_N='
ps -A -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep
printf 'SCRIPT_N='
ps -A -o command= | grep -E 'ziyan_run.lua|e48_non_agent_business.lua|ios7.lua|ios8p.lua' | grep -v grep | wc -l | tr -d ' '
printf '\n'
PRE

push_case() {
  local local_script="$1" remote_name="$2"
  "${SCP[@]}" "$local_script" "$REMOTE_USER@$IP:$MEDIA/$remote_name"
  "${SSH[@]}" "chmod 666 '$MEDIA/$remote_name'; sha256sum '$MEDIA/$remote_name' 2>/dev/null || shasum -a 256 '$MEDIA/$remote_name'"
}

run_case() {
  local case_id="$1" action="$2" local_script="$3" width="$4" height="$5" mode="$6"
  local rid="e48_${case_id}_${DEVICE_TAG}_${RANDOM}_$(date +%s)"
  local remote_name="e48_${case_id}.lua"
  local result_path="/tmp/ziyan_e48_sample_result.txt"
  local snapshot_path="$MEDIA/_zy_e48_non_agent_business.png"
  local started ended
  started="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  push_case "$local_script" "$remote_name" > "$OUT/cases/${case_id}_push.txt" 2>&1
  local remote_sha
  remote_sha="$(${SSH[@]} "sha256sum '$MEDIA/$remote_name' 2>/dev/null || shasum -a 256 '$MEDIA/$remote_name'" | sed -n 's/^[[:space:]]*\([0-9A-Fa-f]\{64\}\).*/\1/p' | head -1 | tr -d '\r')"
  : > "$OUT/cases/${case_id}_remote.txt"
  "${SSH[@]}" "PKG_SHA='$PKG_SHA' REMOTE_SHA='$remote_sha' RESOURCE_SHA='$ASSET_SHA' VAR='$VAR' MEDIA='$MEDIA' SCRIPT='$remote_name' RID='$rid' RESULT='$result_path' SNAP='$snapshot_path' ACTION='$action' W='$width' H='$height' MODE='$mode' BID='$BID' DEVICE='$DEVICE_LABEL' bash -s" > "$OUT/cases/${case_id}_remote.txt" 2>&1 <<'EOS'
set +e
mkdir -p "$MEDIA/verdicts"
rm -f "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_go" "$VAR/.ziyan_embed_script" \
      "$VAR/.ziyan_active" "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_stop" \
      "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_session_keep" "$VAR/.ziyan_keep_daemon" \
      "$VAR/.ziyan_open_app" "$VAR/.ziyan_app_user_closed" "$VAR/.ziyan_target_bid" \
      "$MEDIA/.ziyan_open_app" "$RESULT" "$SNAP" "$MEDIA/_zy_e48_non_agent_business.png"
printf '%s\n' "$BID" > "$VAR/.ziyan_open_app"
printf '%s\n' "$BID" > "$MEDIA/.ziyan_open_app"
chmod 666 "$VAR/.ziyan_open_app" "$MEDIA/.ziyan_open_app"
open_app_ready=0
for i in $(seq 1 15); do
  front_now=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
  if [ "$front_now" = "$BID" ]; then
    open_app_ready=1
    break
  fi
  sleep 1
done
printf 'path=%s/%s\nstop=0\n' "$MEDIA" "$SCRIPT" > "$VAR/.ziyan_run_intent"
printf '%s/%s\n' "$MEDIA" "$SCRIPT" > "$VAR/.ziyan_embed_script"
printf 'nonce=%s\nrequest_id=%s\nsession_id=%s\n' "$RID" "$RID" "$RID" > "$VAR/.ziyan_embed_go"
echo 1 > "$VAR/.ziyan_embed_on"
date +%s > "$VAR/.ziyan_project_active"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" "$VAR/.ziyan_embed_on" "$VAR/.ziyan_project_active"
echo "RUN_ID=$RID ACTION=$ACTION MODE=$MODE WIDTH=$W HEIGHT=$H"
start_epoch=$(date +%s)
# abnormal/background cases inject one controlled lifecycle event during the active wait.
if [ "$MODE" = stop_early ]; then
  ( sleep 1; echo 1 > "$VAR/.ziyan_stop"; echo "INJECT_STOP=1" ) &
elif [ "$MODE" = background ]; then
  ( sleep 2; echo 1 > "$VAR/.ziyan_go_home"; sleep 3; rm -f "$VAR/.ziyan_go_home"; echo "INJECT_HOME=1" ) &
fi
seen=0
for i in $(seq 1 35); do
  if [ -f "$RESULT" ]; then seen=1; break; fi
  if [ ! -f "$VAR/.ziyan_embed_go" ] && [ -f "$VAR/.ziyan_embed_ack" ]; then :; fi
  sleep 1
done
# Device-side evidence is written only after the run has stopped or timed out.
printf 'stop=1\n' > "$VAR/.ziyan_run_intent"
echo 1 > "$VAR/.ziyan_user_stopped"
echo 1 > "$VAR/.ziyan_stop"
sleep 2
rm -f "$VAR/.ziyan_active" "$VAR/.ziyan_keep_daemon" "$VAR/.ziyan_session_keep" "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_stop" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_go" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_project_active" "$VAR/.ziyan_open_app" "$MEDIA/.ziyan_open_app"
end_epoch=$(date +%s)
sample=$(tr '\n' '|' < "$RESULT" 2>/dev/null)
front=$(tr -d '\r\n' < "$VAR/.ziyan_front_bid" 2>/dev/null)
run_pid=$(sed -n 's/^pid=//p' "$VAR/.ziyan_embed_ack" 2>/dev/null | head -1 | tr -d '\r')
sb=$(ps -A -o pid=,args= | grep '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | grep -v grep | sed -n 's/^ *\([0-9][0-9]*\).*/\1/p' | head -1)
bb=$(ps -A -o pid=,args= | grep '/usr/libexec/backboardd' | grep -v grep | sed -n 's/^ *\([0-9][0-9]*\).*/\1/p' | head -1)
sleep 2
sb1=$(ps -A -o pid=,args= | grep '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | grep -v grep | sed -n 's/^ *\([0-9][0-9]*\).*/\1/p' | head -1)
bb1=$(ps -A -o pid=,args= | grep '/usr/libexec/backboardd' | grep -v grep | sed -n 's/^ *\([0-9][0-9]*\).*/\1/p' | head -1)
sb_stable=0; bb_stable=0
[ -n "$sb" ] && [ "$sb" = "$sb1" ] && sb_stable=1
[ -n "$bb" ] && [ "$bb" = "$bb1" ] && bb_stable=1
active_seen=$(grep -q "foreground active=$BID" "$VAR/.ziyan_toast_hist" 2>/dev/null && echo 1 || echo 0)
fc_n=$(ps -A -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep)
script_n=$(ps -A -o command= | grep -E 'ziyan_run.lua|e48_.*\.lua|ios7\.lua|ios8p\.lua' | grep -v grep | wc -l | tr -d ' ')
active=$(test -f "$VAR/.ziyan_active" && echo 1 || echo 0)
keep=$(test -f "$VAR/.ziyan_keep_daemon" && echo 1 || echo 0)
cleanup=0
[ "$active" = 0 ] && [ "$keep" = 0 ] && [ "$script_n" = 0 ] && cleanup=1
identity_ok=0
case "$PKG_SHA:$REMOTE_SHA:$RESOURCE_SHA" in
  *[!0-9a-fA-F:]*|*:*:*:*|'') ;;
  *) [ "${#PKG_SHA}" = 64 ] && [ "${#REMOTE_SHA}" = 64 ] && [ "${#RESOURCE_SHA}" = 64 ] && identity_ok=1 ;;
esac
pid_ok=0
case "$run_pid:$sb:$bb" in
  *[!0-9:]*|'') ;;
  *) pid_ok=1 ;;
esac
status=NOT_RUN
if [ "$seen" = 1 ]; then status=$(sed -n 's/^status=//p' "$RESULT" | head -1); fi
verdict=INVALID_RUN
if [ "$seen" = 1 ] && [ "$cleanup" = 1 ] && [ "$active_seen" = 1 ] && [ "$sb_stable" = 1 ] && [ "$bb_stable" = 1 ] && [ "$identity_ok" = 1 ] && [ "$pid_ok" = 1 ]; then
  case "$ACTION" in
    stop_early) verdict=PASS ;; 
    *) [ "$status" = completed ] || [ "$status" = error_cleaned ] && verdict=PASS ;;
  esac
fi
FINAL="$MEDIA/verdicts/${RID}.txt"
{
  echo "run_id=$RID"
  echo "device=$DEVICE"
  echo "sample=$SCRIPT"
  echo "action=$ACTION"
  echo "started_epoch=$start_epoch"
  echo "ended_epoch=$end_epoch"
  echo "sample_result=$sample"
  echo "sample_status=$status"
  echo "result_seen=$seen"
  echo "timeout=$([ "$seen" = 1 ] && echo 0 || echo 1)"
  echo "run_pid=$run_pid"
  echo "cleanup=$cleanup"
  echo "active=$active"
  echo "keep_after_stop=$keep"
  echo "script_processes=$script_n"
  echo "framecap_processes=$fc_n"
  echo "front=$front"
  echo "springboard_pid=$sb"
  echo "backboardd_pid=$bb"
  echo "springboard_stable=$sb_stable"
  echo "backboardd_stable=$bb_stable"
  echo "foreground_active_seen=$active_seen"
  echo "open_app_requested=$BID"
  echo "open_app_ready=$open_app_ready"
  echo "identity_fields_valid=$identity_ok"
  echo "pid_fields_valid=$pid_ok"
  echo "width=$W"
  echo "height=$H"
  echo "package_sha256=$PKG_SHA"
  echo "script_sha256=$REMOTE_SHA"
  echo "resource_sha256=$RESOURCE_SHA"
  echo "final_cleanup=$cleanup"
  echo "final_verdict=$verdict"
  echo "log=$VAR/.ziyan_framecap_log"
  echo "snapshot=$SNAP"
} > "$FINAL"
cat "$FINAL"
EOS
  # Pull current device logs and structured outputs.
  "${SCP[@]}" "$REMOTE_USER@$IP:$MEDIA/verdicts/$rid.txt" "$OUT/device_verdicts/${case_id}_device.txt" 2>>"$OUT/cases/${case_id}_scp.stderr" || true
  "${SCP[@]}" "$REMOTE_USER@$IP:$MEDIA/_zy_e48_non_agent_business.png" "$OUT/screenshots/${case_id}.png" 2>>"$OUT/cases/${case_id}_shot.stderr" || true
  "${SSH[@]}" "tail -80 '$VAR/.ziyan_framecap_log' 2>/dev/null; echo ---TOAST---; tail -40 '$VAR/.ziyan_toast_hist' 2>/dev/null; echo ---RESULT---; cat '$result_path' 2>/dev/null; echo ---RES---; ls -l '$MEDIA/_zy_e48_non_agent_business.png' '$MEDIA/$remote_name' 2>/dev/null" > "$OUT/cases/${case_id}_logs.txt" 2>"$OUT/cases/${case_id}_logs.stderr" || true
  ended="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'case=%s\naction=%s\nrun_id=%s\ndevice=%s\nlocal_script=%s\nremote_script=%s\nlocal_script_sha256=%s\nremote_script_sha256=%s\nwidth=%s\nheight=%s\nstarted=%s\nended=%s\n' \
    "$case_id" "$action" "$rid" "$DEVICE_LABEL" "$local_script" "$MEDIA/$remote_name" "$(shasum -a 256 "$local_script" | awk '{print $1}')" "$remote_sha" "$width" "$height" "$started" "$ended" > "$OUT/cases/${case_id}_metadata.txt"
}

case_enabled() {
  [ -z "$CASE_FILTER" ] || [ "$CASE_FILTER" = "$1" ]
}

# Normal and lifecycle coverage. Base sample timeout branches are exercised by findUntil(360ms) misses.
case_enabled cold_start && run_case cold_start cold_start "$SAMPLE" 1136 640 normal
case_enabled repeated_run_1 && run_case repeated_run_1 repeated_run "$SAMPLE" 1136 640 normal
case_enabled repeated_run_2 && run_case repeated_run_2 repeated_run "$SAMPLE" 1136 640 normal
case_enabled stop_rerun && run_case stop_rerun stop_after_stop "$SAMPLE" 1136 640 stop_early
case_enabled rerun_after_stop && run_case rerun_after_stop rerun_after_stop "$SAMPLE" 1136 640 normal
case_enabled foreground_background && run_case foreground_background foreground_background "$SAMPLE" 1136 640 background

# Resolution and approved image capability variants are generated from the migration sample only.
for spec in 'multi_resolution_568x320 568 320' 'multi_resolution_2208x1242 2208 1242'; do
  set -- $spec; id="$1"; w="$2"; h="$3"
  v="$OUT/${id}.lua"
  sed -e "s/local DESIGN_W = tonumber(os.getenv(\"ZIYAN_SAMPLE_W\")) or 1136/local DESIGN_W = $w/" \
      -e "s/local DESIGN_H = tonumber(os.getenv(\"ZIYAN_SAMPLE_H\")) or 640/local DESIGN_H = $h/" \
      "$SAMPLE" > "$v"
  case_enabled "$id" && run_case "$id" multi_resolution "$v" "$w" "$h" normal
done
IMG="$OUT/with_approved_image.lua"
sed -e 's/local image_path = os.getenv("ZIYAN_SAMPLE_IMAGE") or ""/local image_path = "\/var\/mobile\/Media\/ZiYan\/e48_approved_asset.jpg"/' "$SAMPLE" > "$IMG"
if case_enabled screenshot_find_image; then
  "${SCP[@]}" "$OUT/approved_asset.jpg" "$REMOTE_USER@$IP:$MEDIA/e48_approved_asset.jpg"
  run_case screenshot_find_image screenshot_find_image "$IMG" 1136 640 normal
fi

# Final host summary is derived from device-side final files; no empty/transport result becomes PASS.
pass=0; total=0
for f in "$OUT"/device_verdicts/*_device.txt; do
  [ -f "$f" ] || continue
  total=$((total+1))
  grep -q '^final_verdict=PASS$' "$f" && pass=$((pass+1)) || true
done
printf 'matrix_finished=%s\ndevice=%s\ntotal_cases=%s\npass_cases=%s\nall_cases_pass=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$DEVICE_LABEL" "$total" "$pass" "$([ "$total" -eq 9 ] && [ "$pass" -eq 9 ] && echo 1 || echo 0)" > "$OUT/SUMMARY.txt"
cat "$OUT/SUMMARY.txt"
printf 'OUT=%s\n' "$OUT"
