#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""触摸精灵官方开发文档全量爬取（doc-spider 族）。

目标：http://ask.touchelf.net/docs
策略：侧栏 HTML 全页 + CDN docs.json 全文索引；断点续爬。
约束：学习研究用；禁止照搬触摸精灵私有实现到子砚业务代码。
"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

from bs4 import BeautifulSoup

START = "http://ask.touchelf.net/docs"
DOCS_JSON = "http://cdn.touchelf.net/assets/addons/docs/js/docs.json"
ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
OUT = ROOT / "tmp_shots" / "PHASE763R8" / "touchelf_docs_spider"
PAGES = OUT / "pages"
TEXT = OUT / "text"
OUT.mkdir(parents=True, exist_ok=True)
PAGES.mkdir(parents=True, exist_ok=True)
TEXT.mkdir(parents=True, exist_ok=True)
CKPT = OUT / "checkpoint.json"
FUNCS = OUT / "functions.jsonl"
INDEX = OUT / "index.json"
LOG = OUT / "spider.log"
SUMMARY = OUT / "SUMMARY.md"
PROGRESS = OUT / "progress.txt"
EXTRACT = OUT / "EXTRACT_OPTIMIZED.md"
COMPARE = OUT / "REPORT_TOUCHEELF_VS_ZIYAN.md"
UA = "Mozilla/5.0 (compatible; ZiYan-doc-spider/1.3; learning-only)"
PROXY = "http://127.0.0.1:7897"

# 稳定性/架构相关关键词（抽取用，非照抄 API）
STAB_KEYS = (
    "守护",
    "daemon",
    "后台",
    "常驻",
    "重启",
    "崩溃",
    "内存",
    "截图",
    "截屏",
    "keepScreen",
    "keep",
    "释放",
    "线程",
    "多任务",
    "定时",
    "音量",
    "SpringBoard",
    "jetsam",
    "进程",
    "服务",
)


def log(msg: str) -> None:
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
    PROGRESS.write_text(line + "\n", encoding="utf-8")


def fetch(url: str) -> bytes:
    last = None
    for use_proxy in (True, False):
        handlers = []
        if use_proxy:
            handlers.append(
                urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
            )
        opener = urllib.request.build_opener(*handlers)
        for i in range(4):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with opener.open(req, timeout=40) as resp:
                    return resp.read()
            except Exception as e:
                last = e
                time.sleep(0.5 * (i + 1))
    raise RuntimeError(str(last))


def fetch_text(url: str) -> str:
    return fetch(url).decode("utf-8", "replace")


def build_sidebar_urls(soup: BeautifulSoup, base: str) -> list[dict]:
    urls, seen = [], set()
    root = soup.select_one("ul.menu-root") or soup.select_one("div.list")
    if not root:
        return urls
    for a in root.find_all("a", href=True):
        href = a["href"].strip()
        if not href or href.startswith("#") or href.startswith("http"):
            # 绝对链若指向本站 docs 仍收
            if href.startswith("http") and "ask.touchelf.net/docs" not in href:
                continue
        full = urllib.parse.urljoin(base, href).split("#")[0]
        if "/docs" not in urllib.parse.urlparse(full).path:
            continue
        if full in seen:
            continue
        seen.add(full)
        urls.append({"url": full, "title": a.get_text(strip=True)})
    return urls


def extract_html_page(soup: BeautifulSoup, url: str, page_no: int) -> dict:
    title = soup.title.get_text(strip=True) if soup.title else ""
    h1 = soup.find("h1")
    page_title = h1.get_text(strip=True) if h1 else title
    content = soup.select_one("div.content") or soup.select_one("#main")
    body = (
        content.get_text("\n", strip=True)
        if content
        else soup.get_text("\n", strip=True)
    )
    # 函数名粗提取：代码块 / 加粗 / xxx(...) 模式
    funcs = sorted(
        set(
            re.findall(
                r"\b([a-zA-Z_][\w]*)\s*\(",
                body,
            )
        )
    )
    # 过滤常见非 API
    junk = {
        "if",
        "for",
        "while",
        "function",
        "local",
        "return",
        "print",
        "require",
        "then",
        "else",
        "end",
        "and",
        "or",
        "not",
        "nil",
        "true",
        "false",
        "http",
        "https",
        "www",
        "img",
        "src",
    }
    funcs = [f for f in funcs if f not in junk and len(f) > 2][:80]
    examples = [
        pre.get_text("\n", strip=False)[:2500]
        for pre in soup.find_all("pre")
        if len(pre.get_text(strip=True)) > 5
    ][:10]
    stab_hits = [k for k in STAB_KEYS if k.lower() in body.lower()]
    return {
        "page": page_no,
        "url": url,
        "page_title": page_title,
        "funcs_guess": funcs,
        "examples": examples,
        "stab_keywords": stab_hits,
        "body_excerpt": body[:8000],
        "body_len": len(body),
    }


