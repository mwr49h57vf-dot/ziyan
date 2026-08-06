#!/bin/bash
# 阶段2：在 macOS 主机编译并跑 ZiYanFrameShm 自检（不 SSH、不部署真机）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/ziyan_shm_selftest_host"
WORK="${TMPDIR:-/tmp}/ziyan_shm_st_work"
mkdir -p "$(dirname "$OUT")"
rm -rf "$WORK"
clang -fobjc-arc -O0 -g \
  -I"$ROOT/objc/shared" \
  -framework Foundation \
  -o "$OUT" \
  "$ROOT/tools/ziyan_shm_selftest/main.m" \
  "$ROOT/objc/shared/ZiYanFrameShm.m"
"$OUT" "$WORK"
echo "host_bin=$OUT"
