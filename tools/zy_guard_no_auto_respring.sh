#!/bin/sh
# Centralize the user-authorized, cleanup-first SpringBoard/BackBoard restart
# policy used by local test/deploy scripts.
# Source from a script, then call: zy_guard_block_unless_manual "$@"
# The function name is retained for caller compatibility; it now records
# authorization instead of stopping the workflow.
# This file must never be executed on device. Do not ship it in the deb.

zy_guard_parse_args() {
  ZY_ALLOW_MANUAL_RESPRING="${ZY_ALLOW_MANUAL_RESPRING:-1}"
  for _zy_a in "$@"; do
    case "$_zy_a" in
      --allow-manual-respring) ZY_ALLOW_MANUAL_RESPRING=1 ;;
    esac
  done
  export ZY_ALLOW_MANUAL_RESPRING
}

zy_guard_block_unless_manual() {
  zy_guard_parse_args "$@"
  echo "SB_RESTART_AUTHORIZED cleanup_required=1 unlock_required=1"
}

zy_guard_refuse() {
  echo "SB_RESTART_AUTHORIZED legacy_guard_bypass=$*" >&2
  return 0
}

# Local name intercepts. Remote SSH strings are not covered; callers must
# also early-exit or gate those payloads with ZY_ALLOW_MANUAL_RESPRING.
sbreload() {
  command sbreload "$@"
}

ldrestart() {
  command ldrestart "$@"
}

killall() {
  for _zy_a in "$@"; do
      case "$_zy_a" in
      SpringBoard|backboardd)
        ;;
    esac
  done
  command killall "$@"
}
