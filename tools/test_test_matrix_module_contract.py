#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "lua/modules/TestMatrix.lua").read_text(encoding="utf-8")
INIT = (ROOT / "lua/modules/init.lua").read_text(encoding="utf-8")


def main() -> None:
    for needle in (
        'name = "TestMatrix"',
        'REAL_DEVICE_TEST_REQUIRED',
        'pass_source = "device_final_verdict"',
        'Zy.Script.generateFromTask',
        'Zy.AI.test',
        'real_device = true',
    ):
        assert needle in SRC, needle
    assert '"TestMatrix"' in INIT
    print("TEST_MATRIX_MODULE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
