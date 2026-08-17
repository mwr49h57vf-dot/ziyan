#!/usr/bin/env bash
# P6：UICreate 子进程受控诊断门禁（只读设备版本；默认 .166）。
# 该门禁不安装包、不重启 SpringBoard，只做有限次 uicreate-dump 和
# framecap snapshot 采样，并把退出码、信号、stderr、dump 大小及 serve 日志
# 汇总到本地证据目录。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
HOST="${1:-166}"
ATTEMPTS="${ZY_P6_ATTEMPTS:-5}"
SNAPS="${ZY_P6_SNAPS:-8}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P6_UICREATE_GATE_${STAMP}_${HOST}"
mkdir -p "$OUT"

case "$HOST" in
  101|112|166) IP="192.168.31.$HOST" ;;
  *) echo "usage: $0 <101|112|166>" >&2; exit 2 ;;
esac

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)
AUTH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}")
if ! "${AUTH[@]}" "root@$IP" true >/dev/null 2>&1; then
  AUTH=(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=12 -o BatchMode=yes)
  "${AUTH[@]}" "root@$IP" true >/dev/null 2>&1 || {
    echo "VERDICT=FAIL reason=ssh_auth_failed" | tee "$OUT/VERDICT.md"
    exit 1
  }
fi

# iOS 测试机 sshd 在连续 P6 读取时会短暂触发认证限流。只给无 stdin 的
# 只读命令有限重试；直接 uicreate-dump 的 heredoc 不能重试，否则第二次会读到
# 空输入并把诊断误做成成功。
remote() {
  local n
  for n in 1 2 3 4; do
    "${AUTH[@]}" "root@$IP" "$@" && return 0
    sleep "$n"
  done
  return 1
}

VAR=/usr/lib/ziyan/var
BIN=/usr/lib/ziyan/bin/ziyan_framecap
PORT_FILE="$(${AUTH[@]} "root@$IP" "tr -dc '0-9' < '$VAR/.ziyan_snap_http_port' 2>/dev/null | head -c 5" 2>/dev/null || true)"
PORT=""
for candidate in "$PORT_FILE" 50005 50015; do
  [ -n "$candidate" ] || continue
  [ "$candidate" = "$PORT" ] && continue
  probe=$(remote "wget -qO- http://127.0.0.1:$candidate/status 2>/dev/null | sed -n '1,2p'" 2>/dev/null || true)
  if printf '%s\n' "$probe" | grep -q '^zy1\|^engine=ZiYan'; then
    PORT="$candidate"
    break
  fi
done
PORT="${PORT:-50005}"

{
  echo "host=$HOST ip=$IP attempts=$ATTEMPTS snapshots=$SNAPS port=$PORT"
  echo "started=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "binary=$BIN"
} | tee "$OUT/meta.txt"

# 读取基线；不清理、不覆盖设备上的历史日志。
remote "tail -n 80 '$VAR/.ziyan_framecap_log' 2>/dev/null" \
  >"$OUT/framecap_before.log" 2>&1 || true
remote "cat '$VAR/.ziyan_cap_diag' 2>/dev/null" \
  >"$OUT/cap_diag_before.txt" 2>&1 || true

# framecap 日志会跨服务重启保留。若直接统计 after 的 tail，上一轮的
# uicreate_child_timeout 会被误判为本轮失败，P6 就无法验证修复是否真正消除了
# 新错误。设备日志前缀固定为 YYYY-MM-DD HH:MM:SS，本轮动作前记录边界，后续只
# 对边界之后的行做门禁；同一秒的极少量边界行宁可保守计入本轮。
RUN_MARKER="$(date '+%Y-%m-%d %H:%M:%S')"
echo "run_marker=$RUN_MARKER" >>"$OUT/meta.txt"

# 直接子进程探针：每次使用独立 dump/stderr 文件，退出后保留本地摘要。
# 越狱机 sshd 在连续读取时可能暂时触发认证限流；heredoc 放在循环体内，
# 每次重试都会重新提供完整 stdin，不能复用一个已被消费的管道。
DIRECT_RC=1
for direct_try in 1 2 3 4; do
  if "${AUTH[@]}" "root@$IP" "BIN='$BIN' ATTEMPTS='$ATTEMPTS' STAMP='$STAMP' bash -s" \
      >"$OUT/direct.tsv" 2>"$OUT/direct.stderr" <<'REMOTE'
