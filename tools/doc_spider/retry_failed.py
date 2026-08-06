#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对 VERIFY 失败项做第二轮抢救下载。"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import time
from datetime import datetime
from pathlib import Path

PROXY = "http://127.0.0.1:7897"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
ROOT = Path("/Users/mac/Desktop/ZiYan_副本/逆向学习/corpus")
VERIFY = ROOT / "verify_all.json"
OUT_RAW = ROOT / "raw"
OUT_TEXT = ROOT / "text"
OUT_REPOS = ROOT / "repos"
OUT_PRI = ROOT / "priority"
LOG = ROOT / "retry_failed.log"
REPORT = ROOT / "RETRY_FAILED_REPORT.md"

OUT_RAW.mkdir(exist_ok=True)
OUT_TEXT.mkdir(exist_ok=True)
OUT_REPOS.mkdir(exist_ok=True)


def log(msg: str) -> None:
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def slug(url: str) -> str:
    h = hashlib.sha1(url.encode()).hexdigest()[:10]
    p = re.sub(r"[^a-zA-Z0-9._-]+", "_", url)[:100]
    return f"{p}_{h}"


def curl(url: str, dest: Path, timeout: int = 60, use_proxy: bool = True) -> tuple[bool, str, int]:
    if not url or not str(url).startswith("http"):
        return False, f"bad_url:{url!r}", 0
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        dest.unlink(missing_ok=True)
    except Exception:
        pass
    cmd = [
        "curl",
        "-fsSL",
        "--connect-timeout",
        "20",
        "--max-time",
        str(timeout),
        "-A",
        UA,
        "-L",
    ]
    if use_proxy:
        cmd += ["-x", PROXY]
    cmd += ["-o", str(dest), url]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout + 15)
        if r.returncode == 0 and dest.exists() and dest.stat().st_size > 200:
            return True, "", dest.stat().st_size
        err = r.stderr.decode("utf-8", "replace")[:220] or f"rc={r.returncode}"
        return False, err, dest.stat().st_size if dest.exists() else 0
    except Exception as e:
        return False, str(e), 0


def html_text(data: bytes) -> str:
    try:
        from bs4 import BeautifulSoup

        soup = BeautifulSoup(data, "html.parser")
        for t in soup(["script", "style"]):
            t.decompose()
        return soup.get_text("\n", strip=True)
    except Exception:
        return re.sub(rb"<[^>]+>", b" ", data).decode("utf-8", "replace")


def save_page(url: str, data: bytes) -> Path:
    s = slug(url)
    if data[:4] == b"%PDF":
        p = OUT_RAW / f"{s}.pdf"
        p.write_bytes(data)
        try:
            subprocess.run(
                ["pdftotext", "-layout", str(p), str(OUT_TEXT / f"{s}.txt")],
                capture_output=True,
                timeout=60,
            )
        except Exception:
            pass
        return p
    p = OUT_RAW / f"{s}.html"
    p.write_bytes(data)
    (OUT_TEXT / f"{s}.txt").write_text(html_text(data), encoding="utf-8")
    return p


def try_urls(cands: list[str], timeout: int = 55) -> tuple[bool, str, Path | None, int]:
    last = ""
    for u in cands:
        for proxy in (True, False):
            tmp = OUT_RAW / f"_tmp_{slug(u)}.bin"
            ok, err, n = curl(u, tmp, timeout=timeout, use_proxy=proxy)
            if ok:
                data = tmp.read_bytes()
                path = save_page(u, data)
                tmp.unlink(missing_ok=True)
                return True, u, path, n
            last = err
            tmp.unlink(missing_ok=True)
    return False, last, None, 0


