#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OfflineQueue 合同测试（真实 HTTP 服务 + 真实 Lua + 真实断网/恢复）。

场景（对齐需求文档「服务器关闭时日志不能丢」）：
  1. 服务器关闭：3 条错误报告全部落盘入队，state=pending
  2. 服务器关闭时 flush：tried=3/sent=0，事件不丢并写入退避时间
  3. 退避生效：未到期不重试（BACKOFF tried=0）
  4. 服务器恢复：flush 自动续传成功 sent=3、pending=0
  5. 幂等：同一 event_id 重投，服务端识别重复（dedup=true）
  6. 重启读取：队列状态全在磁盘，新进程可读回

运行：python3 tools/test_offline_queue_contract.py
"""
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import threading
import time
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = "/tmp/zy_oq_contract"
LUA = shutil.which("lua5.3") or shutil.which("lua") or "/Users/mac/lua/bin/lua"
PORT = 18098

FAILURES = []
SEEN = []


def check(name, cond, detail=""):
    if cond:
        print("PASS " + name)
    else:
        print("FAIL " + name + " :: " + str(detail))
        FAILURES.append(name)


class ReusableServer(socketserver.TCPServer):
    allow_reuse_address = True


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(size)
        try:
            data = json.loads(body)
        except Exception:
            data = {"unparsable": body[:80].decode("utf-8", "replace")}
        dup = any(x.get("event_id") == data.get("event_id") for x in SEEN)
        SEEN.append(data)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(
            json.dumps({"ok": True, "event_id": data.get("event_id"), "dedup": dup}).encode()
        )

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')


    def log_message(self, *args):
        pass


def lua(code, timeout=60):
    proc = subprocess.run([LUA, "-e", code], capture_output=True, text=True, timeout=timeout)
    return proc.stdout + proc.stderr


def prelude():
    return (
        'package.path = "' + ROOT + '/lua/modules/?.lua;" .. package.path\n'
        '_G.ZIYAN_ZYCV = "' + TMP + '/media/ZYCV"\n'
        '_G.ZIYAN_VAR = "' + TMP + '/var"\n'
        '_G.ZIYAN_LOG_SERVER = "http://127.0.0.1:' + str(PORT) + '"\n'
        'os.execute("mkdir -p \'' + TMP + '/var\' \'' + TMP + '/media/ZYCV/config\'")\n'
        'local Q = dofile("' + ROOT + '/lua/modules/OfflineQueue.lua"); Q.install()\n'
    )


def fresh_tmp():
    """每次运行用全新隔离目录，且旧目录删不掉时必须报错而不是静默复用。

    此前 TMP 固定为 /tmp/zy_oq_contract，用 shutil.rmtree(ignore_errors=True) 清理。
    若该目录被 root 占用（本机 sudo 需密码），rmtree 会静默失败，
    于是上一次运行残留的 state.json(status=sent) 被本次复用：
    「服务器关闭时全部入队」实测得到 pending=0 sent=3，7 项断言全部反向假 FAIL，
    真实缺陷会被这种假结果掩盖。现在改为每次 makedirs 到唯一新目录；
    万一仍复用（目录已存在且非空）则直接失败。
    """
    base = "%s.%d.%d" % (TMP, os.getpid(), int(time.time()))
    if os.path.exists(base):
        raise SystemExit("FAIL: fixture dir already exists: " + base)
    os.makedirs(base + "/media/ZYCV/res")
    os.makedirs(base + "/media/ZYCV/config")
    return base


def main():
    global TMP
    TMP = fresh_tmp()
    # 旧的固定路径若残留（例如被 root 占用），只提示，不影响本次运行
    if os.path.isdir("/tmp/zy_oq_contract"):
        leftover = os.path.join("/tmp/zy_oq_contract", "media/ZYCV/res/错误报告/.upload_spool")
        if os.path.isdir(leftover):
            print("NOTE: stale fixture /tmp/zy_oq_contract still present "
                  "(owned by another user?) - not reused by this run.")

    # 1) 服务器关闭时产生 3 条错误
    out = lua(prelude() + (
        'local ER = dofile("' + ROOT + '/lua/modules/ErrorReporter.lua"); ER.install()\n'
        'ER.current_script("' + TMP + '/biz.lua")\n'
        'for i = 1, 3 do ER.report("script_error", "boom " .. i) end\n'
        'local s = Q.stats()\n'
        'print(string.format("QUEUED total=%d pending=%d sent=%d failed=%d", s.total, s.pending, s.sent, s.failed))\n'
    ))
    print(out.strip())
    check("服务器关闭时全部入队", "QUEUED total=3 pending=3 sent=0 failed=0" in out, out)

    # 2) 服务器关闭：flush 失败但不丢
    out = lua(prelude() + (
        'local st = Q.flush{ force = true, timeout = 3 }\n'
        'print(string.format("CLOSED tried=%d sent=%d pending=%d", st.tried, st.sent, st.pending))\n'
        'local s2 = Q.stats()\n'
        'print(string.format("AFTER_CLOSED pending=%d", s2.pending))\n'
    ))
    print(out.strip())
    check("关闭时 flush 全部失败仍 pending", "CLOSED tried=3 sent=0 pending=3" in out, out)
    check("关闭后事件未丢失", "AFTER_CLOSED pending=3" in out, out)

    # 3) 退避生效
    out = lua(prelude() + (
        'local st = Q.flush{ timeout = 3 }\n'
        'print(string.format("BACKOFF tried=%d", st.tried))\n'
    ))
    print(out.strip())
    check("退避期内不重复尝试", "BACKOFF tried=0" in out, out)

    # 4) 服务器恢复 → 自动续传
    server = ReusableServer(("127.0.0.1", PORT), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        out = lua(prelude() + (
            'local st = Q.flush{ force = true, timeout = 5 }\n'
            'print(string.format("UP tried=%d sent=%d pending=%d failed=%d", st.tried, st.sent, st.pending, st.failed))\n'
            'local s = Q.stats()\n'
            'print(string.format("FINAL pending=%d sent=%d failed=%d", s.pending, s.sent, s.failed))\n'
        ))
        print(out.strip())
        check("恢复后自动续传", "UP tried=3 sent=3 pending=0" in out, out)
        check("队列清空 pending", "FINAL pending=0 sent=3" in out, out)

        # 5) 幂等重投
        out = lua(prelude() + (
            'local dir = Q.spool_dir()\n'
            'local p = io.popen("ls -1 \'" .. dir .. "\' | head -1")\n'
            'local ev = p:read("*l"); p:close()\n'
            'local sp = dir .. "/" .. ev .. "/state.json"\n'
            'local body = io.open(sp, "r"):read("*a"):gsub(\'"status":"sent"\', \'"status":"pending"\')\n'
            'local w = io.open(sp, "w"); w:write(body); w:close()\n'
            'local st2 = Q.flush{ force = true, timeout = 5 }\n'
            'local sbody = io.open(sp, "r"):read("*a")\n'
            'local saved = sbody:match(\'"dedup":(%%a+)\')\n'
            'print("REDELIVER sent=" .. tostring(st2.sent) .. " dedup_count=" .. tostring(st2.dedup) .. " saved_dedup=" .. tostring(saved))\n'
        ))
        print(out.strip())
        check("同 ID 重投被识别为重复", ("dedup_count=1" in out) or ("saved_dedup=true" in out), out)
    finally:
        server.shutdown()
        server.server_close()

    # 6) 重启后状态仍在磁盘（崩溃/设备重启等价）
    out = lua(prelude() + (
        'local s = Q.stats()\n'
        'print(string.format("RESTART_READ total=%d sent=%d", s.total, s.sent))\n'
        'local ev = io.popen("ls -1 \'" .. Q.spool_dir() .. "\' | head -1"):read("*l")\n'
        'local st = io.open(Q.spool_dir() .. "/" .. ev .. "/state.json", "r")\n'
        'print("STATE_ON_DISK=" .. tostring(st ~= nil))\n'
        'if st then st:close() end\n'
    ))
    print(out.strip())
    check("重启后读回队列状态", "RESTART_READ total=3 sent=3" in out, out)
    check("状态文件持久化", "STATE_ON_DISK=true" in out, out)

    ids = [x.get("event_id") for x in SEEN]
    counts = Counter(ids)
    check("服务端收到 3 个唯一事件", len(set(ids)) == 3, ids)
    check("存在重复投递（幂等前提）", any(v > 1 for v in counts.values()), dict(counts))


if __name__ == "__main__":
    main()
    if FAILURES:
        print("RESULT=FAIL n=" + str(len(FAILURES)))
        sys.exit(1)
    print("RESULT=PASS")
