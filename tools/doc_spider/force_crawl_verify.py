#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""强制扫完 url_list：每 URL 短超时，写 VERIFY 报告。"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

PROXY = "http://127.0.0.1:7897"
UA = "ZiYan-doc-spider/1.5"
ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
OUT = ROOT / "逆向学习" / "corpus"
URLS = OUT / "url_list.txt"
CKPT = OUT / "checkpoint.json"
RAW = OUT / "raw"
TEXT = OUT / "text"
REPOS = OUT / "repos"
PRIORITY = OUT / "priority"
VERIFY = OUT / "VERIFY_ALL_URLS.md"
VERIFY_JSON = OUT / "verify_all.json"
LOG = OUT / "force_crawl.log"
MANIFEST = OUT / "manifest_force.jsonl"

RAW.mkdir(parents=True, exist_ok=True)
TEXT.mkdir(exist_ok=True)
REPOS.mkdir(exist_ok=True)
PRIORITY.mkdir(exist_ok=True)


def log(msg: str) -> None:
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def slug(url: str) -> str:
    h = hashlib.sha1(url.encode()).hexdigest()[:10]
    p = urllib.parse.urlsplit(url)
    base = re.sub(r"[^a-zA-Z0-9._-]+", "_", f"{p.netloc}{p.path}")[:100]
    return f"{base}_{h}"


def curl(url: str, out: Path | None, timeout: int = 25, proxy: bool | None = None) -> tuple[bool, str, int]:
    """返回 ok, err, bytes"""
    attempts = []
    if proxy is True:
        attempts = [True]
    elif proxy is False:
        attempts = [False]
    else:
        # GitHub 直连优先；其它先代理
        if "github.com" in url or "githubusercontent.com" in url or "codeload.github.com" in url:
            attempts = [False, True]
        else:
            attempts = [True, False]
    last = "no_attempt"
    for use_p in attempts:
        cmd = ["curl", "-fsSL", "--max-time", str(timeout), "-A", UA]
        if use_p:
            cmd += ["-x", PROXY]
        if out:
            cmd += ["-o", str(out)]
        else:
            cmd += ["-o", "/dev/null"]
        cmd.append(url)
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=timeout + 5)
            if r.returncode == 0:
                n = out.stat().st_size if out and out.exists() else 0
                if out and n < 32:
                    last = "too_small"
                    continue
                return True, "", n
            last = r.stderr.decode("utf-8", "replace")[:180] or f"rc={r.returncode}"
        except Exception as e:
            last = str(e)
    return False, last, 0


def html_text(data: bytes) -> str:
    try:
        from bs4 import BeautifulSoup

        soup = BeautifulSoup(data, "html.parser")
        for t in soup(["script", "style"]):
            t.decompose()
        return soup.get_text("\n", strip=True)
    except Exception:
        return re.sub(rb"<[^>]+>", b" ", data).decode("utf-8", "replace")


def already_have(url: str) -> Path | None:
    """检查 priority/raw/repos 是否已有对应产物。"""
    s = slug(url)
    for p in RAW.glob(f"{s}.*"):
        if p.stat().st_size > 32:
            return p
    # github repo
    m = re.match(r"https?://(?:www\.)?github\.com/([^/]+)/([^/#?]+)", url)
    if m:
        dest = REPOS / f"{m.group(1)}__{m.group(2).removesuffix('.git')}"
        if dest.exists() and any(dest.iterdir()):
            return dest
    # priority name heuristics
    for p in PRIORITY.iterdir():
        if p.is_file() and p.stat().st_size > 32:
            # weak match by host keywords
            pass
    return None


