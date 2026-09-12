# -*- coding: utf-8 -*-
"""把抓色器源码编成加密载荷。只在打包机上跑，不进发行 zip。"""
from __future__ import annotations

import hashlib
import hmac
import marshal
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
MAGIC = b"ZY1\0"
# ponytail: 密钥写在启动器里，挡的是解压读文件，不是专业逆向
_KEY_PARTS = (
    b"ziyan-picker-2026",
    b"v175-protect",
    b"no-source-in-zip",
)


def _key() -> bytes:
    h = hashlib.sha256()
    for p in _KEY_PARTS:
        h.update(p)
    return h.digest()


def _keystream(n: int) -> bytes:
    key = _key()
    out = bytearray()
    i = 0
    while len(out) < n:
        out.extend(hashlib.sha256(key + struct.pack("<I", i)).digest())
        i += 1
    return bytes(out[:n])


def encrypt_bytes(raw: bytes) -> bytes:
    packed = zlib.compress(raw, 9)
    mac = hmac.new(_key(), packed, hashlib.sha256).digest()
    stream = _keystream(len(packed))
    enc = bytes(a ^ b for a, b in zip(packed, stream))
    return MAGIC + mac + enc


def decrypt_bytes(blob: bytes) -> bytes:
    if not blob.startswith(MAGIC):
        raise ValueError("bad payload magic")
    mac = blob[4:36]
    enc = blob[36:]
    stream = _keystream(len(enc))
    packed = bytes(a ^ b for a, b in zip(enc, stream))
    if not hmac.compare_digest(mac, hmac.new(_key(), packed, hashlib.sha256).digest()):
        raise ValueError("bad payload mac")
    return zlib.decompress(packed)


def build_payload(out_path=None) -> str:
    files = ("formats.py", "paired_http.py", "ZiYanColorPicker.py")
    codes = {}
    for name in files:
        with open(os.path.join(HERE, name), "r", encoding="utf-8") as source:
            src = source.read()
        codes[name] = compile(src, name, "exec")
    raw = marshal.dumps(codes, 4)
    blob = encrypt_bytes(raw)
    if out_path is None:
        out_path = os.path.join(HERE, "_zy_payload.bin")
    with open(out_path, "wb") as f:
        f.write(blob)
    return out_path


if __name__ == "__main__":
    path = build_payload()
    raw = decrypt_bytes(open(path, "rb").read())
    codes = marshal.loads(raw)
    assert "ZiYanColorPicker.py" in codes
    print("PAYLOAD_OK", path, os.path.getsize(path))
