#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ZiYan APT 仓库生成器（纯 Python，无 dpkg-deb 依赖）。

产物结构（apt.ziyan.com 可原样上线）：
  <repo>/dists/stable/Release
  <repo>/dists/stable/InRelease        （仅当 --gpg-key 可用）
  <repo>/dists/stable/main/binary-iphoneos-arm/Packages
  <repo>/dists/stable/main/binary-iphoneos-arm64/Packages
  <repo>/pool/main/z/ziyan/<deb>

用法：
  python3 tools/ziyan_apt/build_repo.py --repo ziyan_apt_repo \
      packages/com.ziyan.ziyan_...-158-1+debug_iphoneos-arm.deb \
      packages/com.ziyan.ziyan_...-158-2+debug_iphoneos-arm64.deb
"""
import argparse
import gzip
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time


def read_ar_entries(path):
    """极简 ar 解析：返回 [(name, bytes)]，兼容 GNU/BSD tar 里的 ar。"""
    with open(path, "rb") as fh:
        magic = fh.read(8)
        if magic != b"!<arch>\n":
            raise SystemExit(f"not an ar archive: {path}")
        entries = []
        while True:
            header = fh.read(60)
            if len(header) < 60:
                break
            name = header[0:16].decode("ascii", "replace").strip()
            size = int(header[48:58].decode("ascii", "replace").strip())
            data = fh.read(size)
            if size % 2:
                fh.read(1)
            entries.append((name.rstrip("/"), data))
    return entries


def parse_control(deb_path):
    entries = dict(read_ar_entries(deb_path))
    ctl_name = next((n for n in entries if n.startswith("control.tar")), None)
    if not ctl_name:
        raise SystemExit(f"no control.tar in {deb_path}")
    raw = entries[ctl_name]
    mode = "r:gz" if ctl_name.endswith(".gz") else ("r:xz" if ctl_name.endswith(".xz") else "r:")
    with tarfile.open(fileobj=io.BytesIO(raw), mode=mode) as tf:
        member = next((m for m in tf.getmembers() if m.name.lstrip("./") == "control"), None)
        if not member:
            raise SystemExit(f"no control file in {deb_path}")
        body = tf.extractfile(member).read().decode("utf-8")
    fields = {}
    order = []
    for line in body.splitlines():
        m = re.match(r"^([A-Za-z0-9-]+):\s?(.*)$", line)
        if m:
            fields[m.group(1)] = m.group(2)
            order.append(m.group(1))
    return fields, order


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build(repo, debs, suite="stable", component="main", gpg_key=None):
    pool = os.path.join(repo, "pool", "main", "z", "ziyan")
    os.makedirs(pool, exist_ok=True)
    by_arch = {}
    records = []
    for deb in debs:
        fields, order = parse_control(deb)
        arch = fields.get("Architecture", "iphoneos-arm")
        fname = os.path.basename(deb)
        dest = os.path.join(pool, fname)
        if os.path.abspath(deb) != os.path.abspath(dest):
            shutil.copy2(deb, dest)
        size = os.path.getsize(dest)
        rel = os.path.relpath(dest, repo).replace(os.sep, "/")
        rec = {
            "Package": fields.get("Package", "com.ziyan.ziyan"),
            "Version": fields.get("Version", "0"),
            "Architecture": arch,
            "Maintainer": fields.get("Maintainer", "ZiYan"),
            "Installed-Size": fields.get("Installed-Size", "0"),
            "Depends": fields.get("Depends", ""),
            "Section": fields.get("Section", "Utilities"),
            "Description": fields.get("Description", "ZiYan automation"),
            "Author": fields.get("Author", "ZiYan"),
            "Filename": rel,
            "Size": str(size),
            "SHA256": sha256_file(dest),
            "MD5sum": md5_file(dest),
        }
        records.append(rec)
        by_arch.setdefault(arch, []).append(rec)

    packages_all = {}
    for arch, recs in sorted(by_arch.items()):
        lines = []
        for rec in sorted(recs, key=lambda r: r["Version"]):
            for key in ("Package", "Version", "Architecture", "Maintainer", "Installed-Size",
                        "Depends", "Section", "Author", "Filename", "Size", "MD5sum", "SHA256",
                        "Description"):
                val = rec.get(key, "")
                if val:
                    lines.append(f"{key}: {val}")
            lines.append("")
        body = "\n".join(lines)
        pdir = os.path.join(repo, "dists", suite, component, f"binary-{arch}")
        os.makedirs(pdir, exist_ok=True)
        pkg_path = os.path.join(pdir, "Packages")
        with open(pkg_path, "w", encoding="utf-8") as fh:
            fh.write(body)
        with gzip.open(pkg_path + ".gz", "wb") as fh:
            fh.write(body.encode("utf-8"))
        packages_all[f"{component}/binary-{arch}/Packages"] = pkg_path

    # Release
    now = time.strftime("%a, %d %b %Y %H:%M:%S +0800", time.localtime())
    rel_lines = [
        f"Origin: ZiYan",
        f"Label: ZiYan",
        f"Suite: {suite}",
        f"Codename: {suite}",
        f"Architectures: {' '.join(sorted(by_arch))}",
        f"Components: {component}",
        f"Date: {now}",
        "Description: ZiYan automation engine (APT repository)",
    ]
    for label, fn in (("MD5Sum", md5_file), ("SHA256", sha256_file)):
        rel_lines.append(f"{label}:")
        for relpath, path in sorted(packages_all.items()):
            for suffix in ("", ".gz"):
                p = path + suffix
                if os.path.exists(p):
                    rd = os.path.relpath(p, os.path.join(repo, "dists", suite)).replace(os.sep, "/")
                    rel_lines.append(f" {fn(p)} {os.path.getsize(p):>16} {rd}")
    release_path = os.path.join(repo, "dists", suite, "Release")
    with open(release_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(rel_lines) + "\n")

    inrelease = None
    detached = None
    # 本地自签（pgpy，无需系统 gpg；明确记录为 LOCAL_SELF_SIGNED）
    try:
        import pgpy  # noqa
        from pgpy.constants import HashAlgorithm
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "ziyan_log_server"))
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "zy_log_server_sign",
            os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "ziyan_log_server", "server.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        release_path = os.path.join(repo, "dists", suite, "Release")
        with open(release_path, "rb") as fh:
            release_bytes = fh.read()
        b64 = mod._detached_sig_b64(release_bytes)
        if b64:
            import base64
            detached = os.path.join(repo, "dists", suite, "Release.gpg")
            with open(detached, "wb") as fh:
                fh.write(base64.b64decode(b64))
            print("LOCAL_SELF_SIGNED Release.gpg (NOT an official release key)")
    except Exception as exc:  # noqa
        print(f"LOCAL_SIGN_FAILED: {exc}")
    if gpg_key:
        try:
            subprocess.run(
                ["gpg", "--batch", "--yes", "--default-key", gpg_key,
                 "--clearsign", "-o", os.path.join(repo, "dists", suite, "InRelease"),
                 os.path.join(repo, "dists", suite, "Release")],
                check=True, capture_output=True)
            inrelease = os.path.join(repo, "dists", suite, "InRelease")
        except Exception as exc:  # noqa
            print(f"GPG_SIGN_FAILED: {exc}")
    write_root_index(repo, records, suite, component)
    return records, (inrelease or detached)


def write_root_index(repo, records, suite, component):
    """写仓库根 index.html。

    Cydia/Sileo 添加软件源时会先 GET 根 URL 判断该地址是否像一个软件源；
    GitHub Pages 在没有 index.html 时对 `/` 返回 404，界面因此报
    “未找到软件源 / 似乎不是有效的软件源”，即使 dists/stable/Release 完全正常。
    这里生成一个纯静态页面，既消除该误判，也给人一个可读的源首页。
    """
    rows = "\n".join(
        f"    <tr><td>{r['Package']}</td><td>{r['Version']}</td>"
        f"<td>{r['Architecture']}</td></tr>"
        for r in records
    ) or "    <tr><td colspan=\"3\">(no packages)</td></tr>"
    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ZiYan APT Repository</title>
<style>
body{{font:15px/1.6 -apple-system,system-ui,sans-serif;margin:2rem auto;max-width:44rem;padding:0 1rem;color:#222}}
h1{{font-size:1.5rem}} code{{background:#f2f2f7;padding:.1rem .3rem;border-radius:4px}}
table{{border-collapse:collapse;width:100%;margin-top:.5rem}}
th,td{{border:1px solid #ddd;padding:.4rem .6rem;text-align:left;font-size:.9rem}}
th{{background:#f7f7fa}}
</style>
</head>
<body>
<h1>ZiYan APT Repository</h1>
<p>在 Cydia / Sileo 中添加软件源：<code>https://apt.ziyanapp.top/</code></p>
<p>套件 <code>{suite}</code> · 组件 <code>{component}</code></p>
<table>
  <tr><th>Package</th><th>Version</th><th>Architecture</th></tr>
{rows}
</table>
<p><a href="ziyan-apt-key.asc">ziyan-apt-key.asc</a></p>
</body>
</html>
"""
    with open(os.path.join(repo, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(html)
    print("ROOT_INDEX index.html written (Cydia/Sileo root probe)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--suite", default="stable")
    ap.add_argument("--component", default="main")
    ap.add_argument("--gpg-key", default=None)
    ap.add_argument("debs", nargs="+")
    args = ap.parse_args()

    records, inrelease = build(args.repo, args.debs, args.suite, args.component, args.gpg_key)
    print(f"REPO={os.path.abspath(args.repo)}")
    for rec in records:
        print(f"REC {rec['Package']} {rec['Version']} {rec['Architecture']} "
              f"size={rec['Size']} sha256={rec['SHA256'][:16]}… file={rec['Filename']}")
    for root, _dirs, files in os.walk(os.path.join(args.repo, "dists")):
        for f in sorted(files):
            print("DIST", os.path.relpath(os.path.join(root, f), args.repo))
    print("SIGNED" if inrelease else "UNSIGNED (no gpg key)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
