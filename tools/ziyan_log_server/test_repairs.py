"""Isolated HTTP regressions for tickets 4, 9 and 10. Never uses real server data."""
import concurrent.futures
import hashlib
import http.client
import importlib.util
import io
import json
import lzma
import os
from pathlib import Path
import queue
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.parse
import unittest
from unittest import mock
import zipfile

spec = importlib.util.spec_from_file_location("log_server", Path(__file__).with_name("server.py"))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


def deb_bytes(version="1.2-1", arch="iphoneos-arm", package="com.ziyan.ziyan", payload=b"synthetic payload", compression="gz"):
    def tar(name, data):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz" if compression=="gz" else "w") as tf:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        return lzma.compress(buf.getvalue(), format=lzma.FORMAT_ALONE) if compression=="lzma" else buf.getvalue()
    control = (f"Package: {package}\nVersion: {version}\nArchitecture: {arch}\n"
               "Depends: firmware (>= 13.0), ellekit | mobilesubstrate\n").encode()
    out = b"!<arch>\n"
    for name, data in [("debian-binary", b"2.0\n"), ("control.tar."+compression, tar("./control", control)),
                       ("data.tar."+compression, tar("./usr/lib/ziyan/sample", payload))]:
        ar_name = name + "/" if len(name) < 16 else name
        out += f"{ar_name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode()
        out += data + (b"\n" if len(data) % 2 else b"")
    return out


