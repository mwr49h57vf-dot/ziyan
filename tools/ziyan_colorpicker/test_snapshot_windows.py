"""Exercise the real Tk image windows with a delayed device response."""
import threading
import unittest
from unittest.mock import patch

from PIL import Image
from ZiYanColorPicker import App


class DelayedDevice:
    port = 50005
    last_ms = 10

    def __init__(self):
        self.release = threading.Event()
        self.calls = 0

    def set_ip(self, _ip):
        pass

    def snapshot(self, *_args):
        self.calls += 1
        self.release.wait(2)
        return Image.new("RGB", (4, 4), "green")


class SnapshotWindows(unittest.TestCase):
    def setUp(self):
        self.app = App()
        self.app.withdraw()
        self.device = DelayedDevice()
        self.app.dev = self.device
        self.a = self.app.open_image_window(Image.new("RGB", (4, 4), "red"), "A")
        self.b = self.app.open_image_window(Image.new("RGB", (4, 4), "blue"), "B")
        self.app.active_win = self.a

    def tearDown(self):
        self.device.release.set()
        self.app.destroy()

    def finish_request(self, change):
        self.app.after(30, change)
        self.app.after(50, self.device.release.set)
        self.app.after(500, self.app.quit)
        self.app.mainloop()

    def test_switching_tabs_does_not_redirect_delayed_snapshot(self):
        self.app.snap_device(new_window=False)
        self.finish_request(lambda: self.b.activate())
        self.assertEqual(self.a.img.getpixel((0, 0)), (0, 128, 0))
        self.assertEqual(self.b.img.getpixel((0, 0)), (0, 0, 255))

    def test_closed_target_drops_result(self):
        self.app.snap_device(new_window=False)
        self.finish_request(self.a._on_close)
        self.assertEqual(self.b.img.getpixel((0, 0)), (0, 0, 255))
        self.assertEqual(len(self.app.image_windows), 1)

    def test_device_change_drops_result(self):
        self.app.snap_device(new_window=False)
        self.finish_request(lambda: self.app.device_ip.set("127.0.0.2"))
        self.assertEqual(self.a.img.getpixel((0, 0)), (255, 0, 0))
        self.assertFalse(self.app._snap_busy)

    def test_orientation_change_drops_result(self):
        self.app.snap_device(new_window=False)
        self.finish_request(lambda: self.app.device_orient.set(2))
        self.assertEqual(self.a.img.getpixel((0, 0)), (255, 0, 0))

    def test_live_target_does_not_follow_active_tab(self):
        self.app._set_live(True)
        self.b.activate()
        self.app._stop_live(cancel_request=False)
        self.app._live_tick()
        self.finish_request(lambda: None)
        self.assertEqual(self.a.img.getpixel((0, 0)), (0, 128, 0))
        self.assertEqual(self.b.img.getpixel((0, 0)), (0, 0, 255))

    def test_stopping_live_discards_pending_response(self):
        self.app._set_live(True)
        self.app._stop_live(cancel_request=False)
        self.app._live_tick()
        self.finish_request(lambda: self.app._set_live(False))
        self.assertEqual(self.a.img.getpixel((0, 0)), (255, 0, 0))

    def test_old_completion_cannot_clear_new_request(self):
        self.app.snap_device(new_window=False)
        self.app.device_orient.set(2)
        self.app.snap_device(new_window=False)
        current = self.app._snapshot_request
        self.finish_request(lambda: None)
        self.assertEqual(self.app._snapshot_request, current)
        self.assertFalse(self.app._snap_busy)
        self.assertEqual(self.b.img.getpixel((0, 0)), (0, 0, 255))

    def test_continuous_live_refresh_keeps_original_target(self):
        self.device.release.set()
        with patch("ZiYanColorPicker.LIVE_MS", 50):
            self.app._set_live(True)
            self.app.after(30, self.b.activate)
            self.app.after(350, self.app.quit)
            self.app.mainloop()
        self.assertGreaterEqual(self.device.calls, 3)
        self.assertEqual(self.a.img.getpixel((0, 0)), (0, 128, 0))
        self.assertEqual(self.b.img.getpixel((0, 0)), (0, 0, 255))


if __name__ == "__main__":
    unittest.main()
