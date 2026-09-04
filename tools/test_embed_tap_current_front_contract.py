#!/usr/bin/env python3
"""Static contract: embed tap uses the generic current-front request/reply."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOUCH = (ROOT / "lua/ziyan_engine/touch.lua").read_text()
EMBED = (ROOT / "tools/ziyan_framecap/ZiYanLuaEmbed.m").read_text()


class EmbedTapCurrentFrontContract(unittest.TestCase):
    def test_embed_tap_has_atomic_current_front_protocol(self):
        start = TOUCH.index("local function hid_tap")
        end = TOUCH.index("\n  --- tap(", start)
        tap = TOUCH[start:end]
        self.assertIn("write_bbtouch_req(bbBody)", tap)
        self.assertIn("wait_bbtouch_rep(bbNonce,", tap)
        self.assertIn("ziyan_embed_tap", tap)
        self.assertIn("write_touch_req(body)", tap)
        self.assertIn("wait_touch_rep(nonce,", tap)
        self.assertIn("TOUCH_REP", tap)

    def test_embed_path_does_not_short_circuit_on_native_tap_or_classify_front(self):
        self.assertNotIn('find("springboard", 1, true)', TOUCH)
        self.assertNotIn("current_foreground_frame(\"tap\"", TOUCH)

    def test_native_tap_always_uses_the_touchsprite_hand_parent(self):
        start = EMBED.index("static int l_touch_tap")
        end = EMBED.index("static int l_monotonic_ms", start)
        tap = EMBED[start:end]
        self.assertIn("BOOL skipHand = NO", tap)
        self.assertNotIn("!EmbedFrontIsHome()", tap)

    def test_request_keeps_init_logic_coordinates(self):
        self.assertIn('"tap", tostring(id), tostring(x), tostring(y)', TOUCH)
        self.assertNotIn("to_phys(x, y)", TOUCH[TOUCH.index("local function hid_tap"):TOUCH.index("function tap(a, b, c, d)")])


if __name__ == "__main__":
    unittest.main()
