"""Real Lua file I/O, independent processes, and real loopback HTTP receipts.

Only POSIX shell/rename and Zy.Network's host bridge are adapted for Windows.
The bridge accepts mkdir/ls inside a fresh workspace directory, performs HTTP
against the fixture's loopback port, and refuses every deletion/shell command.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
LUA = Path(os.environ.get("ZIYAN_REPAIR_LUA") or os.environ.get("ZIYAN_TEST_LUA") or ROOT / "tmp_shots/repair-20260912/toolchain/lua-5.3.5/src/lua-fixed.exe")

PRELUDE = r'''
io.stdout:setvbuf('no')
local root, phase, server = arg[1], arg[2], arg[3]
local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',string.byte(c)) end)) end
local function unhex(s) return (s:gsub('%x%x',function(c) return string.char(tonumber(c,16)) end)) end
local function call_host(kind, a, b)
  print('HOST '..kind..' '..hex(a or '')..' '..hex(b or ''))
  local reply=assert(io.read('*l'),'host closed bridge')
  local ok,payload=reply:match('^(%d) (.*)$')
  assert(ok,'invalid host response')
  return ok=='1',unhex(payload)
end
ZIYAN_VAR=root..'/var'
ZIYAN_ZYCV=root..'/zycv'
ZIYAN_LUA=root..'/missing-runtime'
ZIYAN_LOG_SERVER=server
local realOpen,realRemove=io.open,os.remove
local function within(path)
  path=path:gsub('\\','/'):gsub('//+','/')
  assert(path:sub(1,#root+1)==root..'/' and not path:find('/../',1,true),'write outside fixture: '..path)
end
io.open=function(path,mode)
  if mode and (mode:find('w',1,true) or mode:find('a',1,true)) then
    within(path)
    if phase=='enqueue' and path:find('/zye_orphan/state.json.',1,true) then
      return nil,'injected state open failure',13
    end
  end
  return realOpen(path,mode)
end
os.remove=function(path) within(path); return realRemove(path) end
-- Windows CRT rename cannot replace an existing file; the host uses the real
-- disk's atomic os.replace to match the production POSIX rename contract.
os.rename=function(src,dst)
  within(src); within(dst)
  local ok,err=call_host('RENAME',src,dst)
  return ok and true or nil,err
end
os.execute=function(command)
  local ok=call_host('SHELL',command)
  return ok and true or nil,'exit',ok and 0 or 1
end
Zy={Network={httpPost=function(url,body) return call_host('HTTP',url,body) end}}
local Q=dofile(arg[4]..'/lua/modules/OfflineQueue.lua')
-- Keep this Windows fixture ASCII; only the configured report root changes.
Q.report_dir=function() return root..'/reports' end
if phase=='enqueue' then
  assert(Q.enqueue('zye_normal',root..'/normal.json'))
  local ok,err=Q.enqueue('zye_orphan',root..'/orphan.json')
  assert(ok==false and err,'orphan state commit must fail visibly')
  assert(not Q.is_durable('zye_orphan',root..'/orphan.json'))
  print('RESULT enqueue normal=true orphan=false')
elseif phase=='offline' then
  local s=Q.flush{force=true,timeout=1}
  assert(s.tried==2 and s.sent==0 and s.pending==2)
  print('RESULT offline tried=2 sent=0 pending=2')
elseif phase=='backoff' then
  local s=Q.flush{timeout=1}
  assert(s.tried==0 and s.pending==2)
  print('RESULT backoff tried=0 pending=2')
elseif phase=='online' then
  local s=Q.flush{force=true,timeout=1}
  assert(s.tried==2 and s.sent==2 and s.pending==0)
  print('RESULT online tried=2 sent=2 pending=0')
elseif phase=='repeat' then
  assert(Q.enqueue('zye_normal',root..'/normal.json'))
  local s=Q.flush{force=true,timeout=1}
  assert(s.tried==1 and s.sent==1 and s.dedup==1)
  print('RESULT repeat sent=1 dedup=1')
elseif phase=='restart' then
  local s=Q.stats()
  assert(s.total==2 and s.sent==2 and s.pending==0)
  print('RESULT restart total=2 sent=2 pending=0')
else error('unknown phase') end
'''


class Receiver(BaseHTTPRequestHandler):
    def do_POST(self):
        self.server.test.assertEqual(self.path, "/api/logs")
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        duplicate = any(event == body for event in self.server.receipts)
        self.server.receipts.append(body)
        raw = json.dumps({"ok": True, "event_id": body["event_id"], "dedup": duplicate}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_args):
        pass


@unittest.skipUnless(LUA.is_file(), "requires the checked Lua 5.3.5 Windows fixture runtime")
class QueueDiskRestart(unittest.TestCase):
    def checked_path(self, text):
        path = Path(text).resolve()
        self.assertTrue(path.is_relative_to(self.fixture), str(path))
        return path

    def shell_bridge(self, command):
        # No command runs through a shell. Only these two filesystem operations
        # are translated; HTTP fallbacks are explicitly unavailable in the host.
        output = re.search(r"> '([^']+)' 2>&1$", command)
        self.assertIsNotNone(output, command)
        result = self.checked_path(output[1])
        if "command -v curl" in command or "command -v wget" in command:
            result.write_text("", encoding="utf-8")
            return False, "fallback unavailable in controlled host"
        mkdir = re.search(r"mkdir -p '([^']+)'", command)
        listing = re.search(r"ls -1 '([^']+)'", command)
        if mkdir:
            self.checked_path(mkdir[1]).mkdir(parents=True, exist_ok=True)
            text = ""
        elif listing:
            path = self.checked_path(listing[1])
            text = "\n".join(sorted(p.name for p in path.iterdir() if not p.name.startswith(".")))
        else:
            self.fail("unsupported host operation: " + command)
        result.write_text(text, encoding="utf-8")
        return True, ""

    def run_lua(self, phase):
        environment = os.environ.copy()
        environment.update(TMP=str(self.fixture / "temps"), TEMP=str(self.fixture / "temps"))
        process = subprocess.Popen([str(LUA), str(self.fixture / "driver.lua"), self.fixture.as_posix(), phase, self.url, ROOT.as_posix()],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding="utf-8", cwd=ROOT, env=environment,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.process_ids.append(process.pid)
        lines = queue.Queue()
        def read_lines():
            for line in process.stdout:
                lines.put(line.rstrip("\n"))
            lines.put(None)
        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()
        output = []
        try:
            while True:
                line = lines.get(timeout=10)
                if line is None:
                    break
                if not line.startswith("HOST "):
                    output.append(line)
                    continue
                _, kind, first, second = line.split(" ", 3)
                a, b = bytes.fromhex(first).decode(), bytes.fromhex(second).decode()
                if kind == "SHELL":
                    ok, response = self.shell_bridge(a)
                elif kind == "RENAME":
                    try:
                        os.replace(self.checked_path(a), self.checked_path(b))
                        ok, response = True, ""
                    except OSError as error:
                        ok, response = False, str(error)
                else:
                    self.assertEqual(kind, "HTTP")
                    self.assertEqual(a, self.url + "/api/logs")
                    request = urllib.request.Request(a, data=b.encode(), headers={"Content-Type": "application/json"})
                    try:
                        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=1) as reply:
                            response, ok = reply.read().decode(), reply.status == 200
                    except urllib.error.URLError as error:
                        response, ok = str(error.reason), False
                    self.http_attempts.append({"phase": phase, "event_id": json.loads(b)["event_id"], "ok": ok})
                process.stdin.write(("1" if ok else "0") + " " + response.encode().hex() + "\n")
                process.stdin.flush()
            process.wait(timeout=5)
            self.assertEqual(process.returncode, 0, "\n".join(output))
            self.assertTrue(any(line.startswith("RESULT ") for line in output), output)
            print("pid=%d %s" % (process.pid, " | ".join(output)))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            process.stdin.close()
            process.stdout.close()
            reader.join(timeout=1)

    def test_real_files_survive_orphan_commit_restart_and_network_recovery(self):
        source = ROOT / "lua/modules/OfflineQueue.lua"
        source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
        workspace_temp = ROOT / "tmp_shots/repair-20260912"
        workspace_temp.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="queue-disk-", dir=workspace_temp) as temp:
            self.fixture = Path(temp).resolve()
            for directory in ("var", "temps", "reports", "zycv/config"):
                (self.fixture / directory).mkdir(parents=True)
            (self.fixture / "driver.lua").write_text(PRELUDE, encoding="utf-8")
            reports = {name: {"event_id": "zye_" + name, "message": "synthetic " + name} for name in ("normal", "orphan")}
            for name, report in reports.items():
                (self.fixture / (name + ".json")).write_text(json.dumps(report), encoding="utf-8")
            self.process_ids, self.http_attempts = [], []
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))  # Reserved but not listening: real connection refusal.
                port = reservation.getsockname()[1]
                self.url = "http://127.0.0.1:%d" % port
                self.run_lua("enqueue")
                spool = self.fixture / "reports/.upload_spool"
                self.assertFalse((spool / "zye_orphan/state.json").exists())
                for name in reports:
                    original = (self.fixture / (name + ".json")).read_bytes()
                    copied = (spool / ("zye_" + name) / "report.json").read_bytes()
                    self.assertEqual(hashlib.sha256(original).digest(), hashlib.sha256(copied).digest())
                self.run_lua("offline")
                for name in reports:
                    state = json.loads((spool / ("zye_" + name) / "state.json").read_text())
                    self.assertEqual((state["status"], state["attempts"]), ("pending", 1))
                    self.assertGreater(state["next_retry"], state["updated"])
                self.run_lua("backoff")
            server = ThreadingHTTPServer(("127.0.0.1", port), Receiver)
            server.test, server.receipts = self, []
            serving = threading.Thread(target=server.serve_forever, daemon=True)
            serving.start()
            try:
                self.run_lua("online")
                self.run_lua("repeat")
                self.run_lua("restart")
                self.assertEqual(len(server.receipts), 3)
                self.assertEqual({r["event_id"] for r in server.receipts}, {"zye_normal", "zye_orphan"})
                self.assertEqual(server.receipts.count(reports["normal"]), 2)
                self.assertEqual(server.receipts.count(reports["orphan"]), 1)
                self.assertEqual([r["ok"] for r in self.http_attempts], [False, False, True, True, True])
                self.assertEqual(len(set(self.process_ids)), 6)
                for name, attempts in (("normal", 3), ("orphan", 2)):
                    state = json.loads((spool / ("zye_" + name) / "state.json").read_text())
                    self.assertEqual((state["status"], state["attempts"]), ("sent", attempts))
                    self.assertEqual(json.loads((self.fixture / (name + ".json")).read_text()), reports[name])
                self.assertTrue(json.loads((spool / "zye_normal/state.json").read_text())["dedup"])
                self.assertEqual(list(self.fixture.rglob("*.tmp")), [])
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), source_sha,
                                 "queue source changed between the six Lua processes")
                print("SOURCE_SHA256=" + source_sha)
                print("HTTP_RECEIPTS=" + json.dumps(self.http_attempts, sort_keys=True))
            finally:
                server.shutdown()
                server.server_close()
                serving.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
