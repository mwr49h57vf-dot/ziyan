#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""逆向学习 URL 列表全量爬取（doc-spider 族）。

输入：逆向学习/逆向pdf网址.txt
输出：逆向学习/corpus/
约束：学习研究；禁止把触动私有实现照搬进子砚业务代码。
代理：Clash Verge mixed-port 7897（失败则直连重试）。
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Optional

UA = "Mozilla/5.0 (compatible; ZiYan-doc-spider/1.4; learning-only)"
PROXY = os.environ.get("ZIYAN_PROXY", "http://127.0.0.1:7897")
ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
URL_FILE = ROOT / "逆向学习" / "逆向pdf网址.txt"
OUT = ROOT / "逆向学习" / "corpus"
RAW = OUT / "raw"
TEXT = OUT / "text"
REPOS = OUT / "repos"
CKPT = OUT / "checkpoint.json"
MANIFEST = OUT / "manifest.jsonl"
LOG = OUT / "spider.log"
SUMMARY = OUT / "SUMMARY.md"
FAILS = OUT / "failures.jsonl"

# 超大仓库：不全量 clone，改为 README + docs/ wiki 稀疏拉取
HUGE_REPOS = {
    ("opencv", "opencv"),
    ("opencv", "opencv_contrib"),
    ("NationalSecurityAgency", "ghidra"),
    ("facebook", "folly"),
    ("theos", "theos"),
    ("lief-project", "LIEF"),
    ("tesseract-ocr", "tesseract"),
    ("Tencent", "ncnn"),
    ("LuaJIT", "LuaJIT"),
}

SITE_CRAWL_MAX = {
    "www.touchsprite.com": 40,
    "helpdoc.touchsprite.com": 60,
    "docs.autotouch.net": 40,
    "theos.dev": 30,
    "www.cycript.org": 20,
    "tesseract-ocr.github.io": 40,
    "crifan.github.io": 40,
    "book.crifan.org": 20,
    "isocpp.github.io": 15,
    "developer.android.com": 15,
    "developer.android.google.cn": 15,
    "developer.apple.com": 15,
}


def now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def log(msg: str) -> None:
    line = f"[{now()}] {msg}"
    print(line, flush=True)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def opener(use_proxy: bool):
    handlers = []
    if use_proxy:
        handlers.append(urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))
    return urllib.request.build_opener(*handlers)


def rewrite_url(url: str) -> list[str]:
    """返回候选 URL 列表（原 URL 优先，后跟备用）。"""
    cands = [url]
    # Lua 手册：无独立 pdf，改抓 html
    if url.endswith("lua.org/manual/5.4/manual.pdf"):
        cands = [
            "https://www.lua.org/manual/5.4/manual.html",
            "https://www.lua.org/manual/5.4/",
        ]
    # crifan PDF 常 403/404 → 对应 GitHub 仓库
    m = re.search(r"book\.crifan\.org/books/([^/]+)/pdf/", url)
    if m:
        book = m.group(1)
        # PDF 常 403/404：直接走 GitHub / 在线 HTML
        cands = [
            f"https://github.com/crifan/{book}",
            f"https://crifan.github.io/{book}/website/",
            f"https://book.crifan.org/books/{book}/website/",
            url,
        ]
    # Mach-O PDF 仓库可能改名
    if "aidansteele/osx-abi-macho-file-format" in url:
        cands.extend(
            [
                "https://github.com/qyang-nj/llios/raw/main/macho.md",
                "https://raw.githubusercontent.com/aidansteele/osx-abi-macho-file-format/main/Mach-O_File_Format.pdf",
            ]
        )
    # OpenCV tutorials pdf 路径变更
    if "opencv.org/4.x/pdf/opencv_tutorials.pdf" in url:
        cands.append("https://docs.opencv.org/4.x/d9/df8/tutorial_root.html")
    return cands


def fetch_bytes(url: str, timeout: int = 45) -> bytes:
    """优先 curl（带代理），失败再 urllib；4xx 立即换候选。"""
    last = None
    for use_proxy in (True, False):
        cmd = [
            "curl",
            "-fsSL",
            "--max-time",
            str(timeout),
            "-A",
            UA,
            "-H",
            "Accept: */*",
        ]
        if use_proxy:
            cmd += ["-x", PROXY]
        cmd.append(url)
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=timeout + 10)
            if r.returncode == 0 and r.stdout:
                return r.stdout
            last = RuntimeError(
                f"curl_rc={r.returncode} err={r.stderr[:200].decode('utf-8','replace')}"
            )
        except Exception as e:
            last = e
        # urllib fallback
        try:
            op = opener(use_proxy)
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with op.open(req, timeout=timeout) as resp:
                code = getattr(resp, "status", 200)
                data = resp.read()
                if code and int(code) >= 400:
                    raise RuntimeError(f"http_{code}")
                return data
        except Exception as e:
            last = e
            time.sleep(0.3)
    raise RuntimeError(str(last))