class HTTPRepairs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ziyan-http-repair-")
        s.ROOT = self.tmp.name
        s.ADMIN_TOKEN = "synthetic-administrator-token"
        s.LOG_TOKEN = "synthetic-device-token"
        s.IMPORT_ROOT = str(Path(self.tmp.name, "imports"))
        Path(s.IMPORT_ROOT).mkdir()
        s.ensure_dirs()
        self.httpd = s.ThreadingHTTPServer(("127.0.0.1", 0), s.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def request(self, path, body=None, token=None):
        con = http.client.HTTPConnection("127.0.0.1", self.httpd.server_port, timeout=10)
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        con.request("POST" if body is not None else "GET", path,
                    json.dumps(body) if body is not None else None, headers)
        res = con.getresponse()
        data = res.read()
        status = res.status
        con.close()
        try:
            data = json.loads(data)
        except (ValueError, UnicodeDecodeError):
            pass
        return status, data

    def publish_body(self, version="1.2-1", arch="iphoneos-arm"):
        p = Path(s.IMPORT_ROOT, arch + ".deb")
        p.write_bytes(deb_bytes(version, arch))
        return {"version": version, "architecture": arch, "package_path": str(p),
                "channel": "stable", "min_os": "13.0", "max_os": "16.7.99", "ziyan_min": "1.0"}

    def test_publish_requires_admin_and_rejects_device_token(self):
        body = self.publish_body()
        self.assertEqual(self.request("/api/hotupdate/publish", body)[0], 401)
        self.assertEqual(self.request("/api/hotupdate/publish", body, s.LOG_TOKEN)[0], 403)
        self.assertFalse(Path(s.manifest_path()).exists())

    def test_publish_rejects_outside_fake_and_mismatched_package(self):
        body = self.publish_body()
        p = Path(self.tmp.name, "outside.deb")
        p.write_bytes(deb_bytes())
        body["package_path"] = str(p)
        self.assertEqual(self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)[0], 400)
        body = self.publish_body()
        Path(body["package_path"]).write_bytes(b"!<arch>\n" + b"secret data" * 100)
        self.assertEqual(self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)[0], 400)
        body = self.publish_body()
        body["architecture"] = "iphoneos-arm64"
        self.assertEqual(self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)[0], 400)

    def test_dual_arch_publish_download_and_strict_upgrade(self):
        for arch in ("iphoneos-arm", "iphoneos-arm64"):
            body = self.publish_body(arch=arch)
            st, result = self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)
            self.assertEqual(st, 200, result)
            st, content = self.request(result["url"])
            self.assertEqual(st, 200)
            self.assertEqual(hashlib.sha256(content).hexdigest(), result["sha256"])
        for arch in ("iphoneos-arm", "iphoneos-arm64"):
            for current, expected in [("1.1", True), ("1.2-1", False), ("2.0", False)]:
                st, data = self.request(f"/api/hotupdate/check?arch={arch}&os=15.8.8&ziyan={current}")
                self.assertEqual(st, 200)
                self.assertEqual(data["update"], expected, data)
                if expected:
                    self.assertEqual(data["architecture"], arch)

    def test_debian_version_semantics(self):
        for low, high in [("1.0~rc1", "1.0"), ("1.0-2", "1.0-10"), ("1.0+a", "1.0+b"),
                          ("1.9", "1.10"), ("1:99.0", "2:1.0"), ("1.0~~", "1.0~")]:
            self.assertLess(s.cmp_version(low, high), 0, (low, high))
        self.assertEqual(s.cmp_version("1.0", "1.0-0"), 0)

    def test_legacy_theos_lzma_alone_deb_publishes_and_downloads(self):
        body = self.publish_body()
        payload = deb_bytes(compression="lzma")
        Path(body["package_path"]).write_bytes(payload)
        status, result = self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)
        self.assertEqual(status, 200, result)
        self.assertEqual(self.request(result["url"])[1], payload)

    def test_event_conflicts_do_not_overwrite_and_export_matches(self):
        one = {"event_id": "shared", "message": "first"}
        two = {"event_id": "shared", "message": "second"}
        barrier = threading.Barrier(2)
        def post(report):
            barrier.wait()
            return self.request("/api/logs", report, s.LOG_TOKEN)
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(post, [one, two]))
        self.assertEqual(sorted(st for st, _ in results), [200, 409])
        st, stored = self.request("/api/logs/shared")
        self.assertEqual(st, 200)
        st, dedup = self.request("/api/logs", stored, s.LOG_TOKEN)
        self.assertEqual(st, 200)
        self.assertTrue(dedup["dedup"])
        entry = s.find_index_entry("shared")
        raw = Path(s.ROOT, entry["path"]).read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), entry["sha256"])
        st, archive = self.request("/api/logs/download.zip")
        with zipfile.ZipFile(io.BytesIO(archive)) as zf:
            self.assertEqual(zf.read("shared.json"), raw)
        self.assertEqual(self.request("/api/logs")[1]["items"][0]["message"], stored["message"])

    def test_index_failure_recovers_without_false_success(self):
        original = s.atomic_write_text
        def fail_index(path, text):
            if path == s.index_path():
                raise OSError("synthetic index failure")
            return original(path, text)
        with mock.patch.object(s, "atomic_write_text", side_effect=fail_index):
            st, _ = self.request("/api/logs", {"event_id": "recover", "message": "durable"}, s.LOG_TOKEN)
            self.assertEqual(st, 500)
        s.ensure_dirs()  # startup recovery uses the same durable journal as a fresh process
        st, data = self.request("/api/logs")
        self.assertEqual(st, 200)
        self.assertEqual(data["total"], 1)
        entry = s.find_index_entry("recover")
        self.assertEqual(s.sha256_file(os.path.join(s.ROOT, entry["path"])), entry["sha256"])

    def test_authorization_disabled_revoked_and_separate_ingest_permissions(self):
        body = self.publish_body()
        previous = s.ADMIN_TOKEN
        s.ADMIN_TOKEN = "synthetic-rotated-administrator-token"
        self.assertEqual(self.request("/api/hotupdate/publish", body, previous)[0], 403)
        self.assertEqual(self.request("/api/admin/session", token=previous)[0], 403)
        self.assertEqual(self.request("/api/logs", {"event_id": "admin-upload"}, s.ADMIN_TOKEN)[0], 403)
        self.assertEqual(self.request("/api/logs", {"event_id": "device-upload"}, s.LOG_TOKEN)[0], 200)
        s.ADMIN_TOKEN = ""
        status, data = self.request("/api/hotupdate/publish", body, previous)
        self.assertEqual((status, data["error"]), (503, "admin_not_configured"))

    def test_metadata_limits_wrong_identity_and_errors_do_not_leak_paths(self):
        for changes in ({"version": "9.0"}, {"min_os": "12.0"}, {"max_os": "12.0"}, {"sha256": "b" * 64}):
            body = self.publish_body()
            body.update(changes)
            status, data = self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)
            self.assertEqual(status, 400)
            self.assertNotIn(self.tmp.name, json.dumps(data))
        body = self.publish_body()
        Path(body["package_path"]).write_bytes(deb_bytes(package="com.synthetic.other"))
        self.assertEqual(self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)[0], 400)

    def test_republishing_identical_bytes_is_idempotent_and_conflicts_preserve_download(self):
        body = self.publish_body()
        _, original = self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)
        body["notes"] = "not actually committed by an idempotent retry"
        _, repeated = self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)
        manifest = self.request("/hotupdate/manifest.json")[1]
        self.assertEqual(repeated["notes"], manifest["versions"][0]["notes"])
        self.assertEqual(len(manifest["versions"]), 1)
        Path(body["package_path"]).write_bytes(deb_bytes(payload=b"different bytes"))
        self.assertEqual(self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)[0], 409)
        self.assertEqual(hashlib.sha256(self.request(original["url"])[1]).hexdigest(), original["sha256"])

    def test_debian_selection_arch_fallback_incompatible_and_encoded_versions(self):
        for version, arch in [("1.0~rc1", "iphoneos-arm"), ("1.0", "iphoneos-arm"),
                              ("1.0-2", "iphoneos-arm"), ("1.0-10", "iphoneos-arm"),
                              ("2:1.0+fix", "iphoneos-arm64")]:
            body = self.publish_body(version, arch)
            body["ziyan_min"] = "0.1"
            self.assertEqual(self.request("/api/hotupdate/publish", body, s.ADMIN_TOKEN)[0], 200)
        for arch, current, target in [("iphoneos-arm", "1.0-2", "1.0-10"),
                                     ("iphoneos-arm64", "1:99.0", "2:1.0+fix")]:
            query = urllib.parse.urlencode({"arch": arch, "os": "15.8.8", "ziyan": current})
            data = self.request("/api/hotupdate/check?" + query)[1]
            self.assertTrue(data["update"], data)
            self.assertEqual(data["version"], target)
        data = self.request("/api/hotupdate/check?arch=iphoneos-arm&os=17.0&ziyan=1.0")[1]
        self.assertEqual((data["update"], data["reason"]), (False, "device_incompatible"))

    def test_parallel_idempotent_posts_and_other_events_finish_consistently(self):
        reports = [{"event_id": "same", "message": "fixed"}] * 8
        reports += [{"event_id": f"distinct-{n}", "message": str(n)} for n in range(8)]
        begin = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda body: self.request("/api/logs", body, s.LOG_TOKEN), reports))
        elapsed = time.monotonic() - begin
        self.assertTrue(all(status == 200 for status, _ in results), results)
        entries = s.load_index_entries()
        self.assertEqual(len(entries), 9)
        self.assertEqual(sum(bool(result.get("dedup")) for _, result in results), 7)
        for entry in entries:
            self.assertEqual(s.sha256_file(os.path.join(s.ROOT, entry["path"])), entry["sha256"])
        self.assertLess(elapsed, 15)
        print(f"CONCURRENCY 16 requests / 4 workers: {elapsed:.3f}s; 9 immutable events")

    def test_real_process_interruption_restarts_from_durable_journal(self):
        root = str(Path(self.tmp.name, "process-case"))
        def launch(crash=False):
            child = subprocess.Popen([sys.executable, str(Path(__file__).with_name("ui_fixture.py")), root]
                                     + (["--crash-index"] if crash else []), stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True)
            ready = queue.Queue()
            threading.Thread(target=lambda: ready.put(child.stdout.readline()), daemon=True).start()
            try:
                port = json.loads(ready.get(timeout=10))["port"]
            except Exception:
                child.kill(); child.wait(timeout=5)
                raise
            return child, port
        child, port = launch(True)
        try:
            con = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            con.request("POST", "/api/logs", json.dumps({"event_id": "restart", "message": "durable"}),
                        {"Authorization": "Bearer synthetic-browser-device-token"})
            with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError)):
                con.getresponse()
            con.close()
            self.assertEqual(child.wait(timeout=10), 73)
            self.assertTrue(Path(root, "logs", ".pending.json").exists())
        finally:
            if child.poll() is None: child.kill(); child.wait(timeout=5)
            child.stdout.close(); child.stderr.close()
        child, port = launch()
        try:
            duplicate = subprocess.run([sys.executable, str(Path(__file__).with_name("server.py")),
                                        "--root", root, "--port", "0"], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(duplicate.returncode, 0)
            self.assertIn("data root is already in use", duplicate.stderr)
            con = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            con.request("GET", "/api/logs")
            response = con.getresponse()
            data = json.loads(response.read()); con.close()
            self.assertEqual((response.status, data["total"]), (200, 1))
            entry = json.loads(Path(root, "logs", "index.jsonl").read_text())
            self.assertEqual(hashlib.sha256(Path(root, entry["path"]).read_bytes()).hexdigest(), entry["sha256"])
            self.assertFalse(Path(root, "logs", ".pending.json").exists())
        finally:
            child.kill(); child.wait(timeout=5)
            child.stdout.close(); child.stderr.close()

    def test_startup_rejects_implicit_lan_and_shared_role_token(self):
        script = str(Path(__file__).with_name("server.py"))
        result = subprocess.run([sys.executable, script, "--root", self.tmp.name,
                                 "--host", "0.0.0.0", "--port", "0"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --allow-lan", result.stderr)
        token_file = Path(self.tmp.name, "synthetic-token.txt")
        token_file.write_text("synthetic-same-token-for-both-roles")
        result = subprocess.run([sys.executable, script, "--root", self.tmp.name, "--port", "0",
                                 "--admin-token-file", str(token_file), "--log-token-file", str(token_file)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("publisher and device tokens must differ", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
