#!/usr/bin/env bash
# Z1-TOUCH 原生 HID 门禁（自证式）
# 用法：bash tools/zy_embed_native_hid_gate.sh <53|101|112|166> [x y]
#       不给 x/y 时自动截屏并挑一个「非壁纸」的点位建议给你，不注入。
#
# 为什么要自证：
#   旧版固定点 tap 后只看 .ziyan_front_bid 变没变。若该坐标下压根没有图标
#   （实测 .101 的 (396,195) 就是纯壁纸），前台不变是必然的，门禁无法区分
#   「HID 没落地」与「那里没东西可点」，会把找色问题误报成触控问题。
#
#   现在改为：注入前后各取一张整屏，比较像素差。
#     前台变化   → HID 确定落地（最强证据）
#     像素有变化 → HID 落地（点到了会响应的控件）
#     两者都无   → 才判 HID 未落地，并附上该点的颜色供判断是不是壁纸
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
TAG="${1:-}"
X="${2:-}"
Y="${3:-}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/EMBED_NATIVE_HID_${STAMP}_${TAG}"
# 判定「画面变了」的像素差比例下限
DIFF_MIN="${ZY_HID_DIFF_MIN:-0.005}"

case "$TAG" in
  53) IP=192.168.31.53; SCHEME=rootless ;;
  101) IP=192.168.31.101; SCHEME=rootful ;;
  112) IP=192.168.31.112; SCHEME=rootful ;;
  166) IP=192.168.31.166; SCHEME=rootful ;;
  *) echo "usage: $0 <53|101|112|166> [x y]"; exit 2 ;;
esac
mkdir -p "$OUT"

SSH_KEY_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 -o ServerAliveInterval=15)
SSH_PW_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
             -o ConnectTimeout=12 -o PreferredAuthentications=password
             -o PubkeyAuthentication=no)
# 探测必须 ssh -n，避免吃掉调用方 heredoc；真正执行禁止 -n。
ssh_r() {
  if [ "${_ZY_SSH_AUTH:-}" = key ]; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$IP" "$@"
  elif [ "${_ZY_SSH_AUTH:-}" = pw ]; then
    sshpass -p "$PASS" ssh "${SSH_PW_OPTS[@]}" "root@$IP" "$@"
  elif ssh -n "${SSH_KEY_OPTS[@]}" "root@$IP" "true" >/dev/null 2>&1; then
    _ZY_SSH_AUTH=key
    ssh "${SSH_KEY_OPTS[@]}" "root@$IP" "$@"
  else
    _ZY_SSH_AUTH=pw
    sshpass -p "$PASS" ssh "${SSH_PW_OPTS[@]}" "root@$IP" "$@"
  fi
}
scp_r() {
  if [ "${_ZY_SSH_AUTH:-}" != pw ] && ssh -n "${SSH_KEY_OPTS[@]}" "root@$IP" "true" >/dev/null 2>&1; then
    _ZY_SSH_AUTH=key
    scp "${SSH_KEY_OPTS[@]}" "$1" "root@$IP:$2"
  else
    _ZY_SSH_AUTH=pw
    sshpass -p "$PASS" scp "${SSH_PW_OPTS[@]}" "$1" "root@$IP:$2"
  fi
}

