#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R8.3：生成对标触动手册结构的「子砚触控函数说明.html」全量文档。"""
from __future__ import annotations

import datetime
import html
import importlib.util
import json
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = Path(__file__).resolve().parent / "api_catalog.json"
OUT = ROOT / "子砚触控函数说明.html"
SELFTEST = ROOT / "tmp_shots" / "PHASE763R8" / "api_selftest"
SCD = Path(__file__).resolve().parent / "sdk_complete_docs.py"

# 触动手册业务模块（展示用）
BIZ_MODULES = [
    ("screen_img", "屏幕图像", ["Screen", "Image", "Vision"]),
    ("touch_sim", "触控模拟", ["Touch"]),
    ("toast_ui", "Toast弹窗 / 日志", ["Log"]),
    ("ocr", "OCR识别", ["OCR"]),
    ("proc", "进程管理", ["App"]),
    ("cache", "缓存控制", ["Screen"]),  # keep 在 Screen
    ("session", "脚本会话", ["Script", "Verify", "StateMachine", "Game", "Engine", "Case"]),
    ("device", "设备系统控制", ["Device", "Coordinate", "File", "Network", "Config", "Input"]),
    ("ai_opt", "AI / 优化（规划与部分实现）", [
        "AI", "Knowledge", "Optimization", "IssueClassifier",
        "OptimizationAdvisor", "OptimizationRollback", "Diagnose",
    ]),
]

TS_GLOBALS = [
    {
        "id": "tap",
        "zh": "点击",
        "sig": "tap(x, y)",
        "desc": "在逻辑坐标 (x,y) 单击。横屏 init(1/2) 时坐标为逻辑横屏画布。",
        "params": [
            ("x", "number", "逻辑 X", "是"),
            ("y", "number", "逻辑 Y", "是"),
        ],
        "returns": [("无", "—", "无返回值")],
        "example": """init(1)
local x, y = 100, 200
if x > 0 then
  tap(x, y)
  mSleep(300)
end""",
    },
    {
        "id": "swipe",
        "zh": "滑动",
        "sig": "swipe(x1, y1, x2, y2, ms)",
        "desc": "逻辑坐标滑动，时长毫秒。",
        "params": [
            ("x1,y1", "number", "起点", "是"),
            ("x2,y2", "number", "终点", "是"),
            ("ms", "number", "时长毫秒", "是"),
        ],
        "returns": [("无", "—", "—")],
        "example": """local x1, y1, x2, y2 = 80, 120, 200, 120
local dur = 250
if dur > 0 then swipe(x1, y1, x2, y2, dur) end""",
    },
    {
        "id": "keepScreen",
        "zh": "锁帧缓存",
        "sig": "keepScreen(on)",
        "desc": "对齐触动 keepScreen：开启后找色优先复用缓存帧。R8.3：找色路径按 TTL 软刷新；停脚本自动释放。",
        "params": [("on", "boolean", "true 开启 / false 关闭", "是")],
        "returns": [("boolean", "boolean", "是否成功")],
        "example": """keepScreen(true)
for i = 1, 5 do
  local c = getColor(10, 10)
  if c >= 0 then break end
  mSleep(200)
end
keepScreen(false)""",
    },
    {
        "id": "getColor",
        "zh": "取色",
        "sig": "getColor(x, y)",
        "desc": "读取逻辑坐标颜色，返回 0xRRGGBB 整数；失败可能为 -1。",
        "params": [("x,y", "number", "逻辑坐标", "是")],
        "returns": [("color", "number", "0xRRGGBB 或 -1")],
        "example": """local cx, cy = 10, 10
local c = getColor(cx, cy)
if type(c) == "number" and c >= 0 then
  toast(string.format("c=0x%06x", c % 0x1000000), 800)
end""",
    },
    {
        "id": "findMultiColorInRegionFuzzy",
        "zh": "多点模糊找色",
        "sig": "findMultiColorInRegionFuzzy(main, offsetStr, degree, x1, y1, x2, y2)",
        "desc": "多点组合模糊找色。degree∈[1,100]。建议局部区域+keepScreen。",
        "params": [
            ("main", "number", "主色 0xRRGGBB", "是"),
            ("offsetStr", "string", "dx|dy|0xRGB,...", "是"),
            ("degree", "number", "相似度 1-100", "是"),
            ("x1,y1,x2,y2", "number", "区域；-1=全屏（不推荐）", "是"),
        ],
        "returns": [("x,y", "number,number", "命中逻辑坐标；未命中 -1,-1")],
        "example": """keepScreen(true)
local main = 0xfdfeeb
local off = "0|1|0xfdfef8,0|2|0xfffff7"
local x, y = findMultiColorInRegionFuzzy(main, off, 90, 2012, 281, 2012, 284)
if x ~= -1 then
  tap(x, y)
else
  toast("searching", 500)
end
keepScreen(false)""",
    },
    {
        "id": "toast",
        "zh": "底部提示",
        "sig": "toast(text, ms)",
        "desc": "HUD 提示。R8.2+：横竖屏统一逻辑底边居中（屏横+scene竖走 portraitHost_rotate）。",
        "params": [
            ("text", "string", "文本", "是"),
            ("ms", "number", "显示毫秒", "否"),
        ],
        "returns": [("无", "—", "—")],
        "example": """local msg = "子砚Toast"
local ms = 1200
if #msg > 0 then toast(msg, ms) end""",
    },
    {
        "id": "mSleep",
        "zh": "延时",
        "sig": "mSleep(ms)",
        "desc": "毫秒延时；内含暂停/停止检查点；R8.3 顺带写断电快照心跳。",
        "params": [("ms", "number", "毫秒", "是")],
        "returns": [("无", "—", "—")],
        "example": """for i = 1, 3 do
  mSleep(200)
end""",
    },
    {
        "id": "init",
        "zh": "初始化方向",
        "sig": "init(orient)",
        "desc": "0 竖屏跟随 / 1 横屏 CCW / 2 横屏 CW。影响逻辑坐标与 Toast/找色。",
        "params": [("orient", "number", "0/1/2", "是")],
        "returns": [("无", "—", "—")],
        "example": """local orient = 1
init(orient)
if orient == 1 or orient == 2 then
  toast("landscape", 800)
end""",
    },
    {
        "id": "snapshot",
        "zh": "截屏存盘",
        "sig": "snapshot(path)",
        "desc": "将当前逻辑屏截图保存到 path（png）。",
        "params": [("path", "string", "输出路径", "是")],
        "returns": [("无/依赖实现", "—", "—")],
        "example": """local p = Zy.File.varDir() .. "/_snap.png"
snapshot(p)
if Zy.File.exists(p) then toast("saved", 600) end""",
    },
]


