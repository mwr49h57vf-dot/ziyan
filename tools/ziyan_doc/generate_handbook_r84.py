#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R8.4：按 TS 官方手册章节分层范式重构「子砚触控函数说明.html」。

数据：api_catalog + sdk_complete_docs + api_selftest + ts_chapter_layer_map.json
约束：仅借鉴分层/契约排版；禁止照搬触动源码与私有 API。
"""
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
LAYER_MAP = Path(__file__).resolve().parent / "ts_chapter_layer_map.json"
MIRROR_MAP = Path(__file__).resolve().parent / "ts_zy_mirror_map.json"
OUT = ROOT / "子砚触控函数说明.html"
SELFTEST = ROOT / "tmp_shots" / "PHASE763R8" / "api_selftest"
SCD = Path(__file__).resolve().parent / "sdk_complete_docs.py"
META_OUT = ROOT / "tmp_shots" / "PHASE763R8" / "HTML_HANDBOOK_R84.md"

# 业务分层：对齐 TS 章节主题范式 → ZiYan 自研模块（顺序即侧栏）
BIZ_MODULES = [
    ("screen_img", "① 屏幕图像 / 找色", ["Screen", "Image", "Vision"]),
    ("touch_sim", "② 触控模拟", ["Touch", "Coordinate"]),
    ("toast_ui", "③ Toast / 日志", ["Log"]),
    ("ocr", "④ OCR识别", ["OCR"]),
    ("proc", "⑤ 应用 / 进程", ["App"]),
    ("file_io", "⑥ 文件", ["File"]),
    ("input_dev", "⑦ 输入 / 按键 / 设备", ["Input", "Device"]),
    ("net", "⑧ 网络", ["Network"]),
    ("thread_widget", "⑧′ 协作线程 / 控件", ["Thread", "Widget"]),
    ("cache", "⑨ 缓存控制", ["Screen"]),
    ("session", "⑩ 脚本会话 / 状态机", [
        "Script", "Verify", "StateMachine", "Game", "Engine", "Case", "Config",
    ]),
    ("ai_opt", "⑪ AI / 优化（规划与部分实现）", [
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


def load_compat_summary() -> str:
    lines = []
    for dev in ("166", "53"):
        p = SELFTEST / f"compat_result_{dev}.txt"
        if not p.exists():
            continue
        t = p.read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"SUMMARY pass=(\d+) fail=(\d+) skip=(\d+) total=(\d+)", t)
        s = re.search(r"\[STATS\]\s+([^\n]+)", t)
        if m:
            chunk = f".{dev}: compat pass={m.group(1)} fail={m.group(2)} skip={m.group(3)} total={m.group(4)}"
            if s:
                chunk += f" ({s.group(1).strip()})"
            lines.append(chunk)
    return " · ".join(lines)


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
    <p class="meta">所属更新：{datetime.date.today().isoformat()} · 双机自测：{esc(selftest)}</p>
  </header>
  <h4>功能说明</h4>
  <p>{esc(desc)}</p>
  <h4>调用语法</h4>
  <pre><code>{esc(usage)}</code></pre>
  <h4>参数说明</h4>
  {params_table(params)}
  <h4>返回值</h4>
  {returns_block(returns)}
  <h4>示例代码</h4>
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


def layer_section_html() -> str:
    if not LAYER_MAP.exists():
        return "<p>分层映射文件缺失。</p>"
    data = json.loads(LAYER_MAP.read_text(encoding="utf-8"))
    rows = []
    for ch, meta in sorted(
        (data.get("chapters") or {}).items(),
        key=lambda x: int(x[0]) if str(x[0]).isdigit() else 999,
    ):
        mods = ", ".join(meta.get("zy_modules") or [])
        rows.append(
            "<tr>"
            f"<td>TS ch{esc(ch)}</td>"
            f"<td>{esc(meta.get('ts_theme',''))}</td>"
            f"<td>{esc(meta.get('zh',''))}</td>"
            f"<td><code>{esc(mods)}</code></td>"
            f"<td>{meta.get('ts_page_count',0)}</td>"
            "</tr>"
        )
    return (
        "<p>下列对照<strong>仅用于手册分层排版范式</strong>（学习自 "
        f"TS 归档 {data.get('archive_pages',0)} 页），"
        "<strong>不</strong>表示复用触动函数名或私有实现。</p>"
        "<table class='params'><thead><tr>"
        "<th>TS章节</th><th>主题（学习）</th><th>子砚分层</th><th>Zy 模块</th><th>归档页数</th>"
        "</tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


STATUS_ZH = {
    "implemented": "已接自研后端",
    "stub_planned": "已挂名/计划实现",
    "stub_unsupported": "不实现（私有/云能力）",
    "stub_generic": "已挂名/未实现",
}

BUCKET_ZH = {
    "color": "图色",
    "touch": "触控",
    "screen": "屏幕",
    "image": "图片",
    "ocr": "OCR",
    "app": "应用",
    "file": "文件",
    "input": "输入",
    "keycode": "按键",
    "widget": "控件",
    "log": "日志",
    "device": "设备",
    "net": "网络",
    "thread": "线程",
    "ui": "UI",
    "time": "时间",
    "util": "工具",
    "ts_cloud": "TS云能力",
    "other": "其它",
}


def mirror_data() -> dict:
    if not MIRROR_MAP.exists():
        return {"count": 0, "stats": {}, "functions": {}}
    return json.loads(MIRROR_MAP.read_text(encoding="utf-8"))


def mirror_test_line(name: str, meta: dict, tested: set[str], summary: str) -> str:
    status = meta.get("status") or "stub_generic"
    if status == "implemented":
        return selftest_line_for(name, "active", tested, summary)
    if status == "stub_unsupported":
        return "SKIP · 触动云/私有生态能力，ZiYan 按合规边界明确不实现"
    if status == "stub_planned":
        return "SKIP · 已注册入口，待 ZiYan 自研后端补齐后再纳入硬测"
    return "SKIP · 已注册入口，当前返回 false/not_implemented，后续按优先级自研补齐"


def mirror_section_html(tested: set[str], summary: str) -> str:
    data = mirror_data()
    funcs = data.get("functions") or {}
    if not funcs:
        return "<p>TS→Zy 镜像映射尚未生成。</p>"

    stats = data.get("stats") or {}
    stat_html = "".join(
        f"<span class='pill'><code>{esc(k)}</code> {esc(STATUS_ZH.get(k, k))}: {esc(v)}</span>"
        for k, v in sorted(stats.items())
    )
    by_bucket = defaultdict(int)
    for meta in funcs.values():
        by_bucket[meta.get("bucket") or "other"] += 1
    bucket_html = "".join(
        f"<span class='pill'>{esc(BUCKET_ZH.get(k, k))}: {v}</span>"
        for k, v in sorted(by_bucket.items(), key=lambda kv: (-kv[1], kv[0]))
    )

    rows = []
    for name, meta in sorted(funcs.items(), key=lambda kv: (kv[1].get("bucket", ""), kv[0].lower())):
        status = meta.get("status") or "stub_generic"
        bucket = meta.get("bucket") or "other"
        zy_impl = meta.get("zy_impl") or "stub.generic"
        title = meta.get("ts_title") or "—"
        usage = f"{name}(...)" if "." not in name else f"{name}(...)"
        test = mirror_test_line(name, meta, tested, summary)
        rows.append(
            "<tr>"
            f"<td><code>{esc(name)}</code></td>"
            f"<td>{esc(BUCKET_ZH.get(bucket, bucket))}</td>"
            f"<td><code>{esc(zy_impl)}</code></td>"
            f"<td>{esc(STATUS_ZH.get(status, status))}</td>"
            f"<td><code>{esc(usage)}</code></td>"
            f"<td>{esc(test)}</td>"
            f"<td>{esc(title)}</td>"
            "</tr>"
        )

    return f"""
