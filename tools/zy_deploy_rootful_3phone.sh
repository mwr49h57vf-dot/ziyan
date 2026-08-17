#!/usr/bin/env bash
# Deploy a rootful package only to .101/.112/.166 and retain a per-device rollback snapshot.
# Current safe default is .101; expansion to .112/.166 must be explicit after gates pass.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=zy_guard_no_auto_respring.sh
. "$ROOT/tools/zy_guard_no_auto_respring.sh"
zy_guard_block_unless_manual "$@"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
DEB="${ZY_DEPLOY_DEB:-$(ls -t "$ROOT"/packages/com.ziyan.ziyan_*+debug_iphoneos-arm.deb 2>/dev/null | head -1)}"
FRAMECAP_ENT="$ROOT/tools/ziyan_framecap/entitlements.plist"
EXPECTED_SHA="${ZY_DEPLOY_EXPECTED_SHA:-}"
EXPECTED_VERSION="${ZY_DEPLOY_EXPECTED_VERSION:-}"
REMOTE_DEB="/var/mobile/Media/ziyan_deploy_${STAMP}.deb"

[ -n "${DEB:-}" ] && [ -f "$DEB" ] || { echo "FAIL: rootful debug deb not found" >&2; exit 2; }
[ -s "$FRAMECAP_ENT" ] || { echo "FAIL: framecap entitlements not found: $FRAMECAP_ENT" >&2; exit 2; }
case "$DEB" in *_iphoneos-arm.deb) ;; *) echo "FAIL: refusing non-rootful package: $DEB" >&2; exit 2 ;; esac
case "$EXPECTED_SHA" in ''|*[!0-9a-fA-F]*)
  [ -z "$EXPECTED_SHA" ] || { echo "FAIL: invalid ZY_DEPLOY_EXPECTED_SHA" >&2; exit 2; }
  ;;
esac
case "$EXPECTED_VERSION" in *[!A-Za-z0-9.+~:_-]*)
  echo "FAIL: invalid ZY_DEPLOY_EXPECTED_VERSION" >&2; exit 2 ;;
esac

HOSTS=()
for host in "$@"; do
  [ "$host" = "--allow-manual-respring" ] && continue
  HOSTS+=("$host")
done
[ "${#HOSTS[@]}" -eq 0 ] && HOSTS=(101)
for host in "${HOSTS[@]}"; do
  case "$host" in 101|112|166) ;; *) echo "FAIL: forbidden host .$host (allowed: 101 112 166)" >&2; exit 2 ;; esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$1" "${@:2}"; }
scp_r() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$1" "root@192.168.31.$2:$3"; }

LOCAL_SHA="$(shasum -a 256 "$DEB" | awk '{print $1}')"
[ -z "$EXPECTED_SHA" ] || [ "$LOCAL_SHA" = "$EXPECTED_SHA" ] || {
  echo "FAIL: local deb SHA mismatch: got=$LOCAL_SHA expected=$EXPECTED_SHA" >&2
  exit 2
}
echo "DEB=$DEB"
echo "SHA256=$LOCAL_SHA"
echo "EXPECTED_VERSION=${EXPECTED_VERSION:-not_enforced}"

for host in "${HOSTS[@]}"; do
  echo "== .$host: preflight + rollback snapshot =="
  ssh_r "$host" "bash -s" <<REMOTE
set -eu
test -d /Library/MobileSubstrate/DynamicLibraries
VER=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p' | head -1 || true)
[ -n "\$VER" ] || VER=unknown
SAFE_VER=\$(printf '%s' "\$VER" | tr -cs 'A-Za-z0-9._-' '_')
ROLL=/var/mobile/Media/ZiYan/rollback/pre_\${SAFE_VER}_${STAMP}
mkdir -p "\$ROLL"
printf 'version=%s\\ninstalled_at=%s\\n' "\$VER" "\$(date '+%Y-%m-%d %H:%M:%S %z')" > "\$ROLL/manifest.txt"
for f in /Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib /Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist /Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib /Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.plist /Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.dylib /Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.plist /Library/MobileSubstrate/DynamicLibraries/ZiYanBBFrame.dylib /Library/MobileSubstrate/DynamicLibraries/ZiYanBBFrame.plist /usr/lib/ziyan/bin/ziyan_framecap /usr/lib/ziyan/bin/ziyan_framecap_bootstrap /usr/lib/ziyan/bin/ziyan_iomfb_diag /usr/lib/ziyan/bin/ziyan_framecap_wrap.sh /usr/lib/ziyan/bin/ziyan_zydaemond.sh; do
  [ -f "\$f" ] && cp -p "\$f" "\$ROLL/"
