#!/bin/bash
# 启动「子砚自动化研发状态控制台」实时窗口（本地网页）
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/tools/ziyan_rd_console"
export ZIYAN_RD_HOST="${ZIYAN_RD_HOST:-192.168.31.53}"
export ZIYAN_RD_USER="${ZIYAN_RD_USER:-mobile}"
export ZIYAN_RD_PASS="${ZIYAN_RD_PASS:-alpine}"
export ZIYAN_RD_PORT="${ZIYAN_RD_PORT:-8765}"
cd "$ROOT"
# 若旧进程占用端口则结束
if lsof -nP -iTCP:"$ZIYAN_RD_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[ZiYan] port $ZIYAN_RD_PORT busy → kill old console"
  lsof -nP -iTCP:"$ZIYAN_RD_PORT" -sTCP:LISTEN -t 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 0.5
fi
exec /usr/bin/env python3 "$DIR/server.py"
