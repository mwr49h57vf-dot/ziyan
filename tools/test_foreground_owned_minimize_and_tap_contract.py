#!/usr/bin/env python3
"""Static contract for foreground-owned minimize and current-frame tap dispatch."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATHS = (ROOT / "objc/shared/ZiYanPaths.h").read_text(encoding="utf-8")
SB = (ROOT / "objc/tweak/springboard/Tweak.m").read_text(encoding="utf-8")
SCREEN_BRIDGE = (
    ROOT / "objc/tweak/springboard/ZiYanScreenBridge.m"
).read_text(encoding="utf-8")
TOUCH = (ROOT / "lua/ziyan_engine/touch.lua").read_text(encoding="utf-8")
EMBED = (ROOT / "tools/ziyan_framecap/ZiYanLuaEmbed.m").read_text(encoding="utf-8")
RUN1_GATE = (ROOT / "tools/zy_run1_script_logic_gate.sh").read_text(
    encoding="utf-8"
)
FG_GATE = (ROOT / "lua/ziyan_engine/fg_gate.lua").read_text(encoding="utf-8")
CV = (ROOT / "lua/ziyan_engine/cv.lua").read_text(encoding="utf-8")
TOAST = (ROOT / "objc/tweak/springboard/ZiYanToastBridge.m").read_text(
    encoding="utf-8"
)


def require(text: str, needle: str) -> None:
    assert needle in text, f"missing contract: {needle}"


def main() -> None:
    require(PATHS, "ZiYanOwnsForegroundForMinimize")
    require(PATHS, '[bundleId isEqualToString:@"com.ziyan.ziyan"]')
    require(PATHS, '@"applicationState"')
    require(PATHS, "owner=com.ziyan.ziyan")
    require(PATHS, "caller_not_active_ziyan")
    assert 'ZiYanWriteVarText(@".ziyan_go_home", @"1\\n")' not in PATHS

    require(SB, "ZiYanGoHomeRequestOwnedByZiYan")
    require(SB, "go_home policy_reject_missing_ziyan_owner")
    require(SB, "go_home policy_reject_front")
    require(SB, "go_home policy_skip_non_ziyan_front")
    home_body = SB[
        SB.index("static void ZiYanRequestSpringBoardHome(void) {")
        : SB.index("static void ZiYanOpenAppWriteGate")
    ]
    assert home_body.index("go_home policy_skip_non_ziyan_front") < home_body.index(
        "ZiYanDismissPopup();"
    )

    require(TOUCH, "request_ziyan_self_minimize")
    require(TOUCH, "owner=com.ziyan.ziyan")
    assert ".ziyan_app_minimize_req" not in TOUCH
    assert ".ziyan_suspend_bid" not in TOUCH
    assert ".ziyan_close_app" not in TOUCH
    require(TOUCH, "front_frame_matches")
    require(TOUCH, ".ziyan_shm_front_bid")
    require(TOUCH, ".ziyan_captured_front_bid")
    require(TOUCH, "rejected=%s")
    require(TOUCH, '"front_frame_mismatch"')
    require(TOUCH, "current_foreground_frame")
    for entrypoint in ("function touchDown", "function touchMove"):
        start = TOUCH.index(entrypoint)
        end = TOUCH.find("\n  function ", start + len(entrypoint))
        if end < 0:
            end = len(TOUCH)
        assert "current_foreground_frame" in TOUCH[start:end], entrypoint
    tap_start = TOUCH.index("function tap")
    tap_end = TOUCH.find("\n  function ", tap_start + len("function tap"))
    if tap_end < 0:
        tap_end = len(TOUCH)
    assert "current_foreground_frame" not in TOUCH[tap_start:tap_end]
    assert 'find("springboard", 1, true)' not in TOUCH

    require(FG_GATE, "前台切换只代表当前可见帧换代")
    assert "local isHome =" not in FG_GATE

    require(CV, "所有前台只代表可见帧换代")
    cv_front_switch = CV[
        CV.index("local function invalidate_keep_if_front_changed()")
        : CV.index("local function ensure_keep_screen_on()")
    ]
    assert "local isHome =" not in cv_front_switch
    assert 'find("springboard", 1, true)' not in cv_front_switch
    assert "local gap = 1.5" in cv_front_switch
    require(CV, 'M.vision_gate("findMulti")')
    require(CV, 'M.vision_gate("findImage")')
    require(CV, "function M.ocr_region")

    toast_lock = TOAST[
        TOAST.index("+ (BOOL)toastSessionLockPortraitHost")
        : TOAST.index("+ (NSInteger)uiOrient")
    ]
    require(toast_lock, "[self scriptOrient]")
    assert ".ziyan_front_bid" not in toast_lock

    assert 'echo 1 >"$VAR/.ziyan_go_home"' not in RUN1_GATE
    assert "PRE_BLOCKED A0_requires_existing_home" not in RUN1_GATE
    assert "TYPED=PRE_BLOCKED_FOREIGN_FRONT" not in RUN1_GATE
    require(RUN1_GATE, "业务脚本从当前真实前台直接开始")

    tap_body = EMBED[EMBED.index("static int l_touch_tap"):EMBED.index(
        "static int l_monotonic_ms"
    )]
    assert "EmbedFrameReadyForCurrentFront()" not in tap_body
    assert "reason=front_frame_mismatch" not in tap_body
    require(SCREEN_BRIDGE, 'ZiYanVarFile(@".ziyan_prefer_app_touch")')
    require(SCREEN_BRIDGE, "if (appPreferred && fgFresh && aliveMod")
    print("FOREGROUND_OWNED_MINIMIZE_AND_TAP_CONTRACT=PASS")


if __name__ == "__main__":
    main()
