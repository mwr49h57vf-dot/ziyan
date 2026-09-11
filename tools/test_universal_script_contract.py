#!/usr/bin/env python3
"""通用性验收门禁的合同检查。

这条门禁存在的唯一理由：**同一份业务脚本**必须在 7/7P/8/8P × iOS 13~17
上都能从冷态自己跑通。2026-09-11 的实测教训是 ios7.lua 写死桌面图标坐标
(1010,294)，在 .101/.112/.166（iOS 13，首页 3 格）命中，在 .61（iOS 15，
首页多了两个小组件共 6 格）落到壁纸，脚本永远进不了游戏——单机跑通发现不了。

门禁本身也要被约束，否则很容易退化成「跑一台就算过」。
"""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "tools" / "zy_universal_script_gate.sh"


def src() -> str:
    return GATE.read_text(encoding="utf-8")


def test_gate_parses() -> None:
    subprocess.run(["bash", "-n", str(GATE)], check=True)


def test_single_script_only() -> None:
    """门禁只接受一份脚本：多份=per-device 变体=自欺。"""
    s = src()
    assert 'SCRIPT_ARG="${1:?' in s
    assert "SCRIPT_ABS=" in s
    assert "SCRIPT_SHA=" in s
    # 不得对脚本本身做 sed 变体生成（E48 fixture 曾按设备 sed 脚本，业务脚本禁止）。
    # 注意：门禁自己用 sed 解析探测输出是允许的，所以只查「sed 出现在脚本路径同一行」。
    for line in s.splitlines():
        if "sed" in line:
            assert "SCRIPT_ABS" not in line and "SCRIPT_ARG" not in line, (
                f"gate must not sed the script: {line.strip()}"
            )


def test_records_model_and_ios_matrix() -> None:
    """必须记录机型 × iOS，否则「矩阵覆盖」无从谈起。"""
    s = src()
    for token in ("hw_model", "sw_vers -productVersion", "matrix.tsv"):
        assert token in s, token
    # 8/7P/7 的 ProductType 映射必须存在
    for pt in ("iPhone9,1", "iPhone9,2", "iPhone10,1", "iPhone10,2"):
        assert pt in s, pt


def test_requires_byte_identical_script_on_device() -> None:
    """远端字节必须与本地逐字节一致，否则「同一份」不成立。"""
    s = src()
    assert "remote_sha256=" in s
    assert "SCRIPT_MISMATCH" in s
    assert 'if [ "$remote_sha" != "$SCRIPT_SHA" ]' in s


def test_reports_uncovered_matrix_cells() -> None:
    """未覆盖格子必须显式列出：既不能写成 PASS，也不能当成 FAIL。"""
    s = src()
    assert "未覆盖" in s
    for m in ("iPhone7", "iPhone7Plus", "iPhone8", "iPhone8Plus"):
        assert m in s, m
    for maj in ("13", "14", "15", "16", "17"):
        assert f"for maj in" in s and maj in s


def test_mobile_transport_is_key_first() -> None:
    """`.61` 的密码通道间歇性拒登且会被 sshd 限流：门禁必须密钥优先。"""
    s = src()
    assert 'if [ "$user" = mobile ]; then' in s
    assert "BatchMode=yes" in s


def test_devices_are_staggered_not_parallel() -> None:
    """并行 SSH 会撞设备限流（2026-09-11 实测矩阵被打断），必须错峰串行。"""
    s = src()
    assert "STAGGER" in s
    assert "sleep \"$STAGGER\"" in s


def test_goal_requires_sustained_foreground() -> None:
    """达成必须是「目标 App 连续在前台」，不是一闪而过。"""
    s = src()
    assert 'streak=$((streak+1))' in s
    assert 'if [ "$streak" -ge 3 ]' in s


def test_all_devices_must_pass() -> None:
    """全体通过才算 PASS；任一未达成即 FAIL，有 SKIP 只能算 INCOMPLETE。"""
    s = src()
    assert 'UNIVERSAL_SCRIPT=PASS devices=$PASSN/${#HOSTS[@]}' in s
    assert 'UNIVERSAL_SCRIPT=FAIL pass=$PASSN fail=$FAILN skip=$SKIPN' in s
    assert 'UNIVERSAL_SCRIPT=INCOMPLETE pass=$PASSN skip=$SKIPN' in s


def test_uninstalled_target_is_skip_not_pass() -> None:
    """未装目标 App 的机器记 SKIP：既不能算 PASS（没测到），也不能算 FAIL（不是脚本问题）。"""
    s = src()
    assert "SKIP_TARGET_NOT_INSTALLED" in s
    assert 'target_installed=' in s
    assert 'if [ "$inst" != "1" ]' in s


if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except AssertionError as exc:
            failed += 1
            print(f"  FAIL {fn.__name__}: {exc}")
    if failed:
        print(f"UNIVERSAL_SCRIPT_CONTRACT=FAIL failed={failed}/{len(fns)}")
        sys.exit(1)
    print(f"UNIVERSAL_SCRIPT_CONTRACT=PASS tests={len(fns)}")