def retry_github(url: str) -> dict:
    m = re.match(r"https?://(?:www\.)?github\.com/([^/]+)/([^/#?]+)", url)
    if not m:
        return {"url": url, "ok": False, "error": "not_github"}
    owner, repo = m.group(1), m.group(2).removesuffix(".git")
    dest = OUT_REPOS / f"{owner}__{repo}"
    if dest.exists() and any(dest.iterdir()):
        return {"url": url, "ok": True, "path": str(dest), "note": "exists"}
    # 1) zip longer
    for ref in ("master", "main"):
        z = ROOT / "tmp" / f"retry_{owner}_{repo}_{ref}.zip"
        z.parent.mkdir(exist_ok=True)
        zurl = f"https://codeload.github.com/{owner}/{repo}/zip/refs/heads/{ref}"
        for proxy in (False, True):
            ok, err, n = curl(zurl, z, timeout=90, use_proxy=proxy)
            if ok and n > 500:
                subprocess.run(
                    ["unzip", "-oq", str(z), "-d", str(OUT_REPOS)],
                    capture_output=True,
                    timeout=120,
                )
                for p in OUT_REPOS.glob(f"{repo}-{ref}*"):
                    if p.is_dir():
                        if dest.exists():
                            import shutil

                            shutil.rmtree(dest, ignore_errors=True)
                        p.rename(dest)
                        break
                z.unlink(missing_ok=True)
                if dest.exists() and any(dest.iterdir()):
                    return {"url": url, "ok": True, "path": str(dest), "bytes": n, "via": zurl}
        z.unlink(missing_ok=True)
    # 2) README
    dest.mkdir(parents=True, exist_ok=True)
    for ref in ("master", "main"):
        for name in ("README.md", "README.rst", "readme.md"):
            raw = f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{name}"
            tmp = dest / name
            ok, err, n = curl(raw, tmp, 40, False)
            if ok:
                return {"url": url, "ok": True, "path": str(dest), "note": "readme_only", "bytes": n}
    # 3) html page with proxy
    tmp = OUT_RAW / f"{slug(url)}.html"
    ok, err, n = curl(url, tmp, 45, True)
    if ok:
        (OUT_TEXT / f"{slug(url)}.txt").write_text(html_text(tmp.read_bytes()), encoding="utf-8")
        return {"url": url, "ok": True, "path": str(tmp), "note": "page_only", "bytes": n}
    return {"url": url, "ok": False, "error": err}


def retry_crifan_pdf(url: str) -> dict:
    m = re.search(r"book\.crifan\.org/books/([^/]+)/", url)
    if not m:
        return {"url": url, "ok": False, "error": "parse"}
    book = m.group(1)
    cands = [
        f"https://crifan.github.io/{book}/website/",
        f"https://crifan.github.io/{book}/",
        f"https://book.crifan.org/books/{book}/website/",
        f"https://www.gitbook.com/book/crifan/{book}/details",
    ]
    # also try github book source
    gh = retry_github(f"https://github.com/crifan/{book}")
    if gh.get("ok"):
        gh["orig"] = url
        gh["note"] = (gh.get("note") or "") + "+crifan_github"
        return gh
    ok, via, path, n = try_urls(cands, timeout=50)
    if ok:
        return {"url": url, "ok": True, "path": str(path), "via": via, "bytes": n, "note": "crifan_website"}
    return {"url": url, "ok": False, "error": "crifan_all_fail"}


def is_placeholder(url: str, status: str) -> bool:
    if status == "placeholder":
        return True
    return bool(
        re.search(
            r"(2509\.(12345|56789)|2605\.24375|2607\.12345|tde-123456|10919/123456|CNKI-2017-006|CN12243203[78]|files/12345678|PCG-Survey-LLM)",
            url,
        )
    )


