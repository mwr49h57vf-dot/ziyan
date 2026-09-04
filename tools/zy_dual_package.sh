#!/usr/bin/env bash
# 8-161-74：一键打 rootful + rootless 双包（兼容 iPhone7 / iPhone8Plus）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export THEOS="${THEOS:-$HOME/theos}"
CONTROL_FILE="$ROOT/control"
CONTROL_BACKUP="$(mktemp "${TMPDIR:-/tmp}/ziyan-control.XXXXXX")"
ROOTFUL_STASH=""
cp -p "$CONTROL_FILE" "$CONTROL_BACKUP"

restore_control() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [ -f "$CONTROL_BACKUP" ]; then
    mv -f "$CONTROL_BACKUP" "$CONTROL_FILE"
  fi
  [ -n "$ROOTFUL_STASH" ] && rm -f "$ROOTFUL_STASH"
  exit "$rc"
}
trap restore_control EXIT HUP INT TERM

set_control_arch() {
  local arch="$1"
  python3 - "$CONTROL_FILE" "$arch" <<'PY'
import os
import re
import sys

path, arch = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    original = fh.read()
updated, count = re.subn(
    r"^Architecture:\s*\S+\s*$",
    f"Architecture: iphoneos-{arch}",
    original,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit(f"FAIL: expected one Architecture line in {path}, got {count}")
tmp = path + ".ziyan-arch-tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(updated)
os.replace(tmp, path)
PY
}

verify_deb_control() {
  local deb="$1" want_arch="$2"
  local ctl got_arch got_ver
  ctl=$(ar t "$deb" | grep '^control\.tar' | sed -n '1p')
  [ -n "$ctl" ] || { echo "FAIL: no control archive in $deb" >&2; return 2; }
  got_arch=$(ar p "$deb" "$ctl" | tar -xOf - ./control 2>/dev/null |
    sed -n 's/^Architecture: //p' | sed -n '1p')
  got_ver=$(ar p "$deb" "$ctl" | tar -xOf - ./control 2>/dev/null |
    sed -n 's/^Version: //p' | sed -n '1p')
  case "$got_ver" in
    "$(sed -n 's/^Version: //p' "$ROOT/control" | sed -n '1p')"|"$(sed -n 's/^Version: //p' "$ROOT/control" | sed -n '1p')"-*) ;;
    *) echo "FAIL: stale package Version=$got_ver deb=$deb" >&2; return 2 ;;
  esac
  [ "$got_arch" = "iphoneos-${want_arch}" ] || {
    echo "FAIL: package Architecture=$got_arch want=iphoneos-${want_arch} deb=$deb" >&2
    return 2
  }
  echo "PASS: control Version=$got_ver Architecture=$got_arch"
}

rewrite_deb_control_arch() {
  local deb="$1" want_arch="$2" ctl tmp
  ctl=$(ar t "$deb" | grep '^control\.tar' | sed -n '1p')
  [ -n "$ctl" ] || { echo "FAIL: no control archive in $deb" >&2; return 2; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ziyan-control-rewrite.XXXXXX")
  case "$tmp" in
    "${TMPDIR:-/tmp}"/ziyan-control-rewrite.*) ;;
    *) echo "FAIL: unsafe temporary directory: $tmp" >&2; return 2 ;;
  esac
  if ! ar p "$deb" "$ctl" | /usr/bin/bsdtar -xf - -C "$tmp"; then
    rm -rf -- "$tmp"
    echo "FAIL: cannot extract control archive from $deb" >&2
    return 2
  fi
  python3 - "$tmp/control" "$want_arch" <<'PY'
import os
import re
import sys

path, arch = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    original = fh.read()
updated, count = re.subn(
    r"^Architecture:\s*\S+\s*$",
    f"Architecture: iphoneos-{arch}",
    original,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit(f"FAIL: expected one Architecture line in {path}, got {count}")
staged = path + ".tmp"
with open(staged, "w", encoding="utf-8") as fh:
    fh.write(updated)
os.replace(staged, path)
PY
  if ! /usr/bin/bsdtar -czf "$tmp/$ctl" -C "$tmp" ./control ./postinst ./preinst ./prerm 2>/dev/null; then
    rm -rf -- "$tmp"
    echo "FAIL: cannot repack control archive from $deb" >&2
    return 2
  fi
  ar r "$deb" "$tmp/$ctl"
  rm -rf -- "$tmp"
}

verify_apptouch_filter_file() {
  local plist="$1"
  [ -s "$plist" ] || { echo "FAIL: missing ZiYanAppTouch filter: $plist" >&2; return 2; }
  plutil -lint "$plist" >/dev/null || {
    echo "FAIL: invalid ZiYanAppTouch plist: $plist" >&2
    return 2
  }
	if ! /usr/libexec/PlistBuddy -c 'Print :Filter:Classes' "$plist" 2>/dev/null |
		grep -Fq 'UIApplication'; then
		echo "FAIL: ZiYanAppTouch plist must match UIApplication class: $plist" >&2
		return 2
	fi
	if /usr/libexec/PlistBuddy -c 'Print :Filter:Bundles' "$plist" 2>/dev/null; then
		echo "FAIL: ZiYanAppTouch plist must not use a framework Bundle filter: $plist" >&2
		return 2
	fi
  if grep -Eq 'com\.(xztl\.ios|ychj\.hlhjlygr|zsyxs180\.game|ljzbbadao\.game|ownbook\.notes)' "$plist"; then
    echo "FAIL: ZiYanAppTouch plist retains a product game Bundle allowlist: $plist" >&2
    return 2
  fi
  if grep -Fq '<key>clang_version</key>' "$plist"; then
    echo "FAIL: ZiYanAppTouch plist is clang static-analyzer output: $plist" >&2
    return 2
  fi
}

