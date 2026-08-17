#!/usr/bin/env bash
# 8-161-74：一键打 rootful + rootless 双包（兼容 iPhone7 / iPhone8Plus）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export THEOS="${THEOS:-$HOME/theos}"

verify_deb_control() {
  local deb="$1" want_arch="$2"
  local ctl got_arch got_ver
  ctl=$(ar t "$deb" | grep '^control\.tar' | head -1)
  [ -n "$ctl" ] || { echo "FAIL: no control archive in $deb" >&2; return 2; }
  got_arch=$(ar p "$deb" "$ctl" | tar -xOf - ./control 2>/dev/null |
    sed -n 's/^Architecture: //p' | head -1)
  got_ver=$(ar p "$deb" "$ctl" | tar -xOf - ./control 2>/dev/null |
    sed -n 's/^Version: //p' | head -1)
  case "$got_ver" in
    "$(sed -n 's/^Version: //p' "$ROOT/control" | head -1)"|"$(sed -n 's/^Version: //p' "$ROOT/control" | head -1)"-*) ;;
    *) echo "FAIL: stale package Version=$got_ver deb=$deb" >&2; return 2 ;;
  esac
  [ "$got_arch" = "iphoneos-${want_arch}" ] || {
    echo "FAIL: package Architecture=$got_arch want=iphoneos-${want_arch} deb=$deb" >&2
    return 2
  }
  echo "PASS: control Version=$got_ver Architecture=$got_arch"
}

verify_apptouch_filter_file() {
  local plist="$1"
  [ -s "$plist" ] || { echo "FAIL: missing ZiYanAppTouch filter: $plist" >&2; return 2; }
  plutil -lint "$plist" >/dev/null || {
    echo "FAIL: invalid ZiYanAppTouch plist: $plist" >&2
    return 2
  }
  /usr/libexec/PlistBuddy -c 'Print :Filter:Bundles' "$plist" 2>/dev/null |
    grep -Fq 'com.xztl.ios' || {
      echo "FAIL: ZiYanAppTouch plist has no com.xztl.ios Filter: $plist" >&2
      return 2
    }
  if grep -Fq '<key>clang_version</key>' "$plist"; then
    echo "FAIL: ZiYanAppTouch plist is clang static-analyzer output: $plist" >&2
    return 2
  fi
}

verify_deb_apptouch_filter() {
  local deb="$1" tmp plist data_archive
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ziyan-apptouch-check.XXXXXX")
  case "$tmp" in
    "${TMPDIR:-/tmp}"/ziyan-apptouch-check.*) ;;
    *) echo "FAIL: unsafe temp path: $tmp" >&2; return 2 ;;
  esac
  data_archive=$(ar t "$deb" | grep '^data\.tar' | head -1)
  if [ -z "$data_archive" ]; then
    rm -rf -- "$tmp"
    echo "FAIL: no data archive in package: $deb" >&2
    return 2
  fi
  if ! ar p "$deb" "$data_archive" | /usr/bin/bsdtar -xf - -C "$tmp"; then
    rm -rf -- "$tmp"
    echo "FAIL: cannot extract package for AppTouch validation: $deb" >&2
    return 2
  fi
  plist=$(find "$tmp" -type f \
    -path '*/Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.plist' \
    -print -quit)
  if ! verify_apptouch_filter_file "$plist"; then
    rm -rf -- "$tmp"
    return 2
  fi
  echo "PASS: deb AppTouch Filter=$(basename "$plist") bundle=com.xztl.ios"
  rm -rf -- "$tmp"
}

echo "[ZiYan] dual-package: rootful then rootless"
verify_apptouch_filter_file "$ROOT/ZiYanAppTouch.plist"
make -f Makefile clean-user-bins
echo "[ZiYan] === rootful (iphoneos-arm) ==="
THEOS_PACKAGE_SCHEME= make -f Makefile clean
THEOS_PACKAGE_SCHEME= make -f Makefile all
THEOS_PACKAGE_SCHEME= make -f Makefile package
DEB32=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm.deb | head -1)
verify_deb_control "$DEB32" arm
verify_deb_apptouch_filter "$DEB32"
echo "[ZiYan] === rootless (iphoneos-arm64) ==="
THEOS_PACKAGE_SCHEME=rootless make -f Makefile clean
THEOS_PACKAGE_SCHEME=rootless make -f Makefile all
# 当前 Theos 的 rootless deb remap 目标不会自行 mkdir，缺目录会静默产出
# rootful 路径的伪 arm64 包；先建目标并让 install_name 校验兜底。
mkdir -p "$ROOT/.theos/_tmp/var/jb"
THEOS_PACKAGE_SCHEME=rootless make -f Makefile package
DEB64=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb | head -1)
verify_deb_control "$DEB64" arm64
verify_deb_apptouch_filter "$DEB64"
bash tools/verify_package_install_names.sh "$DEB64"
echo "[ZiYan] dual-package OK:"
ls -t packages/com.ziyan.ziyan_*.deb | head -4
