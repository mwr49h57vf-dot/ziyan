"""The protected launcher must run without source modules beside it."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from protect_build import build_payload


class ProtectedSnapshotClient(unittest.TestCase):
    def test_source_free_launcher_contains_pairing_client(self):
        source = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix="ziyan-picker-payload-") as temp:
            target = Path(temp)
            build_payload(str(target / "_zy_payload.bin"))
            for name in ("picker_boot.py", "protect_build.py", "picker_imports.py"):
                if (source / name).exists():
                    shutil.copy2(source / name, target / name)
            script = "import runpy,sys;sys.path.insert(0,sys.argv[1]);sys.argv=['picker_boot.py','--smoke'];runpy.run_path(sys.argv[0],run_name='__main__')"
            result = subprocess.run([sys.executable, "-I", "-B", "-c", script, temp], cwd=temp,
                                    capture_output=True, text=True, timeout=10,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ok", result.stdout.lower())


if __name__ == "__main__":
    unittest.main()
