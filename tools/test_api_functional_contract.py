#!/usr/bin/env python3
"""Local fixture/ledger checks; no device PASS can be produced by these tests."""
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import ziyan_api_functional as api


class FunctionalEvidenceTests(unittest.TestCase):
    def test_inventory_preserves_all_cases_without_promoting_binding(self):
        before = api.digest(api.MATRIX)
        with tempfile.TemporaryDirectory() as directory:
            inventory = api.inventory(Path(directory))
            self.assertEqual(inventory["case_count"], 101)
            self.assertEqual(len(inventory["families"]), 12)
            self.assertFalse(inventory["functional_pass"])
            for case in inventory["cases"]:
                for result in case["functional_devices"].values():
                    self.assertEqual(result["verdict"], "NOT_RUN")
                    self.assertEqual(set(result["coverage"].values()), {"NOT_FUNCTIONALLY_TESTED"})
        self.assertEqual(before, api.digest(api.MATRIX))

    def test_hash_works_on_bundled_python(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "data"
            path.write_bytes(b"abc")
            self.assertEqual(api.digest(path), hashlib.sha256(b"abc").hexdigest())

    def test_timeout_is_evidence_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(api.subprocess, "run", side_effect=subprocess.TimeoutExpired(["test"], 1)):
                result = api.command(["test"], Path(directory) / "log")
            self.assertEqual(result.returncode, 124)

    def test_process_counts_exclude_shell_command_text(self):
        result = api.parse_state(
            "PROCESSES_BEGIN\n"
            "1 /usr/lib/ziyan/bin/ziyan_framecap serve\n"
            "2 /bin/sh -c grep ziyan_framecap serve\n"
            "3 /System/Library/CoreServices/SpringBoard.app/SpringBoard\n"
            "4 /usr/lib/ziyan/bin/lua5.3 /tmp/fixture.lua\n"
            "PROCESSES_END\n")
        self.assertEqual(result["fc_n"], "1")
        self.assertEqual(result["lua_n"], "1")
        self.assertEqual(result["sb_pid"], "3")

    def test_lua_syntax(self):
        subprocess.run(["lua", "-e", 'assert(loadfile(arg[1]))', "-", str(api.FIXTURE)], check=True)

    def test_redacted_root_process_requires_live_owner_evidence(self):
        text = (
            "PROCESSES_BEGIN\n"
            "68314 (ziyan_framecap)\n"
            "12 /bin/sh -c ziyan_framecap serve\n"
            "41080 /System/Library/CoreServices/SpringBoard.app/SpringBoard\n"
            "PROCESSES_END\n"
            "sample_ts=1000\n"
            "framecap_owner=pid=68314 ts=999 lock_generation=1\n"
            "framecap_alive=ts=999 pid=68314\n")
        result = api.parse_state(text)
        self.assertEqual(result["fc_n"], "1")
        self.assertEqual(result["fc_identity"], "redacted_comm_live_owner")
        self.assertEqual(result["lua_n"], "0")
        for changed in (text.replace("sample_ts=1000", "sample_ts=1100"),
                        text.replace("sample_ts=1000", "sample_ts="),
                        text.replace("framecap_owner=pid=68314", "framecap_owner=pid=7")):
            self.assertEqual(api.parse_state(changed)["fc_identity"], "UNVERIFIED")
        self.assertEqual(api.parse_state(text.replace(
            "12 /bin/sh", "13 (lua5.3)\n12 /bin/sh"))["lua_n"], "1")
        self.assertEqual(api.parse_state(text.replace(
            "12 /bin/sh", "14 (ziyan_framecap)\n12 /bin/sh"))["fc_n"], "2")

    def test_cleanup_requires_all_idle_markers_and_unchanged_host(self):
        before = {"fc_n": "1", "lua_n": "0", "sb_pid": "7",
                  "fc_identity": "full_argv", "keep": "0", "active": "0", "embed": "0"}
        self.assertTrue(api.cleanup_complete(before, before, 0))
        for key, value in (("keep", "1"), ("active", "1"), ("embed", "1"),
                           ("sb_pid", "8"), ("fc_identity", "UNVERIFIED"), ("lua_n", "1")):
            self.assertFalse(api.cleanup_complete(before, {**before, key: value}, 0))
        self.assertFalse(api.cleanup_complete(before, before, 1))
        self.assertFalse(api.cleanup_complete(before, {"fc_n": "1", "lua_n": "0", "sb_pid": "7"}, 0))

    def test_invalid_payload_cannot_run_scenarios(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            ledger = api.inventory(out)
            pre = subprocess.CompletedProcess([], 0,
                "version=expected\nkeep=0\nactive=0\nembed=0\nPROCESSES_BEGIN\n"
                "1 /usr/lib/ziyan/bin/ziyan_framecap serve\n"
                "7 /System/Library/CoreServices/SpringBoard.app/SpringBoard\nPROCESSES_END\n", "")
            failed = subprocess.CompletedProcess([], 1, "payload mismatch\n", "")
            after = subprocess.CompletedProcess([], 0, "fc_n=1\nlua_n=0\nsb_pid=7\n", "")
            with patch.object(api, "package_identity", return_value=(Path("pkg"), "expected", "sha", {"/lua": "bad"})):
                with patch.object(api, "command", side_effect=[pre, failed, after]) as run:
                    api.run_device(out, "file", "101", ledger)
            verdict = json.loads((out / "file/101/VERDICT.json").read_text())
            self.assertFalse(verdict["started"])
            self.assertEqual(verdict["verdict"], "DEVICE_INCONCLUSIVE")
            self.assertEqual(verdict["reason"], "installed_runtime_differs_from_checkpoint_package")
            self.assertEqual(run.call_count, 3)

    def test_candidate_deploy_without_sudo_credentials_never_uploads(self):
        from tools import ziyan_api_candidate_deploy as deploy
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "candidate.deb"
            package.write_bytes(b"fixture")
            manifest = root / "packages.json"
            api.save(manifest, {"rootless": {"path": str(package), "version": "candidate",
                                           "sha256": api.digest(package)}})
            pre = subprocess.CompletedProcess([], 0,
                "keep=0\nactive=0\nembed=0\nPROCESSES_BEGIN\n"
                "1 /var/jb/usr/lib/ziyan/bin/ziyan_framecap serve\n"
                "7 /System/Library/CoreServices/SpringBoard.app/SpringBoard\nPROCESSES_END\n", "")
            with patch.dict(os.environ, {}, clear=True), patch.object(api, "command", return_value=pre) as run:
                with patch("sys.argv", ["deploy", "--manifest", str(manifest),
                                       "--out", str(root / "deploy"), "--device", "61"]):
                    deploy.main()
            self.assertEqual(run.call_count, 1)
            result = json.loads((root / "deploy/61/VERDICT.json").read_text())
            self.assertEqual(result["reason"], "ZY61_SUDO_PASS_NOT_CONFIGURED")
            self.assertEqual(result["verdict"], "INSTALL_INCONCLUSIVE")


if __name__ == "__main__":
    unittest.main()