done
(md5sum "\$ROLL"/* 2>/dev/null || true) > "\$ROLL/md5.txt"
df -k /private/var | tail -1
printf 'rollback=%s\\n' "\$ROLL"
REMOTE

  echo "== .$host: upload + install =="
  scp_r "$DEB" "$host" "$REMOTE_DEB"
  scp_r "$FRAMECAP_ENT" "$host" /var/mobile/Media/ziyan_framecap_entitlements.plist
  ssh_r "$host" "bash -s" <<REMOTE
set -eu
dpkg -i "$REMOTE_DEB"
# Theos 对 staging 产物的签名不能替代对设备最终 inode 的验证。
# C57 曾因手工覆盖后最终文件未签名，在 ObjC 初始化前直接 RC137。
# 每次 dpkg 安装后都在最终路径重签，失败则禁止重启 SB/扩散测试。
command -v ldid >/dev/null 2>&1
test -s /var/mobile/Media/ziyan_framecap_entitlements.plist
test -x /usr/lib/ziyan/bin/ziyan_framecap
ldid -S/var/mobile/Media/ziyan_framecap_entitlements.plist /usr/lib/ziyan/bin/ziyan_framecap
ldid -e /usr/lib/ziyan/bin/ziyan_framecap >/var/mobile/Media/ziyan_framecap_installed_entitlements.plist
grep -q 'platform-application' /var/mobile/Media/ziyan_framecap_installed_entitlements.plist
chmod 755 /usr/lib/ziyan/bin/ziyan_framecap
INSTALLED_VERSION=\$(dpkg -s com.ziyan.ziyan | sed -n 's/^Version: //p' | head -1)
printf 'version=%s\n' "\$INSTALLED_VERSION"
if [ -n "$EXPECTED_VERSION" ] && [ "\$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]; then
  echo "FAIL: installed version mismatch" >&2
  exit 13
fi
printf 'framecap_sha256='; sha256sum /usr/lib/ziyan/bin/ziyan_framecap
printf 'springboard_before='; pgrep -x SpringBoard | head -1 || true
if [ "${ZY_ALLOW_MANUAL_RESPRING:-0}" = 1 ]; then
  ( sleep 1; sbreload >/dev/null 2>&1 || killall -9 SpringBoard >/dev/null 2>&1 || true ) >/dev/null 2>&1 &
else
  echo BLOCKED_AUTO_SB_RESTART
  exit 78
fi
REMOTE
done

echo "== wait for SpringBoard reload =="
sleep 20
for host in "${HOSTS[@]}"; do
  echo "== .$host: post-install readback =="
  if ! ssh_r "$host" "bash -s" <<'REMOTE'
set +e
V=/usr/lib/ziyan/var
dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: /version=/p'
SB_PID=$(ps -axo pid=,args= 2>/dev/null | grep '[S]pringBoard.app/SpringBoard' | head -1 | sed 's/^ *//' | cut -d' ' -f1)
echo "springboard_pid=${SB_PID:-none}"
md5sum /Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib /Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib /usr/lib/ziyan/bin/ziyan_framecap 2>/dev/null

# 测试机均无锁屏密码。显式 unlock_req 为避免空闲残留误解锁，要求一个真实
# session 标记；部署后尚未启动业务时临时建立 test session，收到回执后立刻清理。
TEST_MARKER_CREATED=0
if [ ! -e "$V/.ziyan_project_active" ] && [ ! -e "$V/.ziyan_script_session" ]; then
  date +%s >"$V/.ziyan_project_active"
  chmod 666 "$V/.ziyan_project_active" 2>/dev/null
  TEST_MARKER_CREATED=1
fi
rm -f "$V/.ziyan_unlock_rep"
echo 1 >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
UNLOCK=timeout
for i in $(seq 1 30); do
  if [ -s "$V/.ziyan_unlock_rep" ]; then
    if head -1 "$V/.ziyan_unlock_rep" | grep -q '^ok$'; then
      UNLOCK=ok
    else
      UNLOCK=err
    fi
    break
  fi
  sleep 0.5
done
[ "$TEST_MARKER_CREATED" = 1 ] && rm -f "$V/.ziyan_project_active"
rm -f "$V/.ziyan_unlock_req"
LOCK_STATE=$(tr -d '\r\n' <"$V/.ziyan_display_locked" 2>/dev/null)
if [ "$LOCK_STATE" != 0 ] && [ "$LOCK_STATE" != 1 ]; then
  LOCK_STATE=$(tr -d '\r\n' <"$V/.ziyan_lock_state" 2>/dev/null)
fi
FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
echo "unlock_status=$UNLOCK display_locked=${LOCK_STATE:-unknown} front=${FRONT:-unknown}"
[ "$UNLOCK" = ok ] || exit 12
REMOTE
  then
    echo "WARN: .$host post-install/unlock failed" >&2
    continue
  fi
done
echo "DEPLOY_DONE stamp=$STAMP hosts=${HOSTS[*]}"
