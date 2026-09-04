#!/usr/bin/env python3
"""Static contract for the opt-in backboardd login-click route."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOUCH = (ROOT / "objc/shared/ZiYanTouchBridge.m").read_text()
TWEAK = (ROOT / "objc/tweak/bbtouch/Tweak.m").read_text()


class BBTouchActivationContract(unittest.TestCase):
    def test_constructor_is_explicitly_opt_in(self):
        self.assertIn("ZiYanBBTouchEnabled", TWEAK)
        self.assertIn(".ziyan_bbtouch_enable", TWEAK)
        self.assertIn("if (!ZiYanBBTouchEnabled())", TWEAK)

    def test_bridge_rechecks_enable_before_timer_or_poll(self):
        self.assertIn("if (!ZYBBTouchEnabled())", TOUCH)
        self.assertIn("self.timer = dispatch_source_create", TOUCH)
        self.assertLess(
            TOUCH.index("if (!ZYBBTouchEnabled())"),
            TOUCH.index("self.timer = dispatch_source_create"),
        )

    def test_bridge_rebinds_after_springboard_respring(self):
        self.assertIn(".ziyan_sb_boot_ts", TOUCH)
        self.assertIn(".ziyan_sb_lifecycle", TOUCH)
        self.assertIn("event=sb_boot_clear_throttle", TOUCH)
        self.assertIn("resetForSpringBoardRestartIfNeeded", TOUCH)
        self.assertIn("self.lastStamp = 0", TOUCH)
        self.assertIn("CFRelease(_client)", TOUCH)
        self.assertIn("removeItemAtPath:[self reqPath]", TOUCH)
        self.assertIn("reason=springboard_restart", TOUCH)

    def test_only_bounded_atomic_single_finger_tap_is_accepted(self):
        self.assertIn('.ziyan_bbtouch_req', TOUCH)
        self.assertIn('.ziyan_bbtouch_rep', TOUCH)
        self.assertIn("lines.count == 6", TOUCH)
        self.assertIn("ZYStrictInt(lines[1], 1, 9", TOUCH)
        self.assertIn("ZYStrictCoordinate(lines[2], oi.lw", TOUCH)
        self.assertIn("ZYStrictCoordinate(lines[3], oi.lh", TOUCH)
        self.assertIn("ZYStrictInt(lines[4], 80, 100", TOUCH)
        self.assertIn("invalid_tap", TOUCH)

    def test_backboard_digitizer_coordinates_use_portrait_glass_space(self):
        self.assertIn("ZiYanMapLogicToNorm(sx, sy, &nx, &ny)", TOUCH)

    def test_up_matches_ios11_touchsprite_range_and_touch_release(self):
        self.assertIn("boolean_t inRange = down", TOUCH)
        self.assertIn("kZYFieldRange, inRange", TOUCH)
        self.assertIn("kZYFieldTouch, down", TOUCH)
        self.assertIn("inRange, down, 0", TOUCH)

    def test_unobserved_bks_metadata_does_not_mutate_touchsprite_wire_event(self):
        # TSEventTweak's iOS 13 arm64 path builds the composite IOHID event and
        # dispatches it directly.  The earlier BKS call was an unverified
        # mutation, so keep the compatible route free of it.
        self.assertNotIn("BKSHIDEventSetDigitizerInfo", TOUCH)
        self.assertNotIn("ZYSetDigitizerInfo", TOUCH)

    def test_touchsprite_compatible_composite_event_is_present(self):
        self.assertIn("ZYCreateDigitizerEvent && ZYAppendEvent", TOUCH)
        self.assertIn("kZYTransducerTypeHand = 35", TOUCH)
        self.assertIn("kZYTransducerTypeFinger = 4", TOUCH)
        self.assertIn(
            "ZYSetIntegerValue(hand, kZYFieldEventMask, (CFIndex)parentMask)",
            TOUCH,
        )
        self.assertIn("shape=touchsprite_ios11_hand_finger", TOUCH)
        self.assertNotIn("ZYCreateFingerEventWithQuality", TOUCH)
        self.assertNotIn("ZYSetIntegerValueWithOptions", TOUCH)

    def test_touchsprite_iohid_route_precedes_bkhid_compatibility_fallback(self):
        self.assertIn('Class bk = NSClassFromString(@"BKHIDSystemInterface");', TOUCH)
        self.assertIn("@selector(injectHIDEvent:)", TOUCH)
        self.assertIn("ZYDispatch(_client, toSend)", TOUCH)
        self.assertLess(
            TOUCH.index("ZYDispatch(_client, toSend)"),
            TOUCH.index('Class bk = NSClassFromString(@"BKHIDSystemInterface");'),
        )
        self.assertIn("if (!sent) {", TOUCH)
        self.assertIn('Class eventTimer = NSClassFromString(@"BKUserEventTimer");', TOUCH)

    def test_modern_sender_id_is_present(self):
        self.assertIn("0x8000000817319376ULL", TOUCH)

    def test_parent_and_child_arguments_match_ios11_touchsprite_slice(self):
        self.assertIn(
            "kCFAllocatorDefault, ts, kZYTransducerTypeHand, 0, 1, 0, 0, 0, 0, 0,",
            TOUCH,
        )
        self.assertIn(
            "kCFAllocatorDefault, ts, idx, 2, childMask, nx, ny, 0, 0, 0, inRange,",
            TOUCH,
        )


if __name__ == "__main__":
    unittest.main()