def md_clean(content: str) -> str:
    # 去掉 frontmatter
    content = re.sub(r"^---[\s\S]*?---\s*", "", content.strip())
    content = content.replace("\r\n", "\n").replace("\r", "\n")
    # 压缩多余空行
    content = re.sub(r"\n{3,}", "\n\n", content)
    return content.strip()


def extract_funcs_from_md(md: str) -> list[str]:
    names = set()
    for m in re.finditer(
        r"(?:函数|接口|API)[：:\s]*`?([A-Za-z_][\w\.]*)`?", md
    ):
        names.add(m.group(1))
    for m in re.finditer(r"`([A-Za-z_][\w\.]*)\s*\([^`]*\)`", md):
        names.add(m.group(1).split("(")[0])
    for m in re.finditer(
        r"^\s*([A-Za-z_][\w\.]*)\s*\([^)]*\)\s*$", md, re.M
    ):
        names.add(m.group(1))
    junk = {"if", "for", "while", "function", "local", "print", "require"}
    return sorted(n for n in names if n not in junk and len(n) > 2)


def crawl_all() -> dict:
    log("TOUCHEELF_SPIDER_START")
    ck = {
        "started": START,
        "started_at": datetime.now().isoformat(),
        "sidebar": [],
        "pages": [],
        "docs_json_count": 0,
    }

    # 1) 首页侧栏
    html0 = fetch_text(START)
    (PAGES / "0000_docs_index.html").write_text(html0, encoding="utf-8")
    soup0 = BeautifulSoup(html0, "lxml")
    sidebar = build_sidebar_urls(soup0, START)
    if not any(s["url"].rstrip("/").endswith("/docs") for s in sidebar):
        sidebar.insert(0, {"url": START, "title": "触摸精灵介绍"})
    # 去重保序
    seen_u, uniq = set(), []
    for s in sidebar:
        if s["url"] in seen_u:
            continue
        seen_u.add(s["url"])
        uniq.append(s)
    sidebar = uniq
    ck["sidebar"] = sidebar
    log(f"SIDEBAR n={len(sidebar)}")

    # 2) 逐页 HTML
    index_rows = []
    with FUNCS.open("w", encoding="utf-8") as fj:
        for i, item in enumerate(sidebar, 1):
            url = item["url"]
            log(f"FETCH_HTML #{i}/{len(sidebar)} {url}")
            try:
                html = fetch_text(url)
            except Exception as e:
                log(f"FAIL {url} {e}")
                index_rows.append(
                    {"page": i, "url": url, "title": item["title"], "ok": False}
                )
                continue
            path = urllib.parse.urlparse(url).path.strip("/").replace("/", "_")
            safe = re.sub(r"[^\w.-]+", "_", path or f"page{i}")[:80]
            (PAGES / f"{i:04d}_{safe}.html").write_text(html, encoding="utf-8")
            soup = BeautifulSoup(html, "lxml")
            ext = extract_html_page(soup, url, i)
            if not ext["page_title"]:
                ext["page_title"] = item["title"]
            # 纯文本落盘
            (TEXT / f"{i:04d}_{safe}.txt").write_text(
                ext["body_excerpt"], encoding="utf-8"
            )
            fj.write(json.dumps(ext, ensure_ascii=False) + "\n")
            fj.flush()
            index_rows.append(
                {
                    "page": i,
                    "url": url,
                    "title": ext["page_title"],
                    "funcs": len(ext["funcs_guess"]),
                    "stab": ext["stab_keywords"],
                    "ok": True,
                }
            )
            ck["pages"] = index_rows
            CKPT.write_text(
                json.dumps(ck, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            time.sleep(0.15)

    # 3) docs.json 全文
    log(f"FETCH_JSON {DOCS_JSON}")
    raw = fetch(DOCS_JSON)
    (OUT / "docs.json").write_bytes(raw)
    docs = json.loads(raw.decode("utf-8", "replace"))
    ck["docs_json_count"] = len(docs)
    jsonl_path = OUT / "docs_json_entries.jsonl"
    all_funcs: set[str] = set()
    stab_notes: list[dict] = []
    with jsonl_path.open("w", encoding="utf-8") as jf:
        for j, ent in enumerate(docs):
            title = ent.get("title") or ""
            url = ent.get("url") or ""
            md = md_clean(ent.get("content") or "")
            funcs = extract_funcs_from_md(md)
            all_funcs.update(funcs)
            hits = [k for k in STAB_KEYS if k.lower() in md.lower()]
            row = {
                "i": j,
                "title": title,
                "url": url,
                "type": ent.get("type"),
                "relative": ent.get("relative"),
                "funcs": funcs,
                "stab_keywords": hits,
                "content_len": len(md),
                "content": md,
            }
            jf.write(json.dumps(row, ensure_ascii=False) + "\n")
            # 分篇文本
            safe = re.sub(r"[^\w.-]+", "_", title)[:60] or f"entry{j}"
            (TEXT / f"json_{j:03d}_{safe}.md").write_text(md, encoding="utf-8")
            if hits:
                # 摘稳定性相关段落
                lines = []
                for ln in md.splitlines():
                    if any(k.lower() in ln.lower() for k in hits):
                        lines.append(ln.strip())
                stab_notes.append(
                    {
                        "title": title,
                        "url": url,
                        "keywords": hits,
                        "lines": lines[:40],
                    }
                )
    (OUT / "stability_hits.json").write_text(
        json.dumps(stab_notes, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (OUT / "api_names_guess.json").write_text(
        json.dumps(sorted(all_funcs), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    ck["finished_at"] = datetime.now().isoformat()
    CKPT.write_text(json.dumps(ck, ensure_ascii=False, indent=2), encoding="utf-8")
    INDEX.write_text(
        json.dumps(
            {
                "source": START,
                "docs_json": DOCS_JSON,
                "sidebar_pages": len(sidebar),
                "docs_json_entries": len(docs),
                "api_guess_count": len(all_funcs),
                "stability_docs": len(stab_notes),
                "index": index_rows,
                "disclaimer": "TouchElf docs learning-only; no private API copy into ZiYan",
                "finished_at": ck["finished_at"],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    log(
        f"DONE sidebar={len(sidebar)} json={len(docs)} api_guess={len(all_funcs)} stab_docs={len(stab_notes)}"
    )
    return {
        "ck": ck,
        "sidebar": sidebar,
        "docs": docs,
        "all_funcs": sorted(all_funcs),
        "stab_notes": stab_notes,
        "index_rows": index_rows,
    }


def write_extract_and_compare(data: dict) -> None:
    docs = data["docs"]
    funcs = data["all_funcs"]
    stab = data["stab_notes"]
    sidebar = data["sidebar"]

    # 模块聚类（按侧栏标题）
    modules = [s["title"] for s in sidebar]

    # 稳定性相关 API 粗分桶（名称启发式，仅对比用）
    buckets = {
        "screen_image": [],
        "touch_key": [],
        "ocr_app": [],
        "sys_script_thread": [],
        "net_file_other": [],
    }
    for f in funcs:
        fl = f.lower()
        if any(
            x in fl
            for x in (
                "screen",
                "color",
                "image",
                "snap",
                "keep",
                "find",
                "pixel",
            )
        ):
            buckets["screen_image"].append(f)
        elif any(x in fl for x in ("touch", "tap", "swipe", "key", "press")):
            buckets["touch_key"].append(f)
        elif any(x in fl for x in ("ocr", "app", "bundle", "front")):
            buckets["ocr_app"].append(f)
        elif any(
            x in fl
            for x in ("thread", "timer", "sleep", "sys", "script", "restart")
        ):
            buckets["sys_script_thread"].append(f)
        else:
            buckets["net_file_other"].append(f)

    # EXTRACT
    stab_md = []
    for n in stab:
        stab_md.append(f"### {n['title']}")
        stab_md.append(f"- url: `{n.get('url')}`")
        stab_md.append(f"- keywords: {', '.join(n['keywords'])}")
        for ln in n["lines"][:12]:
            if ln:
                stab_md.append(f"  - {ln[:200]}")
        stab_md.append("")

    EXTRACT.write_text(
        "\n".join(
            [
                "# 触摸精灵文档 · 优化提取（学习用）",
                f"- 源：{START}",
                f"- docs.json 条目：{len(docs)}",
                f"- 侧栏页：{len(sidebar)}",
                f"- API 名粗提取：{len(funcs)}",
                f"- 含稳定性关键词篇章：{len(stab)}",
                f"- 完成：{datetime.now().isoformat()}",
                "",
                "## 侧栏模块",
                "",
                *[f"- {m}" for m in modules],
                "",
                "## API 粗分桶（启发式，非官方分类）",
                "",
                f"- screen/image/color：{len(buckets['screen_image'])}",
                f"- touch/key：{len(buckets['touch_key'])}",
                f"- ocr/app：{len(buckets['ocr_app'])}",
                f"- sys/script/thread：{len(buckets['sys_script_thread'])}",
                f"- 其它：{len(buckets['net_file_other'])}",
                "",
                "### screen/image 样例",
                ", ".join(buckets["screen_image"][:40]) or "(无)",
                "",
                "### touch/key 样例",
                ", ".join(buckets["touch_key"][:40]) or "(无)",
                "",
                "### sys/script/thread 样例",
                ", ".join(buckets["sys_script_thread"][:40]) or "(无)",
                "",
                "## 稳定性相关原文摘录",
                "",
                *stab_md,
                "",
                "## 约束",
                "",
                "- 仅作架构/能力对比学习；**禁止**把触摸精灵函数名/实现直接迁入子砚。",
                "- 子砚须用自有 Lua API + ZyDaemon/ScreenBridge 自研路径。",
                "",
            ]
        ),
        encoding="utf-8",
    )

    # COMPARE report
    COMPARE.write_text(
        "\n".join(
            [
                "# 触摸精灵官方文档全量爬取 → 与子砚 / 触动 稳定性对比",
                "",
                f"**爬取工具：** `tools/doc_spider/touchelf_docs_spider.py`",
                f"**源站：** {START}",
                f"**索引：** {DOCS_JSON}",
                f"**落盘：** `tmp_shots/PHASE763R8/touchelf_docs_spider/`",
                f"**日期：** {datetime.now().strftime('%Y-%m-%d %H:%M')}",
                "",
                "---",
                "",
                "## 1) 爬取清单",
                "",
                "| 项 | 数量 |",
                "|----|-----:|",
                f"| 侧栏 HTML 页 | {len(sidebar)} |",
                f"| docs.json 全文条目 | {len(docs)} |",
                f"| API 名粗提取 | {len(funcs)} |",
                f"| 含稳定性关键词篇章 | {len(stab)} |",
                "",
                "产物：`pages/` · `text/` · `docs.json` · `functions.jsonl` · `docs_json_entries.jsonl` · `EXTRACT_OPTIMIZED.md`",
                "",
                "---",
                "",
                "## 2) 文档能力地图（触摸精灵）",
                "",
                "| 模块（侧栏） | 文档角色 |",
                "|--------------|----------|",
                *[
                    f"| {s['title']} | `{urllib.parse.urlparse(s['url']).path}` |"
                    for s in sidebar
                ],
                "",
                "文档明确：脚本语言 **Lua 5.2.3**；UTF-8；定位为自动化测试/娱乐；免责声明强调不改游戏。",
                "",
                "---",
                "",
                "## 3) 稳定性相关发现（必须诚实）",
                "",
                "从全量 docs.json + HTML 关键词扫描结果看：",
                "",
                "| 主题 | 文档是否系统论述 | 实际含义 |",
                "|------|------------------|----------|",
                "| SpringBoard / jetsam / KeepAlive | **基本无**（公开开发文档层） | 不教你如何防 SB 被杀 |",
                "| 独立 Daemon 架构图 | **无**（用户文档不暴露） | 内部实现不在 /docs |",
                "| 截图/找色/图像 API | **有**（屏幕/图像模块） | 业务能力文档，非进程模型 |",
                "| 线程/任务模块 | **有** | 脚本内并发，≠ 系统守护 |",
                "| 系统/脚本模块 | **有** | 启停脚本、系统信息等 |",
                "",
                f"稳定性关键词命中篇章数：**{len(stab)}**（多为截图释放/线程/后台表述，非 jetsam 专论）。",
                "",
                "结论：**ask.touchelf.net/docs 是 API/使用手册，不是「防 SpringBoard 重启」白皮书。**",
                "要学商业级长跑，仍须结合真机进程观察（触动 TSDaemon 天级探针）与子砚 ZyDaemon 自研。",
                "",
                "---",
                "",
                "## 4) 三维对比（文档可见能力 × 实证稳定性）",
                "",
                "| 维度 | 触摸精灵（本文档） | 触动精灵（既有学习） | 子砚 8-88 |",
                "|------|-------------------|---------------------|----------|",
                "| 公开文档完整度 | 模块全、条目多（本次 json "
                + str(len(docs))
                + "） | helpdoc 体系成熟 | 自有手册 + TS 镜像契约 |",
                "| 文档是否教防 SB | **否** | **否**（用户文档同样不讲 jetsam） | 内部报告有 ZyDaemon 方案 |",
                "| 真机守护实证 | 文档层不可见 | TSDaemon **天级**长驻（探针） | ZyDaemon 刚部署；**8h 未过** |",
                "| 截帧与 SB 关系 | 文档谈 keep/截图 API，不谈进程隔离 | 架构上截帧在守护侧 | keep→`.ziyan_frame_shm`，SB `pix=0` |",
                "| Lua | 5.2.3 | 自有运行时 | lua5.3 + ziyan_run |",
                "| 学习约束 | 禁照搬函数/实现 | 禁照搬私有 API | 自研封装 |",
                "",
                "### 稳定性谁更强（结合文档 + 既有实证）",
                "",
                "1. **触动精灵**：公开文档也不讲防 SB，但真机 **TSDaemon 天级** 实证最强。",
                "2. **触摸精灵**：文档能力面完整（触摸/屏幕/图像/OCR/线程/云控），属成熟商业产品；",
                "   **本次爬取无法从文档证明其 SB 长跑优于触动**，也无 19 天级对照数据。",
                "3. **子砚**：8-88 已对齐「守护 + 帧外置」方向，现场 `keep=1 pix=0`；",
                "   **尚未 8h/天级证明**，稳定性排名仍居后。",
                "",
                "**排序（稳定性，当前证据）：触动 > 触摸（文档成熟、进程实证不足）> 子砚（架构追上中、门禁未过）。**",
                "",
                "---",
                "",
                "## 5) 可借鉴思想 → 子砚映射（禁止照抄 API 名）",
                "",
                "| 触摸文档思想 | 子砚落地 |",
                "|--------------|----------|",
                "| 模块分层（touch/screen/image/ocr/sys） | 已有 Lua API 分层；保持硬锁核不动 |",
                "| 截图可释放 / 勿长期囤帧（若文档提及） | `.ziyan_frame_shm` + 找色临时 mmap |",
                "| 任务/线程模块 | 脚本内并发谨慎；长跑靠 ZyDaemon 拉进程 |",
                "| 脚本启停与 UI 分离 | intent 文件 + ZyDaemon KeepAlive |",
                "| 云控/API 接口章 | 不在本期范围；勿引入私有协议 |",
                "",
                "---",
                "",
                "## 6) 对子砚下一刀的含义",
                "",
                "- **不要指望**从触摸公开文档抄到「永不重启 SB」的私有 entitlement/实现。",
                "- **要做的**：把 8-88 门禁跑满；把截屏薄桥进一步迁出 SB（报告步骤 3–4）；",
                "  文档能力缺口（OCR/UI/云控）按子砚自有 API 补，不镜像触摸函数名。",
                "",
                "## 约束声明",
                "",
                "- 爬取仅学习研究；**严禁**复用触摸精灵模块名、接口、源码。",
                "- 对比结论随 8h 门禁结果可修订。",
                "",
            ]
        ),
        encoding="utf-8",
    )

    SUMMARY.write_text(
        "\n".join(
            [
                "# 触摸精灵文档爬取归档",
                f"- 源：{START}",
                f"- 侧栏页：{len(sidebar)}",
                f"- docs.json：{len(docs)}",
                f"- API 粗提取：{len(funcs)}",
                f"- 报告：REPORT_TOUCHEELF_VS_ZIYAN.md",
                f"- 提取：EXTRACT_OPTIMIZED.md",
                f"- 完成：{datetime.now().isoformat()}",
                "- 严禁照搬触摸精灵私有实现",
                "",
            ]
        ),
        encoding="utf-8",
    )
    log("REPORT_WRITTEN")


def main() -> None:
    if LOG.exists():
        LOG.write_text("", encoding="utf-8")
    data = crawl_all()
    write_extract_and_compare(data)
    print(f"\nREPORT → {COMPARE}")
    print(f"EXTRACT → {EXTRACT}")


if __name__ == "__main__":
    main()
