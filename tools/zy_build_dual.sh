#!/bin/bash
# 加速：分开编 rootful + rootless，避免 dual-package 第二轮打掉 app stage
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export THEOS="${THEOS:-/opt/theos}"

echo "[zy_build_dual] rootful…"
make package FINALPACKAGE=1
RF=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm.deb 2>/dev/null | head -1)
echo "[zy_build_dual] RF=$RF"

echo "[zy_build_dual] rootless…"
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
RL=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb 2>/dev/null | head -1)
echo "[zy_build_dual] RL=$RL"
echo "DONE RF=$RF RL=$RL"