set +e
  printf 'attempt\trc\tsize\tstderr_bytes\tdump\tstderr\tstderr_head\n'
for i in $(seq 1 "$ATTEMPTS"); do
  D="/tmp/zy_p6_uicreate_${STAMP}_${i}.bin"
  E="$D.err"
  rm -f "$D" "$E"
  "$BIN" uicreate-dump "$D" 2>"$E"
  RC=$?
  SZ=$(wc -c <"$D" 2>/dev/null | tr -d ' ')
  EB=$(wc -c <"$E" 2>/dev/null | tr -d ' ')
  [ -n "$SZ" ] || SZ=0
  [ -n "$EB" ] || EB=0
  EH=$(tr '\t\r\n' '   ' <"$E" 2>/dev/null | head -c 180)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$RC" "$SZ" "$EB" "$D" "$E" "$EH"
  rm -f "$D" "$E"
done
REMOTE
  then
    DIRECT_RC=0
    break
  fi
  sleep "$direct_try"
done
if [ "$DIRECT_RC" != 0 ]; then
  echo "host=$HOST direct_probe=ssh_failed attempts=$direct_try" >"$OUT/direct.tsv"
fi
cat "$OUT/direct.tsv"

# 有界 serve 采样：snapshot 会触发真实 framecap 主环，但不安装/重启任何组件。
for i in $(seq 1 "$SNAPS"); do
  curl -sS -m 15 -o "$OUT/snapshot_${i}.bin" "http://$IP:$PORT/snapshot" \
    >"$OUT/snapshot_${i}.http" 2>&1 || true
  sleep 1
done

remote "tail -n 240 '$VAR/.ziyan_framecap_log' 2>/dev/null" \
  >"$OUT/framecap_after.log" 2>&1 || true
awk -v marker="$RUN_MARKER" \
  'length($0) >= 19 && substr($0, 1, 19) >= marker { print }' \
  "$OUT/framecap_after.log" >"$OUT/framecap_run.log"
remote "cat '$VAR/.ziyan_cap_diag' 2>/dev/null" \
  >"$OUT/cap_diag_after.txt" 2>&1 || true
# 测试机是精简 rootful 系统，.101 没有 curl；用其已有 wget 取状态，避免把
# SSH host-key 提示误存为 status.txt 并把终态 seq 解析成 0。
remote "wget -qO- http://127.0.0.1:$PORT/status 2>/dev/null" \
  >"$OUT/status.txt" 2>&1 || true

DIRECT_BAD=$(awk -F '\t' 'NR>1 && ($2 != 0 || $3 < 16 || $4 != 0) {n++} END{print n+0}' "$OUT/direct.tsv")
if [ "$DIRECT_RC" != 0 ]; then
  DIRECT_BAD=$((DIRECT_BAD + 1))