def handle(url: str) -> dict:
    # placeholder
    if re.search(
        r"(2509\.(12345|56789)|2605\.24375|2607\.12345|tde-123456|10919/123456|CNKI-2017-006|CN12243203[78]|files/12345678|PCG-Survey-LLM)",
        url,
    ):
        return {"url": url, "status": "placeholder", "ok": False, "note": "fake_or_placeholder"}

    # lua pdf → html
    if url.endswith("lua.org/manual/5.4/manual.pdf"):
        url2 = "https://www.lua.org/manual/5.4/manual.html"
        out = PRIORITY / "lua54_manual.html"
        if out.exists() and out.stat().st_size > 1000:
            return {"url": url, "status": "downloaded", "ok": True, "path": str(out), "via": url2}
        ok, err, n = curl(url2, out, 40, False)
        return {"url": url, "status": "downloaded" if ok else "fail", "ok": ok, "path": str(out) if ok else None, "error": err, "bytes": n, "via": url2}

    # crifan pdf dead
    if "book.crifan.org/books/" in url and "/pdf/" in url:
        book = re.search(r"/books/([^/]+)/", url)
        name = book.group(1) if book else "unknown"
        # try github zip
        for ref in ("master", "main"):
            z = PRIORITY / f"crifan_{name}_{ref}.zip"
            zurl = f"https://codeload.github.com/crifan/{name}/zip/refs/heads/{ref}"
            ok, err, n = curl(zurl, z, 45, False)
            if ok:
                dest = REPOS / f"crifan__{name}"
                dest.mkdir(parents=True, exist_ok=True)
                subprocess.run(["unzip", "-oq", str(z), "-d", str(dest.parent)], capture_output=True, timeout=60)
                for p in dest.parent.glob(f"{name}-{ref}*"):
                    if p.is_dir():
                        if dest.exists():
                            import shutil

                            shutil.rmtree(dest, ignore_errors=True)
                        p.rename(dest)
                        break
                return {"url": url, "status": "downloaded", "ok": True, "path": str(dest), "via": zurl, "bytes": n}
        return {"url": url, "status": "fail", "ok": False, "error": "crifan_pdf_and_github_missing", "note": "book.crifan PDF 403/404"}

    # github repo / file
    if "github.com" in url and "/releases" not in url:
        if "raw.githubusercontent.com" in url:
            out = RAW / f"{slug(url)}.bin"
            ok, err, n = curl(url, out, 30, False)
            if ok:
                (TEXT / f"{slug(url)}.txt").write_bytes(out.read_bytes()[:200000])
            return {"url": url, "status": "downloaded" if ok else "fail", "ok": ok, "path": str(out) if ok else None, "error": err, "bytes": n}
        m = re.match(r"https?://(?:www\.)?github\.com/([^/]+)/([^/#?]+)", url)
        if m:
            owner, repo = m.group(1), m.group(2).removesuffix(".git")
            dest = REPOS / f"{owner}__{repo}"
            if dest.exists() and any(dest.iterdir()):
                return {"url": url, "status": "downloaded", "ok": True, "path": str(dest), "note": "exists"}
            # zipball short
            for ref in ("master", "main"):
                z = OUT / "tmp" / f"{owner}_{repo}_{ref}.zip"
                z.parent.mkdir(exist_ok=True)
                zurl = f"https://codeload.github.com/{owner}/{repo}/zip/refs/heads/{ref}"
                ok, err, n = curl(zurl, z, 28, False)
                if ok:
                    subprocess.run(["unzip", "-oq", str(z), "-d", str(REPOS)], capture_output=True, timeout=90)
                    for p in REPOS.glob(f"{repo}-{ref}*"):
                        if p.is_dir():
                            if dest.exists():
                                import shutil

                                shutil.rmtree(dest, ignore_errors=True)
                            p.rename(dest)
                            break
                    z.unlink(missing_ok=True)
                    if dest.exists() and any(dest.iterdir()):
                        return {"url": url, "status": "downloaded", "ok": True, "path": str(dest), "bytes": n, "ref": ref}
            # page only
            out = RAW / f"{slug(url)}.html"
            ok, err, n = curl(url, out, 20, False)
            if ok:
                (TEXT / f"{slug(url)}.txt").write_text(html_text(out.read_bytes()), encoding="utf-8")
                return {"url": url, "status": "page_only", "ok": True, "path": str(out), "bytes": n, "note": "zip_fail_saved_html"}
            return {"url": url, "status": "fail", "ok": False, "error": err}

    # generic page/pdf
    out = RAW / f"{slug(url)}.bin"
    ok, err, n = curl(url, out, 35, None)
    if not ok:
        return {"url": url, "status": "fail", "ok": False, "error": err}
    data = out.read_bytes()
    if data[:4] == b"%PDF" or url.lower().endswith(".pdf"):
        out2 = out.with_suffix(".pdf")
        out.rename(out2)
        out = out2
        try:
            r = subprocess.run(["pdftotext", "-layout", str(out), str(TEXT / f"{slug(url)}.txt")], capture_output=True, timeout=60)
        except Exception:
            pass
    elif b"<html" in data[:1500].lower() or url.endswith("/"):
        out2 = out.with_suffix(".html")
        out.rename(out2)
        out = out2
        (TEXT / f"{slug(url)}.txt").write_text(html_text(data), encoding="utf-8")
    else:
        try:
            (TEXT / f"{slug(url)}.txt").write_text(data.decode("utf-8"), encoding="utf-8")
        except Exception:
            (TEXT / f"{slug(url)}.txt").write_text(f"[binary {n}]\n", encoding="utf-8")
    return {"url": url, "status": "downloaded", "ok": True, "path": str(out), "bytes": n}


