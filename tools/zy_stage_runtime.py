#!/usr/bin/env python3
"""Stage runtime files inside one validated Theos staging tree."""
import argparse
from pathlib import Path
import subprocess
import sys


class Stage:
    def __init__(self, destination, build_root, prefix, repo):
        if not destination or not build_root:
            raise ValueError("staging and build root must be non-empty")
        self.root = Path(destination).resolve(strict=True)
        build = Path(build_root).resolve(strict=True)
        if (not self.root.is_dir() or not build.is_dir() or build == Path(build.anchor)
                or self.root == build or build not in self.root.parents):
            raise ValueError("staging must be a directory strictly inside the build root")
        if prefix not in ("", "/var/jb"):
            raise ValueError("unsupported package install prefix")
        self.prefix, self.repo = prefix, Path(repo).resolve(strict=True)

    def target(self, relative):
        target = self.root / relative
        resolved = target.resolve()
        if self.root not in resolved.parents:
            raise ValueError("write escapes staging: " + str(target))
        # rsync --delete may traverse an existing tree. Reject escaped links
        # before invoking any command, including links to the staging root.
        if target.is_dir():
            for item in target.rglob("*"):
                if item.is_symlink() and self.root not in item.resolve().parents:
                    raise ValueError("staging contains an escaping symlink: " + str(item))
        return str(target)

    def run(self, command, *args, targets):
        checked = [self.target(path) for path in targets]
        subprocess.run([command, *args, *checked], cwd=self.repo, check=True)

    def mkdir(self, *paths):
        self.run("mkdir", "-p", targets=paths)

    def copy(self, source, destination):
        self.run("cp", "-f", source, targets=[destination])

    def sync(self, source, destination, *options):
        self.run("rsync", "-a", *options, source + "/", targets=[destination + "/"])

    def chmod(self, *paths):
        self.run("chmod", "755", targets=paths)

    def rewrite(self, relative, *args):
        self.run("install_name_tool", *args, targets=[relative])

    def sign(self, *paths):
        self.run("ldid", "-S", targets=paths)

    def stage(self):
        runtime = "usr/lib/ziyan/"
        self.mkdir(*(runtime + name for name in (
            "bin", "lib/lua", "engine", "runtime", "hook", "var", "modules", "models",
            "share/media_seed")), "Library/LaunchDaemons")
        self.sync("vendor/bin", runtime + "bin")
        self.sync("vendor/lib", runtime + "lib", "--exclude=lua")
        self.sync("lua", runtime + "lib/lua", "--delete")
        self.mkdir(runtime + "lib/lua/agent")
        self.sync("Agent", runtime + "lib/lua/agent")
        self.chmod(runtime + "bin/lua5.3", runtime + "bin/python3.7")
        for link, target in (("bin/lua", "lua5.3"), ("bin/python3", "python3.7"),
                             ("lib/libreadline.8.dylib", "libreadline.8.0.dylib")):
            self.run("ln", "-sfn", target, targets=[runtime + link])
        if self.prefix:
            lib = self.prefix + "/usr/lib/ziyan/lib/"
            for name in ("liblua5.3.dylib", "libreadline.8.dylib"):
                self.rewrite(runtime + "bin/lua5.3", "-change", "/usr/lib/ziyan/lib/" + name, lib + name)
            for name in ("liblua5.3.dylib", "libreadline.8.0.dylib"):
                self.rewrite(runtime + "lib/" + name, "-id", lib + name)
            self.rewrite(runtime + "lib/libreadline.8.0.dylib", "-change", "/usr/lib/libncurses.6.dylib",
                         self.prefix + "/usr/lib/libncurses.6.dylib")
            self.sign(runtime + "bin/lua5.3", runtime + "lib/liblua5.3.dylib", runtime + "lib/libreadline.8.0.dylib")
        for name in ("wnriakwyww", "wnriakwyww.dylib"):
            self.copy("vendor/runtime/engine/" + name, runtime + "engine/" + name)
            self.chmod(runtime + "engine/" + name)
        if self.prefix:
            self.rewrite(runtime + "engine/wnriakwyww", "-change", "/bin/wnriakwyww.dylib",
                         self.prefix + "/bin/wnriakwyww.dylib")
            self.rewrite(runtime + "engine/wnriakwyww.dylib", "-id", self.prefix + "/bin/wnriakwyww.dylib")
            self.sign(runtime + "engine/wnriakwyww", runtime + "engine/wnriakwyww.dylib")
        self.sync("vendor/runtime/data", runtime + "runtime", "--delete")
        self.mkdir(*(runtime + "runtime/" + name for name in ("scripts", "var/log", "var/tmp")))
        for name in ("ZiYanTEHook.dylib", "ZiYanTEHook.plist"):
            self.copy("vendor/runtime/hook/" + name, runtime + "hook/" + name)
        self.sync("vendor/modules", runtime + "modules", "--delete")
        self.sync("layout/usr/lib/ziyan/models", runtime + "models")
        self.mkdir(runtime + "tessdata/lstm/tessdata")
        self.sync("layout/usr/lib/ziyan/tessdata", runtime + "tessdata")
        for language in ("chi_sim", "eng"):
            self.copy("layout/usr/lib/ziyan/tessdata/_fast/" + language + ".traineddata",
                      runtime + "tessdata/lstm/tessdata/" + language + ".traineddata")
        for name in ("engine", "fscloak", "scripthub", "zydaemon", "framecap"):
            self.copy("vendor/runtime/launch/com.ziyan." + name + ".plist",
                      "Library/LaunchDaemons/com.ziyan." + name + ".plist")
        for name in ("ziyan_fscloakd.sh", "ziyan_scripthubd.sh"):
            self.copy("vendor/runtime/bin/" + name, runtime + "bin/" + name)
            self.chmod(runtime + "bin/" + name)
        for name in ("ziyan_zero_sb_unload.sh", "ziyan_framerelay_toggle.sh"):
            # These optional vendor tools are not included in every release.
            if (self.root / runtime / "bin" / name).exists():
                self.chmod(runtime + "bin/" + name)
        for name in ("ziyan_zydaemond.sh", "ziyan_framecap_wrap.sh", "ziyan_runtime_root.sh"):
            self.copy("layout/usr/lib/ziyan/bin/" + name, runtime + "bin/" + name)
            self.chmod(runtime + "bin/" + name)
        for source in ("layout/private/var/mobile/Media/ZiYan", "media_seed"):
            self.sync(source, runtime + "share/media_seed")
        self.run("rm", "-f", targets=["private/var/mobile/Media/ZiYan/login_" + name + ".lua"
                                     for name in ("xztl", "lan", "usb")])
        if self.prefix:
            for prefix in ("", self.prefix.lstrip("/") + "/"):
                hook = prefix + "Library/MobileSubstrate/DynamicLibraries/ZiYanTEHook.dylib"
                if (self.root / hook).is_file():
                    self.rewrite(hook, "-id", self.prefix + "/Library/MobileSubstrate/DynamicLibraries/ZiYanTEHook.dylib")
                    self.rewrite(hook, "-change", "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                                 "@rpath/CydiaSubstrate.framework/CydiaSubstrate")
                    self.sign(hook)
        print("[ZiYan] staged (pre-remap): " + str(self.root) + " prefix=" + (self.prefix or "/"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging", required=True)
    parser.add_argument("--build-root", required=True)
    parser.add_argument("--prefix", default="")
    args = parser.parse_args(argv)
    try:
        Stage(args.staging, args.build_root, args.prefix, Path(__file__).resolve().parents[1]).stage()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print("STAGE_FAILED: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
