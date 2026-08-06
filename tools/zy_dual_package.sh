#!/usr/bin/env bash
# 8-161-74：一键打 rootful + rootless 双包（兼容 iPhone7 / iPhone8Plus）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export THEOS="${THEOS:-$HOME/theos}"
echo "[ZiYan] dual-package: rootful then rootless"
make -f Makefile clean-user-bins
echo "[ZiYan] === rootful (iphoneos-arm) ==="
THEOS_PACKAGE_SCHEME= make -f Makefile clean
THEOS_PACKAGE_SCHEME= make -f Makefile all
THEOS_PACKAGE_SCHEME= make -f Makefile package
echo "[ZiYan] === rootless (iphoneos-arm64) ==="
THEOS_PACKAGE_SCHEME=rootless make -f Makefile clean
THEOS_PACKAGE_SCHEME=rootless make -f Makefile all
# 当前 Theos 的 rootless deb remap 目标不会自行 mkdir，缺目录会静默产出
# rootful 路径的伪 arm64 包；先建目标并让 install_name 校验兜底。
mkdir -p "$ROOT/.theos/_tmp/var/jb"
THEOS_PACKAGE_SCHEME=rootless make -f Makefile package
DEB64=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb | head -1)
bash tools/verify_package_install_names.sh "$DEB64"
echo "[ZiYan] dual-package OK:"
ls -t packages/com.ziyan.ziyan_*.deb | head -4
