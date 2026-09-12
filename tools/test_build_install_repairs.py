#!/usr/bin/env python3
"""Host-only regressions. Every mutable fixture is an isolated temporary tree."""
import contextlib
import gzip
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") if os.name != "nt" else r"D:\Program Files\Git\bin\bash.exe"


def posix(path):
    value = str(path).replace("\\", "/")
    return "/" + value[0].lower() + value[2:] if re.match(r"^[A-Za-z]:", value) else value


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StageBoundary(unittest.TestCase):
    def test_make_recipe_propagates_stage_failure(self):
        make = shutil.which("make") or shutil.which("gmake")
        if not make:
            self.skipTest("GNU Make required for recipe integration")
        source = (ROOT / "Makefile").read_text(encoding="utf-8")
        body = source.split("stage-runtime:\n", 1)[1].split("\n.PHONY:", 1)[0]
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            stage_program = root / "failing_stage.py"
            stage_program.write_text("import sys\nprint('STAGE_RECIPE_CALLED')\nsys.exit(42)\n")
            interpreter = '"' + Path(sys.executable).as_posix() + '" "' + stage_program.as_posix() + '"'
            body = body.replace("python3 tools/zy_stage_runtime.py", interpreter)
            makefile = root / "fixture.mk"
            makefile.write_text("SHELL := " + Path(BASH).as_posix() + "\n"
                                "package: stage-runtime\n\t@echo PACKAGE_COMPLETED\n"
                                "stage-runtime:\n" + body, encoding="utf-8", newline="\n")
            result = subprocess.run([make, "-f", str(makefile), "package"], cwd=ROOT,
                                    capture_output=True, text=True, encoding="utf-8", errors="replace")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("STAGE_RECIPE_CALLED", result.stdout)
            self.assertNotIn("PACKAGE_COMPLETED", result.stdout)

    def test_make_stage_never_loses_destination(self):
        """Run old logical recipe lines with inert shell command substitutes."""
        source = (ROOT / "Makefile").read_text(encoding="utf-8")
        body = source.split("stage-runtime:\n", 1)[1].split("\n.PHONY:", 1)[0]
        if "zy_stage_runtime.py" in body:
            self.assertNotIn(".ONESHELL:", source)
            module = load_module("stage", ROOT / "tools/zy_stage_runtime.py")
            with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
                build = Path(td) / "build"
                stage = build / "stage"
                stage.mkdir(parents=True)
                calls = []
                def substitute(command, **kwargs):
                    calls.append(command)
                    # The last argument of every mutating command is a path.
                    self.assertIn(stage, Path(command[-1]).resolve().parents)
                for prefix in ("", "/var/jb"):
                    with patch.object(module.subprocess, "run", substitute):
                        self.assertEqual(module.main(["--staging", str(stage), "--build-root", str(build),
                                                      "--prefix", prefix]), 0)
                self.assertTrue(any(command[0] == "rsync" and Path(command[-1]).name == "runtime" for command in calls))
            return
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            dest = posix(Path(td) / "stage")
            prelude = "\n".join(
                f'{name}() {{ printf "WRITE %s\\n" "$*"; }}'
                for name in ("mkdir", "rsync", "cp", "chmod", "ln", "install_name_tool", "ldid", "rm")
            )
            logical, pending = [], ""
            for line in body.splitlines():
                if not line.startswith("\t"):
                    continue
                line = line[1:].lstrip("@")
                line = line.replace("$(THEOS_STAGING_DIR)", dest)
                line = line.replace("$(THEOS_PACKAGE_INSTALL_PREFIX)", "/var/jb")
                line = line.replace("$(THEOS_PACKAGE_SCHEME)", "rootless").replace("$$", "$")
                pending += line + "\n"
                if not line.endswith("\\"):
                    logical.append(pending)
                    pending = ""
            output = ""
            for command in logical:
                result = subprocess.run([BASH, "--noprofile", "--norc", "-c", prelude + "\n" + command],
                                        capture_output=True, text=True, encoding="utf-8")
                output += result.stdout
            self.assertNotRegex(output, r"WRITE (?:-a --delete |\-f )?[^\n]* (?<!stage)/usr/lib/ziyan/runtime/")
            for line in output.splitlines():
                if line.startswith("WRITE") and "/usr/lib/ziyan/runtime/" in line:
                    self.assertIn(dest + "/usr/lib/ziyan/runtime", line)

    def test_invalid_stage_rejected_before_write(self):
        module = load_module("stage", ROOT / "tools/zy_stage_runtime.py")
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            build = Path(td) / "build"
            build.mkdir()
            for dest in ("", str(Path(td).anchor), str(build), str(Path(td)), str(build / "missing")):
                with self.subTest(dest=dest), patch.object(module.subprocess, "run") as command:
                    self.assertEqual(module.main(["--staging", dest, "--build-root", str(build)]), 1)
                    command.assert_not_called()

    def test_each_mutating_tool_failure_stops_stage(self):
        module = load_module("stage", ROOT / "tools/zy_stage_runtime.py")
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            build = Path(td) / "build"
            stage = build / "stage"
            stage.mkdir(parents=True)
            for tool in ("mkdir", "rsync", "cp", "chmod", "ln", "install_name_tool", "ldid", "rm"):
                calls, output = [], io.StringIO()
                def failing(command, **kwargs):
                    calls.append(command[0])
                    if command[0] == tool:
                        raise subprocess.CalledProcessError(42, command)
                with self.subTest(tool=tool), patch.object(module.subprocess, "run", failing), contextlib.redirect_stdout(output):
                    self.assertEqual(module.main(["--staging", str(stage), "--build-root", str(build),
                                                  "--prefix", "/var/jb"]), 1)
                    self.assertEqual(calls[-1], tool)
                    self.assertNotIn("staged (pre-remap)", output.getvalue())


