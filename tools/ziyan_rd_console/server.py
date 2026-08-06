#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""子砚自动化研发状态控制台 — 本地网页窗口（真实采集 / 自动刷新）。"""
from __future__ import annotations

import json
import sys
import threading
import time
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from collect import OUT_JSON, collect  # noqa: E402

HOST = "127.0.0.1"
PORT = int(__import__("os").environ.get("ZIYAN_RD_PORT", "8765"))
REFRESH_SEC = 6

_lock = threading.Lock()
_cache: Dict[str, Any] = {}
_last_err = ""


def _collector_loop() -> None:
    global _cache, _last_err
    while True:
        try:
            data = collect()
            with _lock:
                _cache = data
                _last_err = ""
        except Exception:
            with _lock:
                _last_err = traceback.format_exc()
        time.sleep(REFRESH_SEC)


HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>子砚自动化研发状态控制台</title>
<style>
  :root {
    --bg: #0e1114;
    --panel: #161b20;
    --fg: #d7dde3;
    --muted: #8b949e;
    --accent: #3d8bfd;
    --ok: #3fb950;
    --warn: #d29922;
    --err: #f85149;
    --line: #2a323a;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font-family: "PingFang SC", "Helvetica Neue", sans-serif;
  }
  header {
    padding: 16px 20px 8px; border-bottom: 1px solid var(--line);
    display: flex; justify-content: space-between; align-items: baseline; gap: 12px;
  }
  h1 { margin: 0; font-size: 20px; font-weight: 650; letter-spacing: 0.02em; }
  .meta { color: var(--muted); font-family: Menlo, monospace; font-size: 12px; }
  .focus {
    padding: 10px 20px; color: var(--accent); font-size: 14px;
    border-bottom: 1px solid var(--line);
  }
  .cycle {
    display: flex; flex-wrap: wrap; gap: 6px; align-items: center;
    padding: 10px 20px; border-bottom: 1px solid var(--line);
  }
  .chip {
    padding: 4px 10px; background: var(--panel); color: var(--muted);
    font-size: 12px; border: 1px solid var(--line);
  }
  .chip.on { color: var(--accent); border-color: var(--accent); }
  .arrow { color: var(--line); font-size: 12px; }
  main {
    display: grid; grid-template-columns: 1fr 1fr; gap: 12px;
    padding: 12px 16px 24px;
  }
  @media (max-width: 980px) { main { grid-template-columns: 1fr; } }
  section {
    background: var(--panel); border: 1px solid var(--line); padding: 12px 14px;
    min-height: 80px;
  }
  section h2 {
    margin: 0 0 8px; font-size: 13px; color: var(--accent); font-weight: 600;
  }
  pre, .mono {
    margin: 0; white-space: pre-wrap; word-break: break-word;
    font-family: Menlo, monospace; font-size: 11.5px; line-height: 1.45; color: var(--fg);
  }
  .ok { color: var(--ok); }
  .warn { color: var(--warn); }
  .err { color: var(--err); }
  .muted { color: var(--muted); }
  footer {
    padding: 8px 20px 16px; color: var(--muted); font-size: 11px;
    border-top: 1px solid var(--line);
  }
</style>
</head>
<body>
<header>
  <h1>子砚自动化研发状态控制台</h1>
  <div class="meta" id="clock">连接中…</div>
</header>
<div class="focus" id="focus">等待首轮真实采集…</div>
<div class="cycle" id="cycle"></div>
<main id="main"></main>
<footer>
  数据源：工程文件 mtime · tmp_shots · 真机 SSH · 禁止虚构完成状态 ·
  自动刷新 <span id="sec"></span>s ·
  <a href="/api/status" style="color:var(--accent)">/api/status</a>
</footer>
<script>
const REFRESH = %REFRESH%;
document.getElementById('sec').textContent = REFRESH;
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));}
function line(t, cls){return `<div class="mono ${cls||''}">${esc(t)}</div>`;}
function section(title, html){return `<section><h2>${esc(title)}</h2>${html}</section>`;}

