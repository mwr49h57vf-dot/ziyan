#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""子砚 SDK 函数文档生成器：扫描 lua/modules → 合并 catalog → 输出 HTML + 同步报告。"""
from __future__ import annotations

import json
import os
import re
import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MOD_DIR = ROOT / "lua" / "modules"
CATALOG = Path(__file__).resolve().parent / "api_catalog.json"
CHANGELOG = Path(__file__).resolve().parent / "CHANGELOG.jsonl"
HTML_OUT = ROOT / "子砚触控函数说明.html"
REPORT_OUT = Path(__file__).resolve().parent / "SYNC_REPORT.json"

MODULE_ORDER = [
    "Device", "App", "Screen", "Coordinate", "Vision", "Image", "OCR",
    "Touch", "File", "Network", "Verify", "StateMachine", "Game",
    "Script", "AI", "Knowledge", "Optimization", "IssueClassifier",
    "OptimizationAdvisor", "OptimizationRollback",
    "Config", "Input", "Engine", "Case", "Diagnose", "Log",
]

MODULE_BLURB = {
    "Device": "连接设备、获取设备信息、检测状态、设备画像落盘。",
    "App": "应用启动/关闭、前后台切换、窗口状态检测、运行监控。",
    "Screen": "截图、获取分辨率、屏幕同步与锁帧。",
    "Coordinate": "设计坐标转换、比例计算（禁止固定物理像素）。",
    "Vision": "视觉分析门面（聚合 Image + OCR）。",
    "Image": "找色、找图、取色、轮询找色。",
    "OCR": "文字识别、找字、轮询找字。",
    "Touch": "比例/设计/命中点击、滑动、手势、长按（禁止裸物理坐标）。",
    "File": "读写配置与数据、路径辅助。",
    "Network": "HTTP GET/POST、Lua↔Python。",
    "Verify": "结果验证、指纹、失败报告。",
    "StateMachine": "状态查询、建议、步进与转移校验。",
    "Game": "通用交互状态引擎：分类→建议→步进。",
    "Script": "脚本会话、变量/循环/任务流、异常恢复。",
    "Config": "JSON 配置读写（对齐外置配置思想）。",
    "Input": "文本输入通道（点比例焦点后输入）。",
    "AI": "自主脚本生成闭环。",
    "Knowledge": "自动化经验库（含优化版本字段）。",
    "Optimization": "长期自主优化编排 2.0（proposal 默认）。",
    "IssueClassifier": "问题自动分类（七类）。",
    "OptimizationAdvisor": "优化建议生成器（禁止静默改核心）。",
    "OptimizationRollback": "优化快照与失败回滚。",
    "Engine": "通用自动化编排与能力验证。",
    "Case": "自动化测试案例库。",
    "Diagnose": "卡住时自动归因。",
    "Log": "日志、toast、对话框。",
}


def scan_modules() -> dict[str, list[dict]]:
    found: dict[str, list[dict]] = {}
    for fn in sorted(MOD_DIR.glob("*.lua")):
        if fn.name.startswith("_") or fn.name == "init.lua":
            continue
        mod = fn.stem
        text = fn.read_text(encoding="utf-8")
        funcs = []
        seen = set()
        for m in re.finditer(r"^function\s+M\.(\w+)\s*\(([^)]*)\)", text, re.M):
            name, args = m.group(1), m.group(2).strip()
            params = [a.strip() for a in args.split(",") if a.strip() and a.strip() != "..."]
            vararg = "..." in args
            # docstring: previous -- lines
            start = m.start()
            pre = text[:start].splitlines()
            docs = []
            for line in reversed(pre):
                s = line.strip()
                if s.startswith("---"):
                    docs.append(s.lstrip("- ").strip())
                elif s.startswith("--"):
                    docs.append(s.lstrip("- ").strip())
                elif s == "" or s.startswith("local "):
                    continue
                else:
                    break
            docs.reverse()
            summary = " ".join(docs) if docs else ""
            funcs.append({
                "name": name,
                "params_raw": params,
                "vararg": vararg,
                "summary_from_code": summary,
                "source": str(fn.relative_to(ROOT)),
            })
            seen.add(name)
        # 别名：M.swipe = M.swipeRatio
        for m in re.finditer(r"^M\.(\w+)\s*=\s*M\.(\w+)", text, re.M):
            alias, target = m.group(1), m.group(2)
            if alias in seen:
                continue
            tgt = next((f for f in funcs if f["name"] == target), None)
            funcs.append({
                "name": alias,
                "params_raw": (tgt or {}).get("params_raw") or [],
                "vararg": (tgt or {}).get("vararg") or False,
                "summary_from_code": f"别名 → M.{target}",
                "source": str(fn.relative_to(ROOT)),
            })
            seen.add(alias)
        found[mod] = funcs
    # Vision is virtual in init.lua
    found.setdefault("Vision", [])
    found.setdefault("Log", [])
    return found


def load_catalog() -> dict:
    if CATALOG.exists():
        return json.loads(CATALOG.read_text(encoding="utf-8"))
    return {"version": "1.0.0", "functions": {}}


def default_entry(mod: str, name: str, params: list[str], summary: str) -> dict:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    plist = []
    for p in params:
        plist.append({
            "name": p,
            "type": "any",
            "desc": "",
            "required": not p.endswith("?"),
            "default": None,
        })
    fq = f"Zy.{mod}.{name}"
    return {
        "id": fq,
        "name": fq,
        "module": mod,
        "summary": summary or f"{mod}.{name}",
        "purpose": "",
        "params": plist,
        "returns": {"type": "any", "desc": ""},
        "errors": [],
        "usage": f"Zy.{mod}.{name}(...)",
            "example": "-- TODO 示例\nlocal r = Zy.{}.{}()".format(mod, name),
        "principle": "Device→Screen→Coordinate→Vision→Touch→Verify→StateMachine",
        "status": "active",
        "updated": now,
        "changelog": [],
    }


