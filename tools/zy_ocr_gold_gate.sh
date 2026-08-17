#!/usr/bin/env bash
# P3：标准答案 OCR / 找字门禁。
# 设备侧直接调用同一 ziyan_ocr Vision 二进制读取标准素材，逐样本记录
# text、OCR 是否完全正确、find-string 命中/误报与耗时；ok=true 或非空文本
# 不计为正确。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
ASSET="${ZY_OCR_ASSET_DIR:-$ROOT/tmp_shots/OCR_GOLD_20260808_132832}"
REPEAT="${ZY_OCR_REPEAT:-5}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/OCR_GOLD_RUN_${STAMP}"
mkdir -p "$OUT"

[[ -f "$ASSET/expected.json" && -f "$ASSET/zh.png" && -f "$ASSET/en.png" && -f "$ASSET/num.png" ]] || {
  echo "FATAL missing OCR gold assets under $ASSET" >&2
  exit 2
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)
if [[ "$#" -gt 0 ]]; then HOSTS=("$@"); else HOSTS=(53 101 112 166); fi
echo "OUT=$OUT ASSET=$ASSET REPEAT=$REPEAT HOSTS=${HOSTS[*]}" | tee "$OUT/OUT_PATH.txt"
cp "$ASSET/expected.json" "$OUT/expected.json"

for H in "${HOSTS[@]}"; do
  IP="192.168.31.$H"
  if [[ "$H" = 53 ]]; then BIN=/var/jb/usr/lib/ziyan/bin/ziyan_ocr; else BIN=/usr/lib/ziyan/bin/ziyan_ocr; fi
  REMOTE_DIR="/private/var/mobile/Media/ZiYan/OCR_GOLD_${STAMP}"
  echo "==== .$H BIN=$BIN ====" | tee "$OUT/host_${H}.log"
  AUTH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no)
  if ! "${AUTH[@]}" "root@$IP" true >/dev/null 2>&1; then
    AUTH=(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o BatchMode=yes)
    "${AUTH[@]}" "root@$IP" true >/dev/null 2>&1 || {
      echo "FAIL .$H ssh_auth_failed" | tee -a "$OUT/host_${H}.log"
      continue
    }
  fi
  # 先用一个连接传素材，再用一个长连接批量跑样本；避免每个样本单独认证。
  "${AUTH[@]}" "root@$IP" \
    "mkdir -p '$REMOTE_DIR'" >"$OUT/push_${H}.log" 2>&1
  tar -C "$ASSET" -cf - zh.png en.png num.png |
    "${AUTH[@]}" "root@$IP" \
      "tar -xf - -C '$REMOTE_DIR'" >>"$OUT/push_${H}.log" 2>&1
  "${AUTH[@]}" "root@$IP" \
      "H='$H' BIN='$BIN' REMOTE_DIR='$REMOTE_DIR' REPEAT='$REPEAT' bash -s" \
      >"$OUT/raw_${H}.tsv" 2>"$OUT/ssh_${H}.log" <<'REMOTE'
set +e
printf 'host\tid\trep\tlat_ms\ttext\tocr_correct\tfind_hit\tfind_false\traw_json\n'
for spec in 'zh|子砚测试|zh.png' 'en|ZiYan TEST|en.png' 'num|2026-081|num.png'; do
  ID=${spec%%|*}; rest=${spec#*|}; EXPECT=${rest%%|*}; FILE=${rest##*|}
  for REP in $(seq 1 "$REPEAT"); do
    S=$(date +%s%N)
    JSON=$("$BIN" "$REMOTE_DIR/$FILE" --json 2>/dev/null)
    E=$(date +%s%N)
    LAT=$(( (E-S) / 1000000 ))
    TEXT=$(printf '%s\n' "$JSON" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
    [ -n "$TEXT" ] || TEXT=""
    CORRECT=0; FIND=0; FALSE=0
    [ "$TEXT" = "$EXPECT" ] && CORRECT=1
    case "$TEXT" in *"$EXPECT"*) FIND=1;; esac
    case "$TEXT" in *不存在目标*) FALSE=1;; esac
    SAFE=$(printf '%s' "$JSON" | tr '\t\r\n' '   ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$H" "$ID" "$REP" "$LAT" "$TEXT" "$CORRECT" "$FIND" "$FALSE" "$SAFE"
  done
done
REMOTE
  grep -E '^(host|[0-9]+[[:space:]]+)' "$OUT/raw_${H}.tsv" >"$OUT/samples_${H}.tsv" || true
  cat "$OUT/samples_${H}.tsv" | tee -a "$OUT/host_${H}.log"
done

{
  echo "host\tn\tcorrect\tfind_hit\tfind_false\tp50_ms\tp95_ms\tmax_ms\taccuracy\tfind_rate\tfalse_positive_rate"
  for H in "${HOSTS[@]}"; do
    F="$OUT/samples_${H}.tsv"
    N=$(awk -F '\t' 'NR>1 && $1 ~ /^[0-9]+$/ {n++} END{print n+0}' "$F")
    C=$(awk -F '\t' 'NR>1 && $6==1 {n++} END{print n+0}' "$F")
    FH=$(awk -F '\t' 'NR>1 && $7==1 {n++} END{print n+0}' "$F")
    FP=$(awk -F '\t' 'NR>1 && $8==1 {n++} END{print n+0}' "$F")
    P50=$(awk -F '\t' 'NR>1 && $4 ~ /^[0-9]+$/ {print $4}' "$F" | sort -n | awk -v n="$N" 'BEGIN{r=int(0.50*n+0.999); if(r<1)r=1; if(r>n)r=n} NR==r{print; found=1} END{if(!found)print 0}')
    P95=$(awk -F '\t' 'NR>1 && $4 ~ /^[0-9]+$/ {print $4}' "$F" | sort -n | awk -v n="$N" 'BEGIN{r=int(0.95*n+0.999); if(r<1)r=1; if(r>n)r=n} NR==r{print; found=1} END{if(!found)print 0}')
    MAX=$(awk -F '\t' 'NR>1 && $4 ~ /^[0-9]+$/ {if($4>m)m=$4} END{print m+0}' "$F")
    ACC=$(awk -v c="$C" -v n="$N" 'BEGIN{if(n)printf "%.4f",c/n; else print "0.0000"}')
    FR=$(awk -v c="$FH" -v n="$N" 'BEGIN{if(n)printf "%.4f",c/n; else print "0.0000"}')
    FPR=$(awk -v c="$FP" -v n="$N" 'BEGIN{if(n)printf "%.4f",c/n; else print "0.0000"}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$H" "$N" "$C" "$FH" "$FP" "$P50" "$P95" "$MAX" "$ACC" "$FR" "$FPR"
  done
} | tee "$OUT/SUMMARY.tsv"

awk -F '\t' 'NR==1{next} {n++; if($2==0||$9<1.0||$10<1.0||$11>0) bad++} END{print "HOSTS="n" FAIL_HOSTS="bad+0; print (bad==0?"VERDICT=PASS":"VERDICT=FAIL")}' "$OUT/SUMMARY.tsv" | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