class InstallMigration(unittest.TestCase):
    def run_migration(self, root, extra="", operation="migrate_old config"):
        source = (ROOT / "layout/DEBIAN/postinst").read_text(encoding="utf-8")
        begin = source.index("migrate_old() {")
        if "# BEGIN SAFE MIGRATION" in source:
            begin = source.index("# BEGIN SAFE MIGRATION")
        end = source.index("\nmigrate_old config", begin)
        code = source[begin:end]
        script = ('set -e\nDIR=' + repr(posix(root)) + '\nZYCV="$DIR/ZYCV"\n'
                  + code + "\n" + extra + "\n" + operation)
        return subprocess.run([BASH, "--noprofile", "--norc", "-c", script], capture_output=True,
                              text=True, encoding="utf-8", errors="replace")

    def test_copy_failure_retains_old_data_and_fails_install(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "config").mkdir()
            (root / "config/user.cfg").write_bytes(b"unique user data")
            result = self.run_migration(root, 'cp() { return 28; }')
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / "config/user.cfg").read_bytes(), b"unique user data")

    def test_different_same_name_retains_both_and_reports_conflict(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "config").mkdir()
            (root / "ZYCV/config").mkdir(parents=True)
            (root / "config/user.cfg").write_bytes(b"old data")
            (root / "ZYCV/config/user.cfg").write_bytes(b"different data")
            result = self.run_migration(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "config/user.cfg").read_bytes(), b"old data")
            self.assertEqual((root / "ZYCV/config/user.cfg").read_bytes(), b"different data")
            self.assertIn("conflict", result.stderr.lower())

    def test_normal_migration_keeps_verified_rollback_and_is_repeatable(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            expected = {"user.cfg": b"settings", "nested/file.lua": b"print('hello')", ".hidden": b"hidden"}
            for name, data in expected.items():
                path = root / "config" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            result = self.run_migration(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            backups = list((root / ".migration-backups").glob("*/source"))
            self.assertEqual(len(backups), 1)
            for name, data in expected.items():
                self.assertEqual((root / "ZYCV/config" / name).read_bytes(), data)
                self.assertEqual((backups[0] / name).read_bytes(), data)
            self.assertEqual(self.run_migration(root).returncode, 0)
            self.assertEqual(len(list((root / ".migration-backups").glob("*/source"))), 1)

    def test_script_conflict_uses_same_preservation_rule(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "ZYCV/res").mkdir(parents=True)
            (root / "hello.lua").write_bytes(b"old script")
            (root / "ZYCV/res/hello.lua").write_bytes(b"new script")
            result = self.run_migration(root, operation='migration_commit "$DIR/hello.lua" "$ZYCV/res/hello.lua"')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "hello.lua").read_bytes(), b"old script")
            self.assertEqual((root / "ZYCV/res/hello.lua").read_bytes(), b"new script")

    def test_interruption_during_copy_preserves_source(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "config").mkdir()
            (root / "config/user.cfg").write_bytes(b"original")
            result = self.run_migration(root, 'cp() { command cp "$@"; kill -TERM "$BASHPID"; }')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "config/user.cfg").read_bytes(), b"original")
            resumed = self.run_migration(root)
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertEqual((root / "ZYCV/config/user.cfg").read_bytes(), b"original")

    def test_permissions_failure_retains_source(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "config").mkdir()
            (root / "config/user.cfg").write_bytes(b"original")
            result = self.run_migration(root, 'mkdir() { return 13; }')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "config/user.cfg").read_bytes(), b"original")

    def test_concurrent_destination_creation_is_not_overwritten(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "config").mkdir()
            (root / "config/user.cfg").write_bytes(b"original")
            result = self.run_migration(root, 'ln() { printf concurrent > "$2"; command ln "$@"; }')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "config/user.cfg").read_bytes(), b"original")
            self.assertEqual((root / "ZYCV/config/user.cfg").read_bytes(), b"concurrent")

    def test_interruption_after_archive_retains_backup_and_can_repeat(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "config").mkdir()
            (root / "config/user.cfg").write_bytes(b"original")
            result = self.run_migration(root, 'mv() { command mv "$@"; kill -TERM "$BASHPID"; }')
            self.assertNotEqual(result.returncode, 0)
            backups = list((root / ".migration-backups").glob("*/source/user.cfg"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), b"original")
            self.assertEqual((root / "ZYCV/config/user.cfg").read_bytes(), b"original")
            self.assertEqual(self.run_migration(root).returncode, 0)

    def test_tail_resource_migration_preserves_same_name_conflict(self):
        source = (ROOT / "layout/DEBIAN/postinst").read_text(encoding="utf-8")
        tail = source.split("# 防御状态文件统一到 ZYCV/res（旧顶层迁入）", 1)[1].split("\nfor b in ", 1)[0]
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            (root / "ZYCV/res").mkdir(parents=True)
            (root / "defense.log").write_bytes(b"older user log")
            (root / "ZYCV/res/defense.log").write_bytes(b"newer user log")
            tail = tail.replace("/var/mobile/Media/ZiYan", posix(root))
            result = self.run_migration(root, operation=tail)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "defense.log").read_bytes(), b"older user log")
            self.assertEqual((root / "ZYCV/res/defense.log").read_bytes(), b"newer user log")