def merge(scanned: dict, catalog: dict) -> tuple[dict, dict]:
    """返回合并后的 catalog 与 sync 报告。"""
    funcs = catalog.setdefault("functions", {})
    report = {
        "scanned": 0,
        "catalog_before": len(funcs),
        "added": [],
        "missing_in_code": [],
        "modules": {},
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    seen = set()
    for mod, flist in scanned.items():
        report["modules"][mod] = []
        for f in flist:
            fq = f"Zy.{mod}.{f['name']}"
            seen.add(fq)
            report["scanned"] += 1
            report["modules"][mod].append(f["name"])
            if fq not in funcs:
                funcs[fq] = default_entry(mod, f["name"], f["params_raw"], f["summary_from_code"])
                report["added"].append(fq)
                append_changelog({
                    "action": "add",
                    "id": fq,
                    "reason": "auto-scan new function",
                    "after": funcs[fq]["summary"],
                })
            else:
                # sync param names if empty catalog params
                ent = funcs[fq]
                if f["summary_from_code"] and (not ent.get("summary") or ent["summary"].startswith(mod + ".")):
                    ent["summary"] = f["summary_from_code"]
                if not ent.get("params") and f["params_raw"]:
                    ent["params"] = default_entry(mod, f["name"], f["params_raw"], "")["params"]
    for fq in list(funcs.keys()):
        if fq.startswith("Zy.") and fq not in seen:
            # allow Vision/Log virtual + deprecated
            mod = fq.split(".")[1] if fq.count(".") >= 2 else ""
            if mod in ("Vision", "Log"):
                continue
            if funcs[fq].get("status") == "deprecated":
                continue
            # if module file exists but function gone
            if mod in scanned:
                report["missing_in_code"].append(fq)
    catalog["functions"] = funcs
    catalog["version"] = catalog.get("version") or "1.0.0"
    catalog["updated"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    report["catalog_after"] = len(funcs)
    return catalog, report


def append_changelog(row: dict) -> None:
    row = dict(row)
    row["ts"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with CHANGELOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def esc(s: str) -> str:
    return (
        str(s or "")
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def render_fn(ent: dict) -> str:
    status = ent.get("status") or "active"
    badge = {"active": "正常", "deprecated": "已废弃", "planned": "待完善"}.get(status, status)
    params = ent.get("params") or []
    rows = []
    for p in params:
        rows.append(
            f"<tr><td><code>{esc(p.get('name'))}</code></td>"
            f"<td>{esc(p.get('type'))}</td>"
            f"<td>{esc(p.get('desc'))}</td>"
            f"<td>{'是' if p.get('required') else '否'}</td>"
            f"<td>{esc(p.get('default') if p.get('default') is not None else '—')}</td></tr>"
        )
    param_table = (
        "<table class='params'><thead><tr><th>参数名</th><th>类型</th><th>作用</th><th>必填</th><th>默认值</th></tr></thead>"
        f"<tbody>{''.join(rows) or '<tr><td colspan=5>无参数</td></tr>'}</tbody></table>"
    )
    ret = ent.get("returns") or {}
    errs = ent.get("errors") or []
    err_html = "".join(f"<li>{esc(e)}</li>" for e in errs) or "<li>无特殊说明</li>"
    related = ent.get("related") or []
    rel_html = " · ".join(f"<a href='#{esc(r)}'><code>{esc(r)}</code></a>" for r in related) or "—"
    ch = ent.get("changelog") or []
    ch_html = "".join(
        f"<li><strong>{esc(c.get('date',''))}</strong>：{esc(c.get('before',''))} → {esc(c.get('after',''))} "
        f"（原因：{esc(c.get('reason',''))}）测试：{esc(c.get('test',''))}</li>"
        for c in ch
    ) or "<li>尚无变更记录</li>"
    dep = ""
    if status == "deprecated":
        dep = (
            f"<div class='warn'><strong>废弃原因：</strong>{esc(ent.get('deprecated_reason',''))}<br>"
            f"<strong>替代方案：</strong><code>{esc(ent.get('replacement',''))}</code><br>"
            f"<strong>迁移指南：</strong>{esc(ent.get('migration',''))}</div>"
        )
    zh_name = ent.get("zh_name") or ""
    zh_desc = ent.get("zh_desc") or ent.get("summary") or ""
    aliases = ent.get("aliases") or []
    alias_html = ""
    if aliases:
        alias_html = (
            "<h4>兼容别名</h4><p>"
            + " · ".join(f"<code>{esc(a)}</code>" for a in aliases)
            + "</p>"
        )
    complete = ent.get("doc_complete")
    gap_note = ""
    if complete is False:
        gaps = "、".join(ent.get("doc_gaps") or [])
        gap_note = f"<div class='warn'><strong>文档待完善：</strong>{esc(gaps)}</div>"
    short_usage = ent.get("short_usage") or ""
    scenario = ent.get("scenario") or ""
    return f"""
<article class="fn" id="{esc(ent['id'])}" data-module="{esc(ent.get('module'))}" data-status="{esc(status)}">
  <header>
    <h3><code>{esc(ent.get('name'))}</code>
      {f'<span class="zh">{esc(zh_name)}</span>' if zh_name else ''}
      <span class="badge {esc(status)}">{esc(badge)}</span></h3>
    <p class="meta">所属模块：<strong>{esc(ent.get('module'))}</strong> · 更新：{esc(ent.get('updated',''))}</p>
  </header>
  {dep}
  {gap_note}
  <h4>中文名称</h4><p><strong>{esc(zh_name or '—')}</strong></p>
  <h4>功能说明</h4><p>{esc(zh_desc or ent.get('summary'))}</p>
  <h4>设计目的</h4><p>{esc(ent.get('purpose') or zh_desc or ent.get('summary'))}</p>
  <h4>实际使用场景</h4><p>{esc(scenario or '见功能说明')}</p>
  <h4>输入参数</h4>{param_table}
  <h4>返回值</h4>
  <p>返回类型：<code>{esc(ret.get('type','any'))}</code></p>
  <p>{esc(ret.get('desc',''))}</p>
  <h4>错误处理</h4><ul>{err_html}</ul>
  <h4>调用方法</h4><pre><code>{esc(ent.get('usage',''))}</code></pre>
  {f'<h4>简便调用</h4><pre><code>{esc(short_usage)}</code></pre>' if short_usage else ''}
  {alias_html}
  <h4>完整代码示例</h4><pre><code>{esc(ent.get('example',''))}</code></pre>
  <h4>内部实现原理</h4><p>{esc(ent.get('principle',''))}</p>
  <h4>关联函数</h4><p>{rel_html}</p>
  <h4>变更历史</h4><ul>{ch_html}</ul>
</article>
"""


def render_html(catalog: dict, report: dict) -> str:
    funcs = catalog.get("functions") or {}
    by_mod: dict[str, list] = {}
    for fq, ent in funcs.items():
        by_mod.setdefault(ent.get("module") or "?", []).append(ent)
    for m in by_mod:
        by_mod[m].sort(key=lambda e: e.get("name", ""))

    nav = []
    body = []
    for mod in MODULE_ORDER:
        items = by_mod.get(mod) or []
        if not items and mod not in ("Vision", "Log"):
            continue
        nav.append(f'<a href="#mod-{esc(mod)}">{esc(mod)} <small>{len(items)}</small></a>')
        cards = "".join(render_fn(e) for e in items)
        empty = '<p class="todo">本模块函数待从代码同步完善。</p>'
        blurb = esc(MODULE_BLURB.get(mod) or "")
        mod_esc = esc(mod)
        body.append(
            "<section id='mod-{m}' class='module'>"
            "<h2>{m}</h2>"
            "<p class='blurb'>{b}</p>"
            "{c}"
            "</section>".format(m=mod_esc, b=blurb, c=cards or empty)
        )

    # leftover modules
    for mod, items in sorted(by_mod.items()):
        if mod in MODULE_ORDER:
            continue
        body.append(
            f"<section id='mod-{esc(mod)}' class='module'><h2>{esc(mod)}</h2>"
            + "".join(render_fn(e) for e in items)
            + "</section>"
        )

    added = report.get("added") or []
    missing = report.get("missing_in_code") or []
    planned = [fq for fq, e in funcs.items() if e.get("status") == "planned"]
    deprecated = [fq for fq, e in funcs.items() if e.get("status") == "deprecated"]

    index_rows = []
    for mod in MODULE_ORDER:
        for e in by_mod.get(mod) or []:
            index_rows.append(
                f"<tr><td><a href='#{esc(e['id'])}'><code>{esc(e['name'])}</code></a>"
                f"{(' <span class=zh>' + esc(e.get('zh_name')) + '</span>') if e.get('zh_name') else ''}</td>"
                f"<td>{esc(e.get('module'))}</td><td>{esc(e.get('status'))}</td>"
                f"<td>{esc(e.get('zh_desc') or e.get('summary',''))}</td></tr>"
            )

    nav_html = "\n".join(nav)
    body_html = "\n".join(body)
    index_html = "\n".join(index_rows)
    added_s = ", ".join(added) or "无"
    missing_s = ", ".join(missing) or "无"
    planned_s = ", ".join(planned) or "无"

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>子砚触控函数说明 · SDK</title>
<style>
:root {{
  --bg:#0f1419; --panel:#1a222c; --text:#e7eef7; --muted:#93a4b8;
  --accent:#3dbb9a; --line:#2a3542; --warn:#c9833a; --bad:#c44c4c; --ok:#3dbb9a;
  --code:#0b1015; --font: "IBM Plex Sans", "PingFang SC", "Noto Sans SC", sans-serif;
  --mono: "IBM Plex Mono", "SF Mono", Menlo, monospace;
}}
* {{ box-sizing:border-box; }}
body {{
  margin:0; font-family:var(--font); background:
    radial-gradient(1200px 600px at 10% -10%, #1c3a34 0%, transparent 55%),
    radial-gradient(900px 500px at 100% 0%, #243044 0%, transparent 50%),
    var(--bg);
  color:var(--text); line-height:1.55;
}}
a {{ color:var(--accent); text-decoration:none; }}
a:hover {{ text-decoration:underline; }}
.layout {{ display:grid; grid-template-columns:260px 1fr; min-height:100vh; }}
nav {{
  position:sticky; top:0; height:100vh; overflow:auto; padding:24px 16px;
  border-right:1px solid var(--line); background:rgba(15,20,25,.92); backdrop-filter:blur(8px);
}}
nav h1 {{ font-size:18px; margin:0 0 4px; letter-spacing:.02em; }}
nav .sub {{ color:var(--muted); font-size:12px; margin-bottom:18px; }}
nav a {{
  display:flex; justify-content:space-between; align-items:center;
  padding:8px 10px; border-radius:8px; color:var(--text); margin-bottom:4px;
}}
nav a:hover {{ background:var(--panel); text-decoration:none; }}
nav small {{ color:var(--muted); }}
main {{ padding:32px 40px 80px; max-width:980px; }}
.hero {{
  padding:28px 28px 22px; border:1px solid var(--line); border-radius:16px;
  background:linear-gradient(135deg, rgba(61,187,154,.12), rgba(26,34,44,.9));
  margin-bottom:28px;
}}
.hero h2 {{ margin:0 0 8px; font-size:28px; }}
.hero p {{ margin:6px 0; color:var(--muted); }}
.pipeline {{
  font-family:var(--mono); font-size:13px; color:var(--accent);
  padding:10px 12px; background:var(--code); border-radius:8px; margin-top:12px;
}}
.stats {{ display:flex; flex-wrap:wrap; gap:10px; margin-top:14px; }}
.stat {{
  background:var(--panel); border:1px solid var(--line); border-radius:10px;
  padding:10px 14px; min-width:120px;
}}
.stat b {{ display:block; font-size:20px; }}
.stat span {{ color:var(--muted); font-size:12px; }}
.module {{ margin:36px 0; }}
.module h2 {{
  font-size:22px; border-bottom:1px solid var(--line); padding-bottom:8px; margin-bottom:8px;
}}
.blurb {{ color:var(--muted); margin-top:0; }}
.fn {{
  background:var(--panel); border:1px solid var(--line); border-radius:14px;
  padding:18px 20px; margin:16px 0;
}}
.fn h3 {{ margin:0 0 4px; font-size:16px; font-family:var(--mono); }}
.fn h3 .zh {{ margin-left:8px; font-family:var(--font); font-weight:600; color:var(--accent); font-size:14px; }}
.fn h4 {{ margin:16px 0 6px; font-size:13px; color:var(--accent); text-transform:uppercase; letter-spacing:.06em; }}
.meta {{ color:var(--muted); font-size:12px; margin:0; }}
.badge {{
  font-family:var(--font); font-size:11px; padding:2px 8px; border-radius:999px;
  vertical-align:middle; margin-left:6px;
}}
.badge.active {{ background:rgba(61,187,154,.2); color:var(--ok); }}
.badge.deprecated {{ background:rgba(196,76,76,.2); color:#f0a0a0; }}
.badge.planned {{ background:rgba(201,131,58,.2); color:#e6b57a; }}
table.params {{ width:100%; border-collapse:collapse; font-size:13px; }}
table.params th, table.params td {{
  border:1px solid var(--line); padding:8px 10px; text-align:left;
}}
table.params th {{ background:var(--code); color:var(--muted); font-weight:600; }}
pre {{
  background:var(--code); border:1px solid var(--line); border-radius:10px;
  padding:12px 14px; overflow:auto; font-family:var(--mono); font-size:12.5px;
}}
.warn {{
  background:rgba(201,131,58,.12); border:1px solid rgba(201,131,58,.35);
  padding:10px 12px; border-radius:8px; margin:10px 0; font-size:13px;
}}
.index table {{ width:100%; border-collapse:collapse; font-size:13px; }}
.index td, .index th {{ border-bottom:1px solid var(--line); padding:8px; text-align:left; }}
.todo {{ color:var(--warn); }}
.search {{
  width:100%; padding:10px 12px; border-radius:8px; border:1px solid var(--line);
  background:var(--code); color:var(--text); margin-bottom:14px; font-family:var(--font);
}}
@media (max-width:900px) {{
  .layout {{ grid-template-columns:1fr; }}
  nav {{ position:relative; height:auto; }}
  main {{ padding:20px; }}
}}
</style>
</head>
<body>
<div class="layout">
<nav>
  <h1>子砚 SDK</h1>
  <div class="sub">触控函数说明 · 自动同步</div>
  <input class="search" id="q" placeholder="搜索函数 / 模块…" oninput="filterFns(this.value)"/>
  {nav_html}
  <p style="margin-top:20px;font-size:11px;color:var(--muted)">生成器：tools/ziyan_doc/generate_html.py<br/>catalog：api_catalog.json</p>
</nav>
<main>
  <div class="hero">
    <h2>子砚触控函数说明</h2>
    <p>通用自动化引擎 SDK。游戏仅为测试案例。</p>
    <p><strong>调用方式（兼容并存）：</strong>
      <code>Zy.Device.gameRect()</code> ·
      <code>Device.gameRect()</code> / <code>Device.gameArea()</code> ·
      <code>设备.游戏区域()</code>
    </p>
    <p>禁止复制/调用 TouchSprite；禁止固定物理坐标（请用设计坐标 / 比例 / 视觉命中）。</p>
    <div class="pipeline">{esc(catalog.get('pipeline') or 'Device→Screen→Coordinate→Vision→OCR→Touch→Verify→StateMachine')}</div>
    <div class="stats">
      <div class="stat"><b>{len(funcs)}</b><span>函数总数</span></div>
      <div class="stat"><b>{len(added)}</b><span>本次新增</span></div>
      <div class="stat"><b>{len(planned)}</b><span>待完善</span></div>
      <div class="stat"><b>{len(deprecated)}</b><span>已废弃</span></div>
      <div class="stat"><b>{esc(catalog.get('updated',''))}</b><span>文档更新</span></div>
    </div>
  </div>

  <section class="index" id="index">
    <h2>当前函数列表</h2>
    <table>
  <thead><tr><th>函数 / 中文名</th><th>模块</th><th>状态</th><th>说明</th></tr></thead>
      <tbody>{index_html}</tbody>
    </table>
  </section>

  <section id="sync">
    <h2>文档同步状态</h2>
    <ul>
      <li>扫描代码函数：{report.get('scanned',0)}</li>
      <li>目录条目：{report.get('catalog_after',0)}</li>
      <li>本次自动新增：{esc(added_s)}</li>
      <li>代码中缺失（需确认废弃）：{esc(missing_s)}</li>
      <li>待完善：{esc(planned_s)}</li>
    </ul>
    <p>维护规则：新增函数自动入 catalog；修改请写 changelog；废弃须填写替代与迁移。</p>
    <pre><code>python3 tools/ziyan_doc/generate_html.py</code></pre>
  </section>

  {body_html}
</main>
</div>
<script>
function filterFns(q) {{
  q = (q || '').toLowerCase();
  document.querySelectorAll('article.fn').forEach(el => {{
    const t = (el.innerText || '').toLowerCase();
    el.style.display = !q || t.includes(q) ? '' : 'none';
  }});
}}
</script>
</body>
</html>
"""


def seed_enrichment(catalog: dict) -> None:
    """手工增强关键 API 与待完善/废弃项（幂等覆盖摘要）。"""
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    enrich = {
        "Zy.Touch.tapDesign": {
            "summary": "按设计分辨率坐标点击（推荐）。",
            "purpose": "禁止脚本写死单机物理像素；经 Device→Screen→Coordinate 映射后触控。",
            "params": [
                {"name": "dx", "type": "number", "desc": "设计坐标系 X", "required": True, "default": None},
                {"name": "dy", "type": "number", "desc": "设计坐标系 Y", "required": True, "default": None},
                {"name": "hold_ms", "type": "number", "desc": "按住毫秒", "required": False, "default": 70},
            ],
            "returns": {"type": "boolean, number, number", "desc": "成功标志, 逻辑X, 逻辑Y"},
            "errors": ["未 begin/setDesign → 抛错", "管道未 Device.refresh/Screen.sync → 抛错"],
            "usage": "Zy.Touch.tapDesign(dx, dy [, hold_ms])",
            "example": "local ok, lx, ly = Zy.Touch.tapDesign(568, 320)\nif ok then\n  Zy.Log(string.format(\"hit %d,%d\", lx, ly))\nend",
            "principle": "Device画像 → Screen.sync → Coordinate.point(设计→逻辑) → 真实触控",
        },
        "Zy.Touch.tapRatio": {
            "summary": "按屏幕比例(0~1)点击。",
            "purpose": "跨分辨率相对定位主按钮/安全区。",
            "params": [
                {"name": "rx", "type": "number", "desc": "横向比例 0~1", "required": True, "default": None},
                {"name": "ry", "type": "number", "desc": "纵向比例 0~1", "required": True, "default": None},
                {"name": "hold_ms", "type": "number", "desc": "按住毫秒", "required": False, "default": 70},
            ],
            "returns": {"type": "boolean, number, number", "desc": "成功标志与逻辑坐标"},
            "errors": ["未走管道 → 抛错"],
            "usage": "Zy.Touch.tapRatio(rx, ry [, hold_ms])",
            "example": "Zy.Touch.tapRatio(0.5, 0.72)",
            "principle": "比例→设计或逻辑尺寸→Coordinate→Touch",
        },
        "Zy.Touch.tapHit": {
            "summary": "点击视觉/OCR 命中的逻辑坐标。",
            "purpose": "点来自识别结果，而非手写死坐标。",
            "params": [
                {"name": "lx", "type": "number", "desc": "逻辑 X（来自 Vision/OCR）", "required": True, "default": None},
                {"name": "ly", "type": "number", "desc": "逻辑 Y", "required": True, "default": None},
                {"name": "hold_ms", "type": "number", "desc": "按住毫秒", "required": False, "default": 70},
            ],
            "returns": {"type": "boolean, number, number", "desc": "成功标志与坐标"},
            "errors": ["lx/ly 非法 → false"],
            "usage": "Zy.Touch.tapHit(lx, ly [, hold_ms])",
            "example": "local fx, fy = Zy.OCR.find(\"登录\", 0, 0, 1136, 640)\nif fx ~= -1 then Zy.Touch.tapHit(fx, fy) end",
            "principle": "Vision/OCR 命中点 → Screen.sync → Touch",
        },
        "Zy.Touch.tap": {
            "summary": "【已废弃/禁止】裸坐标点击。",
            "purpose": "防止固定物理坐标绕过同步层。",
            "status": "deprecated",
            "deprecated_reason": "固定物理/逻辑裸坐标会破坏跨设备适配。",
            "replacement": "Zy.Touch.tapDesign / Zy.Touch.tapRatio / Zy.Touch.tapHit",
            "migration": "将 Zy.Touch.tap(x,y) 改为 Zy.Touch.tapDesign(dx,dy)（需 Script.begin 设定设计分辨率）。",
            "params": [
                {"name": "x", "type": "number", "desc": "禁止使用", "required": True, "default": None},
                {"name": "y", "type": "number", "desc": "禁止使用", "required": True, "default": None},
            ],
            "returns": {"type": "error", "desc": "调用即抛错"},
            "errors": ["任何调用 → error: Zy.Touch.tap forbidden"],
            "usage": "-- 禁止\n-- Zy.Touch.tap(568, 320)",
            "example": "-- 错误示例（会抛错）\n-- local result = Zy.Touch.tap(568, 320)\n-- 正确：\nlocal result = Zy.Touch.tapDesign(568, 320)\nif result then Zy.Log(\"点击成功\") else Zy.Log(\"点击失败\") end",
            "principle": "刻意拦截，引导走 Coordinate 管道",
        },
        "Zy.Script.begin": {
            "summary": "开启脚本会话：Device.refresh → Screen.sync → Coordinate.setDesign。",
            "purpose": "强制管道前置；写入会话变量 bid/design/dpi。",
            "params": [
                {"name": "opts", "type": "table", "desc": "{bid, design_w, design_h, orient}", "required": True, "default": None},
            ],
            "returns": {"type": "table", "desc": "全局 Zy"},
            "errors": ["缺 design_w/h → 抛错"],
            "usage": "Zy.Script.begin({bid=..., design_w=1136, design_h=640, orient=1})",
            "example": "Zy.Script.begin({\n  bid = \"com.example.app\",\n  design_w = 1136, design_h = 640, orient = 1,\n})\nZy.Log(Zy.Script.get(\"device_model\"))",
            "principle": "Device→Screen→Coordinate 初始化 + 变量管理",
        },
        "Zy.Script.act": {
            "summary": "在 Verify 包裹下执行一次动作（脚本核心）。",
            "purpose": "禁止无验证点击；ctx 仅提供 tapDesign/tapRatio/tapHit。",
            "params": [
                {"name": "label", "type": "string", "desc": "动作标签", "required": True, "default": None},
                {"name": "fn", "type": "function", "desc": "function(ctx)", "required": True, "default": None},
                {"name": "wait_ms", "type": "number", "desc": "验证等待", "required": False, "default": 1200},
            ],
            "returns": {"type": "boolean, table, string", "desc": "ok, after, reason"},
            "errors": ["相位未推进 → ok=false"],
            "usage": "Zy.Script.act(label, fn [, wait_ms])",
            "example": "local ok, after, reason = Zy.Script.act(\"tap_cta\", function(ctx)\n  ctx.tapDesign(568, 320)\nend, 1200)\nif not ok then Zy.Script.recover({reason=reason, frame=after}) end",
            "principle": "Verify.act + Case 记录 + 变量 last_*",
        },
        "Zy.Script.set": {
            "summary": "设置脚本变量。",
            "purpose": "任务间状态共享，替代全局散落变量。",
            "params": [
                {"name": "key", "type": "string", "desc": "变量名", "required": True, "default": None},
                {"name": "value", "type": "any", "desc": "值", "required": True, "default": None},
            ],
            "returns": {"type": "any", "desc": "写入的 value"},
            "errors": [],
            "usage": "Zy.Script.set(key, value)",
            "example": "Zy.Script.set(\"phase\", \"login\")",
            "principle": "会话内 _vars 表",
        },
        "Zy.Script.get": {
            "summary": "读取脚本变量。",
            "purpose": "条件判断与任务流读取状态。",
            "params": [
                {"name": "key", "type": "string", "desc": "变量名", "required": True, "default": None},
                {"name": "default", "type": "any", "desc": "缺省值", "required": False, "default": None},
            ],
            "returns": {"type": "any", "desc": "变量值或 default"},
            "errors": [],
            "usage": "Zy.Script.get(key [, default])",
            "example": "local n = Zy.Script.get(\"retry\", 0)",
            "principle": "读 _vars",
        },
        "Zy.Script.when": {
            "summary": "条件成立时执行动作（可选 Verify）。",
            "purpose": "脚本条件分支。",
            "params": [
                {"name": "pred", "type": "function|boolean", "desc": "条件", "required": True, "default": None},
                {"name": "fn", "type": "function", "desc": "动作", "required": True, "default": None},
                {"name": "label", "type": "string", "desc": "若提供则走 act 验证", "required": False, "default": None},
                {"name": "wait_ms", "type": "number", "desc": "验证等待", "required": False, "default": 1200},
            ],
            "returns": {"type": "boolean [, ...]", "desc": "是否执行 / act 结果"},
            "errors": [],
            "usage": "Zy.Script.when(pred, fn [, label, wait_ms])",
            "example": "Zy.Script.when(function(ctx) return ctx.phase()==\"login\" end,\n  function(ctx) ctx.tapRatio(0.5,0.7) end, \"login_cta\", 1000)",
            "principle": "pred → optional Verify.act",
        },
        "Zy.Script.loop": {
            "summary": "有限次循环；body 返回 false 提前结束。",
            "purpose": "可控循环，禁止死循环刷点击。",
            "params": [
                {"name": "max_times", "type": "number", "desc": "最大次数", "required": True, "default": 1},
                {"name": "body", "type": "function", "desc": "function(i, ctx)", "required": True, "default": None},
            ],
            "returns": {"type": "number", "desc": "实际执行次数"},
            "errors": [],
            "usage": "Zy.Script.loop(max_times, body)",
            "example": "Zy.Script.loop(5, function(i, ctx)\n  local ok, fr = Zy.Script.tick({handlers=H})\n  if fr.phase==\"running\" then return false end\nend)",
            "principle": "for i=1..max；变量 loop_i",
        },
        "Zy.Script.untilPhase": {
            "summary": "轮询直到目标状态或超时。",
            "purpose": "等待加载/转场。",
            "params": [
                {"name": "target", "type": "string", "desc": "目标相位", "required": True, "default": "running"},
                {"name": "timeout_ms", "type": "number", "desc": "超时", "required": False, "default": 15000},
                {"name": "interval_ms", "type": "number", "desc": "间隔", "required": False, "default": 800},
            ],
            "returns": {"type": "boolean, string", "desc": "是否到达, 最终相位"},
            "errors": [],
            "usage": "Zy.Script.untilPhase(target [, timeout_ms, interval_ms])",
            "example": "local ok, st = Zy.Script.untilPhase(\"running\", 10000, 500)",
            "principle": "Screen.sync + Game.phase 轮询",
        },
        "Zy.Script.tick": {
            "summary": "标准一轮：分析状态→建议→handler→Verify→失败则 recover。",
            "purpose": "脚本主循环单步。",
            "params": [
                {"name": "opts", "type": "table", "desc": "{handlers, on_tick, wait_ms}", "required": False, "default": None},
            ],
            "returns": {"type": "boolean, table, string", "desc": "ok, frame, reason"},
            "errors": ["no_handler"],
            "usage": "Zy.Script.tick({handlers={login=fn, default=fn}})",
            "example": "Zy.Script.tick({\n  handlers = {\n    login = function(ctx) ctx.tapRatio(0.64, 0.72) end,\n    running = function(ctx) Zy.Script.set(\"done\", true) end,\n  }\n})",
            "principle": "analyze → suggest → act → recover?",
        },
        "Zy.Script.recover": {
            "summary": "异常恢复：诊断报告 + resync / relaunch。",
            "purpose": "失败后自动归因并尝试恢复管道。",
            "params": [
                {"name": "info", "type": "table", "desc": "{reason, frame, phase, policy=resync|relaunch}", "required": False, "default": None},
            ],
            "returns": {"type": "boolean", "desc": "已执行恢复"},
            "errors": [],
            "usage": "Zy.Script.recover({reason=..., frame=..., policy=\"resync\"})",
            "example": "Zy.Script.recover({reason=\"still_login\", frame=after, policy=\"resync\"})",
            "principle": "Diagnose/FailReport → App.close/launch? → Screen.sync",
        },
        "Zy.Script.defineTask": {
            "summary": "注册命名任务。",
            "purpose": "任务流程管理。",
            "params": [
                {"name": "name", "type": "string", "desc": "任务名", "required": True, "default": None},
                {"name": "fn", "type": "function", "desc": "任务函数", "required": True, "default": None},
            ],
            "returns": {"type": "nil", "desc": ""},
            "errors": [],
            "usage": "Zy.Script.defineTask(name, fn)",
            "example": "Zy.Script.defineTask(\"open\", function()\n  return Zy.App.launch(Zy.Script.get(\"bid\"))\nend)",
            "principle": "_tasks 注册表",
        },
        "Zy.Script.runTasks": {
            "summary": "按序执行任务列表，失败即停。",
            "purpose": "编排多步骤自动化。",
            "params": [
                {"name": "names", "type": "table", "desc": "任务名数组", "required": True, "default": None},
            ],
            "returns": {"type": "table", "desc": "[{name, ok, err}, ...]"},
            "errors": [],
            "usage": "Zy.Script.runTasks({\"a\",\"b\",\"c\"})",
            "example": "local rs = Zy.Script.runTasks({\"register\",\"validate\",\"summary\"})",
            "principle": "顺序 runTask",
        },
        "Zy.Script.run": {
            "summary": "运行 Media/ZiYan/scripts 下相对路径脚本。",
            "purpose": "加载用户脚本文件。",
            "params": [
                {"name": "rel", "type": "string", "desc": "相对或绝对路径", "required": True, "default": None},
            ],
            "returns": {"type": "any", "desc": "dofile 返回值"},
            "errors": ["文件不存在 → Lua 错误"],
            "usage": "Zy.Script.run(\"templates/01_basic_automation.lua\")",
            "example": "Zy.Script.set(\"bid\", \"com.example.app\")\nZy.Script.set(\"design_w\", 1136)\nZy.Script.set(\"design_h\", 640)\nZy.Script.run(\"templates/01_basic_automation.lua\")\nmain()",
            "principle": "scriptsDir() + dofile",
        },
        "Zy.Script.stepState": {
            "summary": "委托 StateMachine.step 执行一步。",
            "purpose": "状态切换与验证绑定。",
            "params": [
                {"name": "handlers", "type": "table", "desc": "相位→函数", "required": True, "default": None},
                {"name": "wait_ms", "type": "number", "desc": "等待", "required": False, "default": 1200},
            ],
            "returns": {"type": "boolean, string, string, string", "desc": "同 StateMachine.step"},
            "errors": ["repeat_blocked"],
            "usage": "Zy.Script.stepState(handlers [, wait_ms])",
            "example": "Zy.Script.stepState({ login = function(bid, st) Zy.Touch.tapRatio(0.5,0.7) end })",
            "principle": "StateMachine.step",
        },
        "Zy.AI.collect": {
            "summary": "采集 AI 生成输入：设备/屏幕/截图/状态/视觉启发/历史。",
            "purpose": "为 plan/generate 提供证据，禁止凭空写死坐标。",
            "params": [
                {"name": "bid", "type": "string", "desc": "目标 Bundle", "required": False, "default": "上下文"},
                {"name": "opts", "type": "table", "desc": "{words, wait_ms, orient}", "required": False, "default": None},
            ],
            "returns": {"type": "table", "desc": "ctx {device,screen,phase,vision,shot,history}"},
            "errors": [],
            "usage": "local ctx = Zy.AI.collect(bid, opts)",
            "example": "local ctx = Zy.AI.collect(\"com.example.app\")\nZy.Log(ctx.phase)",
            "principle": "Device+App+Screen+Game+Vision → 上下文",
        },
        "Zy.AI.plan": {
            "summary": "根据目标与上下文建立状态模型并选择 Zy 函数。",
            "purpose": "决定用哪些模块、点击用比例而非物理像素。",
            "params": [
                {"name": "goal", "type": "string", "desc": "任务目标", "required": True, "default": None},
                {"name": "ctx", "type": "table", "desc": "collect 结果", "required": True, "default": None},
                {"name": "opts", "type": "table", "desc": "{design_w,design_h,tune}", "required": False, "default": None},
            ],
            "returns": {"type": "table", "desc": "plan {funcs,steps,action,phase}"},
            "errors": [],
            "usage": "local plan = Zy.AI.plan(goal, ctx, opts)",
            "example": "local plan = Zy.AI.plan(\"advance_ui\", ctx, {design_w=1136, design_h=640})",
            "principle": "相位启发式 + Vision 比例 + 函数清单",
        },
        "Zy.AI.generate": {
            "summary": "将 plan 编译为仅含 Zy.* 的 Lua 脚本源码。",
            "purpose": "自动生成初始化/同步/状态/视觉/点击/任务/恢复代码。",
            "params": [
                {"name": "plan", "type": "table", "desc": "plan 对象", "required": True, "default": None},
                {"name": "opts", "type": "table", "desc": "{max_loop}", "required": False, "default": None},
            ],
            "returns": {"type": "string", "desc": "Lua 源码"},
            "errors": ["检测到固定坐标 tap 模式 → 抛错拒绝"],
            "usage": "local src = Zy.AI.generate(plan)",
            "example": "local src = Zy.AI.generate(plan)\nlocal path = Zy.AI.save(src, {goal=\"advance_ui\", bid=BID, plan=plan})",
            "principle": "模板汇编 + 静态闸门禁 Touch.tap(裸坐标)",
        },
        "Zy.AI.save": {
            "summary": "保存生成脚本到 scripts/generated/ 并写 AI_GEN_DB。",
            "purpose": "落盘可运行脚本与生成记录。",
            "params": [
                {"name": "source", "type": "string", "desc": "源码", "required": True, "default": None},
                {"name": "meta", "type": "table", "desc": "{goal,bid,plan,name,iter}", "required": False, "default": None},
            ],
            "returns": {"type": "string", "desc": "文件路径"},
            "errors": [],
            "usage": "Zy.AI.save(source, meta)",
            "example": "local path = Zy.AI.save(src, {goal=\"advance_ui\", bid=BID})",
            "principle": "File.write + jsonl 记录",
        },
        "Zy.AI.test": {
            "summary": "真机执行生成脚本并记录结果。",
            "purpose": "验证生成代码可运行且只走 SDK。",
            "params": [
                {"name": "path_or_src", "type": "string", "desc": "路径或源码", "required": True, "default": None},
                {"name": "opts", "type": "table", "desc": "{goal,bid,iter}", "required": False, "default": None},
            ],
            "returns": {"type": "boolean, table", "desc": "是否跑通, detail"},
            "errors": ["加载失败 → ok=false"],
            "usage": "local ok, detail = Zy.AI.test(path, opts)",
            "example": "local ok, d = Zy.AI.test(path, {bid=BID, goal=\"advance_ui\"})",
            "principle": "dofile → main → Case/AI 记录",
        },
        "Zy.AI.optimize": {
            "summary": "根据失败原因调整 plan（比例微调/重开）。",
            "purpose": "自动优化闭环中的修改步骤。",
            "params": [
                {"name": "plan", "type": "table", "desc": "原计划", "required": True, "default": None},
                {"name": "fail_info", "type": "table", "desc": "{reason,ctx,iter}", "required": False, "default": None},
            ],
            "returns": {"type": "table, table", "desc": "new_plan, tune"},
            "errors": [],
            "usage": "local plan2, tune = Zy.AI.optimize(plan, fail_info)",
            "example": "local p2 = Zy.AI.optimize(plan, {reason=\"still_login\", ctx=ctx})",
            "principle": "失败归因 → tune.shift → 重 plan",
        },
        "Zy.AI.loop": {
            "summary": "完整闭环：collect→plan→generate→test→optimize→再生成。",
            "purpose": "自主生成并迭代优秀方案。",
            "params": [
                {"name": "goal", "type": "string", "desc": "目标任务", "required": True, "default": None},
                {"name": "opts", "type": "table", "desc": "{bid,design_w,design_h,max_iter,require_running}", "required": True, "default": None},
            ],
            "returns": {"type": "table", "desc": "best {ok,path,phase,iter}"},
            "errors": ["缺 bid/design → assert"],
            "usage": "local best = Zy.AI.loop(goal, opts)",
            "example": "local best = Zy.AI.loop(\"advance_ui\", {\n  bid = \"com.example.app\",\n  design_w = 1136, design_h = 640,\n  max_iter = 2,\n})",
            "principle": "生成→执行→验证→优化→保存 ai_best.lua",
        },
        "Zy.AI.record": {
            "summary": "写入 AI 生成流水：时间/目标/函数/版本/设备/结果。",
            "purpose": "可追溯优化记录。",
            "params": [
                {"name": "row", "type": "table", "desc": "记录字段", "required": True, "default": None},
            ],
            "returns": {"type": "string", "desc": "jsonl 行"},
            "errors": [],
            "usage": "Zy.AI.record(row)",
            "example": "Zy.AI.record({goal=\"advance_ui\", ok=true, path=path, event=\"save\"})",
            "principle": "AI_GEN_DB.jsonl + Case",
        },
        "Zy.AI.pathDB": {
            "summary": "返回 AI_GEN_DB.jsonl 路径。",
            "purpose": "主机拉取生成记录。",
            "params": [],
            "returns": {"type": "string", "desc": "路径"},
            "errors": [],
            "usage": "Zy.AI.pathDB()",
            "example": "Zy.Log(Zy.AI.pathDB())",
            "principle": "Media/ZiYan/scripts/generated/AI_GEN_DB.jsonl",
        },
        "Zy.Engine.validate": {
            "summary": "对任意 Bundle 跑通用能力验证链。",
            "purpose": "验证设备/App/屏幕/分类/OCR/验证/状态机，非游戏专用脚本。",
            "params": [
                {"name": "opts", "type": "table", "desc": "{bid, design_w, design_h, orient, target_state?}", "required": True, "default": None},
            ],
            "returns": {"type": "table", "desc": "report {ok, steps, bid, pipeline}"},
            "errors": ["缺 bid/design → assert"],
            "usage": "Zy.Engine.validate({bid=..., design_w=..., design_h=...})",
            "example": "local report = Zy.Engine.validate({\n  bid = \"com.example.app\",\n  design_w = 1136, design_h = 640,\n})",
            "principle": "完整管道编排 + Case 落盘",
        },
        "Zy.App.launch": {
            "summary": "启动应用并尽量等到前台。",
            "purpose": "App 抽象层统一开应用入口。",
            "params": [
                {"name": "bid", "type": "string", "desc": "Bundle ID", "required": True, "default": None},
                {"name": "wait_ms", "type": "number", "desc": "等待毫秒", "required": False, "default": 2500},
            ],
            "returns": {"type": "boolean, string", "desc": "是否发起成功, 当前前台"},
            "errors": ["bid 空 → false"],
            "usage": "Zy.App.launch(bid [, wait_ms])",
            "example": "local ok, front = Zy.App.launch(\"com.example.app\", 3000)",
            "principle": "appRun IPC → waitFrontApp",
        },
        "Zy.Device.refresh": {
            "summary": "刷新设备画像（分辨率/DPI/游戏区等）。",
            "purpose": "所有后续 Screen/Coordinate 依赖最新 Device Model。",
            "params": [],
            "returns": {"type": "table", "desc": "设备 profile"},
            "errors": [],
            "usage": "Zy.Device.refresh()",
            "example": "local p = Zy.Device.refresh()\nZy.Log(p.model)",
            "principle": "读取 native/orient → 构建 profile → 标记管道 device_ok",
        },
        "Zy.Screen.sync": {
            "summary": "屏幕同步（必须先于找色/OCR/点击）。",
            "purpose": "对齐方向、Bundle、逻辑屏映射。",
            "params": [
                {"name": "orient", "type": "number", "desc": "方向 0/1", "required": False, "default": 1},
                {"name": "bid", "type": "string", "desc": "目标 Bundle", "required": False, "default": "上下文 bid"},
            ],
            "returns": {"type": "boolean", "desc": "是否同步成功"},
            "errors": ["未 Device.refresh → 抛错"],
            "usage": "Zy.Screen.sync(orient, bid)",
            "example": "Zy.Screen.sync(1, \"com.example.app\")",
            "principle": "screenSync / syncGameScreen + 标记 synced",
        },
        "Zy.Coordinate.setDesign": {
            "summary": "设定设计分辨率（脚本必调）。",
            "purpose": "后续 point/tapDesign 的基准。",
            "params": [
                {"name": "w", "type": "number", "desc": "设计宽", "required": True, "default": None},
                {"name": "h", "type": "number", "desc": "设计高", "required": True, "default": None},
            ],
            "returns": {"type": "boolean [, string]", "desc": "是否设定成功"},
            "errors": ["非法宽高 → false"],
            "usage": "Zy.Coordinate.setDesign(w, h)",
            "example": "Zy.Coordinate.setDesign(1136, 640)",
            "principle": "写入会话上下文 design_w/h",
        },
        "Zy.Verify.act": {
            "summary": "执行动作并验证界面是否变化。",
            "purpose": "禁止点击后默认成功；login 下钮变暗不算离开登录。",
            "params": [
                {"name": "label", "type": "string", "desc": "标签", "required": True, "default": None},
                {"name": "act_fn", "type": "function", "desc": "触控闭包", "required": True, "default": None},
                {"name": "wait_ms", "type": "number", "desc": "等待", "required": False, "default": 1200},
            ],
            "returns": {"type": "boolean, table, string", "desc": "ok, after, reason"},
            "errors": ["still_login / no_change → ok=false 并写 FAIL_REPORT"],
            "usage": "Zy.Verify.act(label, act_fn [, wait_ms])",
            "example": "local ok, after, reason = Zy.Verify.act(\"tap\", function()\n  Zy.Touch.tapDesign(100, 100)\nend)",
            "principle": "指纹前 → 动作 → 等待 → 指纹后 → changed",
        },
        "Zy.Game.classify": {
            "summary": "通用界面状态分类（不绑游戏名）。",
            "purpose": "boot/loading/login/menu/role/running/error。",
            "params": [
                {"name": "bid", "type": "string", "desc": "Bundle", "required": False, "default": "上下文"},
                {"name": "opts", "type": "table", "desc": "可选设计分辨率覆盖", "required": False, "default": None},
            ],
            "returns": {"type": "string, table", "desc": "状态, 细节{via,word,...}"},
            "errors": [],
            "usage": "local st, detail = Zy.Game.classify(bid)",
            "example": "local st, d = Zy.Game.classify()\nZy.Log(st .. \" via=\" .. tostring(d.via))",
            "principle": "App窗口 → Vision词表 → 亮色控件启发式",
        },
        "Zy.Log": {
            "summary": "输出日志（toast + print）。",
            "purpose": "脚本调试与文档示例统一入口。",
            "status": "active",
            "params": [
                {"name": "msg", "type": "any", "desc": "日志内容", "required": True, "default": None},
                {"name": "ms", "type": "number", "desc": "toast 时长", "required": False, "default": 1200},
            ],
            "returns": {"type": "nil", "desc": "无返回"},
            "errors": [],
            "usage": "Zy.Log(msg [, ms])",
            "example": "Zy.Log(\"点击成功\")",
            "principle": "print + toast",
            "module": "Log",
            "name": "Zy.Log",
            "id": "Zy.Log",
            "updated": now,
        },
        "Zy.Touch.swipe": {
            "summary": "比例滑动（swipeRatio 短别名）。",
            "purpose": "列表滚动、手势导航；禁止固定物理坐标。",
            "status": "active",
            "params": [
                {"name": "rx1", "type": "number", "desc": "起点比例X 0~1", "required": True, "default": None},
                {"name": "ry1", "type": "number", "desc": "起点比例Y 0~1", "required": True, "default": None},
                {"name": "rx2", "type": "number", "desc": "终点比例X 0~1", "required": True, "default": None},
                {"name": "ry2", "type": "number", "desc": "终点比例Y 0~1", "required": True, "default": None},
                {"name": "steps", "type": "number", "desc": "插值步数", "required": False, "default": 12},
                {"name": "step_ms", "type": "number", "desc": "每步间隔毫秒", "required": False, "default": 16},
            ],
            "returns": {"type": "boolean, ...", "desc": "是否成功及起止逻辑点"},
            "errors": [],
            "usage": "Zy.Touch.swipe(rx1,ry1,rx2,ry2 [, steps, step_ms])",
            "example": "-- 等价于 swipeRatio\nTouch.swipe(0.5, 0.75, 0.5, 0.35)\n触控.滑动(0.5, 0.75, 0.5, 0.35)",
            "principle": "同 Zy.Touch.swipeRatio → Coordinate.ratio → touchDown/Move/Up",
            "module": "Touch",
            "name": "Zy.Touch.swipe",
            "id": "Zy.Touch.swipe",
            "zh_name": "滑动",
            "zh_desc": "比例滑动（swipeRatio 短别名）",
            "updated": now,
        },
        "Zy.Touch.longPress": {
            "summary": "设计坐标长按。",
            "purpose": "触发长按菜单等。",
            "status": "active",
            "params": [
                {"name": "dx", "type": "number", "desc": "设计X", "required": True, "default": None},
                {"name": "dy", "type": "number", "desc": "设计Y", "required": True, "default": None},
                {"name": "hold_ms", "type": "number", "desc": "按住时长", "required": False, "default": 800},
            ],
            "returns": {"type": "boolean, number, number", "desc": "是否成功, 逻辑x, 逻辑y"},
            "errors": [],
            "usage": "Zy.Touch.longPress(dx, dy [, hold_ms])",
            "example": "Touch.longPress(568, 320, 1000)\n触控.长按(568, 320, 1000)",
            "principle": "tapDesign 延长 hold_ms",
            "module": "Touch",
            "name": "Zy.Touch.longPress",
            "id": "Zy.Touch.longPress",
            "zh_name": "长按",
            "zh_desc": "设计坐标长按",
            "updated": now,
        },
    }

    # Vision facade entries
    for name, summary in [
        ("findColor", "找色（转调 Image）"),
        ("findImage", "找图（转调 Image）"),
        ("colorAt", "设计点取色"),
        ("ocr", "区域 OCR"),
        ("findText", "找字"),
        ("analyze", "词表视觉分析"),
    ]:
        fq = f"Zy.Vision.{name}"
        enrich[fq] = {
            "summary": summary,
            "purpose": "Vision 聚合门面，内部转 Image/OCR。",
            "module": "Vision",
            "name": fq,
            "id": fq,
            "status": "active",
            "params": [],
            "returns": {"type": "any", "desc": "同底层 Image/OCR"},
            "errors": [],
            "usage": fq + "(...)",
            "example": "-- 见 Zy.Image / Zy.OCR\n-- {}(...)".format(fq),
            "principle": "Zy.Vision → Image|OCR → Coordinate",
            "updated": now,
        }

    funcs = catalog.setdefault("functions", {})
    for fq, data in enrich.items():
        cur = funcs.get(fq) or {"id": fq, "name": data.get("name", fq), "module": data.get("module", fq.split(".")[1]), "changelog": []}
        for k, v in data.items():
            cur[k] = v
        cur.setdefault("updated", now)
        cur.setdefault("changelog", [])
        funcs[fq] = cur


def apply_naming_from_lua(catalog: dict) -> None:
    """从 lua/modules/_naming.lua 抽取中文名/别名写入 catalog。"""
    naming_path = MOD_DIR / "_naming.lua"
    if not naming_path.exists():
        return
    text = naming_path.read_text(encoding="utf-8")
    # MODULES
    mods = {}
    mm = re.search(r"M\.MODULES\s*=\s*\{(.*?)\n\}", text, re.S)
    if mm:
        for k, v in re.findall(r'(\w+)\s*=\s*"([^"]+)"', mm.group(1)):
            mods[k] = v
    # FUNCS
    funcs_map = {}
    fm = re.search(r"M\.FUNCS\s*=\s*\{(.*?)\n\}", text, re.S)
    if fm:
        block = fm.group(1)
        for m in re.finditer(
            r'\["([^"]+)"\]\s*=\s*\{([^}]*)\}',
            block,
        ):
            key, body = m.group(1), m.group(2)
            short = re.search(r'short\s*=\s*"([^"]+)"', body)
            zh = re.search(r'zh\s*=\s*"([^"]+)"', body)
            zh_desc = re.search(r'zh_desc\s*=\s*"([^"]+)"', body)
            funcs_map[key] = {
                "short": short.group(1) if short else None,
                "zh": zh.group(1) if zh else None,
                "zh_desc": zh_desc.group(1) if zh_desc else None,
            }

    catalog["modules_zh"] = mods
    funcs = catalog.setdefault("functions", {})
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    for key, meta in funcs_map.items():
        mod, name = key.split(".", 1)
        fq = f"Zy.{mod}.{name}"
        ent = funcs.get(fq)
        if not ent:
            # may be new; skip if not in catalog yet
            continue
        if meta.get("zh"):
            ent["zh_name"] = meta["zh"]
        if meta.get("zh_desc"):
            ent["zh_desc"] = meta["zh_desc"]
            if not ent.get("summary") or ent["summary"].startswith(mod + "."):
                ent["summary"] = meta["zh_desc"]
        aliases = []
        zh_mod = mods.get(mod, mod)
        aliases.append(f"{mod}.{name}")
        if meta.get("short"):
            aliases.append(f"{mod}.{meta['short']}")
            aliases.append(f"Zy.{mod}.{meta['short']}")
        if meta.get("zh"):
            aliases.append(f"{zh_mod}.{meta['zh']}")
        ent["aliases"] = aliases
        # 简便调用示例
        prefer = meta.get("short") or name
        zh_call = f"{zh_mod}.{meta['zh']}()" if meta.get("zh") else ""
        ent["short_usage"] = f"{mod}.{prefer}()" + (f"  或  {zh_call}" if zh_call else "")
        # enrich example if still TODO / 待完善 / empty
        ex = str(ent.get("example") or "")
        if (not ex) or ("TODO" in ex) or ("待完善" in ex):
            ent["example"] = (
                f"-- 稳定写法\nlocal r = Zy.{mod}.{name}()\n"
                f"-- 短英文\nlocal r2 = {mod}.{prefer}()\n"
            )
            if meta.get("zh"):
                ent["example"] += f"-- 中文\nlocal r3 = {zh_mod}.{meta['zh']}()\n"
        ent["updated"] = now
        funcs[fq] = ent

    # dump naming json for tools
    out = Path(__file__).resolve().parent / "naming_map.json"
    out.write_text(
        json.dumps({"modules": mods, "functions": funcs_map}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    scanned = scan_modules()
    catalog = load_catalog()
    catalog["pipeline"] = "Device→Screen→Coordinate→Vision→OCR→Touch→Verify→StateMachine"
    catalog, report = merge(scanned, catalog)
    seed_enrichment(catalog)
    apply_naming_from_lua(catalog)
    # 阶段7.3：完整 SDK 文档字段
    try:
        from sdk_complete_docs import apply_complete_docs
        quality = apply_complete_docs(catalog)
        report["doc_quality"] = {
            "target_complete": quality.get("target_complete"),
            "target_total": quality.get("target_total"),
            "incomplete": len(quality.get("incomplete") or []),
        }
    except Exception as e:
        report["doc_quality_error"] = str(e)
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    html = render_html(catalog, report)
    HTML_OUT.write_text(html, encoding="utf-8")
    REPORT_OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"HTML → {HTML_OUT}")
    print(f"Catalog functions: {len(catalog['functions'])}")
    print(f"Added this run: {len(report['added'])}")
    print(f"Planned: {sum(1 for e in catalog['functions'].values() if e.get('status')=='planned')}")
    print(f"Deprecated: {sum(1 for e in catalog['functions'].values() if e.get('status')=='deprecated')}")
    dq = report.get("doc_quality") or {}
    if dq:
        print(f"Doc complete: {dq.get('target_complete')}/{dq.get('target_total')} incomplete={dq.get('incomplete')}")


if __name__ == "__main__":
    main()
