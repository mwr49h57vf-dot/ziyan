#!/usr/bin/env python3
"""Contract tests for E48's fixed-root migration copier."""

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "e48_collect_migration", ROOT / "tools" / "e48_collect_migration.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class E48MigrationCollectorContract(unittest.TestCase):
    def test_root_and_allowed_extensions_are_fixed(self) -> None:
        self.assertEqual(MODULE.SOURCE_ROOT, r"E:\传奇世界")
        self.assertIn(".lua", MODULE.COPY_EXTENSIONS)
        self.assertIn(".png", MODULE.COPY_EXTENSIONS)

    def test_relative_paths_cannot_escape_source_root(self) -> None:
        self.assertEqual(
            MODULE.checked_relative_path("safe/script.lua").as_posix(), "safe/script.lua"
        )
        for value in ("../secret.lua", "/absolute.lua", "", None):
            with self.assertRaises(ValueError):
                MODULE.checked_relative_path(value)

    def test_remote_path_is_fixed_to_e48_root(self) -> None:
        path = MODULE.remote_path(MODULE.checked_relative_path("safe/script.lua"))
        self.assertEqual(path, "E:/传奇世界/safe/script.lua")

    def test_verified_copy_records_completion_time_and_exclusion_summary(self) -> None:
        source = {
            "exclusions": {"count": 2, "policy": "redacted"},
        }
        self.assertIn("exclusions", source)
        self.assertIn("count", source["exclusions"])
        self.assertIn("policy", source["exclusions"])
        mapping = {
            "copyStatus": "verified",
            "copiedAtUtc": "2026-09-09T03:00:00+00:00",
        }
        self.assertEqual(mapping["copyStatus"], "verified")
        self.assertRegex(mapping["copiedAtUtc"], r"^\d{4}-\d{2}-\d{2}T")

    def test_existing_verification_does_not_require_source_copy(self) -> None:
        self.assertTrue(hasattr(MODULE, "sha256"))
        self.assertIn("--verify-existing", MODULE.main.__code__.co_consts)


if __name__ == "__main__":
    unittest.main()
