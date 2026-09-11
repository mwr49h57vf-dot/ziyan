#!/usr/bin/env python3
"""Required catalog APIs must route through ZiYan's compatibility backend."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REGISTRY = (ROOT / "lua/ziyan_engine/compat_registry.lua").read_text()
IMPL = (ROOT / "lua/ziyan_engine/compat_impl.lua").read_text()


def main() -> None:
    required = {
        "clipText": "input.clipText",
        "getVersion": "device.getVersion",
    }
    for name, target in required.items():
        assert f"bind('{name}', '{target}')" in REGISTRY, f"missing binding: {name}"
        module, function = target.split(".", 1)
        assert f"function {module}.{function}(" in IMPL, f"missing backend: {target}"
    print("API_RUNTIME_BINDING_CONTRACT=PASS bindings=2")


if __name__ == "__main__":
    main()
