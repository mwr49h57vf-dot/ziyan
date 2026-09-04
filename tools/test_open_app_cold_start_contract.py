"""Static contract for the .ziyan_open_app cold-start regression."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPRINGBOARD = (ROOT / "objc/tweak/springboard/Tweak.m").read_text()
FRAMERELAY = (ROOT / "objc/tweak/framerelay/Tweak.m").read_text()
PATHS = (ROOT / "objc/shared/ZiYanPaths.h").read_text()


def test_springboard_uses_atomic_open_app_consumer():
    poll = SPRINGBOARD[
        SPRINGBOARD.index("void ZiYanVolTrigPollOnce(void)")
        : SPRINGBOARD.index("// 8-161-80", SPRINGBOARD.index("void ZiYanVolTrigPollOnce(void)"))
    ]
    assert "ZiYanConsumeOpenAppFile" in poll
    assert "stringWithContentsOfFile:openPath" not in poll
    assert 'bundleId.length ? bundleId : @"com.ziyan.ziyan"' not in poll
    assert "if (ZiYanSbVolThin())" in poll
    assert "ZiYanSbInjectTooYoung()" in poll


def test_empty_open_app_never_defaults_to_ziyan():
    consumer = PATHS[
        PATHS.index("static inline BOOL ZiYanConsumeOpenAppFile")
        : PATHS.index("/// 业务启动只能最小化 ZiYan 自身")
    ]
    assert '@"com.ziyan.ziyan"' not in consumer
    assert "open_app_skip_empty" in consumer
    assert "open_app_invalid" in consumer


def test_only_one_open_app_poller_is_enabled():
    assert "if (ZiYanSbVolThin())" in FRAMERELAY
    assert "ZiYanConsumeOpenAppFile(@\"relay\"" in FRAMERELAY
    assert "ZiYanConsumeOpenAppFile(@\"vol\"" in SPRINGBOARD
    assert "if (ZiYanSbVolThin() || ZiYanSbInjectTooYoung())" in FRAMERELAY


def test_cold_start_gate_is_present_in_shared_protocol():
    assert "static inline BOOL ZiYanSbInjectTooYoung(void)" in PATHS
    assert "static inline void ZiYanMarkSbInjectBirth(void)" in PATHS
    assert ".ziyan_open_app.taking.%d.%llu" in PATHS
    assert "ZiYanSbInjectTooYoung()" in SPRINGBOARD
    assert "ZiYanSbInjectTooYoung()" in FRAMERELAY


def test_launch_retry_is_bounded_and_stops_on_duplicate_or_pid_change():
    assert "launchAttempts < 5" in SPRINGBOARD
    assert "launch_suppressed_duplicate" in SPRINGBOARD
    assert "sb_pid_changed" in SPRINGBOARD
    assert "ZiYanSpringBoardPidChanged" in SPRINGBOARD
