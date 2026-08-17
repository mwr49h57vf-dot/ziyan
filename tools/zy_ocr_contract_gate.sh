#!/usr/bin/env bash
# 本包 OCR/找字独立门禁。二进制存在 ≠ PASS。固定样本 + Lua 契约。
# 用法: bash tools/zy_ocr_contract_gate.sh [53 101 112 166]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="${ZY_OCR_ASSET_DIR:-$ROOT/tests/ocr_gold}"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')_$$"
OUT="$ROOT/tmp_shots/Z1_OCR_${STAMP}"
mkdir -p "$OUT"
if [ "$#" -eq 0 ]; then HOSTS=(53 101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 53|101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
[[ -f "$ASSET/zh.png" && -f "$ASSET/en.png" && -f "$ASSET/num.png" && -f "$ASSET/empty.png" ]] || {
  echo "FATAL missing $ASSET gold samples"; exit 2
}
SSH_KEY_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 -o ServerAliveInterval=15)
SSH_PW_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
             -o ConnectTimeout=12 -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() {
  local ip="$1"; shift
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" "true" >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_PW_OPTS[@]}" "root@$ip" "$@"
  fi
}
echo "OUT=$OUT hosts=${HOSTS[*]} asset=$ASSET" | tee "$OUT/meta.txt"

