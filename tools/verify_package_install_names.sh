#!/usr/bin/env bash
# verify_package_install_names.sh — 打包后门禁：rootless deb 的 tweak install_name 必须含 /var/jb
# 用法：tools/verify_package_install_names.sh [path/to.deb]
# 失败退出码 2（禁止交付错误 rootless 包）
set -euo pipefail
DEB="${1:-}"
if [[ -z "$DEB" ]]; then
  DEB=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)
fi
if [[ -z "$DEB" || ! -f "$DEB" ]]; then
  echo "FAIL: no arm64 deb given/found" >&2
  exit 2
fi
DEB="$(cd "$(dirname "$DEB")" && pwd)/$(basename "$DEB")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
ar x "$DEB"
tar xf data.tar.lzma 2>/dev/null || tar xf data.tar.gz 2>/dev/null || tar xf data.tar.xz 2>/dev/null || tar xf data.tar
FAIL=0
while IFS= read -r -d '' dy; do
  base=$(basename "$dy")
  # 只强制校验 SpringBoard 主 tweak；其它可用 @rpath
  if [[ "$base" != "ZiYanVol.dylib" ]]; then
    continue
  fi
  name=$(otool -D "$dy" 2>/dev/null | tail -1 | tr -d '[:space:]')
  echo "CHECK $base install_name=$name"
  if [[ "$name" != /var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib ]]; then
    echo "FAIL: ZiYanVol install_name must be /var/jb/Library/... (got: $name)" >&2
    echo "HINT: THEOS_PACKAGE_SCHEME=rootless make clean package  （禁止 rootful 后不 clean 直接打 rootless）" >&2
    FAIL=1
  fi
  case "$dy" in
    */var/jb/Library/MobileSubstrate/*) ;;
    *)
      echo "FAIL: staged path missing /var/jb: $dy" >&2
      FAIL=1
      ;;
  esac
done < <(find . -name 'ZiYanVol.dylib' -print0)
if [[ $FAIL -ne 0 ]]; then
  exit 2
fi
echo "PASS: $DEB ZiYanVol install_name OK"
