#!/usr/bin/env bash
# Final Lua 5.3 runtime package/device verification. No SpringBoard or
# backboardd restart is performed; package postinst explicitly defers reloads.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE_ROOT="$ROOT/tmp_shots/LUA53_ROOTLESS_STATIC_REVERSE_20260908"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${OUT:-$EVIDENCE_ROOT/final_4device_$STAMP}"
ROOTFUL_DEB="${ROOTFUL_DEB:-$ROOT/packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-98+debug-10-38-17-143+debug_iphoneos-arm.deb}"
ROOTLESS_DEB="${ROOTLESS_DEB:-$ROOT/packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-98+debug-10-38-17-144+debug_iphoneos-arm64.deb}"
PASS="${ZY_SSH_PASS:-alpine}"

SSH_KEY_OPTS=(
  -o BatchMode=yes
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

SSH_PASS_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
)

fail() {
  printf 'FINAL_VERIFY=FAIL reason=%s\n' "$*" >&2
  exit 1
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

need_file() {
  [ -f "$1" ] || fail "missing_file:$1"
}

ssh_r() {
  local ip="$1"
  shift
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_PASS_OPTS[@]}" "root@$ip" "$@"
  fi
}

scp_r() {
  local source="$1" ip="$2" destination="$3"
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    scp "${SSH_KEY_OPTS[@]}" "$source" "root@$ip:$destination"
  else
    sshpass -p "$PASS" scp "${SSH_PASS_OPTS[@]}" "$source" "root@$ip:$destination"
  fi
}

extract_deb() {
  local label="$1" deb="$2" extract="$OUT/static/$label/extract"
  mkdir -p "$extract"
  cp -p "$deb" "$OUT/static/$label/final.deb"
  (
    cd "$extract"
    ar x "$deb"
    local data
    data="$(ar t "$deb" | awk '/^data\.tar/{print; exit}')"
    [ -n "$data" ] || exit 2
    /usr/bin/bsdtar -xf "$data"
  )
}

macho_report() {
  local path="$1" report="$2"
  {
    printf 'PATH=%s\n' "$path"
    file -h "$path"
    shasum -a 256 "$path"
    ls -ld "$path"
    if [ -L "$path" ]; then
      printf 'SYMLINK_TARGET='
      readlink "$path"
    fi
    otool -L "$path"
    otool -D "$path"
    otool -l "$path"
    nm -gU "$path"
    ldid -e "$path" 2>&1 || true
  } >"$report" 2>&1
}

static_verify_one() {
  local label="$1" deb="$2" payload="$3"
  local base="$OUT/static/$label"
  mkdir -p "$base"
  printf '%s  %s\n' "$(sha256 "$deb")" "$deb" >"$base/deb.sha256"
  ar t "$deb" >"$base/ar_members.txt"
  local control
  control="$(ar t "$deb" | awk '/^control\.tar/{print; exit}')"
  [ -n "$control" ] || fail "no_control_archive:$deb"
  ar p "$deb" "$control" | /usr/bin/bsdtar -xOf - ./control >"$base/control.txt"
  extract_deb "$label" "$deb"
  local root="$base/extract/$payload"
  [ -d "$root" ] || fail "payload_root_missing:$root"
  (
    cd "$base/extract"
    find . -type f -o -type l
  ) | sort >"$base/payload_listing.txt"
  for f in \
    "$root/bin/lua5.3" \
    "$root/lib/liblua5.3.dylib" \
    "$root/lib/libreadline.8.dylib" \
    "$root/lib/libreadline.8.0.dylib"; do
    [ -e "$f" ] || fail "runtime_file_missing:$f"
    macho_report "$f" "$base/$(basename "$f").macho.txt"
  done
  {
    printf 'LUA_LOADS\n'
    otool -L "$root/bin/lua5.3"
    printf '\nLUA_LOAD_COMMANDS\n'
    otool -l "$root/bin/lua5.3" | grep -A4 -E 'LC_LOAD_DYLIB|LC_RPATH|LC_CODE_SIGNATURE'
    printf '\nLIBLUA_ID_AND_LOADS\n'
    otool -l "$root/lib/liblua5.3.dylib" | grep -A4 -E 'LC_ID_DYLIB|LC_LOAD_DYLIB|LC_RPATH|LC_CODE_SIGNATURE'
    printf '\nREADLINE_ID_AND_LOADS\n'
    otool -l "$root/lib/libreadline.8.0.dylib" | grep -A4 -E 'LC_ID_DYLIB|LC_LOAD_DYLIB|LC_RPATH|LC_CODE_SIGNATURE'
    printf '\nNON_SYSTEM_CLOSURE\n'
    otool -L "$root/bin/lua5.3" "$root/lib/liblua5.3.dylib" \
      "$root/lib/libreadline.8.0.dylib"
  } >"$base/dependency_closure.txt" 2>&1
}

