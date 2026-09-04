#!/usr/bin/env python3
"""Default install/upgrade maintainer-script lifecycle regression contract."""
import argparse
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DEBIAN = ROOT / "layout" / "DEBIAN"
FORBIDDEN = re.compile(
    r"(?m)^\s*(?:[A-Za-z0-9_./-]+/)?(?:killall|launchctl)\b.*"
    r"(?:\bkillall\b|\bbootout\b|\bunload\b|\bbootstrap\b|\bload\b)"
)


def executable_lines(path: Path) -> str:
    lines = []
    for raw in path.read_text().splitlines():
        stripped = raw.strip()
        if stripped and not stripped.startswith("#"):
            lines.append(raw)
    return "\n".join(lines)


def require(text: str, needle: str) -> None:
    assert needle in text, f"missing {needle}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--debian-dir",
        type=Path,
        default=DEBIAN,
        help="directory containing extracted preinst/postinst/prerm",
    )
    args = parser.parse_args()
    debian = args.debian_dir
    preinst = executable_lines(debian / "preinst")
    postinst = executable_lines(debian / "postinst")
    prerm = executable_lines(debian / "prerm")

    for name, text in (("preinst", preinst), ("postinst", postinst)):
        assert not FORBIDDEN.search(text), f"{name} has lifecycle command"
        require(text, ".ziyan_inject_reload_pending")
        require(text, "pending_manual_inject_reload")

    upgrade_case = re.search(
        r"case \"\$1\" in\s+upgrade\|failed-upgrade\)(.*?)^\s*;;",
        prerm,
        re.MULTILINE | re.DOTALL,
    )
    assert upgrade_case, "missing upgrade case"
    upgrade_body = upgrade_case.group(1)
    assert "stop_daemons" not in upgrade_body, "upgrade must not stop services"
    require(upgrade_body, ".ziyan_inject_reload_pending")
    print("PACKAGE_INSTALL_LIFECYCLE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