def slug(url: str, maxlen: int = 120) -> str:
    h = hashlib.sha1(url.encode("utf-8")).hexdigest()[:10]
    p = urllib.parse.urlsplit(url)
    base = re.sub(r"[^a-zA-Z0-9._-]+", "_", f"{p.netloc}{p.path}")[:maxlen]
    return f"{base}_{h}"


def load_ckpt() -> dict:
    if CKPT.exists():
        return json.loads(CKPT.read_text(encoding="utf-8"))
    return {"done": {}, "started": datetime.now().isoformat()}


def save_ckpt(ck: dict) -> None:
    CKPT.write_text(json.dumps(ck, ensure_ascii=False, indent=2), encoding="utf-8")


def append_jsonl(path: Path, obj: dict) -> None:
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def extract_urls(text: str) -> list[str]:
    # 补全无 scheme 的 shturl / book.crifan
    text = re.sub(
        r"(?<![\w/:])((?:shturl\.cc|book\.crifan\.org)/[^\s）\)\]\"']+)",
        r"https://\1",
        text,
    )
    found = re.findall(r"https?://[^\s）\)\]\"'，,；;<>]+", text)
    clean = []
    for u in found:
        u = u.rstrip(".,;:，。；：)>]")
        # blob → raw
        if "github.com" in u and "/blob/" in u:
            u = u.replace("github.com", "raw.githubusercontent.com").replace(
                "/blob/", "/"
            )
        clean.append(u)
    # 保序去重
    seen = set()
    out = []
    for u in clean:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def pdftotext(data: bytes, outp: Path) -> int:
    try:
        r = subprocess.run(
            ["pdftotext", "-layout", "-"],
            input=data,
            capture_output=True,
            timeout=90,
        )
        if r.returncode == 0 and r.stdout.strip():
            outp.write_bytes(r.stdout)
            return len(r.stdout)
    except Exception:
        pass
    strings = re.findall(rb"[\x20-\x7e]{6,}", data)
    body = "\n".join(x.decode("ascii", "ignore") for x in strings[:1500])
    outp.write_text(body + "\n", encoding="utf-8")
    return len(body)


def html_to_text(html: bytes) -> str:
    try:
        from bs4 import BeautifulSoup

        soup = BeautifulSoup(html, "html.parser")
        for t in soup(["script", "style", "noscript"]):
            t.decompose()
        return soup.get_text("\n", strip=True)
    except Exception:
        return re.sub(rb"<[^>]+>", b" ", html).decode("utf-8", "replace")


def parse_github(url: str):
    m = re.match(
        r"https?://(?:www\.)?github\.com/([^/]+)/([^/#?]+)(?:/(tree|blob)/([^/]+)/?(.*))?",
        url,
    )
    if not m:
        return None
    owner, repo = m.group(1), m.group(2)
    if repo.endswith(".git"):
        repo = repo[:-4]
    kind = m.group(3) or ""
    ref = m.group(4) or ""
    path = (m.group(5) or "").rstrip("/")
    return owner, repo, kind, ref, path


def gh_api(path: str) -> object:
    # prefer gh cli
    try:
        p = subprocess.run(
            ["gh", "api", path],
            capture_output=True,
            timeout=120,
        )
        if p.returncode == 0 and p.stdout:
            return json.loads(p.stdout.decode("utf-8", "replace"))
    except Exception:
        pass
    return json.loads(
        fetch_bytes(f"https://api.github.com{path}").decode("utf-8", "replace")
    )