class AptVerification(unittest.TestCase):
    def test_empty_indexes_and_fake_signatures_must_fail(self):
        module = load_module("verify", ROOT / "tools/ziyan_apt/verify_repo.py")
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            repo = Path(td)
            stable = repo / "dists/stable"
            for arch in ("iphoneos-arm", "iphoneos-arm64"):
                directory = stable / ("main/binary-" + arch)
                directory.mkdir(parents=True)
                (directory / "Packages").write_text("")
            (stable / "Release").write_text("Origin: ZiYan\n")
            (stable / "Release.gpg").write_bytes(b"not a signature")
            (stable / "InRelease").write_bytes(b"not a signature")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertNotEqual(module.main(str(repo)), 0)

    def make_repo(self, repo):
        stable = repo / "dists/stable"
        hashes = []
        for arch in ("iphoneos-arm", "iphoneos-arm64"):
            payload = repo / (arch + ".deb")
            payload.write_bytes(("fixture " + arch).encode())
            directory = stable / ("main/binary-" + arch)
            directory.mkdir(parents=True)
            body = ("Package: com.ziyan.ziyan\nVersion: 1.0\nArchitecture: " + arch +
                    "\nDepends: firmware (>= 13)\nFilename: " + payload.name +
                    "\nSize: " + str(payload.stat().st_size) + "\nSHA256: " +
                    hashlib.sha256(payload.read_bytes()).hexdigest() + "\n\n").encode()
            (directory / "Packages").write_bytes(body)
            (directory / "Packages.gz").write_bytes(gzip.compress(body))
            for name in ("Packages", "Packages.gz"):
                path = directory / name
                hashes.append(" " + hashlib.sha256(path.read_bytes()).hexdigest() + " " +
                              str(path.stat().st_size) + " " + path.relative_to(stable).as_posix())
        (stable / "Release").write_text("Origin: ZiYan\nLabel: ZiYan\nSuite: stable\nCodename: stable\n"
            "Architectures: iphoneos-arm iphoneos-arm64\nComponents: main\n"
            "Date: Sat, 12 Sep 2026 14:00:00 +0800\nSHA256:\n" + "\n".join(hashes) + "\n",
            encoding="utf-8", newline="\n")
        return stable

    def test_metadata_failures_remain_failures_with_valid_signature(self):
        module = load_module("verify", ROOT / "tools/ziyan_apt/verify_repo.py")
        fixture = load_module("signing_fixture", ROOT / "tools/ziyan_apt/test_signing_fixture.py")
        gpgv = shutil.which("gpgv")
        if not gpgv:
            self.skipTest("gpgv required for cryptographic integration")
        signer = fixture.TestSigner()
        for corruption, expected in (
            ("empty_index", "PACKAGE_COUNT"), ("missing_arch", "FAILS="),
            ("missing_release_hash", "RELEASE_COVERAGE_MISSING"),
            ("wrong_release_size", "RELEASE_MISMATCH"),
            ("missing_release_field", "MISSING_RELEASE_FIELD"),
            ("duplicate_record", "DUPLICATE_PACKAGE_RECORD"),
            ("compressed_index", "COMPRESSED_INDEX_MISMATCH"),
        ):
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
                root = Path(td)
                stable = self.make_repo(root)
                index = stable / "main/binary-iphoneos-arm/Packages"
                release = (stable / "Release").read_text(encoding="utf-8")
                kwargs = {}
                if corruption == "empty_index":
                    index.write_bytes(b"")
                elif corruption == "missing_arch":
                    (stable / "main/binary-iphoneos-arm64/Packages").unlink()
                elif corruption == "missing_release_hash":
                    release = "\n".join(line for line in release.split("\n") if not line.endswith("/Packages.gz"))
                elif corruption == "wrong_release_size":
                    release = re.sub(r"(?m)^( [0-9a-f]{64}) \d+ ", r"\1 999999 ", release)
                elif corruption == "missing_release_field":
                    release = release.replace("Suite: stable\n", "")
                elif corruption == "duplicate_record":
                    kwargs["expected_count_per_arch"] = 2
                    index.write_bytes(index.read_bytes() * 2)
                    index.with_name("Packages.gz").write_bytes(gzip.compress(index.read_bytes()))
                elif corruption == "compressed_index":
                    index.with_name("Packages.gz").write_bytes(gzip.compress(b"different index"))
                (stable / "Release").write_bytes(release.encode())
                (stable / "Release.gpg").write_bytes(signer.sign(release.encode()))
                keyring = root / "operator-selected.gpg"
                keyring.write_bytes(signer.public_keyring)
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    code = module.main(root, trusted_keyring=keyring, gpgv=gpgv, **kwargs)
                self.assertNotEqual(code, 0, output.getvalue())
                self.assertIn(expected, output.getvalue())
                self.assertIn("SIGNATURE_VERIFIED=Release.gpg", output.getvalue())

    def test_actual_gpg_signatures_and_corruption(self):
        module = load_module("verify", ROOT / "tools/ziyan_apt/verify_repo.py")
        gpgv = shutil.which("gpgv")
        if not gpgv:
            self.skipTest("gpgv required for cryptographic integration")
        # Generate an ephemeral test key without GPG's persistent agent.
        # The production verifier still uses the real gpgv executable.
        fixture = load_module("signing_fixture", ROOT / "tools/ziyan_apt/test_signing_fixture.py")
        signer = fixture.TestSigner()
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            keyring = root / "trusted.gpg"
            keyring.write_bytes(signer.public_keyring)
            repo = root / "repo"
            repo.mkdir()
            stable = self.make_repo(repo)
            release = (stable / "Release").read_bytes()
            (stable / "Release.gpg").write_bytes(signer.sign(release))
            (stable / "InRelease").write_bytes(signer.clearsign(release))
            def verify(**kwargs):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    code = module.main(repo, trusted_keyring=kwargs.pop("trusted_keyring", keyring), gpgv=gpgv, **kwargs)
                return code, output.getvalue()
            code, output = verify()
            self.assertEqual(code, 0, output)
            self.assertIn("SIGNATURE_VERIFIED=Release.gpg", output)
            self.assertIn("SIGNATURE_VERIFIED=InRelease", output)
            self.assertNotEqual(verify(package="wrong.package")[0], 0)
            self.assertNotEqual(verify(expected_count_per_arch=2)[0], 0)
            self.assertNotEqual(verify(expected_version="wrong-version")[0], 0)
            self.assertIn("TRUST_MATERIAL_REQUIRED", verify(trusted_keyring=None)[1])
            wrong_keyring = root / "wrong-trusted.gpg"
            wrong_keyring.write_bytes(fixture.TestSigner().public_keyring)
            self.assertIn("SIGNATURE_INVALID", verify(trusted_keyring=wrong_keyring)[1])
            original = (stable / "Release.gpg").read_bytes()
            (stable / "Release.gpg").write_bytes(b"fake signature")
            self.assertNotEqual(verify()[0], 0)
            (stable / "Release.gpg").write_bytes(original)
            original_inline = (stable / "InRelease").read_bytes()
            (stable / "InRelease").write_bytes(signer.clearsign(release.replace(b"Label: ZiYan", b"Label: Different")))
            self.assertIn("INRELEASE_CONTENT_MISMATCH", verify()[1])
            (stable / "InRelease").write_bytes(original_inline)
            (stable / "Release").write_bytes(release.replace(b"Label: ZiYan", b"Label: Tampered"))
            self.assertIn("SIGNATURE_INVALID", verify()[1])
            (stable / "Release").write_bytes(release)
            payload = repo / "iphoneos-arm.deb"
            payload.write_bytes(b"tampered")
            self.assertNotEqual(verify()[0], 0)