run_one() {
  local H="$1" IP="192.168.31.$1" JB="" BIN VAR
  if [ "$H" = 53 ]; then JB=/var/jb; fi
  BIN="${JB}/usr/lib/ziyan/bin/ziyan_ocr"
  VAR="${JB}/usr/lib/ziyan/var"
  local RD="/private/var/mobile/Media/ZiYan/OCR_GOLD_${STAMP}"
  echo "==== OCR .$H ===="
  if ! ssh_r "$IP" "test -x '$BIN'"; then
    echo "CLASS=INVALID_RUN reason=ocr_bin_missing" | tee "$OUT/run_${H}.txt"
    return 1
  fi
  ssh_r "$IP" "mkdir -p '$RD' /private/var/mobile/Media/ZiYan/verdicts" >/dev/null 2>&1 || true
  if ! tar -C "$ASSET" -cf - zh.png en.png num.png empty.png multi.png expected.json |
       ssh_r "$IP" "tar -xf - -C '$RD'"; then
    echo "CLASS=TRANSPORT_BLOCKED reason=gold_push_failed" | tee "$OUT/run_${H}.txt"
    return 1
  fi
  ssh_r "$IP" "H='$H' BIN='$BIN' RD='$RD' VAR='$VAR' bash -s" >"$OUT/raw_${H}.txt" 2>&1 <<'EOS' || true
set +e
RSS0=$(ps -axo rss=,args= 2>/dev/null | while read -r rss args; do
  case "$args" in *ziyan_framecap\ serve*) echo "$rss"; break ;; esac
done)
echo "RSS0=${RSS0:-0}"
echo "BIN_OK=1"
for spec in 'zh|子砚测试|zh.png' 'en|ZiYan TEST|en.png' 'num|20260815|num.png' 'empty||empty.png' 'multi|第一行中文|multi.png'; do
  ID=${spec%%|*}; rest=${spec#*|}; EXP=${rest%%|*}; FILE=${rest##*|}
  S=$(date +%s)
  JSON=$("$BIN" "$RD/$FILE" --json 2>/dev/null)
  E=$(date +%s)
  LAT=$((E-S))
  TEXT=$(printf '%s\n' "$JSON" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  OK=0
  if [ "$ID" = empty ]; then
    [ -z "$TEXT" ] && OK=1
  else
    case "$TEXT" in *"$EXP"*) OK=1;; esac
  fi
  echo "FILE id=$ID expect=$EXP text=${TEXT:-} lat=${LAT}s correct=$OK"
done
# Lua 契约：空 ROI / 不存在词 / 超时。getText 可挂，8s 看门狗。
M=/private/var/mobile/Media/ZiYan
cat >"$M/_ocr_contract.lua" <<'LUA'
function main()
  init(1)
  local out = "/private/var/mobile/Media/ZiYan/_ocr_contract_out.txt"
  local function w(s)
    local f = io.open(out, "a")
    if f then f:write(tostring(s).."\n"); f:close() end
  end
  w("started")
  local t0 = os.time()
  local gt = "nil"
  if type(getText) == "function" then
    local ok, a = pcall(getText, 0, 0, 8, 8)
    if ok then gt = tostring(a) else gt = "err:"..tostring(a) end
  else
    gt = "missing"
  end
  w("getText_empty="..gt)
  w("getText_ms="..tostring((os.time()-t0)*1000))
  local fx, fy = -9, -9
  if type(findStr) == "function" then
    local ok, x, y = pcall(findStr, "___NO_SUCH_OCR_TOKEN___", 0, 0, 80, 80)
    if ok then fx, fy = tonumber(x) or -1, tonumber(y) or -1 else fx, fy = -2, -2 end
  end
  w(string.format("findStr_miss=%s,%s", tostring(fx), tostring(fy)))
  local st = ""
  if type(strFind) == "function" then
    local ok, a = pcall(strFind, 0, 0, 8, 8)
    if ok then st = tostring(a) else st = "err" end
  else
    st = "missing"
  end
  w("strFind_empty="..st)
  local num = "nil"
  if type(findNumber) == "function" then
    local ok, a = pcall(findNumber, 0, 0, 8, 8)
    if ok then num = tostring(a) else num = "err" end
  else
    num = "missing"
  end
  w("findNumber_empty="..num)
  w("done")
end
LUA
printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"; sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_user_stopped" "$M/_ocr_contract_out.txt"
printf 'path=%s/_ocr_contract.lua\nstop=0\n' "$M" >"$VAR/.ziyan_run_intent"
printf '%s/_ocr_contract.lua\n' "$M" >"$VAR/.ziyan_embed_script"
echo 1 >"$VAR/.ziyan_embed_on"
echo "nonce=ocr_${H}_$$" >"$VAR/.ziyan_embed_go"
i=0
while [ "$i" -lt 30 ]; do
  [ -s "$M/_ocr_contract_out.txt" ] && grep -q '^done$' "$M/_ocr_contract_out.txt" && break
  sleep 0.5
  i=$((i+1))
done
if [ -s "$M/_ocr_contract_out.txt" ] && grep -q '^done$' "$M/_ocr_contract_out.txt"; then
  echo "LUA_CONTRACT=ok"
  cat "$M/_ocr_contract_out.txt"
elif [ -s "$M/_ocr_contract_out.txt" ]; then
  echo "LUA_CONTRACT=ocr_timeout"
  echo "CLASS=ocr_timeout"
  cat "$M/_ocr_contract_out.txt"
else
  echo "LUA_CONTRACT=no_receipt"
  echo "CLASS=INVALID_RUN"
fi
printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"; sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_go" \
  "$VAR/.ziyan_embed_script" "$VAR/.ziyan_active" "$M/_ocr_contract.lua" "$M/_ocr_contract_out.txt"
RSS1=$(ps -axo rss=,args= 2>/dev/null | while read -r rss args; do
  case "$args" in *ziyan_framecap\ serve*) echo "$rss"; break ;; esac
done)
echo "RSS1=${RSS1:-0}"
echo "FC_N=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')"
echo "ACTIVE=$(test -f "$VAR/.ziyan_active" && echo 1 || echo 0)"
echo "KEEP_AFTER_STOP=$(test -f "$VAR/.ziyan_keep_daemon" && echo 1 || echo 0)"
EOS
  if [ ! -s "$OUT/raw_${H}.txt" ] || ! grep -q '^BIN_OK=1' "$OUT/raw_${H}.txt"; then
    echo "CLASS=INVALID_RUN reason=no_device_ocr_output" | tee "$OUT/run_${H}.txt"
    return 1
  fi
  local ZH EN NUM EMP CORR OK
  CORR=0
  ZH=$(sed -n 's/^FILE id=zh .* correct=//p' "$OUT/raw_${H}.txt" | tail -1)
  EN=$(sed -n 's/^FILE id=en .* correct=//p' "$OUT/raw_${H}.txt" | tail -1)
  NUM=$(sed -n 's/^FILE id=num .* correct=//p' "$OUT/raw_${H}.txt" | tail -1)
  EMP=$(sed -n 's/^FILE id=empty .* correct=//p' "$OUT/raw_${H}.txt" | tail -1)
  [ "$ZH" = 1 ] && CORR=$((CORR+1))
  [ "$EN" = 1 ] && CORR=$((CORR+1))
  [ "$NUM" = 1 ] && CORR=$((CORR+1))
  [ "$EMP" = 1 ] && CORR=$((CORR+1))
  OK=1
  [ "$CORR" -ge 2 ] || { echo "FAIL .$H gold_accuracy=$CORR/4"; OK=0; }
  if grep -q 'LUA_CONTRACT=no_receipt' "$OUT/raw_${H}.txt"; then
    echo "CLASS=INVALID_RUN reason=lua_no_receipt"
    OK=0
  elif ! grep -q '^LUA_CONTRACT=' "$OUT/raw_${H}.txt"; then
    echo "CLASS=INVALID_RUN reason=lua_contract_missing"
    OK=0
  fi
  local FCN ACT KEEP
  FCN=$(sed -n 's/^FC_N=//p' "$OUT/raw_${H}.txt" | tail -1)
  ACT=$(sed -n 's/^ACTIVE=//p' "$OUT/raw_${H}.txt" | tail -1)
  KEEP=$(sed -n 's/^KEEP_AFTER_STOP=//p' "$OUT/raw_${H}.txt" | tail -1)
  [ "${FCN:-0}" = 1 ] || { echo "FAIL .$H fc_n=$FCN"; OK=0; }
  [ "${ACT:-1}" = 0 ] || { echo "FAIL .$H active_residual"; OK=0; }
  [ "${KEEP:-1}" = 0 ] || { echo "FAIL .$H keep_after_stop"; OK=0; }
  local VDICT=FAIL
  [ "$OK" = 1 ] && VDICT=PASS
  local PKG RID
  PKG=$(ssh_r "$IP" "dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\\([^ ]*\\).*/\\1/p'" | tr -d '\r')
  RID="ocr_${H}_$(date +%s)"
  {
    echo "run_id=$RID"
    echo "host=.$H"
    echo "pkg=$PKG"
    echo "gold_correct=$CORR/4"
    echo "zh=$ZH en=$EN num=$NUM empty=$EMP"
    echo "FC_N=$FCN ACTIVE=$ACT KEEP_AFTER_STOP=$KEEP"
    echo "VERDICT=$VDICT"
    echo "final=1"
  } >"$OUT/device_final_${H}.txt"
  ssh_r "$IP" "cat > /private/var/mobile/Media/ZiYan/verdicts/${RID}.txt" <"$OUT/device_final_${H}.txt" || true
  echo "DEVICE_FINAL_$H=$RID VERDICT=$VDICT gold=$CORR/4" | tee "$OUT/run_${H}.txt"
  [ "$OK" = 1 ]
}

PASS_N=0; FAIL_N=0
for H in "${HOSTS[@]}"; do
  if run_one "$H"; then PASS_N=$((PASS_N+1)); else FAIL_N=$((FAIL_N+1)); fi
done
{
  echo "# Z1-OCR 本包固定样本门禁"
  echo "stamp=$STAMP hosts=${HOSTS[*]}"
  echo "asset=$ASSET"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  echo "binary_exists_is_not_pass"
  [ "$FAIL_N" -eq 0 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
} | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ]
