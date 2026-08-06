#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TS doc-spider 断点续爬看门狗：进程被杀后从 checkpoint 恢复。"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

from bs4 import BeautifulSoup

START = "https://helpdoc.touchsprite.com/dev_docs/29/1.html"
ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
OUT = ROOT / "tmp_shots" / "PHASE763R8" / "ts_docs_archive"
PAGES = OUT / "pages"
OUT.mkdir(parents=True, exist_ok=True)
PAGES.mkdir(parents=True, exist_ok=True)
CKPT = OUT / "checkpoint.json"
FUNCS = OUT / "functions.jsonl"
INDEX = OUT / "index.json"
LOG = OUT / "spider.log"
SUMMARY = OUT / "SUMMARY.md"
PROGRESS = OUT / "progress.txt"
UA = "Mozilla/5.0 (compatible; ZiYan-doc-spider/1.2; learning-only)"
PROXY = "http://127.0.0.1:7897"


def log(msg: str) -> None:
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
    PROGRESS.write_text(line + "\n", encoding="utf-8")


def fetch(url: str) -> str:
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
                    return resp.read().decode("utf-8", "replace")
            except Exception as e:
                last = e
                time.sleep(0.6 * (i + 1))
    raise RuntimeError(str(last))


def build_toc(soup: BeautifulSoup, base: str) -> list[str]:
    summary = soup.select_one("ul.summary")
    urls, seen = [], set()
    if not summary:
        return urls
    for a in summary.find_all("a", href=True):
        href = urllib.parse.urljoin(base, a["href"]).split("#")[0]
        if "dev_docs" not in href or not href.endswith(".html"):
            continue
        if href in seen:
            continue
        seen.add(href)
        urls.append(href)
    return urls


def find_next_nav(soup: BeautifulSoup, cur: str) -> str | None:
    a = soup.select_one("a.navigation-next")
    if a and a.get("href"):
        return urllib.parse.urljoin(cur, a["href"]).split("#")[0]
    return None


def toc_next(toc: list[str], cur: str) -> str | None:
    path = urllib.parse.urlparse(cur).path
    for j, u in enumerate(toc):
        if u == cur or urllib.parse.urlparse(u).path == path:
            return toc[j + 1] if j + 1 < len(toc) else None
    return None


def _section_after(soup: BeautifulSoup, keys: tuple[str, ...]) -> str:
    for h in soup.find_all(re.compile(r"^h[1-6]$")):
        t = h.get_text(strip=True)
        if any(k in t for k in keys):
            bits = []
            for sib in h.next_siblings:
                if getattr(sib, "name", None) and re.match(
                    r"^h[1-6]$", sib.name or ""
                ):
                    break
                if hasattr(sib, "get_text"):
                    tx = sib.get_text("\n", strip=True)
                    if tx:
                        bits.append(tx)
            return "\n".join(bits)[:4000]
    text = soup.get_text("\n", strip=True)
    for k in keys:
        i = text.find(k)
        if i >= 0:
            return text[i : i + 2000]
    return ""


def extract_page(soup: BeautifulSoup, url: str, page_no: int) -> dict:
    title = soup.title.get_text(strip=True) if soup.title else ""
    h1 = soup.find("h1")
    page_title = h1.get_text(strip=True) if h1 else title
    name = page_title
    m = re.search(r"函数[：:]\s*([^\s]+)", page_title)
    name = m.group(1) if m else (
        re.search(r"([A-Za-z_][\w\.:]*)", page_title).group(1)
        if re.search(r"([A-Za-z_][\w\.:]*)", page_title)
        else page_title
    )
    examples = [
        pre.get_text("\n", strip=False)[:3000]
        for pre in soup.find_all("pre")
        if len(pre.get_text(strip=True)) > 5
    ][:8]
    body = soup.select_one(
        "section.normal, div.page-inner, div.markdown-section"
    )
    return {
        "page": page_no,
        "url": url,
        "page_title": page_title,
        "name": name,
        "params": _section_after(soup, ("参数说明", "参数", "入参", "原型")),
        "returns": _section_after(soup, ("返回值", "返回", "Return")),
        "examples": examples
        or ([_section_after(soup, ("示例", "例子", "Example"))] if True else []),
        "body_excerpt": (
            body.get_text("\n", strip=True)[:5000]
            if body
            else soup.get_text("\n", strip=True)[:5000]
        ),
    }