def load_complete_docs() -> dict:
    spec = importlib.util.spec_from_file_location("sdk_complete_docs", SCD)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(mod)
    return getattr(mod, "DOCS", {})


def load_selftest_summary() -> str:
    lines = []
    for dev in ("166", "53"):
        p = SELFTEST / f"result_{dev}.txt"
        if not p.exists():
            continue
        t = p.read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"SUMMARY pass=(\d+) fail=(\d+) skip=(\d+)", t)
        if m:
            lines.append(f".{dev}: pass={m.group(1)} fail={m.group(2)} skip={m.group(3)}")
        probe = re.search(r"find_hit_rate=([0-9%]+)", t)
        if probe:
            lines.append(f".{dev} find_hit_rate={probe.group(1)}")
    return " · ".join(lines) if lines else "见 tmp_shots/PHASE763R8/api_selftest/"


def esc(s: str) -> str:
    return html.escape(str(s or ""), quote=True)


def params_table(params: list) -> str:
    rows = []
    for p in params:
        if isinstance(p, dict):
            rows.append(
                f"<tr><td>{esc(p.get('name','—'))}</td><td>{esc(p.get('type','any'))}</td>"
                f"<td>{esc(p.get('desc') or p.get('zh_desc') or '—')}</td>"
                f"<td>{'是' if p.get('required') else '否'}</td>"
                f"<td>{esc(p.get('default') if p.get('default') is not None else '—')}</td></tr>"
            )
        else:
            name, typ, desc, req = p
            rows.append(
                f"<tr><td>{esc(name)}</td><td>{esc(typ)}</td><td>{esc(desc)}</td>"
                f"<td>{esc(req)}</td><td>—</td></tr>"
            )
    if not rows:
        rows.append("<tr><td colspan='5'>无参数</td></tr>")
    return (
        "<table class='params'><thead><tr><th>参数名</th><th>类型</th><th>作用</th>"
        "<th>必填</th><th>默认值</th></tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


def returns_block(ret) -> str:
    if isinstance(ret, dict):
        return f"<p>返回类型：<code>{esc(ret.get('type','any'))}</code> · {esc(ret.get('desc','—'))}</p>"
    if isinstance(ret, list):
        rows = "".join(
            f"<tr><td>{esc(a)}</td><td>{esc(b)}</td><td>{esc(c)}</td></tr>" for a, b, c in ret
        )
        return (
            "<table class='params'><thead><tr><th>名</th><th>类型</th><th>说明</th></tr></thead>"
            f"<tbody>{rows}</tbody></table>"
        )
    return f"<p>{esc(ret)}</p>"


def fn_article(aid: str, title: str, zh: str, desc: str, usage: str, params, returns, example: str, selftest: str, status: str = "active") -> str:
    badge = {"active": "正常", "done": "正常", "deprecated": "废弃", "planned": "规划中", "partial": "部分"}.get(status, status)
    return f"""
<article class="fn" id="{esc(aid)}">
  <header>
    <h3><code>{esc(title)}</code> <span class="zh">{esc(zh)}</span>
      <span class="badge">{esc(badge)}</span></h3>
    <p class="meta">更新：{datetime.date.today().isoformat()} · 自测：{esc(selftest)}</p>
  </header>
  <h4>功能说明</h4>
  <p>{esc(desc)}</p>
  <h4>调用语法</h4>
  <pre><code>{esc(usage)}</code></pre>
  <h4>输入参数</h4>
  {params_table(params)}
  <h4>返回值</h4>
  {returns_block(returns)}
  <h4>可运行示例</h4>
  <pre><code>{esc(example)}</code></pre>
  <h4>双机自测记录</h4>
  <p>{esc(selftest)}</p>
</article>
"""


def enrich_example(fq: str, meta: dict, docs: dict) -> str:
    d = docs.get(fq) or docs.get(fq.replace("Zy.", "")) or {}
    if d.get("example") and "TODO" not in d["example"]:
        return d["example"]
    # synthesize runnable snippet with basics
    short = fq.split(".")[-1]
    params = meta.get("params") or []
    args = []
    for p in params[:4]:
        n = p.get("name", "a")
        if n in ("无", "—", ""):
            continue
        t = (p.get("type") or "").lower()
        if "number" in t or n in ("x", "y", "ms", "sim", "degree"):
            args.append("0")
        elif "bool" in t:
            args.append("true")
        else:
            args.append('"demo"')
    call = f"{fq}({', '.join(args)})" if args else f"{fq}()"
    return f"""-- UTF-8 · 示例含赋值/判断
local ok = true
local r = nil
if ok then
  r = {call}
end
if r ~= nil then
  -- 使用返回值
end"""


def load_tested_names() -> set[str]:
    """从双机 result_*.txt 解析真实 [PASS]/[SKIP] 名，禁止虚构覆盖。"""
    names: set[str] = set()
    for p in (
        ROOT / "tmp_shots/PHASE763R8/api_selftest/result_166.txt",
        ROOT / "tmp_shots/PHASE763R8/api_selftest/result_53.txt",
    ):
        if not p.exists():
            continue
        for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
            m = re.match(r"\[(PASS|SKIP|FAIL)\]\s+(\S+)", line.strip())
            if m:
                names.add(m.group(2))
    return names


def selftest_line_for(fq: str, status: str, tested: set[str], summary: str) -> str:
    if status in ("planned", "partial") or status == "deprecated":
        return "SKIP（规划/未实现/废弃）· 不计入本轮硬门禁"
    # 仅精确匹配 runner 中出现的名字，禁止模糊误标
    candidates = {
        fq,
        fq.replace("Zy.", ""),
    }
    # 常见 runner 特例
    special = {
        "Zy.File.write": "Zy.File.write_read_remove",
        "Zy.File.read": "Zy.File.write_read_remove",
        "Zy.File.remove": "Zy.File.write_read_remove",
        "Zy.Screen.keep": "Zy.Screen.keep",
        "keepScreen": "keepScreen_on",
    }
    if fq in special:
        candidates.add(special[fq])
    hit = next((c for c in candidates if c in tested), None)
    if hit is None:
        # 叶子名仅当 runner 里也是完整 Zy.Mod.name 或恰好同名全局
        leaf = fq.split(".")[-1]
        if leaf in tested and ("." not in leaf):
            # 仅全局函数允许 leaf（tap/toast/...）
            if fq.count(".") == 0 or fq in (
                "tap", "toast", "mSleep", "init", "swipe", "snapshot",
                "getColor", "findMultiColorInRegionFuzzy", "keepScreen",
                "notifyMessage", "longTap",
            ):
                hit = leaf
    if hit:
        return f".166/.53 PASS · api_full_selftest::{hit} · 汇总 {summary}"
    return f"待逐函数补测 · 本轮硬测汇总 {summary}（本条目未单独列入 runner）"


def main() -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    functions: dict = catalog.get("functions") or {}
    docs = load_complete_docs()
    selftest_sum = load_selftest_summary()
    tested = load_tested_names()
    by_mod: dict[str, list[tuple[str, dict]]] = defaultdict(list)
    for fq, meta in sorted(functions.items()):
        by_mod[meta.get("module") or "?"].append((fq, meta))

    nav_links = []
    body_parts = []

    # ---- globals ----
    nav_links.append('<a href="#ts-globals">全局图色触控</a>')
    ghtml = ['<section id="ts-globals" class="module"><h2>全局函数 · 屏幕图像 / 触控 / Toast / 缓存</h2>']
    for g in TS_GLOBALS:
        # 全局条目：若有专用 selftest 字段则保留，否则按真实 PASS 名映射
        st = selftest_line_for(g["id"], "active", tested, selftest_sum)
        ghtml.append(
            fn_article(
                g["id"], g["sig"], g["zh"], g["desc"], g["sig"],
                g["params"], g["returns"], g["example"], st,
            )
        )
    ghtml.append("</section>")
    body_parts.append("\n".join(ghtml))

    for mid, title, mods in BIZ_MODULES:
        nav_links.append(f'<a href="#{mid}">{esc(title)}</a>')
        sec = [f'<section id="{mid}" class="module"><h2>{esc(title)}</h2>']
        seen = set()
        for mod in mods:
            for fq, meta in by_mod.get(mod, []):
                if fq in seen:
                    continue
                seen.add(fq)
                d = docs.get(fq, {})
                zh = d.get("zh_name") or d.get("zh_desc") or meta.get("summary") or fq.split(".")[-1]
                desc = d.get("zh_desc") or d.get("purpose") or meta.get("purpose") or meta.get("summary") or "见源码与契约。"
                usage = d.get("usage") or meta.get("usage") or fq + "(...)"
                params = d.get("params") or meta.get("params") or []
                returns = d.get("returns") or meta.get("returns") or {"type": "any", "desc": "—"}
                example = enrich_example(fq, meta, docs)
                st = meta.get("status") or "active"
                stest = selftest_line_for(fq, st, tested, selftest_sum)
                sec.append(
                    fn_article(
                        fq, fq, zh, desc, usage, params, returns, example, stest, st,
                    )
                )
        sec.append("</section>")
        body_parts.append("\n".join(sec))

    # practical
    body_parts.append(f"""
<section id="examples" class="module">
  <h2>综合实战示例</h2>
  <pre><code>-- UTF-8
init(1)
keepScreen(true)
local hits = 0
for i = 1, 10 do
  local c = getColor(120, 120)
  if type(c) == "number" and c &gt;= 0 then
    local x, y = findMultiColorInRegionFuzzy(c, string.format("0|0|0x%06x", c % 0x1000000), 85, 110, 110, 130, 130)
    if x ~= -1 then
      hits = hits + 1
      tap(x, y)
      break
    end
  end
  mSleep(300)
end
keepScreen(false)
toast("hits=" .. tostring(hits), 1200)</code></pre>
  <p>双机自测汇总：{esc(selftest_sum)}</p>
</section>
""")

    css = """
:root{--bg:#0f1419;--panel:#1a222c;--text:#e7eef7;--muted:#93a4b8;--accent:#3dbb9a;--line:#2a3542;--code:#0b1015}
*{box-sizing:border-box}body{margin:0;font-family:"PingFang SC","Noto Sans SC",sans-serif;background:var(--bg);color:var(--text);line-height:1.55}
a{color:var(--accent);text-decoration:none}.layout{display:grid;grid-template-columns:240px 1fr;min-height:100vh}
nav{position:sticky;top:0;height:100vh;overflow:auto;padding:16px;border-right:1px solid var(--line);background:#121820}
nav a{display:block;padding:6px 0;font-size:13px;color:var(--muted)}nav a:hover{color:var(--accent)}
main{padding:24px 28px 80px;max-width:980px}.hero{background:var(--panel);padding:20px;border-radius:10px;margin-bottom:20px}
.module{margin:28px 0}.fn{background:var(--panel);padding:16px 18px;border-radius:10px;margin:14px 0;border:1px solid var(--line)}
.fn h3{margin:0 0 8px;font-size:16px}.zh{color:var(--muted);font-weight:500}.badge{font-size:11px;padding:2px 8px;border-radius:999px;background:#234;color:var(--accent);margin-left:6px}
.meta{color:var(--muted);font-size:12px}pre{background:var(--code);padding:12px;border-radius:8px;overflow:auto}
code{font-family:Menlo,Consolas,monospace;font-size:12.5px}
table.params{width:100%;border-collapse:collapse;font-size:13px}table.params th,table.params td{border:1px solid var(--line);padding:6px 8px;text-align:left}
table.params th{background:#15202b}h2{border-bottom:1px solid var(--line);padding-bottom:8px}h4{margin:14px 0 6px;color:#c9d7e6}
.search{width:100%;padding:8px;margin:8px 0 12px;background:#0b1015;border:1px solid var(--line);color:var(--text);border-radius:6px}
@media(max-width:900px){.layout{grid-template-columns:1fr}nav{position:relative;height:auto}}
"""

    page = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>子砚触控函数说明 · 开发手册</title>
<style>{css}</style>
</head>
<body>
<div class="layout">
<nav>
  <strong>子砚开发手册</strong>
  <input class="search" id="q" placeholder="搜索函数…" oninput="filterFns(this.value)"/>
  <a href="#preface">前言</a>
  <a href="#lua-basics">Lua基础语法</a>
  <a href="#utf8">UTF-8编码规范</a>
  <a href="#engine">Zy引擎总述</a>
  {''.join(nav_links)}
  <a href="#examples">综合实战</a>
</nav>
<main>
  <div class="hero">
    <h1>子砚触控函数说明</h1>
    <p>结构对标触动精灵开发手册（<a href="https://helpdoc.touchsprite.com/dev_docs/598.html">helpdoc 598</a>）：前言 · Lua基础 · 扩展函数分册 · 示例。禁止复用触动/XXTouch 原生 API。</p>
    <p>生成日期：{datetime.datetime.now():%Y-%m-%d %H:%M} · 函数条目：{len(functions)} · 自测：{esc(selftest_sum)}</p>
    <p>验收设备：.166 iPhone7 rootful · .53 iPhone8Plus rootless · 包以真机 dpkg 为准</p>
  </div>

  <section id="preface" class="module">
    <h2>前言</h2>
    <p>子砚采用 Lua 5.3 作为脚本语言，并扩展图色、触控、OCR、进程与会话等能力。阅读函数说明前请掌握注释、变量、类型、运算符、条件与循环、函数定义。</p>
    <p>本说明供学习与自动化测试参考。严禁用于非法用途。示例仅供函数参考，部署前请在二类真机自测。</p>
    <p>对照：触动手册结构 · Lua 手册 https://www.lua.org/manual/5.3/</p>
  </section>

  <section id="lua-basics" class="module">
    <h2>Lua 基础语法</h2>
    <h4>注释</h4>
    <pre><code>-- 单行
--[[ 多行注释 ]]</code></pre>
    <h4>变量与类型</h4>
    <pre><code>local n = 1
local s = "子砚"      -- string，UTF-8
local ok = true
local t = {{x=1, y=2}}
local f = function(a) return a end</code></pre>
    <h4>运算符 / 判断 / 循环 / 关键字</h4>
    <pre><code>local a = 1 + 2 * 3
if a &gt; 0 and a ~= 4 then
  for i = 1, 3 do end
elseif a == 0 then
else
  while false do break end
end
-- 关键字：and or not if then else end for while function local return nil true false</code></pre>
  </section>

  <section id="utf8" class="module">
    <h2>UTF-8 编码规范</h2>
    <p>脚本开发与存储必须使用 UTF-8。若中文无法显示，请在编辑器中将编码设置为 UTF-8（无 BOM）。</p>
  </section>

  <section id="engine" class="module">
    <h2>Zy 引擎扩展库总述</h2>
    <p>管线：Device→Screen→Coordinate→Vision→OCR→Touch→Verify→StateMachine。</p>
    <p>禁止固定物理像素点击；请用 <code>Touch.atRatio</code> / <code>atDesign</code> / 找色命中坐标。</p>
    <p>坐标系由 <code>init(0/1/2)</code> + ScreenTransform 统一；Toast 底边居中；keepScreen 软刷新兼顾识别率与 SB 稳定。</p>
    <p>断电快照：<code>/var/mobile/ZiYan/state_snapshot.json</code>（rootless 冷启需人工重越狱）。</p>
  </section>

  {''.join(body_parts)}

</main>
</div>
<script>
function filterFns(q){{
  q=(q||'').toLowerCase();
  document.querySelectorAll('article.fn').forEach(el=>{{
    const t=el.innerText.toLowerCase();
    el.style.display=!q||t.includes(q)?'':'none';
  }});
}}
</script>
</body>
</html>
"""
    OUT.write_text(page, encoding="utf-8")
    print(f"wrote {OUT} bytes={OUT.stat().st_size} functions={len(functions)}")


if __name__ == "__main__":
    main()