def save_file(url: str, data: bytes, kind: str) -> dict:
    name = slug(url)
    raw_path = RAW / f"{name}.bin"
    # better extension
    path = urllib.parse.urlsplit(url).path.lower()
    if path.endswith(".pdf") or data[:4] == b"%PDF":
        raw_path = RAW / f"{name}.pdf"
        text_path = TEXT / f"{name}.txt"
        raw_path.write_bytes(data)
        n = pdftotext(data, text_path)
        return {
            "url": url,
            "kind": kind,
            "raw": str(raw_path.relative_to(OUT)),
            "text": str(text_path.relative_to(OUT)),
            "bytes": len(data),
            "text_chars": n,
            "ok": True,
        }
    if b"<html" in data[:2000].lower() or path.endswith((".html", ".htm")) or not path.split("/")[-1].count("."):
        raw_path = RAW / f"{name}.html"
        text_path = TEXT / f"{name}.txt"
        raw_path.write_bytes(data)
        body = html_to_text(data)
        text_path.write_text(body, encoding="utf-8")
        return {
            "url": url,
            "kind": kind,
            "raw": str(raw_path.relative_to(OUT)),
            "text": str(text_path.relative_to(OUT)),
            "bytes": len(data),
            "text_chars": len(body),
            "ok": True,
        }
    # markdown / plain
    raw_path = RAW / f"{name}.dat"
    text_path = TEXT / f"{name}.txt"
    raw_path.write_bytes(data)
    try:
        s = data.decode("utf-8")
        text_path.write_text(s, encoding="utf-8")
        tc = len(s)
    except Exception:
        text_path.write_text(f"[binary {len(data)} bytes]\n", encoding="utf-8")
        tc = 0
    return {
        "url": url,
        "kind": kind,
        "raw": str(raw_path.relative_to(OUT)),
        "text": str(text_path.relative_to(OUT)),
        "bytes": len(data),
        "text_chars": tc,
        "ok": True,
    }


def clone_or_sparse(owner: str, repo: str) -> dict:
    dest = REPOS / f"{owner}__{repo}"
    url = f"https://github.com/{owner}/{repo}"
    if dest.exists() and any(dest.iterdir()):
        return {"url": url, "kind": "git", "path": str(dest), "ok": True, "note": "exists"}
    dest.parent.mkdir(parents=True, exist_ok=True)

    def try_zip(ref: str) -> bool:
        zurl = f"https://codeload.github.com/{owner}/{repo}/zip/refs/heads/{ref}"
        zpath = dest.parent / f"{owner}__{repo}_{ref}.zip"
        # GitHub zip：优先直连（经 Clash 常 401）
        for use_proxy in (False, True):
            cmd = [
                "curl",
                "-fsSL",
                "--max-time",
                "60",
                "-A",
                UA,
                "-o",
                str(zpath),
                zurl,
            ]
            if use_proxy:
                cmd[1:1] = ["-x", PROXY]
            r = subprocess.run(cmd, capture_output=True, timeout=75)
            if r.returncode == 0 and zpath.exists() and zpath.stat().st_size > 64:
                dest.mkdir(parents=True, exist_ok=True)
                subprocess.run(
                    ["unzip", "-oq", str(zpath), "-d", str(dest.parent)],
                    check=False,
                    capture_output=True,
                    timeout=120,
                )
                for p in dest.parent.glob(f"{repo}-{ref}*"):
                    if p.is_dir():
                        if dest.exists():
                            import shutil

                            shutil.rmtree(dest, ignore_errors=True)
                        p.rename(dest)
                        break
                zpath.unlink(missing_ok=True)
                return dest.exists() and any(dest.iterdir())
        return False

    # 超大仓：只拉 README（禁止再 zip / 长爬）
    if (owner, repo) in HUGE_REPOS:
        dest.mkdir(parents=True, exist_ok=True)
        got = False
        for ref in ("master", "main"):
            for name in ("README.md", "README.rst", "readme.md"):
                try:
                    data = fetch_bytes(
                        f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{name}",
                        timeout=20,
                    )
                    (dest / name).write_bytes(data)
                    got = True
                    break
                except Exception:
                    continue
            if got:
                break
        if got:
            return {"url": url, "kind": "readme_only", "path": str(dest), "ok": True}
        try:
            data = fetch_bytes(url, timeout=20)
            (dest / "github_page.html").write_bytes(data)
            (dest / "github_page.txt").write_text(html_to_text(data), encoding="utf-8")
            return {"url": url, "kind": "github_page", "path": str(dest), "ok": True}
        except Exception as e:
            return {"url": url, "kind": "huge_fail", "ok": False, "error": str(e)}

    for ref in ("master", "main"):
        try:
            if try_zip(ref):
                return {"url": url, "kind": "zipball", "path": str(dest), "ok": True, "ref": ref}
        except Exception:
            continue

    # 最后：仓库首页 HTML
    try:
        data = fetch_bytes(url)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "github_page.html").write_bytes(data)
        (dest / "github_page.txt").write_text(html_to_text(data), encoding="utf-8")
        return {
            "url": url,
            "kind": "github_page",
            "path": str(dest),
            "ok": True,
            "note": "zip_fail_page_only",
        }
    except Exception as e:
        return {"url": url, "kind": "git", "ok": False, "error": str(e)}