def load_ckpt() -> dict:
    if CKPT.exists():
        return json.loads(CKPT.read_text(encoding="utf-8"))
    return {"next_url": START, "page_no": 0, "seen": [], "toc": [], "index": []}


def save_ckpt(ck: dict) -> None:
    CKPT.write_text(json.dumps(ck, ensure_ascii=False, indent=2), encoding="utf-8")


def finalize(ck: dict) -> None:
    INDEX.write_text(
        json.dumps(
            {
                "started": START,
                "finished_at": datetime.now().isoformat(),
                "pages": ck["page_no"],
                "index": ck.get("index", []),
                "disclaimer": "TS docs learning-only; no code/API copy",
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    SUMMARY.write_text(
        "\n".join(
            [
                "# 触动精灵官方文档爬取归档（学习用）",
                f"- 起始：{START}",
                f"- 页数：{ck['page_no']}",
                f"- 完成：{datetime.now().isoformat()}",
                "- **严禁**照搬 TS 源码/私有 API；仅借鉴分层与契约范式",
                "",
            ]
        ),
        encoding="utf-8",
    )
    log(f"DONE pages={ck['page_no']}")


def crawl_batch(max_pages: int = 40) -> bool:
    """爬一批后返回是否全部完成。每批结束写 checkpoint，便于被杀后续跑。"""
    ck = load_ckpt()
    url = ck.get("next_url") or START
    seen = set(ck.get("seen") or [])
    toc = ck.get("toc") or []
    index = ck.get("index") or []
    page_no = int(ck.get("page_no") or 0)

    if not toc:
        html0 = fetch(START)
        soup0 = BeautifulSoup(html0, "lxml")
        toc = build_toc(soup0, START)
        if START in toc:
            toc = toc[toc.index(START) :]
        log(f"TOC from START size={len(toc)}")
        ck["toc"] = toc
        save_ckpt(ck)

    processed = 0
    mode = "a" if FUNCS.exists() and page_no > 0 else "w"
    with FUNCS.open(mode, encoding="utf-8") as fj:
        while url and url not in seen and processed < max_pages:
            page_no += 1
            processed += 1
            seen.add(url)
            log(f"FETCH #{page_no}/{len(toc)} {url}")
            try:
                html = fetch(url)
            except Exception as e:
                log(f"FAIL {url} err={e}")
                url = toc_next(toc, url)
                ck.update(
                    {
                        "next_url": url,
                        "page_no": page_no,
                        "seen": list(seen),
                        "index": index,
                    }
                )
                save_ckpt(ck)
                continue
            safe = re.sub(r"[^\w.-]+", "_", urllib.parse.urlparse(url).path)[
                :80
            ]
            (PAGES / f"{page_no:04d}_{safe}.html").write_text(
                html, encoding="utf-8"
            )
            soup = BeautifulSoup(html, "lxml")
            item = extract_page(soup, url, page_no)
            fj.write(json.dumps(item, ensure_ascii=False) + "\n")
            fj.flush()
            index.append(
                {
                    "page": page_no,
                    "url": url,
                    "title": item["page_title"],
                    "name": item["name"],
                }
            )
            nav = find_next_nav(soup, url)
            via = toc_next(toc, url)
            if nav and nav not in seen:
                nxt, how = nav, "nav-next"
            elif via and via not in seen:
                nxt, how = via, "toc-next"
            else:
                nxt, how = None, "end"
            log(f"  name={item['name']} next={nxt} via={how}")
            url = nxt
            ck.update(
                {
                    "next_url": url,
                    "page_no": page_no,
                    "seen": list(seen),
                    "index": index,
                    "toc": toc,
                }
            )
            save_ckpt(ck)
            time.sleep(0.2)

    if not url or url in seen:
        finalize(ck)
        return True
    log(f"BATCH_END page_no={page_no} next={url}")
    return False


def main() -> None:
    log("WATCHDOG_START")
    # 若无 checkpoint 且已有旧 jsonl，不删；全新则清空 LOG 头
    done = False
    while not done:
        try:
            done = crawl_batch(max_pages=50)
        except Exception as e:
            log(f"BATCH_EXC {e}")
            time.sleep(3)
        if not done:
            time.sleep(1)
    log("WATCHDOG_DONE")


if __name__ == "__main__":
    main()
