"""Synthetic loopback-only server used by the browser acceptance script."""
import json
import os
from pathlib import Path
import sys

from test_repairs import deb_bytes, s

s.ROOT = sys.argv[1]
s.IMPORT_ROOT = str(Path(s.ROOT, "imports"))
s.ADMIN_TOKEN = "synthetic-browser-publisher-token"
s.LOG_TOKEN = "synthetic-browser-device-token"
Path(s.IMPORT_ROOT).mkdir(parents=True, exist_ok=True)
Path(s.IMPORT_ROOT, "sample.deb").write_bytes(deb_bytes())
storage_lock = s.acquire_storage_lock()
s.ensure_dirs()
if "--crash-index" in sys.argv:
    original_write = s.atomic_write_text
    def crash_index(path, text):
        if path == s.index_path():
            os._exit(73)  # Deliberately interrupt this synthetic fixture after durable body save.
        return original_write(path, text)
    s.atomic_write_text = crash_index
httpd = s.ThreadingHTTPServer(("127.0.0.1", 0), s.Handler)
print(json.dumps({"port": httpd.server_port}), flush=True)
httpd.serve_forever()
