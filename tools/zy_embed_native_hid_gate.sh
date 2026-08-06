#!/usr/bin/env bash
# Embed 单宿主 HID 门禁：framecap 内 Lua → 原生 HID，禁 touch_req 文件热路径。
# 用法：bash tools/zy_embed_native_hid_gate.sh <53|101|112|166> <x> <y>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
TAG="${1:-}"
X="${2:-}"
Y="${3:-}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/EMBED_NATIVE_HID_${STAMP}_${TAG}"
mkdir -p "$OUT"

case "$TAG" in
  53) IP=192.168.31.53; SCHEME=rootless ;;
  101) IP=192.168.31.101; SCHEME=rootful ;;
  112) IP=192.168.31.112; SCHEME=rootful ;;
  166) IP=192.168.31.166; SCHEME=rootful ;;
  *) echo "usage: $0 <53|101|112|166> <x> <y>"; exit 2 ;;
esac
[[ "$X" =~ ^[0-9]+([.][0-9]+)?$ && "$Y" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "x/y must be numeric"; exit 2
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)
ssh_r() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$IP" "$@"
}

ssh_r "TAG=$TAG SCHEME=$SCHEME X=$X Y=$Y bash -s" <<'EOS' | tee "$OUT/gate.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var
  B=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var
  B=/usr/lib/ziyan/bin
fi
M=/private/var/mobile/Media/ZiYan
S="$M/_embed_native_hid_gate.lua"

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_touch_req" \
  "$V/.ziyan_touch_rep" "$V/.ziyan_touch_native" \
  "$V/.ziyan_embed_go" "$V/.ziyan_embed_alive" \
  "$V/.ziyan_lua_embedded" "$M/.ziyan_touch_req"

for i in $(seq 1 10); do
  echo 1 >"$V/.ziyan_go_home"
  sleep 0.8
  rm -f "$V/.ziyan_go_home"
  F=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "HOME try=$i front=$F"
  echo "$F" | grep -qi springboard && break
done
FRONT0=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)

echo 1 >"$V/.ziyan_force_recap"
echo "nonce=native_hid_$TAG" >"$V/.ziyan_frame_req"
sleep 2

cat >"$S" <<LUA
function main()
  init(1)
  local ok = tap($X, $Y, 90)
  local f = io.open("$M/_embed_native_hid_result.txt", "w")
  if f then
    f:write("tap_ok=" .. tostring(ok) .. "\\n")
    f:close()
  end
  mSleep(3000)
end
LUA
chmod 666 "$S"
rm -f "$M/_embed_native_hid_result.txt"
printf 'path=%s\nstop=0\n' "$S" >"$V/.ziyan_run_intent"
printf '%s\n' "$S" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
echo "nonce=native_hid_${TAG}_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" \
  "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"

for i in $(seq 1 30); do
  [ -s "$V/.ziyan_touch_native" ] && break
  sleep 0.2
done
sleep 1

FRONT1=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
NATIVE=$(tr '\n' ' ' <"$V/.ziyan_touch_native" 2>/dev/null)
RESULT=$(tr '\n' ' ' <"$M/_embed_native_hid_result.txt" 2>/dev/null)
REQ=0
[ -e "$V/.ziyan_touch_req" ] && REQ=1
[ -e "$M/.ziyan_touch_req" ] && REQ=1
echo "META tag=$TAG xy=$X,$Y front0=$FRONT0 front1=$FRONT1"
echo "NATIVE=$NATIVE"
echo "RESULT=$RESULT TOUCH_REQ_RESIDUE=$REQ"

PASS=1
echo "$FRONT0" | grep -qi springboard || PASS=0
echo "$NATIVE" | grep -q 'kind=tap' || PASS=0
echo "$NATIVE" | grep -q 'ok=1' || PASS=0
echo "$RESULT" | grep -q 'tap_ok=true' || PASS=0
[ "$REQ" -eq 0 ] || PASS=0
[ "$FRONT1" != "$FRONT0" ] || PASS=0

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_run_intent" \
  "$V/.ziyan_embed_go" "$V/.ziyan_embed_script" \
  "$V/.ziyan_active" "$V/.ziyan_keep_daemon" \
  "$M/_embed_native_hid_result.txt" "$S"

if [ "$PASS" -eq 1 ]; then
  echo "VERDICT=PASS"
else
  echo "VERDICT=FAIL"
fi
EOS

if grep -q 'VERDICT=PASS' "$OUT/gate.txt"; then
  echo "VERDICT=PASS" | tee "$OUT/VERDICT.md"
else
  echo "VERDICT=FAIL" | tee "$OUT/VERDICT.md"
  exit 1
fi
echo "OUT=$OUT"