static_verify() {
  need_file "$ROOTFUL_DEB"
  need_file "$ROOTLESS_DEB"
  mkdir -p "$OUT/static"
  static_verify_one rootful "$ROOTFUL_DEB" "usr/lib/ziyan"
  static_verify_one rootless "$ROOTLESS_DEB" "var/jb/usr/lib/ziyan"
  bash "$ROOT/tools/verify_package_install_names.sh" "$ROOTLESS_DEB" \
    >"$OUT/static/rootless/install_name_gate.txt" 2>&1
  python3 "$ROOT/tools/test_package_install_lifecycle_contract.py" \
    >"$OUT/static/package_install_lifecycle.txt" 2>&1
  printf 'STATIC_VERIFY=PASS\n' >"$OUT/static/VERDICT.txt"
}

verify_device() {
  local tag="$1" ip="$2" scheme="$3" deb="$4"
  local base="$OUT/devices/$tag"
  local local_sha remote_deb
  mkdir -p "$base"
  local_sha="$(sha256 "$deb")"
  remote_deb="/var/mobile/Media/ziyan_lua53_final_${local_sha}.deb"
  {
    printf 'TAG=%s\nIP=%s\nSCHEME=%s\nLOCAL_DEB=%s\nLOCAL_DEB_SHA256=%s\n' \
      "$tag" "$ip" "$scheme" "$deb" "$local_sha"
    date '+LOCAL_TIME=%Y-%m-%d %H:%M:%S %z'
  } >"$base/meta.txt"

  ssh_r "$ip" "TAG='$tag' SCHEME='$scheme' bash -s" >"$base/preflight.log" 2>&1 <<'REMOTE'
set +e
hash_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1"
  else echo HASH_TOOL_MISSING "$1"; return 127
  fi
}
if [ "$SCHEME" = rootless ]; then
  export PATH="/var/jb/usr/bin:/var/jb/bin:$PATH"
  ROOT=/var/jb/usr/lib/ziyan
  NC=/var/jb/usr/lib/libncurses.6.dylib
else
  ROOT=/usr/lib/ziyan
  NC=/usr/lib/libncurses.6.dylib
fi
echo REMOTE_TIME="$(date '+%Y-%m-%d %H:%M:%S %z')"
echo TAG="$TAG"
uname -a
sw_vers 2>&1 || true
echo ROOTLESS_MARKER="$(test -d /var/jb && echo present || echo absent)"
echo PACKAGE_BEFORE="$(dpkg-query -W -f='${Package}|${Version}|${Architecture}|${Status}\n' com.ziyan.ziyan 2>&1)"
df -k / | tail -1
echo PROCESS_BEFORE
ps -A -o pid=,args= 2>/dev/null | grep -E '[z]iyan|[l]ua5.3|[S]pringBoard|[b]ackboardd' || true
for f in "$ROOT/bin/lua5.3" "$ROOT/lib/liblua5.3.dylib" \
         "$ROOT/lib/libreadline.8.dylib" "$ROOT/lib/libreadline.8.0.dylib" "$NC"; do
  echo "TARGET=$f"
  ls -ld "$f" 2>&1
  test -L "$f" && echo "SYMLINK_TARGET=$(readlink "$f")"
  hash_file "$f" 2>&1
done
REMOTE

  scp_r "$deb" "$ip" "$remote_deb" >"$base/scp.log" 2>&1
  ssh_r "$ip" "REMOTE_DEB='$remote_deb' EXPECTED_SHA='$local_sha' bash -s" \
    >"$base/transfer_verify.log" 2>&1 <<'REMOTE'
set -e
if command -v shasum >/dev/null 2>&1; then
  GOT="$(shasum -a 256 "$REMOTE_DEB")"
  GOT="${GOT%%[[:space:]]*}"
elif command -v sha256sum >/dev/null 2>&1; then
  GOT="$(sha256sum "$REMOTE_DEB")"
  GOT="${GOT%%[[:space:]]*}"
else
  GOT="$(openssl dgst -sha256 "$REMOTE_DEB")"
  GOT="${GOT##* }"
fi
echo REMOTE_DEB_SHA256="$GOT"
test "$GOT" = "$EXPECTED_SHA"
echo TRANSFER_VERIFY=PASS
REMOTE

  ssh_r "$ip" "REMOTE_DEB='$remote_deb' bash -s" >"$base/install.log" 2>&1 <<'REMOTE'
set +e
dpkg -i "$REMOTE_DEB"
rc=$?
echo DPKG_RC=$rc
exit "$rc"
REMOTE

  ssh_r "$ip" "TAG='$tag' SCHEME='$scheme' EXPECTED_SHA='$local_sha' bash -s" \
    >"$base/postflight.log" 2>&1 <<'REMOTE'
