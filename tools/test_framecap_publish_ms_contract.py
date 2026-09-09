#!/usr/bin/env python3
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cap = (root / "objc/shared/ZiYanFrameCapture.m").read_text()
hdr = (root / "objc/shared/ZiYanFrameCapture.h").read_text()
main = (root / "tools/ziyan_framecap/main.m").read_text()
runner_path = (
    root / "tmp_shots/STORM_BIZ11_PUBLISH53_20260907/run_storm_biz11_embed53.py"
)
runner_text = runner_path.read_text()

assert "ZiYanFrameCaptureLastPublishMs" in hdr
assert "ZiYanFrameCaptureLastPublishMs" in cap
assert "sLastCapPublishMs" in cap
assert "publish_ms=" in main
assert "heavy3x ? 2500 : 250" in main
assert "surfReuseMs" in main
assert 'verdict = "PUBLISH_SPLIT"' not in runner_text
assert "VERDICT_BASIS=" in runner_text
assert "CLOCK_SOURCE=remote_.53_date_gettimeofday" in runner_text
assert "RUN_START" in runner_text and "STOP_SENT" in runner_text
assert "WINDOW_SECONDS" in runner_text and "<= 90.0" in runner_text
assert "visual_positive" in runner_text
assert "VISUAL_POSITIVE_UNAVAILABLE" in runner_text
assert "stop_then_kill_scripts" in runner_text
assert "P50_METHOD=standard_median" in runner_text
assert "REMOTE_BINARY_SHA" in runner_text

publish_start = cap.index("BOOL ZiYanFrameCapturePublishPixels")
publish_end = cap.index("\n}\n", publish_start) + 2
publish = cap[publish_start:publish_end]
timer_start = publish.index("double tPublish0 = ZiYanNowMs();")
empty_return = publish.index("if (!pixels || w < 2 || h < 2 || bpr < 8)")
resolve = publish.index("ZiYanResolveCaptureSize")
timer_stop = publish.index("sLastCapPublishMs = ZiYanNowMs() - tPublish0;")
assert timer_start < empty_return < resolve < timer_stop
assert publish.count("return ") == 1
assert "do {" in publish and "} while (0);" in publish

spec = importlib.util.spec_from_file_location("storm_biz11_runner", runner_path)
runner = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(runner)

fixture = """\
ts=99.999 reuse=0 cost_ms=1.0 create_ms=0.1 xfer_ms=0.1 src_lock_ms=0.0 destlock_ms=0.0 copy_ms=0.1 resident_ms=0.1 release_ms=0.1 publish_ms=0.1
ts=100.000 reuse=0 cost_ms=2.0 create_ms=0.1 xfer_ms=0.1 src_lock_ms=0.0 destlock_ms=0.0 copy_ms=0.1 resident_ms=0.1 release_ms=0.1 publish_ms=0.1
ts=105.000 reuse=1 cost_ms=3.0 create_ms=0.0 xfer_ms=0.0 src_lock_ms=0.0 destlock_ms=0.0 copy_ms=0.0 resident_ms=0.0 release_ms=0.0 publish_ms=0.0
ts=110.000 reuse=0 cost_ms=4.0 create_ms=0.1 xfer_ms=0.1 src_lock_ms=0.0 destlock_ms=0.0 copy_ms=0.1 resident_ms=0.1 release_ms=0.1 publish_ms=0.1
"""
window_rows, tail_rows, malformed = runner.split_cap_cost_rows(
    fixture, run_start=100.0, stop_sent=110.0
)
assert malformed == 0
assert len(window_rows) == 2
assert sum(row["reuse"] == "0" for row in window_rows) == 1
assert sum(row["reuse"] == "1" for row in window_rows) == 1
assert len(tail_rows) == 1
assert tail_rows[0]["ts"] == "110.000"
assert tail_rows[0]["reuse"] == "0"

assert runner.median([1.0, 9.0]) == 5.0
assert runner.median([1.0, 5.0, 9.0]) == 5.0

print("FRAMECAP_PUBLISH_MS_CONTRACT=PASS")
