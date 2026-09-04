#!/usr/bin/env python3
"""tap must dispatch the exact script arguments without mutation or suppression."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOUCH = (ROOT / "lua/ziyan_engine/touch.lua").read_text(encoding="utf-8")
SAFE = (ROOT / "lua/modules/SafeExecutor.lua").read_text(encoding="utf-8")


def main() -> None:
    tap_start = TOUCH.index("function tap(a, b, c, d)")
    tap_end = TOUCH.index("\n  if not defined(\"moveTo\")", tap_start)
    tap_body = TOUCH[tap_start:tap_end]
    assert "hid_tap(finger, x, y, holdMs)" in tap_body
    assert "current_foreground_frame(" not in tap_body
    assert "current_foreground_frame(\"tap\"" not in tap_body
    assert "x + math.random" not in tap_body
    assert "y + math.random" not in tap_body
    assert "to_phys(x, y)" not in tap_body
    assert "finger = finger or random_finger()" in tap_body
    assert "holdMs = tonumber(holdMs) or random_hold_ms()" in tap_body
    assert "local TAP_HOLD_MIN, TAP_HOLD_MAX = 80, 100" in TOUCH

    hid_start = TOUCH.index("local function hid_tap")
    hid_end = TOUCH.index("\n  --- tap(x, y", hid_start)
    hid_body = TOUCH[hid_start:hid_end]
    assert "id = 1" not in hid_body
    assert 'match("^/var/jb/")' in hid_body
    assert hid_body.index("pcall(_G.ziyan_embed_tap") < hid_body.index(
        "write_touch_req(sbBody)"
    )
    assert hid_body.index("write_touch_req(sbBody)") < hid_body.index(
        "write_bbtouch_req(bbBody)"
    )
    # rootless 内嵌宿主先走已真机证明的 daemon IOKit；其它宿主继续
    # SpringBoard -> BackBoard -> AppTouch 兼容链。
    assert hid_body.index("write_bbtouch_req(bbBody)") < hid_body.index(
        "prefer_app_touch(true)"
    )

    safe_start = SAFE.index("local function safe_tap")
    safe_end = SAFE.index("\nend", safe_start) + len("\nend")
    safe_body = SAFE[safe_start:safe_end]
    assert "return _orig_tap(...)" in safe_body
    assert "math.random" not in safe_body
    assert "TAP_COOLDOWN_MS" not in safe_body

    print("TAP_ARGUMENT_PASSTHROUGH_CONTRACT=PASS")


if __name__ == "__main__":
    main()