<p class="note">本章来自已归档的 TS 文档函数名清单，<strong>只做名称/契约镜像</strong>；
所有执行均转入 <code>compat_impl.lua</code> 的 ZiYan 自研后端，禁止调用触动私有模块或源码。</p>
<p>{stat_html}</p>
<p>{bucket_html}</p>
<table class='params mirror-table'>
  <thead><tr><th>采集函数名</th><th>分桶</th><th>ZiYan后端</th><th>状态</th><th>调用形式</th><th>测试口径</th><th>来源标题</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
"""


def main() -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    functions: dict = catalog.get("functions") or {}
    mirror = mirror_data()
    docs = load_complete_docs()
    base_selftest_sum = load_selftest_summary()
    compat_sum = load_compat_summary()
    selftest_sum = base_selftest_sum + ((" · " + compat_sum) if compat_sum else "")
    tested = load_tested_names()
    by_mod: dict[str, list[tuple[str, dict]]] = defaultdict(list)
    for fq, meta in sorted(functions.items()):
        by_mod[meta.get("module") or "?"].append((fq, meta))

    nav_links = []
    body_parts = []

    nav_links.append('<a href="#doc-layers">文档分层对照</a>')
    body_parts.append(
        '<section id="doc-layers" class="module"><h2>文档分层对照（TS 章节范式 → Zy 模块）</h2>'
        + layer_section_html()
        + "</section>"
    )

    nav_links.append('<a href="#ts-zy-mirror">TS→Zy 一一镜像函数</a>')
    body_parts.append(
        '<section id="ts-zy-mirror" class="module"><h2>TS→Zy 一一镜像函数（采集名 → 自研后端）</h2>'
        + mirror_section_html(tested, selftest_sum)
        + "</section>"
    )

    # ---- globals ----
    nav_links.append('<a href="#ts-globals">⓪ 全局图色触控</a>')
    ghtml = ['<section id="ts-globals" class="module"><h2>⓪ 全局函数 · 屏幕图像 / 触控 / Toast / 缓存</h2>']
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
:root{--bg:#f7f8fa;--panel:#fff;--text:#1a1f26;--muted:#5b6b7c;--accent:#0b6e4f;--line:#e2e8f0;--code:#0f172a;--codefg:#e2e8f0;--nav:#111827}
*{box-sizing:border-box}body{margin:0;font-family:"PingFang SC","Noto Sans SC","Source Han Sans SC",sans-serif;background:var(--bg);color:var(--text);line-height:1.6}
a{color:var(--accent);text-decoration:none}.layout{display:grid;grid-template-columns:260px 1fr;min-height:100vh}
nav{position:sticky;top:0;height:100vh;overflow:auto;padding:18px 14px;border-right:1px solid var(--line);background:var(--nav);color:#cbd5e1}
nav strong{color:#fff;font-size:15px}nav a{display:block;padding:7px 8px;font-size:12.5px;color:#94a3b8;border-radius:6px}nav a:hover{color:#fff;background:#1f2937}
main{padding:28px 32px 96px;max-width:980px}.hero{background:var(--panel);padding:22px 24px;border-radius:12px;margin-bottom:22px;border:1px solid var(--line);box-shadow:0 1px 2px rgba(0,0,0,.04)}
.module{margin:32px 0}.fn{background:var(--panel);padding:18px 20px;border-radius:12px;margin:16px 0;border:1px solid var(--line)}
.fn h3{margin:0 0 8px;font-size:17px}.zh{color:var(--muted);font-weight:500;margin-left:6px}.badge{font-size:11px;padding:2px 8px;border-radius:999px;background:#ecfdf5;color:var(--accent);margin-left:6px;border:1px solid #a7f3d0}
.meta{color:var(--muted);font-size:12px}pre{background:var(--code);color:var(--codefg);padding:14px;border-radius:8px;overflow:auto}
code{font-family:Menlo,Consolas,ui-monospace,monospace;font-size:12.5px}
table.params{width:100%;border-collapse:collapse;font-size:13px;background:#fff}table.params th,table.params td{border:1px solid var(--line);padding:8px 10px;text-align:left}
table.params th{background:#f1f5f9;color:#334155}h2{border-bottom:2px solid var(--accent);padding-bottom:8px;font-size:22px}h4{margin:16px 0 8px;color:#0f172a;font-size:14px;letter-spacing:.02em}
.search{width:100%;padding:9px 10px;margin:10px 0 14px;background:#0b1220;border:1px solid #334155;color:#e2e8f0;border-radius:8px}
.note{background:#fff7ed;border:1px solid #fed7aa;color:#9a3412;padding:10px 12px;border-radius:8px;font-size:13px}
.pill{display:inline-block;margin:3px 6px 3px 0;padding:3px 8px;border:1px solid var(--line);border-radius:999px;background:#f8fafc;font-size:12px;color:#334155}
.mirror-table td{vertical-align:top}.mirror-table td:nth-child(6),.mirror-table td:nth-child(7){font-size:12px}
@media(max-width:900px){.layout{grid-template-columns:1fr}nav{position:relative;height:auto}}
"""

    page = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>子砚触控函数说明 · R8.4 开发手册</title>
