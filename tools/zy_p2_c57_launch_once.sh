#!/bin/bash
set -eu

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LABEL="${1:-com.ziyan.p2c57.$(date +%Y%m%d%H%M%S)}"
OUT="${2:-$ROOT/tmp_shots/P2_30M_C57_$(date +%Y%m%d_%H%M%S)}"
RUNNER="$SCRIPT_DIR/zy_p2_c57_30m_detached.sh"

case "$LABEL" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: invalid launchctl label: $LABEL" >&2
    exit 2
    ;;
esac

if test ! -x "$RUNNER"; then
  echo "ERROR: runner is missing or not executable: $RUNNER" >&2
  exit 2
fi

mkdir -p "$OUT"
if launchctl list "$LABEL" >/dev/null 2>&1; then
  echo "ERROR: launchctl label already exists: $LABEL" >&2
  exit 2
fi

launchctl submit -l "$LABEL" \
  -o "$OUT/launchctl.stdout.log" \
  -e "$OUT/launchctl.stderr.log" \
  -- "$RUNNER" "$OUT" "$LABEL"

echo "LABEL=$LABEL"
echo "OUT=$OUT"
echo "SAMPLES=$OUT/SAMPLES.txt"
echo "SUMMARY=$OUT/SUMMARY.txt"
echo "The runner removes this launchctl label only after evidence is committed."
