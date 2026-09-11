#!/usr/bin/env python3
"""Static contract for the fixed Windows read-only inventory."""

from pathlib import Path
import importlib.util
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
PS = (ROOT / "tools" / "e48_legend_readonly_manifest.ps1").read_text(encoding="utf-8")
RUNNER = (ROOT / "tools" / "e48_readonly_ps.py").read_text(encoding="utf-8")
SPEC = importlib.util.spec_from_file_location(
    "e48_readonly_ps", ROOT / "tools" / "e48_readonly_ps.py"
)
RUNNER_MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(RUNNER_MODULE)


class E48ReadOnlyManifestContract(unittest.TestCase):
    def test_fixed_root_and_output_schema(self) -> None:
        self.assertIn('$root = "E:\\传奇世界"', PS)
        self.assertIn('sourceRoot = "E:\\传奇世界"', PS)
        self.assertIn('accessMode = "read_only"', PS)
        self.assertIn("relativePath =", PS)
        self.assertIn("sha256 =", PS)
        self.assertIn("touchSpriteApiCalls =", PS)
        self.assertIn("fileDependencies =", PS)
        self.assertIn("Group-Object", PS)
        self.assertIn("[object[]]$luaFacts.touchSpriteApiCalls", PS)

    def test_no_remote_mutators(self) -> None:
        prohibited = (
            "Set-Content",
            "Add-Content",
            "Out-File",
            "Remove-Item",
            "Move-Item",
            "Rename-Item",
            "Copy-Item",
            "New-Item",
            "Start-Process",
            "Invoke-Expression",
        )
        for token in prohibited:
            self.assertNotIn(token, PS)

    def test_collections_are_powershell_arrays(self) -> None:
        self.assertIn("$allowed = @()", PS)
        self.assertIn("$excluded = @()", PS)
        self.assertNotIn("System.Collections.Generic.List", PS)

    def test_all_copyable_text_files_receive_sensitive_content_check(self) -> None:
        self.assertIn("if ($textExtensions -contains $extension)", PS)
        self.assertIn("$sensitiveContent.IsMatch($textBody)", PS)

    def test_runner_only_executes_encoded_fixed_script(self) -> None:
        self.assertIn("DEFAULT_SCRIPT", RUNNER)
        self.assertIn('"-EncodedCommand"', RUNNER)
        self.assertIn("[Console]::In.ReadToEnd()", RUNNER)
        self.assertIn("input=encoded_script(DEFAULT_SCRIPT)", RUNNER)
        self.assertIn('completed.stdout.decode("utf-8")', RUNNER)
        self.assertIn('completed.stderr.decode("utf-8", errors="replace")', RUNNER)
        self.assertIn("normalize_result", RUNNER)
        self.assertNotIn("parser.add_argument(\"--command\"", RUNNER)

    def test_encoded_command_fits_windows_command_line_limit(self) -> None:
        encoded = RUNNER_MODULE.encoded_command()
        self.assertLess(len(encoded), 8000)
        self.assertGreater(
            len(RUNNER_MODULE.encoded_script(ROOT / "tools" / "e48_legend_readonly_manifest.ps1")),
            8000,
        )

    def test_dry_run_does_not_require_output(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "e48_readonly_ps.py"), "--dry-run"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("E48_READONLY_DRY_RUN", completed.stdout)

    def test_normalize_result_makes_singletons_arrays(self) -> None:
        result = RUNNER_MODULE.normalize_result(
            {
                "files": [
                    {
                        "modules": "TSLib",
                        "fileDependencies": {},
                        "resources": {},
                        "touchSpriteApiCalls": {"name": "mSleep", "count": 1},
                    }
                ],
                "exclusions": {"records": {"reason": "sensitive"}},
            }
        )
        entry = result["files"][0]
        self.assertEqual(entry["modules"], ["TSLib"])
        self.assertEqual(entry["fileDependencies"], [{}])
        self.assertEqual(entry["resources"], [{}])
        self.assertEqual(entry["touchSpriteApiCalls"][0]["name"], "mSleep")
        self.assertEqual(len(result["exclusions"]["records"]), 1)


if __name__ == "__main__":
    unittest.main()
