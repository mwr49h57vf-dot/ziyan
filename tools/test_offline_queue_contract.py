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
import tempfile
import threading
import time
import traceback
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


def assert_writable(path):
    """写探针：证明这个目录真的归当前用户所有且可写。

    这里单独成函数是为了能直接测它（见 tools/test_offline_queue_fixture_guard.py）。
    只要写不进去就立刻失败，绝不继续跑出一堆无法解释的断言结果。
    """
    probe = os.path.join(path, ".write_probe")
    try:
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
    except OSError as e:
        raise SystemExit(
            "FAIL: fresh fixture dir is not writable by uid %d: %s (%s)\n"
            "      该目录必须归当前用户所有，否则测试状态会被污染。"
            % (os.getuid(), path, e)
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
    assert_writable(base)
    return base


def describe_owner(path):
    """返回 'uid:gid'（拿不到就返回 unknown），用于把夹具污染的原因说清楚。"""
    try:
        st = os.stat(path)
        return "%d:%d" % (st.st_uid, st.st_gid)
    except OSError as e:
        return "unknown (%s)" % e


def cleanup_fixture(path):
    """跑完删掉本次自己的夹具目录，避免 /tmp 里越堆越多。

    删不掉时如实报出原因（而不是静默 ignore_errors=True），
    因为「删不掉的残留」正是上一轮假 FAIL 的根源。
    """
    try:
        shutil.rmtree(path)
        return True, ""
    except OSError as e:
        return False, str(e)


def run_checks():
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



def main():
    global TMP
    stale = os.path.isdir("/tmp/zy_oq_contract")
    if stale:
        owner = describe_owner("/tmp/zy_oq_contract")
        print("NOTE: stale fixture /tmp/zy_oq_contract still present (owner uid:gid=%s)." % owner)
        print("      This run does NOT reuse it: it uses a fresh unique directory instead.")
        if owner.startswith(str(os.getuid()) + ":"):
            print("      NOTE: it is owned by the current user, so it is removable:")
            print("            rm -rf /tmp/zy_oq_contract")
            print("      (kept on purpose so a real cause is visible instead of silently deleted)")
        else:
            print("      NOTE: it is NOT owned by uid %d and cannot be removed without sudo:"
                  % os.getuid())
            print("            sudo rm -rf /tmp/zy_oq_contract")
            print("      Removing it is NOT required for this test to be trustworthy,")
            print("      but it must be recorded as environment residue.")

    TMP = fresh_tmp()
    crashed = None
    try:
        run_checks()
    except BaseException as e:  # 包括断言/超时/键盘中断：都要留下可读原因
        crashed = e
    finally:
        cleaned, why = cleanup_fixture(TMP)
        if cleaned:
            print("CLEANUP removed fixture " + TMP)
        else:
            print("CLEANUP FAILED (fixture left behind): " + TMP + " :: " + why)
            FAILURES.append("夹具清理失败")

    if crashed is not None:
        traceback.print_exception(type(crashed), crashed, crashed.__traceback__)
        print("RESULT=ERROR " + type(crashed).__name__ + ": " + str(crashed))
        sys.exit(2)


# ---------------------------------------------------------------------------
# 防护自测（--self-test）
#
# 本测试曾因夹具被 root 占用而静默复用旧 state.json(status=sent)，
# 导致 7 项断言反向假 FAIL。修好后必须证明「防护本身有效」，
# 否则防护失效时会再次安静地给出假结果。这里直接测那几个防护。
# ---------------------------------------------------------------------------
def self_test():
    failures = []

    def guard(name, cond, detail=""):
        if cond:
            print("PASS " + name)
        else:
            print("FAIL " + name + " :: " + str(detail))
            failures.append(name)

    made = []

    # assert_writable：可写目录静默通过
    d = tempfile.mkdtemp(prefix="zy_guard_ok_")
    made.append((d, 0o755))
    try:
        assert_writable(d)
        guard("可写目录通过写探针", True)
    except SystemExit as e:
        guard("可写目录通过写探针", False, e)

    # assert_writable：只读目录必须响亮失败
    ro = tempfile.mkdtemp(prefix="zy_guard_ro_")
    made.append((ro, 0o755))
    os.chmod(ro, 0o555)
    try:
        assert_writable(ro)
        guard("只读目录被写探针拦下", False, "没有抛异常，防护失效")
    except SystemExit as e:
        guard("只读目录被写探针拦下", "not writable" in str(e), e)
    finally:
        os.chmod(ro, 0o755)

    # fresh_tmp：目录已存在时必须拒绝复用（一次性污染不再可能）
    poison = tempfile.mkdtemp(prefix="zy_guard_poison_")
    made.append((poison, 0o755))
    saved = TMP
    try:
        globals()["TMP"] = poison
        base = "%s.%d.%d" % (poison, os.getpid(), int(time.time()))
        os.makedirs(base)
        try:
            fresh_tmp()
            guard("已存在目录被拒绝复用", False, "静默复用了旧目录")
        except SystemExit as e:
            guard("已存在目录被拒绝复用", "already exists" in str(e), e)
    finally:
        globals()["TMP"] = saved

    # fresh_tmp：正常路径必须真的建出隔离目录
    ok_root = tempfile.mkdtemp(prefix="zy_guard_new_")
    made.append((ok_root, 0o755))
    saved = TMP
    try:
        globals()["TMP"] = ok_root
        new = fresh_tmp()
        guard("正常路径建出隔离目录", os.path.isdir(new) and new.startswith(ok_root), new)
        guard("隔离目录带 media/ZYCV 结构",
              os.path.isdir(os.path.join(new, "media/ZYCV/res")), new)
        cleaned, why = cleanup_fixture(new)
        guard("cleanup_fixture 能删自己的目录", cleaned and not os.path.exists(new), why)
    finally:
        globals()["TMP"] = saved

    # cleanup_fixture：删不掉时必须如实报错，不静默
    stuck = tempfile.mkdtemp(prefix="zy_guard_stuck_")
    made.append((stuck, 0o755))
    inner = os.path.join(stuck, "x")
    os.makedirs(inner)
    os.chmod(inner, 0o555)
    os.chmod(stuck, 0o555)
    try:
        cleaned, why = cleanup_fixture(stuck)
        guard("删不掉时如实报错而非静默", (not cleaned) and bool(why), (cleaned, why))
    finally:
        os.chmod(stuck, 0o755)
        os.chmod(inner, 0o755)

    # describe_owner：能读出真实属主
    owner = describe_owner(tempfile.gettempdir())
    guard("describe_owner 返回 uid:gid", ":" in owner and not owner.startswith("unknown"), owner)

    for path, mode in made:
        try:
            os.chmod(path, mode)
            for root_dir, dirs, files in os.walk(path):
                for name in dirs + files:
                    try:
                        os.chmod(os.path.join(root_dir, name), 0o755)
                    except OSError:
                        pass
            shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass

    if failures:
        print("RESULT=FAIL n=" + str(len(failures)))
        return 1
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    main()
    if FAILURES:
        print("RESULT=FAIL n=" + str(len(FAILURES)))
        sys.exit(1)
    print("RESULT=PASS")
