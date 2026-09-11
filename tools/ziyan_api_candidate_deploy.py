#!/usr/bin/env python3
"""Install a hash-pinned API candidate without restarting SpringBoard."""
import argparse
import json
import os
import shlex
from pathlib import Path

from tools import ziyan_api_functional as api


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--device", choices=api.DEVICES, required=True)
    args = parser.parse_args()
    scheme = "rootful" if args.device in api.DEVICES[:3] else "rootless"
    package = json.loads(args.manifest.read_text())[scheme]
    assert api.digest(Path(package["path"])) == package["sha256"]
    local = args.out.resolve() / args.device
    local.mkdir(parents=True, exist_ok=False)
    root = "/usr/lib/ziyan" if scheme == "rootful" else "/var/jb/usr/lib/ziyan"
    target = ("mobile" if args.device == "61" else "root") + "@192.168.31." + args.device
    remote = "/tmp/ziyan_api_install_" + package["version"].split("-")[-1] + "_" + args.device
    env = f"R={shlex.quote(root)}\nD={shlex.quote(remote)}\n"
    ssh = ["ssh", *api.SSH_OPTIONS, target, "bash -s"]
    before = api.command(ssh, local / "before.txt", input=env + 'mkdir -p "$D"\n' + api.STATE)
    state = api.parse_state(before.stdout)
    record = {"device": "." + args.device, "package": package, "before": state,
              "verdict": "INSTALL_INCONCLUSIVE", "evidence": str(local)}
    try:
        if not api.cleanup_complete(state, state, before.returncode):
            record["reason"] = "precondition_not_idle"
            return
        if args.device == "61" and not os.environ.get("ZY61_SUDO_PASS"):
            record["reason"] = "ZY61_SUDO_PASS_NOT_CONFIGURED"
            return
        copied = api.command(["scp", *api.SSH_OPTIONS, package["path"], target + ":" + remote + "/candidate.deb"],
                             local / "copy.txt", timeout=180)
        if copied.returncode:
            record["reason"] = "package_copy_failed"
            return
        script = env + f"""
set -e
export PATH="$R/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:$PATH"
echo '{package["sha256"]}  '"$D/candidate.deb" | sha256sum -c -
test "$(id -u)" = 0
dpkg -i "$D/candidate.deb"
test "$(dpkg-query -W -f='${{Version}}' com.ziyan.ziyan)" = {shlex.quote(package["version"])}
"""
        script += "\n".join(f"echo '{sha}  /{path}' | sha256sum -c -"
                            for path, sha in package["payload"].items()) + "\n"
        # Only the verified prior host is stopped; zydaemon remains the sole owner.
        pid = next((part.split("=", 1)[1] for part in state.get("framecap_owner", "").split()
                    if part.startswith("pid=")), "")
        if not pid.isdigit():
            record["reason"] = "framecap_owner_pid_missing"
            return
        script += f"""
P={pid}
cmd=$(ps -p "$P" -o command= 2>/dev/null || true)
case "$cmd" in "$R/bin/ziyan_framecap serve"*) kill -TERM "$P";; esac
echo zydaemon > "$R/var/.ziyan_framecap_owner_mode"
echo 1 > "$R/var/.ziyan_watchdog_framecap_need"
sleep 8
""" + api.STATE
        password = ""
        if args.device == "61":
            ssh[-1] = 'sudo -S -p "" /var/jb/bin/bash -s'
            password = os.environ["ZY61_SUDO_PASS"] + "\n"
        installed = api.command(ssh, local / "install.txt", input=password + script, timeout=180)
        record["install_exit_code"] = installed.returncode
        record["after"] = api.parse_state(installed.stdout)
        record["verdict"] = ("INSTALL_VERIFIED" if
                             api.cleanup_complete(state, record["after"], installed.returncode)
                             and record["after"].get("version") == package["version"]
                             else "INSTALL_INCONCLUSIVE")
        record["reason"] = "functional_validation_required"
    finally:
        api.save(local / "VERDICT.json", record)
        print(json.dumps(record, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