function render(d){
  const gen = d.generated_at || '';
  const focus = (d.phase&&d.phase.current_focus) || '';
  document.getElementById('clock').textContent = `更新 ${gen} · 每 ${REFRESH}s`;
  document.getElementById('focus').textContent =
    `当前研发焦点 → ${focus}    引擎 ${d.engine_version||'?'}    设备 ${d.device_host||''}`;

  const cycle = (d.phase&&d.phase.cycle)||[];
  document.getElementById('cycle').innerHTML = cycle.map((n,i)=>
    `<span class="chip ${n===focus?'on':''}">${esc(n)}</span>` +
    (i<cycle.length-1?'<span class="arrow">→</span>':'')
  ).join('');

  const device = d.device||{};
  const left=[], right=[];

  // phases
  let ph='';
  ((d.phase&&d.phase.stages)||[]).forEach(s=>{
    const cls = s.status==='done'?'ok':(s.status==='blocked'?'err':'warn');
    ph += line(`[${s.status}] ${s.name}`, cls);
    ph += line(`  证据: ${s.evidence}`, 'muted');
  });
  left.push(section('当前研发阶段', ph||line('无','muted')));

  left.push(section('正在执行任务', line(d.running_task||'','muted')));

  let done='';
  (d.completed_tasks||[]).forEach(x=> done += line('· '+x,'ok'));
  left.push(section('已完成任务', done||line('（尚无带证据的完成项）','muted')));

  let ch='';
  (d.code_changes||[]).slice(0,20).forEach(c=> ch += line(`${c.mtime}  ${c.path}`,'muted'));
  left.push(section('代码变化（48h 真实 mtime）', ch||line('无','muted')));

  const nm=(d.new_modules||[]).join(', ');
  left.push(section('新增模块', line(nm?nm:'（相对基线无新增）', nm?'ok':'muted') +
    line(`引擎模块总数: ${(d.modules||[]).length}`,'muted')));

  let fo='';
  (d.function_optimizations||[]).forEach(h=> fo += line('· '+h,'muted'));
  left.push(section('函数优化（由真实改动映射）', fo||line('无','muted')));

  const ts=d.ts_learning||{};
  let tsh = line('规则: '+(ts.rule||''),'muted') +
    line(`learning 模块: ${ts.learning_module} (${ts.learning_path||''})`,'muted') +
    line('说明: '+(ts.note||''),'warn');
  (ts.docs||[]).forEach(doc=> tsh += line(`· ${doc.file} (${doc.bytes}B)`,'muted'));
  left.push(section('TouchSprite 学习结果', tsh));

  // right
  let run = line(`SSH: ${device.ssh_ok?'OK':'FAIL'}`, device.ssh_ok?'ok':'err');
  if(device.error) run += line(device.error,'err');
  run += line(`ping=${device.ping} host=${device.host}`,'muted');
  run += line(`project_active=${device.project_active}`,'muted');
  run += line(`sb_alive=${device.sb_alive}`,'muted');
  run += line(`selftest_pass=${device.selftest_pass}`, String(device.selftest_pass)==='1'?'ok':'warn');
  right.push(section('真机运行状态', run));

  right.push(section('设备信息', line(device.pkg||'（无 dpkg 输出）','muted')));

  const ss=d.screen_sync||{};
  right.push(section('屏幕同步状态',
    line(`ok=${ss.ok}`, ss.ok?'ok':'warn') + line(ss.raw||ss.note||'','muted')));

  const gt=d.game_test||{};
  let g = line('forever:\n'+(gt.forever_status||'（无）'),'muted');
  (gt.play_log_tail||[]).slice(-6).forEach(ln=> g += line(ln, ln.includes('FAIL')?'err':'muted'));
  right.push(section('游戏测试状态', g));

  const role=d.role_enter||{};
  const rcls = role.verdict==='FAIL'?'err':(role.verdict==='PASS'?'ok':'warn');
  right.push(section('进入角色状态',
    line(`verdict=${role.verdict}  ${role.role_enter||''}`, rcls) +
    line(role.login_once_file?('文件: '+role.login_once_file):'', 'muted')));

  const cg=d.codegen||{};
  let cgh = line(cg.status||'','muted');
  (cg.scripts||[]).slice(0,8).forEach(s=> cgh += line(`· ${s.path} @ ${s.mtime}`,'muted'));
  right.push(section('自动化脚本生成状态', cgh));

  const probs=(d.errors&&d.errors.problems)||[];
  let pe = probs.length?'' : line('当前采集未发现带证据的问题项','ok');
  probs.forEach(p=>{
    pe += line(`[${p.level}] ${p.item}`, p.level==='error'?'err':'warn');
    pe += line('  src: '+p.src,'muted');
  });
  right.push(section('错误分析 / 问题列表', pe));

  let fx='';
  (d.fix_progress||[]).forEach(f=>{
    fx += line(`· ${f.item}: ${f.status}`,'ok');
    fx += line('  证据: '+f.evidence,'muted');
  });
  right.push(section('修复进度', fx||line('（无带证据的修复项）','muted')));

  let np='';
  (d.next_plans||[]).forEach(p=> np += line('→ '+p,'warn'));
  right.push(section('下一步计划', np||line('无','muted')));

  if(d._collector_error){
    right.push(section('采集器异常', line(d._collector_error,'err')));
  }

  document.getElementById('main').innerHTML = left.join('') + right.join('');
}

async function tick(){
  try{
    const r = await fetch('/api/status?ts='+Date.now());
    const d = await r.json();
    render(d);
  }catch(e){
    document.getElementById('focus').textContent = '拉取失败: '+e;
  }
}
tick();
setInterval(tick, REFRESH*1000);
</script>
</body>
</html>
""".replace("%REFRESH%", str(REFRESH_SEC))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self._send(200, HTML.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path == "/api/status":
            with _lock:
                data = dict(_cache) if _cache else {}
                err = _last_err
            if not data:
                # fallback read file
                if OUT_JSON.exists():
                    try:
                        data = json.loads(OUT_JSON.read_text(encoding="utf-8"))
                    except Exception as e:
                        data = {"generated_at": "", "phase": {"current_focus": "采集中"}, "errors": {"problems": []}}
                        err = str(e)
                else:
                    data = {
                        "generated_at": "",
                        "phase": {"current_focus": "首轮采集中", "cycle": [], "stages": []},
                        "device": {},
                        "errors": {"problems": []},
                        "code_changes": [],
                        "completed_tasks": [],
                        "next_plans": [],
                    }
            if err:
                data["_collector_error"] = err
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            return
        self._send(404, b"not found", "text/plain")


def main() -> None:
    # warm first collect
    try:
        data = collect()
        with _lock:
            _cache.update(data)
    except Exception:
        with _lock:
            global _last_err
            _last_err = traceback.format_exc()

    threading.Thread(target=_collector_loop, daemon=True).start()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    url = f"http://{HOST}:{PORT}/"
    print(f"[ZiYan] RD console → {url}", flush=True)
    print(f"[ZiYan] JSON → {OUT_JSON}", flush=True)
    try:
        webbrowser.open(url)
    except Exception:
        pass
    httpd.serve_forever()


if __name__ == "__main__":
    main()
