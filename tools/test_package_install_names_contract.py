#!/usr/bin/env python3
"""Rootless install-name gate must inspect every packaged injection dylib."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE = (ROOT / "tools/verify_package_install_names.sh").read_text()


def main() -> None:
    assert "*/var/jb/Library/MobileSubstrate/DynamicLibraries/*.dylib" in GATE
    assert 'otool -L "$dy"' in GATE
    assert "rootful dependency in rootless package" in GATE
    assert 'if [[ "$base" != "ZiYanVol.dylib" ]]' not in GATE
    print("PACKAGE_INSTALL_NAMES_CONTRACT=PASS")


if __name__ == "__main__":
    main()
