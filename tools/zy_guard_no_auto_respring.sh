#!/bin/sh
# Hard block automatic SpringBoard / backboardd restart in local test/deploy scripts.
# Source from a script, then call: zy_guard_block_unless_manual "$@"
#
# Default: print BLOCKED_AUTO_SB_RESTART and exit 78.
# Human override only: --allow-manual-respring  or  ZY_ALLOW_MANUAL_RESPRING=1
# This file must never be executed on device. Do not ship it in the deb.

zy_guard_parse_args() {
  ZY_ALLOW_MANUAL_RESPRING="${ZY_ALLOW_MANUAL_RESPRING:-0}"
  for _zy_a in "$@"; do
    case "$_zy_a" in
      --allow-manual-respring) ZY_ALLOW_MANUAL_RESPRING=1 ;;
    esac
  done
  export ZY_ALLOW_MANUAL_RESPRING
}

zy_guard_block_unless_manual() {
  zy_guard_parse_args "$@"
  if [ "$ZY_ALLOW_MANUAL_RESPRING" != 1 ]; then
    echo "BLOCKED_AUTO_SB_RESTART" >&2
    echo "refused: ${0:-unknown} default path cannot sbreload/ldrestart/killall SpringBoard/backboardd" >&2
    echo "human override only: --allow-manual-respring (do not pass unless explicitly authorized)" >&2
    exit 78
  fi
}

zy_guard_refuse() {
  echo "BLOCKED_AUTO_SB_RESTART" >&2
  echo "blocked: $*" >&2
  exit 78
}

# Local name intercepts. Remote SSH strings are not covered; callers must
# also early-exit or gate those payloads with ZY_ALLOW_MANUAL_RESPRING.
sbreload() {
  [ "${ZY_ALLOW_MANUAL_RESPRING:-0}" = 1 ] || zy_guard_refuse sbreload "$@"
  command sbreload "$@"
}

ldrestart() {
  [ "${ZY_ALLOW_MANUAL_RESPRING:-0}" = 1 ] || zy_guard_refuse ldrestart "$@"
  command ldrestart "$@"
}

killall() {
  for _zy_a in "$@"; do
    case "$_zy_a" in
      SpringBoard|backboardd)
        [ "${ZY_ALLOW_MANUAL_RESPRING:-0}" = 1 ] || zy_guard_refuse killall "$@"
        ;;
    esac
  done
  command killall "$@"
}
