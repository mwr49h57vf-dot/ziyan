#!/usr/bin/env python3
"""Static contract for the dual-package control-architecture lifecycle."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "tools" / "zy_dual_package.sh").read_text(encoding="utf-8")


def require_after(marker: str, required: str) -> None:
    index = SCRIPT.find(marker)
    assert index >= 0, f"missing marker: {marker}"
    assert SCRIPT.find(required, index) >= 0, f"{required} must follow {marker}"


assert 'CONTROL_FILE="$ROOT/control"' in SCRIPT
assert 'trap restore_control EXIT HUP INT TERM' in SCRIPT
assert 'mv -f "$CONTROL_BACKUP" "$CONTROL_FILE"' in SCRIPT
assert "def set_control_arch()" not in SCRIPT
assert "set_control_arch() {" in SCRIPT
assert 'f"Architecture: iphoneos-{arch}"' in SCRIPT
assert "rewrite_deb_control_arch() {" in SCRIPT
assert "verify_deb_runtime_payload() {" in SCRIPT
require_after('echo "[ZiYan] === rootful (iphoneos-arm) ==="', "set_control_arch arm")
require_after('echo "[ZiYan] === rootful (iphoneos-arm) ==="',
              'rm -rf "$ROOT/.theos/_/var/jb"')
require_after('DEB32=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm.deb | sed -n \'1p\')',
              'rewrite_deb_control_arch "$DEB32" arm')
require_after('verify_deb_apptouch_filter "$DEB32"',
              'verify_deb_runtime_payload "$DEB32" "usr/lib/ziyan/lib/lua/ziyan_run.lua"')
require_after('verify_deb_runtime_payload "$DEB32" "usr/lib/ziyan/lib/lua/ziyan_run.lua"',
              'verify_deb_runtime_payload "$DEB32" "usr/lib/ziyan/bin/ziyan_runtime_root.sh"')
require_after('echo "[ZiYan] === rootless (iphoneos-arm64) ==="', "set_control_arch arm64")
require_after('DEB64=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb | sed -n \'1p\')',
              'rewrite_deb_control_arch "$DEB64" arm64')
require_after('verify_deb_apptouch_filter "$DEB64"',
              'verify_deb_runtime_payload "$DEB64" "var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua"')
require_after('verify_deb_runtime_payload "$DEB64" "var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua"',
              'verify_deb_runtime_payload "$DEB64" "var/jb/usr/lib/ziyan/bin/ziyan_runtime_root.sh"')

print("PASS: dual-package normalizes control Architecture and validates scheme runtime payload")
