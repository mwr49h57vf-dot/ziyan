#!/usr/bin/env python3
"""Contract checks for the device-side E48 evidence writer."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tools" / "e48_device112_sample_matrix.sh"


class E48Device112MatrixContract(unittest.TestCase):
    def test_password_transport_does_not_exhaust_public_key_attempts(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("-o PubkeyAuthentication=no", source)
        self.assertIn("-o PreferredAuthentications=password", source)
        self.assertNotIn('"root@$IP:', source)

    def test_remote_evidence_does_not_require_device_awk(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        remote = source.split("<<'EOS'", 1)[1].split("EOS", 1)[0]
        self.assertNotIn("awk", remote)

    def test_remote_verdict_has_runtime_identity_fields_and_injection(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        for field in ("package_sha256", "script_sha256", "resource_sha256"):
            self.assertIn(f'echo "{field}=', source)
        self.assertIn("PKG_SHA='$PKG_SHA' REMOTE_SHA='$remote_sha'", source)
        self.assertIn("RESOURCE_SHA='$ASSET_SHA'", source)
        self.assertNotIn("__PACKAGE_SHA__", source)
        self.assertNotIn("__SCRIPT_SHA__", source)
        self.assertNotIn("__RESOURCE_SHA__", source)
        self.assertIn('"$VAR/.ziyan_app_user_closed"', source)
        self.assertIn('printf \'%s\\n\' "$BID" > "$MEDIA/.ziyan_open_app"', source)
        self.assertIn("run_pid=$(sed -n 's/^pid=//p'", source)
        self.assertIn("springboard_pid=$sb", source)
        self.assertIn("backboardd_pid=$bb", source)
        self.assertIn("identity_fields_valid=$identity_ok", source)
        self.assertIn("pid_fields_valid=$pid_ok", source)
        self.assertIn('printf \'%s\\n\' "$BID" > "$VAR/.ziyan_open_app"', source)
        self.assertIn("open_app_ready=$open_app_ready", source)


if __name__ == "__main__":
    unittest.main()