verify_deb_apptouch_filter() {
  local deb="$1" tmp plist data_archive
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ziyan-apptouch-check.XXXXXX")
  case "$tmp" in
    "${TMPDIR:-/tmp}"/ziyan-apptouch-check.*) ;;
    *) echo "FAIL: unsafe temp path: $tmp" >&2; return 2 ;;
  esac
  data_archive=$(ar t "$deb" | grep '^data\.tar' | sed -n '1p')
  if [ -z "$data_archive" ]; then
    rm -rf -- "$tmp"
    echo "FAIL: no data archive in package: $deb" >&2
    return 2
  fi
  if ! ar p "$deb" "$data_archive" | /usr/bin/bsdtar -xf - -C "$tmp"; then
    rm -rf -- "$tmp"
    echo "FAIL: cannot extract package for AppTouch validation: $deb" >&2
    return 2
  fi
  plist=$(find "$tmp" -type f \
    -path '*/Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.plist' \
    -print -quit)
  if ! verify_apptouch_filter_file "$plist"; then
    rm -rf -- "$tmp"
    return 2
  fi
  echo "PASS: deb AppTouch UIKit bundle filter with runtime exclusions: $(basename "$plist")"
  rm -rf -- "$tmp"
}

verify_deb_runtime_payload() {
  local deb="$1" want_path="$2" data_archive
  data_archive=$(ar t "$deb" | grep '^data\.tar' | sed -n '1p')
  [ -n "$data_archive" ] || {
    echo "FAIL: no data archive for runtime payload validation: $deb" >&2
    return 2
  }
  if ! ar p "$deb" "$data_archive" | /usr/bin/bsdtar -tf - 2>/dev/null |
      grep -Fxq "$want_path"; then
    echo "FAIL: missing runtime entry $want_path in $deb" >&2
    return 2
  fi
  echo "PASS: runtime payload $want_path"
}

verify_deb_install_lifecycle() {
  local deb="$1" ctl tmp
  ctl=$(ar t "$deb" | grep '^control\.tar' | sed -n '1p')
  [ -n "$ctl" ] || { echo "FAIL: no control archive for lifecycle validation: $deb" >&2; return 2; }
  tmp=$(mktemp -d)
  if ! ar p "$deb" "$ctl" | /usr/bin/bsdtar -xf - -C "$tmp"; then
    rm -rf -- "$tmp"
    echo "FAIL: cannot extract control archive for lifecycle validation: $deb" >&2
    return 2
  fi
  python3 "$ROOT/tools/test_package_install_lifecycle_contract.py" --debian-dir "$tmp"
  local rc=$?
  rm -rf -- "$tmp"
  return "$rc"
}

echo "[ZiYan] dual-package: rootful then rootless"
verify_apptouch_filter_file "$ROOT/ZiYanAppTouch.plist"
python3 "$ROOT/tools/test_package_install_lifecycle_contract.py"
make -f Makefile clean-user-bins
echo "[ZiYan] === rootful (iphoneos-arm) ==="
set_control_arch arm
THEOS_PACKAGE_SCHEME= make -f Makefile clean
# Theos does not remove an earlier rootless remap from the shared staging tree.
# A rootful package must never inherit var/jb runtime files from the prior run.
rm -rf "$ROOT/.theos/_/var/jb"
THEOS_PACKAGE_SCHEME= make -f Makefile all
THEOS_PACKAGE_SCHEME= make -f Makefile package
DEB32=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm.deb | sed -n '1p')
rewrite_deb_control_arch "$DEB32" arm
verify_deb_control "$DEB32" arm
verify_deb_apptouch_filter "$DEB32"
verify_deb_runtime_payload "$DEB32" "usr/lib/ziyan/lib/lua/ziyan_run.lua"
verify_deb_runtime_payload "$DEB32" "usr/lib/ziyan/bin/ziyan_runtime_root.sh"
verify_deb_install_lifecycle "$DEB32"
# The rootless clean target clears the shared packages directory. Preserve the
# validated rootful artifact while producing the rootless package.
ROOTFUL_STASH="$(mktemp "${TMPDIR:-/tmp}/ziyan-rootful-package.XXXXXX")"
cp -p "$DEB32" "$ROOTFUL_STASH"
echo "[ZiYan] === rootless (iphoneos-arm64) ==="
set_control_arch arm64
THEOS_PACKAGE_SCHEME=rootless make -f Makefile clean
THEOS_PACKAGE_SCHEME=rootless make -f Makefile all
# 当前 Theos 的 rootless deb remap 目标不会自行 mkdir，缺目录会静默产出
# rootful 路径的伪 arm64 包；先建目标并让 install_name 校验兜底。
mkdir -p "$ROOT/.theos/_tmp/var/jb"
THEOS_PACKAGE_SCHEME=rootless make -f Makefile package
DEB64=$(ls -t packages/com.ziyan.ziyan_*_iphoneos-arm64.deb | sed -n '1p')
rewrite_deb_control_arch "$DEB64" arm64
verify_deb_control "$DEB64" arm64
verify_deb_apptouch_filter "$DEB64"
verify_deb_runtime_payload "$DEB64" "var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua"
verify_deb_runtime_payload "$DEB64" "var/jb/usr/lib/ziyan/bin/ziyan_runtime_root.sh"
verify_deb_install_lifecycle "$DEB64"
bash tools/verify_package_install_names.sh "$DEB64"
cp -p "$ROOTFUL_STASH" "$DEB32"
rm -f "$ROOTFUL_STASH"
ROOTFUL_STASH=""
echo "[ZiYan] dual-package OK:"
ls -t packages/com.ziyan.ziyan_*.deb | sed -n '1,4p'