fi
DIRECT_N=$(awk -F '\t' 'NR>1 && $1 ~ /^[0-9]+$/ {n++} END{print n+0}' "$OUT/direct.tsv")
DIRECT_BLACK=$(awk -F '\t' 'NR>1 && $2 != 0 && $7 ~ /uicreate_dump_fail err=uicreate_black/ {n++} END{print n+0}' "$OUT/direct.tsv")
CHILD_FAIL=$(rg -c 'uicreate_child_(fail|exit|sig|timeout)|uicreate_dump_(short|magic|geom)' "$OUT/framecap_run.log" 2>/dev/null || true)
CHILD_FAIL="${CHILD_FAIL:-0}"
UIC_OK=$(rg -c 'uicreate=ok' "$OUT/framecap_run.log" 2>/dev/null || true)
UIC_OK="${UIC_OK:-0}"
INFLIGHT=$(rg -c 'uicreate_inflight' "$OUT/framecap_run.log" 2>/dev/null || true)
INFLIGHT="${INFLIGHT:-0}"
SEQ0=$(rg -c 'seq=0' "$OUT/framecap_run.log" 2>/dev/null || true)
SEQ0="${SEQ0:-0}"
STATUS_SEQ=$(sed -n 's/^frame_seq=//p' "$OUT/status.txt" | head -1 | tr -dc '0-9')
if [ -z "$STATUS_SEQ" ]; then
  STATUS_SEQ=$(sed -n 's/.*"frame_seq"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$OUT/status.txt" | head -1)
fi
STATUS_SEQ="${STATUS_SEQ:-0}"
# CapLog 成功行会被生产限频合并，不能以它是否恰好落在 tail 中判断本轮成败。
# cap_diag 是本次守护真实合帧的最终链路证据，且 who=ziyan_framecap 可排除直接
# uicreate-dump 子进程。异步 child 的第一次 poll 允许 inflight/seq=0；验收的是
# 随后确实交出非零 seq，而不是把这个瞬态当成永久失败。
SERVICE_UIC_OK=$(rg -c 'who=ziyan_framecap/.+phase=GLOBAL via=uicreate .+uicreate=ok.+err=ok' \
  "$OUT/cap_diag_after.txt" 2>/dev/null || true)
SERVICE_UIC_OK="${SERVICE_UIC_OK:-0}"
SERVICE_SUCCESS=$((UIC_OK + SERVICE_UIC_OK))
IOMFB_OK=$(rg -c 'phase=(GLOBAL via=iomfb|IOMFB_ACCEL).*(err=ok|via=iomfb_accel_copy_release)' \
  "$OUT/cap_diag_after.txt" 2>/dev/null || true)
IOMFB_OK="${IOMFB_OK:-0}"
# C98：游戏前台主路径是 AppWindow（provider=8）。cap_diag 常停在更早的
# uicreate_inflight，不能再把「服务没再走 UICreate/IOMFB」判成 P6 FAIL。
# 本轮 framecap 日志里的 appwindow_ok + status provider=8 即服务成帧证据。
APPWINDOW_OK=$(rg -c 'appwindow_ok' "$OUT/framecap_run.log" 2>/dev/null || true)
APPWINDOW_OK="${APPWINDOW_OK:-0}"
STATUS_PROVIDER=$(sed -n 's/^frame_provider=//p' "$OUT/status.txt" | head -1 | tr -dc '0-9')
STATUS_PROVIDER="${STATUS_PROVIDER:-0}"
APPWINDOW_EVIDENCE=0
if [ "$APPWINDOW_OK" -gt 0 ] && [ "$STATUS_PROVIDER" = 8 ]; then
  APPWINDOW_EVIDENCE="$APPWINDOW_OK"
fi
SERVICE_CAPTURE_OK=$((SERVICE_SUCCESS + IOMFB_OK + APPWINDOW_EVIDENCE))

{
  echo "# P6 UICreate gate .$HOST"
  echo "run_marker=$RUN_MARKER direct_bad=$DIRECT_BAD direct_n=$DIRECT_N direct_black=$DIRECT_BLACK child_fail=$CHILD_FAIL log_uicreate_ok=$UIC_OK diagnostic_uicreate_ok=$SERVICE_UIC_OK service_uicreate_evidence=$SERVICE_SUCCESS iomfb_ok=$IOMFB_OK appwindow_ok=$APPWINDOW_OK appwindow_evidence=$APPWINDOW_EVIDENCE provider=$STATUS_PROVIDER service_capture_evidence=$SERVICE_CAPTURE_OK inflight=$INFLIGHT seq0_events=$SEQ0 terminal_seq=$STATUS_SEQ"
  echo "diagnostic=$(tail -1 "$OUT/cap_diag_after.txt" 2>/dev/null | tr '\n' ' ')"
  # 服务端优先选择 IOMFB 是正常且更快的主路径；不能把“UICreate 直接探针
  # 已通过、但服务没有必要再调用它”误报为 P6 FAIL。验收的是子进程能力、
  # 无 child 故障，以及服务确实持续交出有效帧。
  if [ "$DIRECT_BAD" = 0 ] && [ "$CHILD_FAIL" = 0 ] && [ "$SERVICE_CAPTURE_OK" -gt 0 ] && [ "$STATUS_SEQ" -gt 0 ]; then
    echo "VERDICT=PASS"
  elif [ "$DIRECT_N" -gt 0 ] && [ "$DIRECT_BAD" = "$DIRECT_N" ] && \
       [ "$DIRECT_BLACK" = "$DIRECT_N" ] && [ "$CHILD_FAIL" = 0 ] && \
       [ "$IOMFB_OK" -gt 0 ] && [ "$STATUS_SEQ" -gt 0 ]; then
    echo "VERDICT=PASS_SAFE_FALLBACK"
    echo "NOTE=isolated_uicreate_black; runtime_iomfb_healthy; UICreate must stay suppressed for this front-bid"
  else
    echo "VERDICT=FAIL"
  fi
  echo "OUT=$OUT"
} | tee "$OUT/VERDICT.md"

grep -q 'VERDICT=PASS' "$OUT/VERDICT.md"