def main() -> None:
    items = json.loads(VERIFY.read_text())
    fails = [r for r in items if not r.get("ok")]
    log(f"retry start fails={len(fails)}")
    results = []
    rescued = 0
    skipped = 0

    for i, r in enumerate(fails, 1):
        url = r["url"]
        st = r.get("status") or ""
        err = r.get("error") or ""
        if is_placeholder(url, st):
            results.append({**r, "retry": "skip_placeholder"})
            skipped += 1
            log(f"[{i}/{len(fails)}] SKIP placeholder {url[:90]}")
            continue
        # hard 404 known dead repos — still try once briefly
        log(f"[{i}/{len(fails)}] RETRY {url[:100]}")
        try:
            if "book.crifan.org/books/" in url and "/pdf/" in url:
                out = retry_crifan_pdf(url)
            elif "github.com" in url and "raw.githubusercontent" not in url:
                out = retry_github(url)
            elif "patents.google.com" in url:
                ok, via, path, n = try_urls([url], timeout=70)
                out = {
                    "url": url,
                    "ok": ok,
                    "path": str(path) if path else None,
                    "via": via,
                    "bytes": n,
                    "error": None if ok else via,
                }
            elif "semanticscholar.org" in url:
                # API abstract
                paper = url.rstrip("/").split("/")[-1]
                api = f"https://api.semanticscholar.org/graph/v1/paper/{paper}?fields=title,abstract,url,year"
                # hash ids vs slug
                if len(paper) == 40 and re.fullmatch(r"[0-9a-f]+", paper):
                    api = f"https://api.semanticscholar.org/graph/v1/paper/{paper}?fields=title,abstract,url,year"
                else:
                    api = f"https://api.semanticscholar.org/graph/v1/paper/URL:{url}?fields=title,abstract,url,year"
                tmp = OUT_RAW / f"s2_{slug(url)}.json"
                ok, e, n = curl(api, tmp, 40, True)
                if not ok:
                    ok, e, n = curl(url, tmp.with_suffix(".html"), 50, True)
                    if ok:
                        path = save_page(url, tmp.with_suffix(".html").read_bytes())
                        out = {"url": url, "ok": True, "path": str(path), "bytes": n}
                    else:
                        out = {"url": url, "ok": False, "error": e}
                else:
                    (OUT_TEXT / f"s2_{slug(url)}.txt").write_text(
                        tmp.read_text("utf-8", "replace"), encoding="utf-8"
                    )
                    out = {"url": url, "ok": True, "path": str(tmp), "bytes": n, "note": "s2_api"}
            else:
                ok, via, path, n = try_urls([url], timeout=60)
                out = {
                    "url": url,
                    "ok": ok,
                    "path": str(path) if path else None,
                    "via": via if ok else None,
                    "bytes": n,
                    "error": None if ok else via,
                }
        except Exception as e:
            out = {"url": url, "ok": False, "error": str(e)}

        out["ts"] = datetime.now().isoformat()
        results.append(out)
        if out.get("ok"):
            rescued += 1
            # update verify entry
            r.update(
                {
                    "ok": True,
                    "status": "downloaded",
                    "path": out.get("path"),
                    "note": "retry_rescued:" + str(out.get("note") or out.get("via") or ""),
                    "error": None,
                }
            )
            log(f"  RESCUED {out.get('bytes') or out.get('note')}")
        else:
            log(f"  STILL_FAIL {out.get('error')}")
        time.sleep(0.2)

    # write updated verify
    VERIFY.write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")
    ok_n = sum(1 for x in items if x.get("ok"))
    fail_n = len(items) - ok_n

    lines = [
        "# 失败项第二轮抢救报告",
        "",
        f"- 时间：{datetime.now().isoformat()}",
        f"- 本轮尝试：{len(fails) - skipped}（跳过占位 {skipped}）",
        f"- 新救回：**{rescued}**",
        f"- 全表现况：成功 {ok_n} / 失败 {fail_n} / 合计 {len(items)}",
        "",
        "## 救回列表",
        "",
    ]
    for o in results:
        if o.get("ok") and o.get("retry") != "skip_placeholder":
            lines.append(f"- `{o['url']}` → `{o.get('path')}`")
    lines += ["", "## 仍失败（需换源或放弃）", ""]
    for o in results:
        if not o.get("ok") and o.get("retry") != "skip_placeholder":
            lines.append(f"- `{o.get('url')}` — {o.get('error') or o.get('retry')}")
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    log(f"DONE rescued={rescued} now_ok={ok_n} now_fail={fail_n}")


if __name__ == "__main__":
    main()