class DeployExit(unittest.TestCase):
    def test_password_auth_probe_preserves_script_and_failure(self):
        source = (ROOT / "tools/zy_deploy_rootful_3phone.sh").read_text(encoding="utf-8")
        helper = source.split("ssh_r() {", 1)[1].split("\nscp_r()", 1)[0]
        script = '''SSH_KEY_OPTS=()
SSH_OPTS=()
PASS=fixture
ssh() { cat >/dev/null; return 255; }
sshpass() { cat; return 17; }
ssh_r() {''' + helper + '''
ssh_r 101 'bash -s' <<'REMOTE'
SCRIPT_MUST_REACH_PASSWORD_SESSION
REMOTE
'''
        result = subprocess.run([BASH, "--noprofile", "--norc", "-s"], input=script,
                                capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertIn("SCRIPT_MUST_REACH_PASSWORD_SESSION", result.stdout)

    def test_remote_failure_is_not_retried_as_empty_password_session(self):
        source = (ROOT / "tools/zy_deploy_rootful_3phone.sh").read_text(encoding="utf-8")
        helper = source.split("ssh_r() {", 1)[1].split("\nscp_r()", 1)[0]
        script = '''SSH_KEY_OPTS=()
SSH_OPTS=()
PASS=fixture
ssh() {
  [ "${@: -1}" != true ] || return 0
  payload=$(cat)
  printf 'REMOTE_EXECUTED:%s\n' "$payload"
  return 12
}
sshpass() { echo UNEXPECTED_PASSWORD_RETRY; return 0; }
ssh_r() {''' + helper + '''
ssh_r 101 'bash -s' <<'REMOTE'
exit 12
REMOTE
'''
        result = subprocess.run([BASH, "--noprofile", "--norc", "-s"], input=script,
                                capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 12, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("REMOTE_EXECUTED"), 1)
        self.assertNotIn("UNEXPECTED_PASSWORD_RETRY", result.stdout)

    def run_deploy(self, failed="", phase="postcheck"):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as td:
            root = Path(td)
            deb = root / "fixture_iphoneos-arm.deb"
            deb.write_bytes(b"fixture")
            source = (ROOT / "tools/zy_deploy_rootful_3phone.sh").read_text(encoding="utf-8")
            source = source.replace('ROOT="$(cd "$(dirname "$0")/.." && pwd)"', 'ROOT=' + repr(posix(ROOT)))
            start, end = source.index("ssh_r() {"), source.index('\nLOCAL_SHA=')
            substitute = '''ssh_r() {
  local host="$1" payload stage
  payload=$(cat)
  case "$payload" in
    *'dpkg -i'*) stage=install ;;
    *'test -d /Library'*) stage=preflight ;;
    *) stage=postcheck ;;
  esac
  echo "MOCK_VISIT host=$host stage=$stage"
  case " $TEST_FAILED " in
    *" $host "*) [ "$stage" != "$TEST_PHASE" ] || return 12 ;;
  esac
  return 0
}
scp_r() {
  local host="$2" stage=upload_package
  case "$3" in *entitlements.plist) stage=upload_entitlements ;; esac
  echo "MOCK_VISIT host=$host stage=$stage"
  case " $TEST_FAILED " in
    *" $host "*) [ "$stage" != "$TEST_PHASE" ] || return 23 ;;
  esac
  return 0
}
sleep() { return 0; }
shasum() { sha256sum "${@: -1}"; }
'''
            source = source[:start] + substitute + source[end:]
            env = dict(os.environ, ZY_DEPLOY_DEB=posix(deb), TEST_FAILED=failed, TEST_PHASE=phase)
            return subprocess.run([BASH, "--noprofile", "--norc", "-s", "--", "101", "112", "166"],
                                  input=source, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)

    def test_failed_postcheck_cannot_report_deploy_done(self):
        result = self.run_deploy("112")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("DEPLOY_DONE", result.stdout)
        self.assertIn("MOCK_VISIT host=166 stage=postcheck", result.stdout)

    def test_all_pass_reports_done(self):
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DEPLOY_DONE", result.stdout)
        self.assertEqual(result.stdout.count("status=passed"), 3)

    def test_all_failed_and_connection_failed_collect_results(self):
        for phase in ("postcheck", "preflight", "install"):
            with self.subTest(phase=phase):
                result = self.run_deploy("101 112 166", phase)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("DEPLOY_DONE", result.stdout)
                self.assertIn("MOCK_VISIT host=166 stage=" + phase, result.stdout)
                for host in ("101", "112", "166"):
                    self.assertIn("host=." + host + " status=failed stage=" + phase, result.stderr)

    def test_one_preflight_failure_preserves_other_results(self):
        result = self.run_deploy("101", "preflight")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DEPLOY_RESULT host=.166 status=passed", result.stdout)
        self.assertNotIn("MOCK_VISIT host=101 stage=install", result.stdout)

    def test_upload_failure_skips_install_and_keeps_other_results(self):
        for phase in ("upload_package", "upload_entitlements"):
            with self.subTest(phase=phase):
                result = self.run_deploy("112", phase)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("MOCK_VISIT host=112 stage=install", result.stdout)
                self.assertIn("host=.112 status=failed stage=" + phase + " exit=23", result.stderr)
                self.assertIn("host=.166 status=passed", result.stdout)
                self.assertNotIn("DEPLOY_DONE", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