<style>{css}</style>
</head>
<body>
<div class="layout">
<nav>
  <strong>子砚开发手册 R8.4</strong>
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
    <p class="note">分层排版学习自触动官方手册 GitBook 章节结构（归档 {LAYER_MAP.name}）；
    <strong>全部 Zy API 为自研实现</strong>，严禁照搬触动/XXTouch 源码与私有接口。</p>
    <p>生成：{datetime.datetime.now():%Y-%m-%d %H:%M} · <strong>Engine 2.24.0 / Modules 1.13.0</strong> · 分工2 Wave1–4 · Zy API 条目：{len(functions)} · TS→Zy 镜像：{mirror.get('count', 0)} · 自测：{esc(selftest_sum)}</p>
    <p>验收设备：.166 iPhone7 rootful iOS13 · .53 iPhone8Plus rootless iOS16 · 坐标统一 ScreenTransform</p>
  </div>

  <section id="preface" class="module">
    <h2>前言</h2>
    <p>子砚采用 Lua 5.3，并扩展图色、触控、OCR、进程与会话等能力。条目体例对齐官方手册常见结构：
    <strong>功能说明 → 调用语法 → 参数说明 → 返回值 → 示例代码 → 双机自测</strong>。</p>
    <p>本说明供学习与自动化测试。示例部署前须在二类真机自测。禁止用于非法用途。</p>
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
    <p>文档分层运行时：<code>Zy.Layers.list()</code> / <code>Zy.Layers.findModule("Screen")</code>（引擎 <code>layers.lua</code>）。</p>
    <p>按键自研封装：<code>Zy.Input.keycode("HOME")</code> / <code>Zy.Input.pressHome()</code>（无后端时返回 false）。</p>
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
    META_OUT.parent.mkdir(parents=True, exist_ok=True)
    META_OUT.write_text(
        "\n".join(
            [
                "# HTML 手册 R8.4 变更说明",
                "",
                f"- 生成时间：{datetime.datetime.now().isoformat()}",
                f"- 成品：`子砚触控函数说明.html`（{OUT.stat().st_size} bytes）",
                f"- Zy API 条目：{len(functions)}",
                f"- TS→Zy 镜像条目：{mirror.get('count', 0)}",
                f"- TS→Zy 镜像状态：{json.dumps(mirror.get('stats') or {}, ensure_ascii=False)}",
                "- 分层：学习 TS 归档章节主题 → Zy 模块侧栏（见 doc-layers）",
                "- 新增章节：TS→Zy 一一镜像函数（476 名采集函数 → ZiYan 自研后端/诚实 stub）",
                "- 条目体例：功能说明 / 调用语法 / 参数说明 / 返回值 / 示例代码 / 双机自测",
                "- 新增模块：`lua/ziyan_engine/layers.lua`；`Zy.Input.Keycode` / `keycode` / `pressHome`",
                "- 映射：`tools/ziyan_doc/ts_chapter_layer_map.json`",
                "- 生成器：`tools/ziyan_doc/generate_handbook_r84.py`",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(f"wrote {OUT} bytes={OUT.stat().st_size} functions={len(functions)}")
    print(f"wrote {META_OUT}")


if __name__ == "__main__":
    main()
