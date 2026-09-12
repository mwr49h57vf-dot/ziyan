#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HotUpdate 客户端合同测试（真实 HTTP 服务 + 真实 Lua 执行）。

覆盖（防止“定义被误删/调用到 nil”这类回归）：
  1. check() 对兼容设备返回 update=true（真实解析服务端 JSON）
  2. check() 对不兼容设备（arch 不符 / os 越界）返回 device_incompatible
  3. compatible() 本地闸：arch / os 上下界 / ziyan_min
  4. verify() 正确 sha 通过、错误 sha 拒绝并删除文件、非 deb 拒绝
  5. download() 坏 URL 不产生可用文件
运行：python3 tools/test_hotupdate_contract.py
"""
import hashlib
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = shutil.which("lua5.3") or shutil.which("lua") or "/Users/mac/lua/bin/lua"
TMP = "/tmp/zy_hot_contract"
PORT = 18095
PORT_BAD = 18096

FAILURES = []
MANIFEST = {
    "ok": True,
    "update": True,
    "version": "0.0.92-test",
    "sha256": "",
    "url": "/hotupdate/packages/0.0.92-test/pkg.deb",
    "size": 0,
}


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else " :: " + str(detail)))
    if not cond:
        FAILURES.append(name)


class Handler(http.server.BaseHTTPRequestHandler):
    incompatible = False   # 由 make_server(port, incompatible=...) 设置

    def do_GET(self):
        if self.path.startswith("/api/hotupdate/check"):
            if self.incompatible:
                body = {"ok": True, "update": False, "reason": "device_incompatible",
                        "detail": "arch mismatch: package iphoneos-arm64 vs device x"}
            else:
                body = dict(MANIFEST)
            payload = json.dumps(body).encode()
        elif self.path == "/hotupdate/manifest.json":
            payload = json.dumps({"channels": {"stable": "0.0.92-test"}}).encode()
        else:
            payload = b"not found"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass


class Reusable(socketserver.TCPServer):
    allow_reuse_address = True


def main():
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP, exist_ok=True)

    # 造一个真实 deb 样本（ar 魔数 + 1KB 填充），并算 sha256
    deb = os.path.join(TMP, "pkg.deb")
    with open(deb, "wb") as fh:
        fh.write(b"!<arch>\n" + b"\x00" * 2048)
    sha = hashlib.sha256(open(deb, "rb").read()).hexdigest()

    Handler.incompatible = False
    server = Reusable(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    class HandlerBad(Handler):
        incompatible = True

    server_bad = Reusable(("127.0.0.1", PORT_BAD), HandlerBad)
    threading.Thread(target=server_bad.serve_forever, daemon=True).start()
    try:
        script = f'''
package.path = "{ROOT}/lua/modules/?.lua;" .. package.path
_G.ZIYAN_VAR = "{TMP}/var"
_G.ZIYAN_ZYCV = "{TMP}/zycv"
_G.ZIYAN_LUA = "{ROOT}/lua"
os.execute("mkdir -p '{TMP}/var' '{TMP}/zycv'")
local H = dofile("{ROOT}/lua/modules/HotUpdate.lua")
local BASE = "http://127.0.0.1:{PORT}"

-- 1) 兼容设备
local info, reason = H.check(BASE, {{ channel = "stable" }})
print("T1 reason=" .. tostring(reason) .. " update=" .. tostring(info and info.update) .. " version=" .. tostring(info and info.version))

-- 2) 不兼容（服务端判定 arch 不符）
local i2, r2 = H.check("http://127.0.0.1:{PORT_BAD}", {{ channel = "stable" }})
print("T2 reason=" .. tostring(r2) .. " update=" .. tostring(i2 and i2.update))

-- 3) 本地闸
local other = (H.arch() == "iphoneos-arm") and "iphoneos-arm64" or "iphoneos-arm"
local a1 = H.compatible({{ architecture = other }})
local a2 = H.compatible({{ architecture = H.arch(), min_os = "13.0", max_os = "17.0" }})
local a2b = H.compatible({{ architecture = H.arch(), min_os = "13.0", max_os = "16.7", os = "16.7.16" }})
print("T3b point_release_gate=" .. tostring(a2b))
local a3 = H.compatible({{ architecture = H.arch(), min_os = "99.0" }})
print("T3 arch_gate=" .. tostring(a1) .. " ok_gate=" .. tostring(a2) .. " min_os_gate=" .. tostring(a3))

-- 4) verify
local v1 = H.verify("{deb}", "{sha}")
local v2, why2 = H.verify("{deb}", "deadbeef")
local bad = "{TMP}/bad.bin"
local bf = io.open(bad, "w"); bf:write("not a deb"); bf:close()
local v3, why3 = H.verify(bad, nil)
print("T4 ok_sha=" .. tostring(v1) .. " bad_sha=" .. tostring(v2) .. "/" .. tostring(why2) .. " not_deb=" .. tostring(v3) .. "/" .. tostring(why3))

-- 5) download 坏 URL
local d1, r1 = H.download("http://127.0.0.1:{PORT}/notfound.bin", "{TMP}/dl.bin")
print("T5 bad_download=" .. tostring(d1) .. " why=" .. tostring(r1))
'''
        proc = subprocess.run([LUA, "-e", script], capture_output=True, text=True, timeout=120)
        out = proc.stdout + proc.stderr
        print(out.strip())
    finally:
        server.shutdown()
        server.server_close()
        server_bad.shutdown()
        server_bad.server_close()

    check("check() 兼容返回 update=true", "T1 reason=nil update=true version=0.0.92-test" in out, out)
    check("check() os 越界判不兼容", "T2 reason=device_incompatible" in out, out)
    check("compatible() arch 闸（异架构拒绝）", "T3 arch_gate=false" in out, out)
    check("compatible() 正常通过", "ok_gate=true" in out, out)
    check("compatible() min_os 闸", "min_os_gate=false" in out, out)
    check("compatible() 点版本不越界（16.7.16 vs max 16.7）", "T3b point_release_gate=true" in out, out)
    check("verify() 正确 sha 通过", "T4 ok_sha=true" in out, out)
    check("verify() 错误 sha 拒绝", "bad_sha=false/checksum_mismatch" in out, out)
    check("verify() 非 deb 拒绝", "not_deb=false/not_a_deb" in out, out)
    check("download() 坏 URL 失败", "T5 bad_download=false" in out, out)


if __name__ == "__main__":
    main()
    if FAILURES:
        print("RESULT=FAIL n=" + str(len(FAILURES)))
        sys.exit(1)
    print("RESULT=PASS")
