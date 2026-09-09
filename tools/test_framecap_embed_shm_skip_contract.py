#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
shm = (root / "objc/shared/ZiYanFrameShm.m").read_text()
hdr = (root / "objc/shared/ZiYanFrameShm.h").read_text()
main = (root / "tools/ziyan_framecap/main.m").read_text()
assert "ZiYanFrameShmLastWriteSkippedPixels" in hdr
assert "ZiYanFrameShmLastWriteSkippedPixels" in shm
assert '.ziyan_lua_embedded' in shm
assert "sFilePixelsSeeded" in shm
assert "skipPx" in shm or "skip_px" in shm
assert "ZFS_ResidentRenew" in shm
assert "BIZ07 embed" in shm
assert "skip_px=" in main
assert "heavy3x ? 2500 : 250" in main
assert "surfReuseMs" in main
print("FRAMECAP_EMBED_SHM_SKIP_CONTRACT=PASS")
