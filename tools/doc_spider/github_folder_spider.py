#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用 GitHub 目录全量爬取（doc-spider 族）：API listing + blob/raw 落盘抽文本。"""
from __future__ import annotations

import base64
import json
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

UA = "ZiYan-doc-spider/1.3; learning-only"
PROXY = "http://127.0.0.1:7897"


def log(msg: str, log_path: Path) -> None:
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with log_path.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def opener(use_proxy: bool):
    handlers = []
    if use_proxy:
        handlers.append(urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))
    return urllib.request.build_opener(*handlers)


def fetch_bytes(url: str, timeout: int = 60) -> bytes:
    last = None
    # encode path spaces
    parts = urllib.parse.urlsplit(url)
    path = urllib.parse.quote(parts.path, safe="/:@")
    url2 = urllib.parse.urlunsplit(
        (parts.scheme, parts.netloc, path, parts.query, parts.fragment)
    )
    for use_proxy in (True, False):
        op = opener(use_proxy)
        for i in range(3):
            try:
                req = urllib.request.Request(url2, headers={"User-Agent": UA})
                with op.open(req, timeout=timeout) as resp:
                    return resp.read()
            except Exception as e:
                last = e
                time.sleep(0.8 * (i + 1))
    raise RuntimeError(str(last))


def fetch_json(url: str) -> object:
    return json.loads(fetch_bytes(url).decode("utf-8", "replace"))


def gh_blob(owner: str, repo: str, sha: str) -> bytes:
    # Prefer gh cli (auth) then API
    try:
        p = subprocess.run(
            ["gh", "api", f"repos/{owner}/{repo}/git/blobs/{sha}"],
            capture_output=True,
            timeout=120,
        )
        if p.returncode == 0 and p.stdout:
            obj = json.loads(p.stdout.decode("utf-8", "replace"))
            if obj.get("encoding") == "base64" and obj.get("content"):
                return base64.b64decode(obj["content"])
    except Exception:
        pass
    api = f"https://api.github.com/repos/{owner}/{repo}/git/blobs/{sha}"
    obj = fetch_json(api)
    if not isinstance(obj, dict):
        raise RuntimeError("blob not dict")
    if obj.get("encoding") == "base64" and obj.get("content"):
        return base64.b64decode(obj["content"])
    raise RuntimeError("blob decode fail")


def extract_text(name: str, data: bytes, outp: Path) -> dict:
    ext = Path(name).suffix.lower()
    meta: dict = {}
    if ext in {
        ".sh",
        ".txt",
        ".md",
        ".plist",
        ".xml",
        ".json",
        ".py",
        ".c",
        ".m",
        ".h",
        ".lua",
        ".command",
        ".css",
        ".html",
    }:
        s = data.decode("utf-8", "replace")
        outp.write_text(s, encoding="utf-8")
        meta["text_chars"] = len(s)
    elif ext == ".rtf":
        s = data.decode("utf-8", "replace")

        def hexesc(m):
            try:
                return bytes.fromhex(m.group(0)[2:]).decode("latin-1", "replace")
            except Exception:
                return " "

        s = re.sub(r"\\'[0-9a-fA-F]{2}", hexesc, s)
        s = re.sub(r"\\[a-zA-Z]+-?\d* ?", " ", s)
        s = re.sub(r"[{}\\]", " ", s)
        s = re.sub(r"\s+", " ", s).strip()
        outp.write_text(s + "\n", encoding="utf-8")
        meta["text_chars"] = len(s)
    elif ext == ".pdf":
        try:
            r = subprocess.run(
                ["pdftotext", "-layout", "-"],
                input=data,
                capture_output=True,
                timeout=60,
            )
            if r.returncode == 0 and r.stdout.strip():
                outp.write_bytes(r.stdout)
                meta["text_chars"] = len(r.stdout)
            else:
                raise RuntimeError("pdftotext empty")
        except Exception as e:
            strings = re.findall(rb"[\x20-\x7e]{6,}", data)
            body = "\n".join(x.decode("ascii", "ignore") for x in strings[:1000])
            outp.write_text(body + "\n", encoding="utf-8")
            meta["note"] = f"pdf_fallback:{e}"
            meta["text_chars"] = len(body)
    elif ext in {".png", ".jpg", ".jpeg", ".gif", ".pkg", ".dmg", ".zip"}:
        # pkg: try xar/strings for text clues
        if ext == ".pkg":
            strings = re.findall(rb"[\x20-\x7e]{8,}", data)
            body = "\n".join(x.decode("ascii", "ignore") for x in strings[:1200])
            outp.write_text(
                f"[pkg binary size={len(data)}]\n--- strings ---\n{body}\n",
                encoding="utf-8",
            )
            meta["note"] = "pkg_strings"
            meta["text_chars"] = len(body)
        else:
            outp.write_text(
                f"[binary skipped name={name} size={len(data)}]\n", encoding="utf-8"
            )
            meta["note"] = "binary_skipped"
    else:
        try:
            s = data.decode("utf-8")
            outp.write_text(s, encoding="utf-8")
            meta["text_chars"] = len(s)
        except Exception:
            outp.write_text(f"[binary/unknown {len(data)} bytes]\n", encoding="utf-8")
            meta["note"] = "binary_unknown"
    return meta


def crawl_github_folder(
    owner: str,
    repo: str,
    path: str,
    out: Path,
    ref: str = "master",
) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    raw = out / "raw"
    text = out / "text"
    raw.mkdir(exist_ok=True)
    text.mkdir(exist_ok=True)
    logf = out / "spider.log"
    enc_path = urllib.parse.quote(path, safe="/")
    api = f"https://api.github.com/repos/{owner}/{repo}/contents/{enc_path}?ref={ref}"
    log(f"list {api}", logf)
    listing = fetch_json(api)
    if isinstance(listing, dict) and listing.get("message"):
        raise RuntimeError(listing.get("message"))
    if not isinstance(listing, list):
        raise RuntimeError("expected directory listing")

    manifest = []
    for item in listing:
        name = item["name"]
        typ = item.get("type")
        sha = item.get("sha")
        size = item.get("size")
        entry = {
            "name": name,
            "type": typ,
            "size": size,
            "sha": sha,
            "html_url": item.get("html_url"),
        }
        if typ != "file":
            manifest.append(entry)
            continue
        log(f"get {name} sha={sha}", logf)
        data = None
        err = None
        # 1) blob API / gh
        try:
            data = gh_blob(owner, repo, sha)
        except Exception as e:
            err = e
        # 2) download_url
        if data is None and item.get("download_url"):
            try:
                data = fetch_bytes(item["download_url"], timeout=90)
            except Exception as e:
                err = e
        if data is None:
            entry["error"] = str(err)
            manifest.append(entry)
            log(f"FAIL {name}: {err}", logf)
            continue
        (raw / name).write_bytes(data)
        entry["saved_bytes"] = len(data)
        meta = extract_text(name, data, text / f"{name}.txt")
        entry.update(meta)
        manifest.append(entry)
        log(f"ok {name} bytes={len(data)}", logf)

    (out / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (out / "file_list.txt").write_text(
        "\n".join(m["name"] for m in manifest) + "\n", encoding="utf-8"
    )
    return out


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--owner", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--path", required=True)
    ap.add_argument("--ref", default="master")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    crawl_github_folder(args.owner, args.repo, args.path, Path(args.out), args.ref)
    print("DONE", args.out)