set -e
hash_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else openssl dgst -sha256 "$1"
  fi
}
if [ "$SCHEME" = rootless ]; then
  ROOT=/var/jb/usr/lib/ziyan
  NC=/var/jb/usr/lib/libncurses.6.dylib
else
  ROOT=/usr/lib/ziyan
  NC=/usr/lib/libncurses.6.dylib
fi
LUA="$ROOT/bin/lua5.3"
LUALIB="$ROOT/lib/lua"
RUN="$LUALIB/ziyan_run.lua"
SMOKE="$LUALIB/ziyan_agent_smoke.lua"
echo REMOTE_TIME="$(date '+%Y-%m-%d %H:%M:%S %z')"
echo PACKAGE_AFTER="$(dpkg-query -W -f='${Package}|${Version}|${Architecture}|${Status}\n' com.ziyan.ziyan)"
echo RUNTIME_SCHEME_MARKER="$(cat /var/mobile/Library/Preferences/com.ziyan.ziyan.runtime_scheme)"
echo ROOT="$ROOT"
for f in "$LUA" "$ROOT/lib/liblua5.3.dylib" "$ROOT/lib/libreadline.8.dylib" \
         "$ROOT/lib/libreadline.8.0.dylib" "$NC"; do
  echo "TARGET=$f"
  ls -ld "$f"
  test -L "$f" && echo "SYMLINK_TARGET=$(readlink "$f")"
  hash_file "$f"
done
if command -v file >/dev/null 2>&1; then
  echo FILE_ARCH
  file "$LUA" "$ROOT/lib/liblua5.3.dylib" "$ROOT/lib/libreadline.8.0.dylib"
else
  echo DEVICE_FILE_UNAVAILABLE=1
fi
if command -v otool >/dev/null 2>&1; then
  echo DEVICE_OTOOL_L
  otool -L "$LUA" "$ROOT/lib/liblua5.3.dylib" "$ROOT/lib/libreadline.8.0.dylib"
  echo DEVICE_OTOOL_LOADS
  otool -l "$LUA" "$ROOT/lib/liblua5.3.dylib" "$ROOT/lib/libreadline.8.0.dylib" \
    | grep -A4 -E 'LC_ID_DYLIB|LC_LOAD_DYLIB|LC_RPATH|LC_CODE_SIGNATURE' || true
else
  echo DEVICE_OTOOL_UNAVAILABLE=1
fi
echo LUA_HEALTH_BEGIN
"$LUA" -e 'io.write("LUA53_HEALTH=PASS\n")'
echo LUA_HEALTH_RC=$?
echo LUA_TRACE_BEGIN
DYLD_PRINT_LIBRARIES=1 "$LUA" -e 'io.write("LUA53_TRACE=PASS\n")' \
  > /tmp/ziyan_lua53_final_trace.out 2> /tmp/ziyan_lua53_final_trace.err
rc=$?
cat /tmp/ziyan_lua53_final_trace.out
cat /tmp/ziyan_lua53_final_trace.err
echo LUA_TRACE_RC=$rc
test "$rc" = 0
if grep -Eqi 'missing: .*(liblua5\.3|libreadline|libncurses)|dyld: Library not loaded|abort trap: 6|exit[[:space:]]+134' \
    /tmp/ziyan_lua53_final_trace.err; then
  echo DYLIB_ERROR_FOUND=1
  exit 20
fi
echo DYLIB_ERROR_FOUND=0
if grep -Fq '/usr/lib/ziyan/lib/liblua5.3.dylib' /tmp/ziyan_lua53_final_trace.err \
    && { grep -Fq '/usr/lib/ziyan/lib/libreadline.8.dylib' /tmp/ziyan_lua53_final_trace.err \
      || grep -Fq '/usr/lib/ziyan/lib/libreadline.8.0.dylib' /tmp/ziyan_lua53_final_trace.err; } \
    && { if [ "$SCHEME" = rootless ]; then
           grep -Fq 'libncursesw.6.dylib' /tmp/ziyan_lua53_final_trace.err
         else
           grep -Fq '/usr/lib/libncurses.6.dylib' /tmp/ziyan_lua53_final_trace.err
         fi; }; then
  echo DYLD_CLOSURE=PASS
else
  echo DYLD_CLOSURE=FAIL
  exit 22
fi

