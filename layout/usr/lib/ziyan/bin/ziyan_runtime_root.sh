#!/bin/sh
# Source-only runtime scheme resolver. postinst writes the marker from the
# installed deb Architecture; `/var/jb` may exist on a rootful device.

ZIYAN_RUNTIME_SCHEME_MARKER="/var/mobile/Library/Preferences/com.ziyan.ziyan.runtime_scheme"
ZIYAN_RUNTIME_SCHEME=""
if [ -r "$ZIYAN_RUNTIME_SCHEME_MARKER" ]; then
  IFS= read -r ZIYAN_RUNTIME_SCHEME <"$ZIYAN_RUNTIME_SCHEME_MARKER" || true
fi

case "$ZIYAN_RUNTIME_SCHEME" in
  rootless) ZIYAN_RUNTIME_ROOT="/var/jb/usr/lib/ziyan" ;;
  rootful) ZIYAN_RUNTIME_ROOT="/usr/lib/ziyan" ;;
  *)
    # Legacy fallback before a marker exists. A newly installed package always
    # has one, so the ambiguous dual-tree case never reaches this branch.
    if [ -f /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua ] &&
       [ ! -f /usr/lib/ziyan/lib/lua/ziyan_run.lua ]; then
      ZIYAN_RUNTIME_SCHEME="rootless"
      ZIYAN_RUNTIME_ROOT="/var/jb/usr/lib/ziyan"
    else
      ZIYAN_RUNTIME_SCHEME="rootful"
      ZIYAN_RUNTIME_ROOT="/usr/lib/ziyan"
    fi
    ;;
esac
export ZIYAN_RUNTIME_SCHEME ZIYAN_RUNTIME_ROOT
