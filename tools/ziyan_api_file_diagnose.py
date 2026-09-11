#!/usr/bin/env python3
"""Read-only file API dependency probes; no functional PASS is emitted."""
import argparse
import json
from pathlib import Path

from tools import ziyan_api_functional as api


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    records = []
    for device in api.DEVICES:
        root = "/usr/lib/ziyan" if device in api.DEVICES[:3] else "/var/jb/usr/lib/ziyan"
        user = "mobile" if device == "61" else "root"
        log = args.out / (device + ".txt")
        result = api.command(
            ["ssh", *api.SSH_OPTIONS, f"{user}@192.168.31.{device}", "bash -s"],
            log, input=f'R={root}\n' + r"""
export PATH="$R/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:$PATH"
printf 'version='; dpkg-query -W -f='${Version}\n' com.ziyan.ziyan
printf 'PATH=%s\n' "$PATH"
for tool in cp ls plutil python3; do command -v "$tool"; done
ls -l /bin/sh /var/jb/bin/sh "$R/bin/lua5.3" "$R/bin/python3" 2>&1
"$R/bin/python3" -c 'import plistlib; print("PLISTLIB_IMPORT_OK", plistlib.__file__)' 2>&1
echo "PYTHON_RC=$?"
plutil -help 2>&1
export API_ROOT="$R"
"$R/bin/lua5.3" - <<'LUA'
print("LUA_VERSION", _VERSION)
print("SHELL_AVAILABLE", os.execute())
print("SHELL_PROBE", os.execute("command -v cp ls; printf LUA_SHELL_OK"))
local r = os.getenv("API_ROOT")
_G.ZIYAN_ROOT = r
_G.ZIYAN_VAR = r .. "/var"
_G.ZIYAN_LUA = r .. "/lib/lua"
package.path = _G.ZIYAN_LUA .. "/?.lua;" .. _G.ZIYAN_LUA .. "/?/init.lua;" .. package.path
require("ziyan_engine")
print("ENGINE_SHELL_PROBE", os.execute("command -v cp ls; printf ENGINE_SHELL_OK"))
LUA
echo PROCESSES_BEGIN
ps -A -o pid=,command=
echo PROCESSES_END
for name in .ziyan_framecap_owner_mode .ziyan_framecap_owner .ziyan_watchdog_framecap_need .ziyan_framecap_alive .ziyan_session .ziyan_framecap_serve.lock; do
  echo "STATE_FILE=$name"
  ls -ld "$R/var/$name" 2>&1
  if [ -f "$R/var/$name" ]; then head -c 1000 "$R/var/$name"; echo; fi
done
""")
        records.append({"device": "." + device, "exit_code": result.returncode,
                        "evidence": str(log.resolve()),
                        "state": api.parse_state(result.stdout)})
        print(json.dumps(records[-1]), flush=True)
    api.save(args.out / "diagnosis.json", {"records": records, "functional_pass": False})


if __name__ == "__main__":
    main()
