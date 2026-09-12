"""Real HTTP client contract against a controlled loopback service."""
import json
import io
import threading
import time
import tkinter as tk
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import ZiYanColorPicker as picker
from PIL import Image


class Handler(BaseHTTPRequestHandler):
    token = "test_session_token"
    seen = []

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.respond(body)

    def do_GET(self):
        self.respond(b"")

    def respond(self, body):
        Handler.seen.append((self.path, self.headers.get("Authorization"), body))
        if self.path == "/pair":
            ok = body == b"code=valid_code"
            if ok:
                self.server.paired = True
            data = {"token": self.token, "expires_in": 900} if ok else {"err": "invalid_code"}
        else:
            ok = self.server.paired and self.headers.get("Authorization") == "Bearer " + self.token
            data = {"ok": True, "x": 12, "y": 20} if ok else {"err": "pairing_required_or_expired"}
            if ok and self.path == "/pairing/revoke":
                self.server.paired = False
        raw = json.dumps(data).encode()
        if ok and self.path.startswith("/snapshot?"):
            image = io.BytesIO()
            Image.new("RGB", (4, 6), "green").save(image, format="PNG")
            raw = image.getvalue()
        self.send_response(200 if ok else 401)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class AccessContract(unittest.TestCase):
    def setUp(self):
        Handler.seen = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.paired = False
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.ports = patch.object(picker, "SNAP_PORTS", (self.server.server_port,))
        self.ports.start()
        self.client = picker.DeviceClient()
        self.client.set_ip("127.0.0.1")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.ports.stop()

    def test_pair_then_find_and_revoke(self):
        self.client.pair("127.0.0.1", "valid_code")
        result = self.client.findtest("127.0.0.1", 1, 0x123456, "", 90, 0, 0, 10, 10)
        self.assertEqual(result["x"], 12)
        self.assertEqual(Handler.seen[-1][1], "Bearer test_session_token")
        self.client.revoke("127.0.0.1")
        with self.assertRaises(picker.PairingRequired):
            self.client.request("127.0.0.1", self.server.server_port, "GET", "/status", token=Handler.token)
        with self.assertRaises(picker.PairingRequired):
            self.client.findtest("127.0.0.1", 1, 1, "", 90, 0, 0, 10, 10)

    def test_wrong_and_expired_pairing_are_explicit(self):
        with self.assertRaises(picker.PairingRequired):
            self.client.pair("127.0.0.1", "wrong")
        self.client.pair("127.0.0.1", "valid_code")
        with patch.object(picker.time, "monotonic", return_value=10**12):
            with self.assertRaises(picker.PairingRequired):
                self.client.findtest("127.0.0.1", 0, 1, "", 90, 0, 0, 1, 1)

    def test_device_change_clears_authorization(self):
        self.client.pair("127.0.0.1", "valid_code")
        self.client.set_ip("127.0.0.2")
        self.client.set_ip("127.0.0.1")
        with self.assertRaises(picker.PairingRequired):
            self.client.findtest("127.0.0.1", 0, 1, "", 90, 0, 0, 1, 1)

    def test_pair_probe_and_snapshot_send_same_credential(self):
        self.client.pair("127.0.0.1", "valid_code")
        self.assertEqual(self.client.probe("127.0.0.1")[0], self.server.server_port)
        image = self.client.snapshot("127.0.0.1", 0)
        self.assertEqual(image.getpixel((0, 0)), (0, 128, 0))
        self.assertEqual(Handler.seen[-1][0], "/snapshot?orient=0")
        self.assertTrue(all(auth == "Bearer test_session_token" for path, auth, _ in Handler.seen if path != "/pair"))

    def test_real_dialog_pairs_snapshots_and_revokes(self):
        app = picker.App()
        app.withdraw()
        errors = []
        app.report_callback_exception = lambda *args: errors.append(args)

        def wait_until(predicate):
            end = time.monotonic() + 3
            def tick():
                if predicate() or time.monotonic() >= end:
                    app.quit()
                else:
                    app.after(10, tick)
            app.after(10, tick)
            app.mainloop()
            self.assertTrue(predicate())

        def descendants(widget):
            for child in widget.winfo_children():
                yield child
                yield from descendants(child)

        try:
            app.device_ip.set("127.0.0.1")
            app.open_device_dialog()
            dialog = next(w for w in app.winfo_children() if isinstance(w, tk.Toplevel) and w.title() == "连接设备")
            dialog.withdraw()
            widgets = list(descendants(dialog))
            buttons = {w.cget("text"): w for w in widgets if isinstance(w, tk.Button)}
            code = next(w for w in widgets if isinstance(w, tk.Entry) and w.cget("show") == "*")
            code.insert(0, "valid_code")
            buttons["配对"].invoke()
            wait_until(lambda: app.lbl_dev.cget("text") == "设备: 已配对")
            self.assertEqual(code.get(), "")
            buttons["截屏"].invoke()
            wait_until(lambda: len(app.image_windows) == 1 and not app._snap_busy)
            self.assertEqual(app.image_windows[0].img.getpixel((0, 0)), (0, 128, 0))
            buttons["撤销配对并关闭设备远程入口"].invoke()
            wait_until(lambda: app.lbl_dev.cget("text") == "设备: 未配对")
            self.assertFalse(self.server.paired)
            self.assertIsNone(app.dev._token)
            self.assertEqual(errors, [])
        finally:
            app.destroy()


if __name__ == "__main__":
    unittest.main()
