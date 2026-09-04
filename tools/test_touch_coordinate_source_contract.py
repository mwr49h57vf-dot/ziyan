#!/usr/bin/env python3
"""找色/找图/找字坐标与固定 tap 坐标必须共用原样点击入口。"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOUCH = (ROOT / "lua/modules/Touch.lua").read_text(encoding="utf-8")
IMAGE = (ROOT / "lua/modules/Image.lua").read_text(encoding="utf-8")
OCR = (ROOT / "lua/modules/OCR.lua").read_text(encoding="utf-8")


def main() -> None:
    start = TOUCH.index("function M.tap(x, y, ...)")
    end = TOUCH.index("\nend", start) + len("\nend")
    raw_tap = TOUCH[start:end]
    assert 'error("Zy.Touch.tap forbidden' not in raw_tap
    assert "x, y = tonumber(x), tonumber(y)" in raw_tap
    assert "tap_logic(x, y, hold_ms)" in raw_tap
    assert "return ok, x, y" in raw_tap

    image_start = IMAGE.index("function M.find(path,")
    image_end = IMAGE.index("\nend", image_start) + len("\nend")
    image_find = IMAGE[image_start:image_end]
    assert "findImageInRegionFuzzy" in image_find
    assert "return tonumber" in image_find

    color_start = IMAGE.index("function M.findMultiColorInRegionFuzzy")
    color_end = IMAGE.index("\nend", color_start) + len("\nend")
    color_find = IMAGE[color_start:color_end]
    assert "return tonumber(fx) or -1, tonumber(fy) or -1" in color_find

    ocr_start = OCR.index("function M.find(word,")
    ocr_end = OCR.index("\nend", ocr_start) + len("\nend")
    ocr_find = OCR[ocr_start:ocr_end]
    assert "fx, fy = tonumber(fx), tonumber(fy)" in ocr_find
    assert "return -1, -1" in ocr_find

    print("TOUCH_COORDINATE_SOURCE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
