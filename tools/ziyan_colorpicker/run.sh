#!/usr/bin/env bash
# Mac/Linux 启动子砚抓色器 v1.3.4
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" == "--test" || "${1:-}" == "-t" ]]; then
  exec python3 ZiYanColorPicker.py --test
fi
exec python3 ZiYanColorPicker.py "$@"