def crawl_site(start: str, max_pages: int) -> list[dict]:
    """浅爬同域文档页。"""
    host = urllib.parse.urlsplit(start).netloc
    seen = set()
    q = [start]
    results = []
    t0 = time.time()
    while q and len(results) < max_pages:
        if time.time() - t0 > 90:
            break
        url = q.pop(0)
        if url in seen:
            continue
        seen.add(url)
        try:
            data = fetch_bytes(url, timeout=25)
            rec = save_file(url, data, "site_page")
            results.append(rec)
            html = data.decode("utf-8", "replace")
            for href in re.findall(r'href=["\']([^"\']+)["\']', html):
                full = urllib.parse.urljoin(url, href)
                p = urllib.parse.urlsplit(full)
                if p.netloc != host:
                    continue
                if p.scheme not in ("http", "https"):
                    continue
                if any(
                    x in p.path.lower()
                    for x in (
                        "/docs",
                        "/doc",
                        "/help",
                        "/manual",
                        "/guide",
                        "/api",
                        "/lua",
                        "/tess",
                        "/books",
                        "/topic",
                        "/dev_docs",
                    )
                ) or p.path.endswith((".html", ".htm", "/")):
                    clean = urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, "", ""))
                    if clean not in seen and len(seen) + len(q) < max_pages * 3:
                        q.append(clean)
        except Exception as e:
            results.append({"url": url, "kind": "site_page", "ok": False, "error": str(e)})
        time.sleep(0.15)
    return results


def handle_url(url: str) -> dict:
    # pip 伪 URL 已过滤
    if url.startswith("pip "):
        return {"url": url, "kind": "skip", "ok": True, "note": "pip_cmd"}

    # 明显占位/假 arxiv/假论文 → 标记 skip（仍记入清单）
    if re.search(r"arxiv\.org/(abs|pdf)/(2509|2605|2607)\.(12345|56789|24375)", url):
        return {"url": url, "kind": "skip_placeholder", "ok": False, "error": "placeholder_id"}
    if any(
        x in url
        for x in (
            "tde-123456-7890",
            "handle/10919/123456",
            "CNKI-2017-006",
            "PCG-Survey-LLM",
            "files/12345678/",
            "CN122432037A",
            "CN122432038A",
        )
    ):
        return {"url": url, "kind": "skip_placeholder", "ok": False, "error": "placeholder_url"}

    # 多候选
    cands = rewrite_url(url)
    if cands[0] != url or len(cands) > 1:
        last_err = None
        for cu in cands:
            try:
                if "github.com/crifan/" in cu and cu.rstrip("/").count("/") >= 3:
                    owner, repo = "crifan", cu.rstrip("/").split("/")[-1]
                    return clone_or_sparse(owner, repo)
                if cu.endswith(".html") or cu.endswith("/"):
                    data = fetch_bytes(cu)
                    rec = save_file(cu, data, "rewrite")
                    rec["orig"] = url
                    return rec
                # fallthrough try fetch
                data = fetch_bytes(cu)
                rec = save_file(cu, data, "rewrite")
                rec["orig"] = url
                return rec
            except Exception as e:
                last_err = e
                continue
        return {
            "url": url,
            "ok": False,
            "error": str(last_err) if last_err else "rewrite_exhausted",
            "kind": "rewrite_fail",
            "tried": cands,
        }

    # GitHub
    if "github.com" in url and "/releases" not in url:
        # raw already rewritten for blob
        if "raw.githubusercontent.com" in url:
            data = fetch_bytes(url)
            return save_file(url, data, "github_raw")
        parsed = parse_github(url)
        if parsed:
            owner, repo, kind, ref, path = parsed  # type: ignore
            if kind == "blob" or (path and path.endswith((".pdf", ".md", ".txt"))):
                # try raw
                ref2 = ref or "master"
                raw_u = f"https://raw.githubusercontent.com/{owner}/{repo}/{ref2}/{path}"
                try:
                    data = fetch_bytes(raw_u)
                    return save_file(url, data, "github_file")
                except Exception:
                    pass
            return clone_or_sparse(owner, repo)

    # gitcode mirrors → treat as page dump
    if any(
        h in url
        for h in (
            "www.touchsprite.com/helpdoc",
            "docs.autotouch.net",
            "theos.dev/docs",
            "www.cycript.org",
            "tesseract-ocr.github.io",
            "crifan.github.io",
            "isocpp.github.io/CppCoreGuidelines",
        )
    ):
        host = urllib.parse.urlsplit(url).netloc
        maxp = SITE_CRAWL_MAX.get(host, 30)
        pages = crawl_site(url, maxp)
        ok_n = sum(1 for p in pages if p.get("ok"))
        return {
            "url": url,
            "kind": "site_crawl",
            "ok": ok_n > 0,
            "pages": len(pages),
            "ok_pages": ok_n,
            "children": pages[:5],  # sample
        }

    # book.crifan.org root → list books index
    if url.rstrip("/").endswith("book.crifan.org"):
        data = fetch_bytes("https://book.crifan.org/")
        return save_file(url, data, "crifan_index")

    # default fetch
    data = fetch_bytes(url)
    return save_file(url, data, "direct")


