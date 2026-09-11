#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""设备无 curl/wget 时的 HTTP 兜底（随包安装到设备，被 Lua 调用）。

用法：
  python3 ziyan_device_net.py get <url> [timeout]
  python3 ziyan_device_net.py post <url> <body_file> [timeout]
  python3 ziyan_device_net.py download <url> <dest> [timeout]
  python3 ziyan_device_net.py sha256 <file>

设计：只做最小 HTTP 客户端，不做任何业务判断；失败打 stderr 且非零退出。
"""
import hashlib
import sys
import urllib.request


def _open(url, data=None, timeout=15):
    req = urllib.request.Request(url, data=data)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    return urllib.request.urlopen(req, timeout=timeout)


def cmd_get(url, timeout=15):
    with _open(url, timeout=timeout) as resp:
        sys.stdout.write(resp.read().decode("utf-8", "replace"))
    return 0


def cmd_post(url, body_file, timeout=15):
    with open(body_file, "rb") as fh:
        body = fh.read()
    with _open(url, data=body, timeout=timeout) as resp:
        sys.stdout.write(resp.read().decode("utf-8", "replace"))
    return 0


def cmd_download(url, dest, timeout=60):
    with _open(url, timeout=timeout) as resp, open(dest, "wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    sys.stdout.write("OK %d\n" % dest.__len__())
    return 0


def cmd_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    sys.stdout.write(h.hexdigest() + "\n")
    return 0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    action = argv[1]
    try:
        if action == "get":
            return cmd_get(argv[2], int(argv[3]) if len(argv) > 3 else 15)
        if action == "post":
            return cmd_post(argv[2], argv[3], int(argv[4]) if len(argv) > 4 else 15)
        if action == "download":
            return cmd_download(argv[2], argv[3], int(argv[4]) if len(argv) > 4 else 60)
        if action == "sha256":
            return cmd_sha256(argv[2])
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write("ERR %s: %s\n" % (action, exc))
        return 3
    sys.stderr.write("ERR unknown action %s\n" % action)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
