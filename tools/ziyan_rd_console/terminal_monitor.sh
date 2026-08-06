#!/bin/bash
# 子砚自动化研发终端状态监控
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export ZIYAN_RD_PASS="${ZIYAN_RD_PASS:-alpine}"
export ZIYAN_RD_TERM_INTERVAL="${ZIYAN_RD_TERM_INTERVAL:-8}"
cd "$ROOT"
# 若已有监控则先结束旧进程
pkill -f 'ziyan_rd_console/terminal_monitor.py' 2>/dev/null || true
sleep 0.3
exec /usr/bin/env python3 "$ROOT/tools/ziyan_rd_console/terminal_monitor.py"