def _mp_worker(u: str, q) -> None:
    try:
        q.put(handle_url(u))
    except Exception as e:
        q.put({"url": u, "ok": False, "error": str(e), "kind": "worker_exc"})


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    RAW.mkdir(exist_ok=True)
    TEXT.mkdir(exist_ok=True)
    REPOS.mkdir(exist_ok=True)

    src = URL_FILE.read_text(encoding="utf-8", errors="replace")
    urls = extract_urls(src)
    log(f"urls_unique={len(urls)} proxy={PROXY}")
    (OUT / "url_list.txt").write_text("\n".join(urls) + "\n", encoding="utf-8")

    ck = load_ckpt()
    done = ck.setdefault("done", {})
    # 已落盘的 repos 记完成
    for d in REPOS.iterdir() if REPOS.exists() else []:
        if d.is_dir() and any(d.iterdir()):
            owner, _, repo = d.name.partition("__")
            if owner and repo:
                u = f"https://github.com/{owner}/{repo}"
                done.setdefault(u, {"ok": True, "kind": "preexisting", "ts": datetime.now().isoformat()})

    ok = fail = skip = 0
    for i, url in enumerate(urls, 1):
        if url in done and done[url].get("ok"):
            skip += 1
            continue
        log(f"[{i}/{len(urls)}] GET {url[:120]}")
        try:
            rec = handle_url(url)
            if not isinstance(rec, dict):
                rec = {"url": url, "ok": False, "error": "bad_rec"}
            rec["ts"] = datetime.now().isoformat()
            append_jsonl(MANIFEST, rec)
            done[url] = {
                "ok": bool(rec.get("ok")),
                "kind": rec.get("kind"),
                "ts": rec["ts"],
            }
            if rec.get("ok"):
                ok += 1
                log(
                    f"  OK kind={rec.get('kind')} bytes={rec.get('bytes', rec.get('pages', ''))}"
                )
            else:
                fail += 1
                append_jsonl(FAILS, rec)
                log(f"  FAIL {rec.get('error')}")
        except Exception as e:
            fail += 1
            rec = {
                "url": url,
                "ok": False,
                "error": str(e),
                "ts": datetime.now().isoformat(),
            }
            append_jsonl(MANIFEST, rec)
            append_jsonl(FAILS, rec)
            done[url] = {"ok": False, "error": str(e)}
            log(f"  EXC {e}")
        ck["done"] = done
        ck["stats"] = {"ok": ok, "fail": fail, "skip": skip, "total": len(urls)}
        if i % 2 == 0:
            save_ckpt(ck)

    save_ckpt(ck)
    summary = f"""# 逆向学习 corpus 爬取摘要

- 时间：{datetime.now().isoformat()}
- URL 去重数：{len(urls)}
- 成功：{ok} · 失败：{fail} · 跳过已完成：{skip}
- 输出：`{OUT}`
- 代理：{PROXY}

## 目录
- `raw/` 原始文件
- `text/` 抽取文本（学习用）
- `repos/` zipball / README
- `manifest.jsonl` / `failures.jsonl` / `checkpoint.json`
"""
    SUMMARY.write_text(summary, encoding="utf-8")
    log(f"DONE ok={ok} fail={fail} skip={skip}")


if __name__ == "__main__":
    main()
