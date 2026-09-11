#!/usr/bin/env python3
"""Exercise the real Lua API and Foundation converter without claiming device PASS."""
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class PlistBackendTests(unittest.TestCase):
    def test_json_retains_decoded_object_shape(self):
        subprocess.run(["lua", "-e",
                        "package.path='lua/?.lua;'..package.path; local j=require('json'); "
                        "assert(j.encode(j.decode('{}'))=='{}'); "
                        "assert(j.encode(j.decode('[]'))=='[]'); "
                        "assert(j.encode({})=='[]'); "
                        "assert(j.encode(j.decode('{\"nested\":{}}'))=='{\"nested\":{}}')"],
                       cwd=ROOT, check=True)

    def test_missing_input_never_reuses_stale_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "var").mkdir()
            (root / "var/.ziyan_plist.json").write_text('{"old":true}')
            script = (
                f"ZIYAN_ROOT={json.dumps(temp)}; ZIYAN_VAR=ZIYAN_ROOT..'/var'; "
                "ZIYAN_ZYCV=ZIYAN_VAR; package.path='lua/?.lua;lua/?/init.lua;'..package.path; "
                "require('ziyan_engine.py_cv').install(); "
                "assert(PlistRead(ZIYAN_ROOT..'/missing.plist') == nil, 'stale plist data returned')")
            subprocess.run(["lua", "-e", script], cwd=ROOT, check=True)

    def test_foundation_converter_and_real_lua_api(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "var").mkdir()
            (root / "bin").mkdir()
            executable = root / "bin/ziyan_plist"
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                            str(ROOT / "tools/ziyan_plist/main.m"), "-o", str(executable)], check=True)
            value = {"marker": "quote' \" & < >", "count": 7, "nested": [True, False, 2.5, {}]}
            (root / "input.plist").write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
            (root / "bad.plist").write_bytes(b"not a plist")
            (root / "sentinel.plist").write_bytes(b"preserve")
            (root / "invalid.json").write_text('{"invalid":null}')
            failure = subprocess.run([str(executable), "write", str(root / "invalid.json"),
                                      str(root / "sentinel.plist")], capture_output=True)
            self.assertNotEqual(failure.returncode, 0)
            self.assertEqual((root / "sentinel.plist").read_bytes(), b"preserve")
            script = (
                f"ZIYAN_ROOT={json.dumps(temp)}; ZIYAN_VAR=ZIYAN_ROOT..'/var'; "
                "ZIYAN_ZYCV=ZIYAN_VAR; package.path='lua/?.lua;lua/?/init.lua;'..package.path; "
                "require('ziyan_engine.py_cv').install(); "
                "local value=assert(PlistRead(ZIYAN_ROOT..'/input.plist')); "
                "assert(value.count==7 and value.nested[1]==true and value.nested[2]==false); "
                "assert(PlistRead(ZIYAN_ROOT..'/missing.plist')==nil); "
                "assert(PlistRead(ZIYAN_ROOT..'/bad.plist')==nil); "
                "assert(PlistRead(nil)==nil); "
                "assert(PlistWrite('',{})==false); "
                "assert(PlistWrite(ZIYAN_ROOT..'/missing-dir/written.plist', value)); "
                "assert(PlistWrite(ZIYAN_ROOT, value)==false)")
            subprocess.run(["lua", "-e", script], cwd=ROOT, check=True)
            self.assertEqual(plistlib.loads((root / "missing-dir/written.plist").read_bytes()), value)


if __name__ == "__main__":
    unittest.main()