CORE="/tmp/ziyan_lua53_final_core_${TAG}.lua"
cat >"$CORE" <<'LUA'
local root = assert(os.getenv("ZIYAN_ROOT"))
local lualib = assert(os.getenv("ZIYAN_LUALIB"))
package.path = table.concat({
  lualib .. "/?.lua",
  lualib .. "/?/init.lua",
  lualib .. "/ziyan_engine/?.lua",
  lualib .. "/modules/?.lua",
  package.path,
}, ";")
local paths = assert(dofile(lualib .. "/ziyan_paths.lua"))
assert(paths.root() == root, "unexpected runtime root " .. tostring(paths.root()))
assert(paths.resolve("/usr/lib/ziyan/lib/lua/ziyan_run.lua") == lualib .. "/ziyan_run.lua")
assert(dofile(lualib .. "/ziyan_te_boot.lua"))
assert(type(_G.Zy) == "table", "Zy bootstrap missing")
assert(type(_G.Zy.Sandbox) == "table", "Zy.Sandbox missing")
local ok, err = _G.Zy.Sandbox.run(function() return true end, "lua53_final")
assert(ok, tostring(err))
print("ZIYAN_CORE_REGRESSION=PASS root=" .. root)
LUA
echo CORE_REGRESSION_BEGIN
ZIYAN_ROOT="$ROOT" ZIYAN_LUALIB="$LUALIB" "$LUA" "$CORE"
echo CORE_REGRESSION_RC=$?
rm -f "$CORE"

SAVE="/tmp/ziyan_lua53_final_agent_${TAG}_$$"
mkdir -p "$SAVE"
for n in .ziyan_agent_session .ziyan_agent_stop; do
  if [ -e "$ROOT/var/$n" ]; then cp -p "$ROOT/var/$n" "$SAVE/$n"; else : > "$SAVE/$n.absent"; fi
done
restore_agent_state() {
  local n failed=0
  for n in .ziyan_agent_session .ziyan_agent_stop; do
    if [ -f "$SAVE/$n" ]; then
      mv -f "$SAVE/$n" "$ROOT/var/$n" || failed=1
    else
      rm -f "$ROOT/var/$n" || failed=1
      rm -f "$SAVE/$n.absent" || failed=1
    fi
  done
  rmdir "$SAVE" || failed=1
  return "$failed"
}
cleanup_agent_smoke() {
  rc=$?
  trap - EXIT
  set +e
  restore_agent_state || true
  rm -f "$CORE" /tmp/ziyan_lua53_final_trace.out /tmp/ziyan_lua53_final_trace.err
  exit "$rc"
}
trap cleanup_agent_smoke EXIT
echo AGENT_SMOKE_BEGIN
"$LUA" "$RUN" "$SMOKE"
echo AGENT_SMOKE_RC=$?
if ! restore_agent_state; then
  echo CLEANUP=FAIL agent_session_restored=0
  exit 21
fi
trap - EXIT
rm -f "$CORE" /tmp/ziyan_lua53_final_trace.out /tmp/ziyan_lua53_final_trace.err
echo PROCESS_AFTER
ps -A -o pid=,args= 2>/dev/null | grep -E '[z]iyan|[l]ua5.3|[S]pringBoard|[b]ackboardd' || true
echo CLEANUP=PASS agent_session_restored=1 no_springboard_or_backboardd_restart=1
REMOTE

  grep -qx 'TRANSFER_VERIFY=PASS' "$base/transfer_verify.log"
  grep -q '^DPKG_RC=0$' "$base/install.log"
  grep -q '^LUA53_HEALTH=PASS$' "$base/postflight.log"
  grep -q '^LUA_TRACE_RC=0$' "$base/postflight.log"
  grep -q '^DYLIB_ERROR_FOUND=0$' "$base/postflight.log"
  grep -q '^ZIYAN_CORE_REGRESSION=PASS ' "$base/postflight.log"
  grep -q '^AGENT_SMOKE_RC=0$' "$base/postflight.log"
  grep -q '^CLEANUP=PASS ' "$base/postflight.log"
  printf 'DEVICE_VERIFY=PASS tag=%s\n' "$tag" >"$base/VERDICT.txt"
}

main() {
  command -v sshpass >/dev/null 2>&1 || fail "sshpass_missing"
  static_verify
  case "${1:-}" in
    --static-only)
      printf 'FINAL_4DEVICE_STATIC_VERIFY=PASS\n' >"$OUT/VERDICT.txt"
      printf '%s\n' "$OUT"
      return
      ;;
    '')
      ;;
    *)
      fail "usage: $0 [--static-only]"
      ;;
  esac
  verify_device 101 192.168.31.101 rootful "$ROOTFUL_DEB"
  verify_device 112 192.168.31.112 rootful "$ROOTFUL_DEB"
  verify_device 166 192.168.31.166 rootful "$ROOTFUL_DEB"
  verify_device 53 192.168.31.53 rootless "$ROOTLESS_DEB"
  printf 'FINAL_4DEVICE_VERIFY=PASS\n' >"$OUT/VERDICT.txt"
  printf '%s\n' "$OUT"
}

main "$@"
