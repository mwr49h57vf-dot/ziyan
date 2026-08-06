#!/usr/bin/env bash
# 裁剪 packages/：保留最新 2 个产品版本（含全部 scheme/arch）。
# 若最新 2 版无 arm64，额外保留最近一份 arm64（rootless .53）。
# 必须 bash 运行：bash tools/cleanup_packages.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packages"
cd "$PKG" || exit 1

python3 <<'PY'
import re, sys
from pathlib import Path

pkgs = list(Path(".").glob("com.ziyan.ziyan_*.deb"))
if not pkgs:
    print("[cleanup] no debs")
    sys.exit(0)

# com.ziyan.ziyan_<ver>-<scheme>+debug_iphoneos-<arch>.deb
# com.ziyan.ziyan_<ver>_iphoneos-<arch>.deb  (无 scheme，如 125b)
pat_scheme = re.compile(
    r"^com\.ziyan\.ziyan_(.+)-(\d+)(?:\+debug)?_iphoneos-(arm64|arm)\.deb$"
)
pat_plain = re.compile(
    r"^com\.ziyan\.ziyan_(.+)(?:\+debug)?_iphoneos-(arm64|arm)\.deb$"
)

def vkey(v: str):
    return [int(x) if x.isdigit() else x for x in re.split(r"([0-9]+)", v)]

rows = []
unparsed = []
for p in pkgs:
    m = pat_scheme.match(p.name)
    if m:
        ver, scheme, arch = m.group(1), m.group(2), m.group(3)
    else:
        m2 = pat_plain.match(p.name)
        if not m2:
            unparsed.append(p.name)
            continue
        ver, scheme, arch = m2.group(1), "0", m2.group(2)
    rows.append((ver, scheme, arch, p))

if unparsed:
    print("[cleanup] WARN unparsed (kept):")
    for n in unparsed:
        print(" ", n)

vers = sorted({r[0] for r in rows}, key=vkey)
keep_vers = set(vers[-2:]) if len(vers) >= 2 else set(vers)

arm64_vers = sorted({r[0] for r in rows if r[2] == "arm64"}, key=vkey)
if arm64_vers and not any(v in keep_vers for v in arm64_vers[-1:]):
    # 最新 keep 里若完全没有 arm64，拉最近 arm64 版
    if not any(r[2] == "arm64" and r[0] in keep_vers for r in rows):
        keep_vers.add(arm64_vers[-1])

print("[cleanup] keep versions:", ", ".join(sorted(keep_vers, key=vkey)))
kept, removed = [], []
for ver, scheme, arch, p in rows:
    if ver in keep_vers:
        kept.append(p.name)
    else:
        print(f"  rm {p.name}")
        p.unlink()
        removed.append(p.name)

# 未解析的一律保留
print(f"[cleanup] removed {len(removed)}, kept {len(kept) + len(unparsed)}")
print("[cleanup] left:")
for n in sorted(Path(".").glob("com.ziyan.ziyan_*.deb")):
    print(" ", n.name)
PY
du -sh .
