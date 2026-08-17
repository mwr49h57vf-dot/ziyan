#!/usr/bin/env bash
# IOMFB 逐层取证：桌面 / App 前台两种场景各采一组
# 用法：bash tools/zy_iomfb_layer_diag.sh <53|101|112|166> [bundle_id]
#
# 现有取帧在 layer 0..7 里取「第一个非空层」且从不校验内容
# （objc/shared/ZiYanFrameCapture.m 的 ZiYanCaptureViaIOMobileFB）。
# 本脚本把每层落成 PNG 并记录几何/格式，用来回答：取错层？行距/平面误读？
# 还是表面本身压缩/tiled？——不靠猜。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
TAG="${1:-}"
BID="${2:-}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/IOMFB_DIAG_${STAMP}_${TAG}"

case "$TAG" in
  53) IP=192.168.31.53; SCHEME=rootless ;;
  101) IP=192.168.31.101; SCHEME=rootful ;;
  112) IP=192.168.31.112; SCHEME=rootful ;;
  166) IP=192.168.31.166; SCHEME=rootful ;;
  *) echo "usage: $0 <53|101|112|166> [bundle_id]"; exit 2 ;;
esac
mkdir -p "$OUT"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)
ssh_r() {
  local i
  for i in 1 2 3; do
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$IP" "$@" && return 0
    sleep $((i * 2))
  done
  return 1
}

if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var; B=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var; B=/usr/lib/ziyan/bin
fi
M=/private/var/mobile/Media/ZiYan

if [ -z "$BID" ]; then
  BID=$(ssh_r "uicache -l 2>/dev/null" | awk -F' : ' '{print $1}' \
        | grep -vE '^(com\.apple\.|com\.saurik\.|com\.ziyan\.|kjc\.|$)' | head -1 | tr -d '\r')
fi
echo "META tag=$TAG scheme=$SCHEME bid=$BID out=$OUT"

# 带受限 entitlements（IOMobileFramebufferUserClient）的二进制若不在信任缓存里会被
# amfid 直接 Killed: 9。dpkg 装包那条路会过，但为了能单推二进制快速迭代，这里用
# 设备上的 ldid 拿 framecap 的 entitlements 重签一次——两者需要的权限完全相同。
resign() {
  ssh_r "set +e; ldid -e '$B/ziyan_framecap' >/tmp/zy_fc_ent.plist 2>/dev/null; \
         [ -s /tmp/zy_fc_ent.plist ] && ldid -S/tmp/zy_fc_ent.plist '$B/ziyan_iomfb_diag' \
         && echo RESIGN_OK || echo RESIGN_SKIP" 2>/dev/null || true
}

collect() {  # collect <场景名>
  local scene="$1"
  local rd="/tmp/iomfb_${scene}"
  ssh_r "rm -rf '$rd'; '$B/ziyan_iomfb_diag' '$rd' >/dev/null 2>&1; \
         ls '$rd' 2>/dev/null | tr '\n' ' '; echo" || true
  mkdir -p "$OUT/$scene"
  # 二进制走 base64，越狱机 scp 偶发静默半失败
  ssh_r "cd '$rd' 2>/dev/null && tar cf - . 2>/dev/null | base64" \
    | base64 -D 2>/dev/null | tar xf - -C "$OUT/$scene" 2>/dev/null || \
    echo "WARN pull_failed scene=$scene"
  echo "---- $scene ----"
  cat "$OUT/$scene/REPORT.txt" 2>/dev/null || echo "（无 REPORT）"
}

echo "RESIGN=$(resign)"

echo "==== 场景一：桌面 ===="
ssh_r "set +e; echo 1 >'$V/.ziyan_go_home'; chmod 666 '$V/.ziyan_go_home' 2>/dev/null; \
       sleep 2; rm -f '$V/.ziyan_go_home'" >/dev/null 2>&1 || true
sleep 3
echo "front=$(ssh_r "tr -d '\r\n' <'$V/.ziyan_front_bid' 2>/dev/null" || true)"
collect home

echo "==== 场景二：App 前台（$BID）===="
ssh_r "set +e; rm -f '$V/.ziyan_app_user_closed'; \
       printf '%s\n' '$BID' >'$V/.ziyan_open_app'; \
       printf '%s\n' '$BID' >'$M/.ziyan_open_app'; \
       chmod 666 '$V/.ziyan_open_app' '$M/.ziyan_open_app' 2>/dev/null" >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 15 ]; do
  F=$(ssh_r "tr -d '\r\n' <'$V/.ziyan_front_bid' 2>/dev/null" 2>/dev/null || true)
  [ "$F" = "$BID" ] && break
  sleep 1; i=$((i + 1))
done
echo "front=$(ssh_r "tr -d '\r\n' <'$V/.ziyan_front_bid' 2>/dev/null" || true)"
sleep 2
collect app

echo "OUT=$OUT"
ls -R "$OUT" | head -40