if [ "$SCHEME" = rootless ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
M=/private/var/mobile/Media/ZiYan

# 合帧守护的 HTTP 端口（50005 被占时会退到 50015）
PORT=$(ssh_r "cat $V/.ziyan_snap_http_port 2>/dev/null" | tr -dc '0-9')
PORT="${PORT:-50005}"
echo "META tag=$TAG scheme=$SCHEME snap_port=$PORT"

snap() {  # snap <outfile>
  local dst="$1" i r
  ssh_r "set +e; echo 1 >'$V/.ziyan_force_recap'; echo nonce=hid\$\$ >'$V/.ziyan_frame_req'; \
         chmod 666 '$V/.ziyan_force_recap' '$V/.ziyan_frame_req' 2>/dev/null; sleep 1" >/dev/null 2>&1
  for i in 1 2 3 4 5; do
    r=$(curl -s -m 15 -o "$dst" -w '%{http_code}' "http://$IP:$PORT/snapshot" || echo 000)
    [ "$r" = "200" ] && return 0
    sleep 2
  done
  return 1
}

echo "==== 回桌面 ===="
ssh_r "set +e; echo 1 >'$V/.ziyan_go_home'; sleep 2; rm -f '$V/.ziyan_go_home'" >/dev/null 2>&1
FRONT0=$(ssh_r "tr -d '\r\n' <'$V/.ziyan_front_bid' 2>/dev/null")
echo "FRONT0=$FRONT0"

snap "$OUT/before.png" || { echo "VERDICT=FAIL reason=snapshot_before_failed"; exit 1; }
echo "BEFORE=$OUT/before.png ($(wc -c <"$OUT/before.png") bytes)"

# 未给坐标：只做点位勘察，帮你避开壁纸，不注入
if [ -z "$X" ] || [ -z "$Y" ]; then
  python3 - "$OUT/before.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
print(f"SCREEN={W}x{H}")
print("未给坐标，仅勘察。下列格点为局部方差较高处（多半是图标而非壁纸）：")
best = []
step = 40
for y in range(step, H - step, step):
    for x in range(step, W - step, step):
        box = im.crop((x - 16, y - 16, x + 16, y + 16))
        cols = box.getcolors(maxcolors=4096)
        best.append((len(cols) if cols else 9999, x, y))
best.sort(reverse=True)
for n, x, y in best[:8]:
    print(f"  候选 ({x},{y}) 色彩数={n} 颜色={im.getpixel((x, y))}")
PY
  echo "VERDICT=SURVEY_ONLY"
  echo "OUT=$OUT"
  exit 0
fi

[[ "$X" =~ ^[0-9]+$ && "$Y" =~ ^[0-9]+$ ]] || { echo "x/y must be integers"; exit 2; }

# 该点是不是壁纸：看邻域色彩丰富度
python3 - "$OUT/before.png" "$X" "$Y" <<'PY' | tee "$OUT/target_probe.txt"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
x, y = int(sys.argv[2]), int(sys.argv[3])
W, H = im.size
if not (0 <= x < W and 0 <= y < H):
    print(f"TARGET_OOB screen={W}x{H}")
    raise SystemExit
box = im.crop((max(0, x - 20), max(0, y - 20), min(W, x + 20), min(H, y + 20)))
cols = box.getcolors(maxcolors=8192)
n = len(cols) if cols else 9999
print(f"TARGET_XY={x},{y} PIXEL={im.getpixel((x, y))} NEIGHBOR_COLORS={n}")
print("TARGET_LOOKS_LIKE=" + ("wallpaper_or_flat" if n < 24 else "widget_or_icon"))
PY

echo "==== 注入 tap($X,$Y) ===="
cat >"$OUT/probe.lua" <<LUA
function main()
  init(1)
  mSleep(400)
  local ok = tap($X, $Y, 90)
  local f = io.open("$M/_hid_gate_result.txt", "w")
  if f then f:write("tap_ok=" .. tostring(ok) .. "\n"); f:close() end
  mSleep(4000)
end
LUA
scp_r "$OUT/probe.lua" "$M/_hid_gate_probe.lua"

ssh_r "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:\$PATH; V='$V' M='$M' bash -s" <<'EOS' | tee "$OUT/inject.txt"
set +e
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; sleep 1
# 停脚本会置停止意图；不清掉的话下一次 embed 起不来（go nonce 被吃、线程不启）
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_off" "$V/.ziyan_active" "$V/.ziyan_lua_embedded" \
  "$V/.ziyan_touch_native" "$V/.ziyan_touch_req" "$V/.ziyan_touch_rep" \
  "$M/.ziyan_touch_req" "$M/_hid_gate_result.txt"
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null
FC0=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
[ -n "$FC0" ] || FC0=0
if [ "$FC0" -eq 0 ]; then
  launchctl kickstart system/com.ziyan.framecap 2>/dev/null || \
    launchctl kickstart com.ziyan.framecap 2>/dev/null
  sleep 2
fi
echo "FC_N=$FC0"
# embed 启动偶发不响应，重试 3 轮
STARTED=0
for r in 1 2 3; do
  printf 'path=%s/_hid_gate_probe.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
  printf '%s/_hid_gate_probe.lua\n' "$M" >"$V/.ziyan_embed_script"
  echo 1 >"$V/.ziyan_embed_on"
  echo "nonce=hidgate_${r}_$$" >"$V/.ziyan_embed_go"
  chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" \
    "$V/.ziyan_embed_on" "$V/.ziyan_embed_go" 2>/dev/null
  for i in $(seq 1 25); do
    if [ -s "$V/.ziyan_touch_native" ]; then STARTED=1; break; fi
    sleep 0.4
  done
  [ "$STARTED" = 1 ] && break
  echo "WARN embed_start_retry=$r"
done
echo "EMBED_STARTED=$STARTED"
sleep 2
echo "NATIVE=$(tr '\n' ' ' <"$V/.ziyan_touch_native" 2>/dev/null)"
echo "RESULT=$(tr '\n' ' ' <"$M/_hid_gate_result.txt" 2>/dev/null)"
REQ=0
[ -e "$V/.ziyan_touch_req" ] && REQ=1
[ -e "$M/.ziyan_touch_req" ] && REQ=1
echo "TOUCH_REQ_RESIDUE=$REQ"
echo "FRONT1=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)"
EOS

FRONT1=$(ssh_r "tr -d '\r\n' <'$V/.ziyan_front_bid' 2>/dev/null")
snap "$OUT/after.png" || echo "WARN snapshot_after_failed"

# 收尾并采停止合同（不得把缺输出写成视觉 FAIL）
ssh_r "set +e; printf 'ts=1\n' >'$V/.ziyan_kill_scripts'; sleep 1; \
  rm -f '$V/.ziyan_kill_scripts' '$V/.ziyan_run_intent' '$V/.ziyan_embed_go' \
    '$V/.ziyan_embed_script' '$V/.ziyan_active' '$V/.ziyan_keep_daemon' \
    '$M/_hid_gate_probe.lua' '$M/_hid_gate_result.txt'" >/dev/null 2>&1
STOP=$(ssh_r "V='$V' bash -s" <<'S'
set +e
FC=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
echo "FC_N=${FC:-0}"
echo "ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0)"
echo "KEEP_AFTER_STOP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)"
echo "EMBED=$(test -f "$V/.ziyan_embed_go" && echo 1 || echo 0)"
Z=$(ps -axo args= 2>/dev/null | grep -E '_hid_gate_probe|_hid_gate_result' | grep -vc grep | tr -dc '0-9')
echo "ZOMBIE_PROBE=${Z:-0}"
echo "SB_N=$(ps -axo args= 2>/dev/null | grep -F '/SpringBoard.app/SpringBoard' | grep -vc grep | tr -dc '0-9')"
S
)
echo "$STOP" | tee "$OUT/stop.txt" >/dev/null
FC_N=$(printf '%s\n' "$STOP" | sed -n 's/^FC_N=//p' | head -1)
ACTIVE=$(printf '%s\n' "$STOP" | sed -n 's/^ACTIVE=//p' | head -1)
KEEP_AFTER=$(printf '%s\n' "$STOP" | sed -n 's/^KEEP_AFTER_STOP=//p' | head -1)
ZOMBIE=$(printf '%s\n' "$STOP" | sed -n 's/^ZOMBIE_PROBE=//p' | head -1)

DIFF="n/a"
if [ -s "$OUT/after.png" ]; then
  DIFF=$(python3 - "$OUT/before.png" "$OUT/after.png" <<'PY'
import sys
from PIL import Image, ImageChops
a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
if a.size != b.size:
    print("1.0")
    raise SystemExit
diff = ImageChops.difference(a, b).convert("L")
n = sum(1 for p in diff.getdata() if p > 24)
print(f"{n / float(a.size[0] * a.size[1]):.4f}")
PY
)
fi

if [ ! -s "$OUT/inject.txt" ] || ! grep -q '^EMBED_STARTED=' "$OUT/inject.txt"; then
  echo "INVALID_RUN reason=inject_stdout_empty host_lost_remote_script" | tee "$OUT/VERDICT.md"
  echo "OUT=$OUT"
  exit 2
fi
STARTED=$(sed -n 's/^EMBED_STARTED=\([0-9]*\).*/\1/p' "$OUT/inject.txt" | head -1)
NATIVE_OK=$(grep -c 'kind=tap.*ok=1' "$OUT/inject.txt" 2>/dev/null || echo 0)
REQ=$(sed -n 's/^TOUCH_REQ_RESIDUE=\([0-9]*\).*/\1/p' "$OUT/inject.txt" | head -1)

{
  echo "# Z1-TOUCH 原生 HID 门禁 .$TAG"
  echo "target=$X,$Y front0=$FRONT0 front1=$FRONT1"
  cat "$OUT/target_probe.txt" 2>/dev/null
  echo "embed_started=${STARTED:-0} native_tap_ok=$NATIVE_OK touch_req_residue=${REQ:-?}"
  echo "pixel_diff_ratio=$DIFF (阈值 $DIFF_MIN)"
  echo "FC_N=${FC_N:-?} ACTIVE=${ACTIVE:-?} KEEP_AFTER_STOP=${KEEP_AFTER:-?} ZOMBIE_PROBE=${ZOMBIE:-?} SB_CHG=0"

  OK=1
  [ "${STARTED:-0}" = "1" ] || { echo "FAIL embed_not_started"; OK=0; }
  # 判据是「点击落地」，不是「走了哪条路由」。
  # 守护进程内没有 BKHIDSystemInterface，原生 HID 必然回 ok=0 并回落 SB 中继，
  # 那条路由带回执、实测能开 App（pixel_diff 0.98），把它判 FAIL 是错的口径。
  # 路由仅记录，不作判据。
  if [ "$NATIVE_OK" -ge 1 ] 2>/dev/null; then
    echo "ROUTE=embed_native"
  else
    echo "ROUTE=sb_relay（守护内无 BKHIDSystemInterface，按设计回落；见 .ziyan_hid_route）"
  fi
  [ "${REQ:-1}" = "0" ] || { echo "FAIL touch_req_residue（请求未被消费，中继没接上）"; OK=0; }

  LANDED=0
  [ -n "$FRONT1" ] && [ "$FRONT1" != "$FRONT0" ] && LANDED=1
  if [ "$LANDED" = 0 ] && [ "$DIFF" != "n/a" ]; then
    if python3 -c "import sys; sys.exit(0 if float('$DIFF') >= float('$DIFF_MIN') else 1)"; then
      LANDED=1
    fi
  fi
  if [ "$LANDED" = 1 ]; then
    echo "OK hid_landed（前台变化或画面变化可证）"
  else
    echo "CLASS=TOUCH_SENT_NO_UI_CHANGE"
    echo "FAIL hid_no_effect：注入报成功但前台与画面都没变"
    if grep -q 'TARGET_LOOKS_LIKE=wallpaper_or_flat' "$OUT/target_probe.txt" 2>/dev/null; then
      echo "  注意：该坐标邻域近乎纯色，多半是壁纸空白处 —— 这是找色/点位问题，不是 HID 问题。"
      echo "  先跑 '$0 $TAG' 勘察可点点位，不要据此判 HID 故障。"
    fi
    OK=0
  fi
  [ "${FC_N:-0}" = "1" ] || { echo "FAIL fc_n=${FC_N:-?}"; OK=0; }
  [ "${ACTIVE:-1}" = "0" ] || { echo "FAIL active_residual"; OK=0; }
  [ "${KEEP_AFTER:-1}" = "0" ] || { echo "FAIL keep_after_stop"; OK=0; }
  [ "${ZOMBIE:-1}" = "0" ] || { echo "FAIL zombie_probe"; OK=0; }
  if [ "$OK" = 1 ]; then
    echo "CLASS=BUSINESS_PASS"
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
} | tee "$OUT/VERDICT.md"

PKG=$(ssh_r "dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\\([^ ]*\\).*/\\1/p'" | tr -d '\r')
RID="touch_${TAG}_$(date +%s)"
{
  echo "run_id=$RID"
  echo "host=.$TAG"
  echo "pkg=$PKG"
  echo "target=$X,$Y"
  echo "front0=$FRONT0"
  echo "front1=$FRONT1"
  echo "FC_N=${FC_N:-}"
  echo "ACTIVE=${ACTIVE:-}"
  echo "KEEP_AFTER_STOP=${KEEP_AFTER:-}"
  cat "$OUT/VERDICT.md"
  echo "final=1"
} >"$OUT/device_final.txt"
ssh_r "mkdir -p /private/var/mobile/Media/ZiYan/verdicts" >/dev/null 2>&1 || true
scp_r "$OUT/device_final.txt" "/private/var/mobile/Media/ZiYan/verdicts/${RID}.txt" || true
echo "OUT=$OUT DEVICE_FINAL=$RID"
grep -q 'VERDICT=PASS' "$OUT/VERDICT.md"