def main() -> None:
    urls = [u.strip() for u in URLS.read_text().splitlines() if u.strip()]
    ck = json.loads(CKPT.read_text()) if CKPT.exists() else {"done": {}}
    done = ck.setdefault("done", {})
    results = []

    # 已有 priority 文件映射
    priority_map = {
        "https://www.zybuluo.com/lisaisacat/note/324664": PRIORITY / "ts_arch_note.html",
        "https://docs.autotouch.net/lua": PRIORITY / "autotouch_lua.html",
        "https://theos.dev/docs": PRIORITY / "theos_docs.html",
        "https://www.cycript.org": PRIORITY / "cycript.html",
        "https://developer.android.com/topic/performance/memory": PRIORITY / "android_memory.html",
        "https://tesseract-ocr.github.io/tessdoc": PRIORITY / "tessdoc.html",
        "https://www.touchsprite.com/helpdoc": None,  # site crawl
        "https://github.com/AloneMonkey/iOSREBook": REPOS / "AloneMonkey__iOSREBook",
        "https://github.com/jon4god/AutoTouchDocuments": None,
    }

    log(f"force_crawl start total={len(urls)}")
    for i, url in enumerate(urls, 1):
        prev = done.get(url) or {}
        # 断点：已有明确终态则跳过（仍写入 results 以便校验覆盖）
        if prev.get("kind") in (
            "downloaded",
            "page_only",
            "fail",
            "placeholder",
            "priority",
            "rewrite_fail",
        ) or (prev.get("ok") is True and prev.get("path")):
            rec = {
                "url": url,
                "status": prev.get("kind") or ("downloaded" if prev.get("ok") else "fail"),
                "ok": bool(prev.get("ok")),
                "path": prev.get("path"),
                "error": prev.get("error"),
                "note": "checkpoint_skip",
            }
            results.append(rec)
            log(f"[{i}/{len(urls)}] SKIP {url[:90]}")
            continue
        # priority hit
        hit = priority_map.get(url)
        if hit and Path(hit).exists() and Path(hit).stat().st_size > 32:
            rec = {"url": url, "status": "downloaded", "ok": True, "path": str(hit), "note": "priority"}
            results.append(rec)
            done[url] = {"ok": True, "kind": "priority", "ts": datetime.now().isoformat()}
            log(f"[{i}/{len(urls)}] PRIORITY {url[:90]}")
            continue
        if url == "https://github.com/jon4god/AutoTouchDocuments" and (PRIORITY / "AutoTouchDocuments.zip").exists():
            rec = {"url": url, "status": "downloaded", "ok": True, "path": str(PRIORITY / "AutoTouchDocuments.zip")}
            results.append(rec)
            done[url] = {"ok": True, "kind": "priority"}
            log(f"[{i}/{len(urls)}] PRIORITY zip {url[:90]}")
            continue

        log(f"[{i}/{len(urls)}] GET {url[:100]}")
        try:
            rec = handle(url)
        except Exception as e:
            rec = {"url": url, "status": "fail", "ok": False, "error": str(e)}
        rec["ts"] = datetime.now().isoformat()
        results.append(rec)
        done[url] = {
            "ok": bool(rec.get("ok")),
            "kind": rec.get("status"),
            "path": rec.get("path"),
            "error": rec.get("error"),
            "ts": rec["ts"],
        }
        with MANIFEST.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        log(f"  -> {rec.get('status')} ok={rec.get('ok')} {rec.get('bytes') or rec.get('error') or rec.get('note') or ''}")
        if i % 5 == 0:
            CKPT.write_text(json.dumps({"done": done, "stats": {"i": i}}, ensure_ascii=False, indent=2), encoding="utf-8")

    CKPT.write_text(json.dumps({"done": done}, ensure_ascii=False, indent=2), encoding="utf-8")
    VERIFY_JSON.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    # 完整性：每个 url 必须出现在 results
    by_url = {r["url"]: r for r in results}
    missing = [u for u in urls if u not in by_url]
    downloaded = [r for r in results if r.get("ok") and r.get("status") in ("downloaded", "page_only")]
    failed = [r for r in results if not r.get("ok")]
    placeholders = [r for r in results if r.get("status") == "placeholder"]

    lines = [
        f"# URL 全量校验报告",
        f"",
        f"- 时间：{datetime.now().isoformat()}",
        f"- URL 总数：**{len(urls)}**",
        f"- 报告覆盖：**{len(results)}**（缺失 {len(missing)}）",
        f"- 下载成功（含 page_only）：**{len(downloaded)}**",
        f"- 失败：**{len(failed)}**（含占位 {len(placeholders)}）",
        f"",
        f"## 结论",
        f"",
    ]
    if missing:
        lines.append(f"**未覆盖 URL 仍有 {len(missing)} 条 — 未完成。**")
    else:
        lines.append("**每个网址均已处理（成功下载或明确失败/占位）。**")
    lines += ["", "## 逐条清单", "", "| # | 状态 | 网址 | 产物/原因 |", "|---|------|------|-----------|"]
    for i, u in enumerate(urls, 1):
        r = by_url.get(u) or {"status": "MISSING", "ok": False, "error": "not_in_results"}
        st = r.get("status")
        detail = r.get("path") or r.get("error") or r.get("note") or ""
        if isinstance(detail, str) and len(detail) > 80:
            detail = detail[:77] + "..."
        lines.append(f"| {i} | {st} | `{u}` | {detail} |")

    lines += ["", "## 失败 URL（需人工或换源）", ""]
    for r in failed:
        lines.append(f"- `{r['url']}` — {r.get('error') or r.get('note') or r.get('status')}")

    VERIFY.write_text("\n".join(lines) + "\n", encoding="utf-8")
    log(f"DONE covered={len(results)}/{len(urls)} ok={len(downloaded)} fail={len(failed)} missing={len(missing)}")
    print("VERIFY", VERIFY)


if __name__ == "__main__":
    main()
