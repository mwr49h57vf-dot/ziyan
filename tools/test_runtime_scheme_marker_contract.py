#!/usr/bin/env python3
"""Regression contract: package Architecture owns the one runtime IPC tree."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def text(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


paths = text("objc/shared/ZiYanPaths.h")
lua_paths = text("lua/ziyan_paths.lua")
runner = text("lua/ziyan_run.lua")
postinst = text("layout/DEBIAN/postinst")
framecap_wrap = text("layout/usr/lib/ziyan/bin/ziyan_framecap_wrap.sh")
zydaemon = text("layout/usr/lib/ziyan/bin/ziyan_zydaemond.sh")
httpctl = text("layout/usr/lib/ziyan/bin/ziyan_httpctl_serve.sh")
runtime_helper = text("layout/usr/lib/ziyan/bin/ziyan_runtime_root.sh")
script_runner = text("objc/shared/ZiYanScriptRunner.m")
watchdog = text("objc/tweak/springboard/ZiyanProcessWatchdog.m")

marker = "/var/mobile/Library/Preferences/com.ziyan.ziyan.runtime_scheme"
assert marker in paths
assert "ZiYanRuntimeScheme(void)" in paths
assert '[marked isEqualToString:@"rootful"]' in paths
assert '[marked isEqualToString:@"rootless"]' in paths
assert "ZiYanRuntimeScheme() isEqualToString:@\"rootless\"" in paths

assert "local SCHEME_MARKER" in lua_paths
assert "local scheme = marked_scheme()" in lua_paths
assert 'scheme == "rootful"' in lua_paths
assert 'scheme == "rootless"' in lua_paths

assert "debug.getinfo(1, \"S\")" in runner
assert 'self_path:gsub("ziyan_run%.lua$", "ziyan_paths.lua")' in runner
assert "if p ~= candidates[1] then" in runner

assert "dpkg-query -W -f='${Architecture}' com.ziyan.ziyan" in postinst
assert 'iphoneos-arm64*|arm64*) SCHEME="rootless"; JB="/var/jb"' in postinst
assert 'iphoneos-arm*|arm*) SCHEME="rootful"; JB=""' in postinst
assert marker in postinst
assert 'printf \'%s\\n\' "$SCHEME" >"$ROOT/var/.ziyan_runtime_scheme"' in postinst

assert marker in runtime_helper
assert 'rootless) ZIYAN_RUNTIME_ROOT="/var/jb/usr/lib/ziyan"' in runtime_helper
assert 'rootful) ZIYAN_RUNTIME_ROOT="/usr/lib/ziyan"' in runtime_helper
for wrapper in (framecap_wrap, zydaemon, httpctl):
    assert "ziyan_runtime_root.sh" in wrapper
    assert 'ROOT="${ZIYAN_RUNTIME_ROOT:-$ROOT}"' in wrapper
assert '[ -d /var/jb/usr/lib/ziyan ] && ROOT="/var/jb/usr/lib/ziyan"' not in framecap_wrap
assert '[ -d /var/jb/usr/lib/ziyan ] && ROOTLESS=1' not in zydaemon

assert "[ZiYanRuntimeBin() stringByAppendingPathComponent:@\"ziyan_framecap\"]" in script_runner
assert 'ZiYanJBPath(@"/Library/LaunchDaemons/com.ziyan.framecap.plist")' in script_runner
assert watchdog.count('ZiYanJBPath(@"/Library/LaunchDaemons/com.ziyan.') == 2

print("PASS: package Architecture marker selects one rootful/rootless runtime tree")
