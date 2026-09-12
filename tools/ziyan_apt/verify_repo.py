#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""APT 仓库本地校验：Packages 每条 Filename 存在 + SHA256/Size 与实体一致 + Release 段一致。

用法：python3 tools/ziyan_apt/verify_repo.py [repo_dir]
"""
import hashlib
import os
import re
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(repo):
    fails = []
    checked = 0
    for arch in ("iphoneos-arm", "iphoneos-arm64"):
        pk = os.path.join(repo, "dists/stable/main", "binary-%s" % arch, "Packages")
        if not os.path.exists(pk):
            fails.append("missing %s" % pk)
            continue
        try:
            txt = open(pk, encoding="utf-8").read()
        except OSError as exc:
            fails.append("UNREADABLE %s: %s" % (pk, exc))
            continue
        for block in [b for b in txt.split("\n\n") if b.strip()]:
            try:
                # Description 是唯一的多行字段，取其之前的部分做字段解析
                head = block.split("\nDescription:", 1)[0]
                fields = dict(re.findall(r"^([A-Za-z0-9-]+): (.*)$", head, re.M))
                if not fields.get("Description"):
                    m = re.search(r"^Description: (.*)$", block, re.M)
                    if m:
                        fields["Description"] = m.group(1)
                fname = fields.get("Filename")
                want = fields.get("SHA256")
                if not fname or not want:
                    fails.append("incomplete record in %s: %s"
                                 % (pk, block[:60].replace("\n", " ")))
                    continue
                try:
                    size = int(fields.get("Size", 0))
                except (TypeError, ValueError):
                    fails.append("BAD_SIZE %s: %r" % (fname, fields.get("Size")))
                    continue
                path = os.path.join(repo, fname)
                # 用 isfile：目录冒充 deb 时也走一行式 MISSING，不再 traceback
                if not os.path.isfile(path):
                    fails.append("MISSING %s" % fname)
                    continue
                try:
                    got = sha256(path)
                    real_size = os.path.getsize(path)
                except OSError as exc:
                    fails.append("UNREADABLE %s: %s" % (fname, exc))
                    continue
                ok = (got == want) and (real_size == size)
                checked += 1
                print("CHECK %s %s arch=%s sha_match=%s size_match=%s"
                      % (fields.get("Package"), fields.get("Version"), arch, got == want, real_size == size))
                if not ok:
                    fails.append("MISMATCH %s" % fname)
                if "Depends" not in fields:
                    fails.append("NO_DEPENDS %s" % fname)
            except Exception as exc:
                # 防御：坏记录一律一行式错误，绝不 traceback
                fails.append("BAD_RECORD %s: %s" % (pk, repr(exc)))
    rel_path = os.path.join(repo, "dists/stable/Release")
    if not os.path.exists(rel_path):
        fails.append("missing Release")
    else:
        try:
            rel = open(rel_path, encoding="utf-8").read()
        except OSError as exc:
            fails.append("UNREADABLE %s: %s" % (rel_path, exc))
            rel = None
        if rel is not None:
            for h, size, relpath in re.findall(r" ([\da-f]{64}) +(\d+) +(\S+)", rel):
                p = os.path.join(repo, "dists/stable", relpath)
                try:
                    if not os.path.isfile(p):
                        fails.append("RELEASE_MISSING %s" % relpath)
                    elif sha256(p) != h or os.path.getsize(p) != int(size):
                        fails.append("RELEASE_MISMATCH %s" % relpath)
                except (OSError, ValueError) as exc:
                    fails.append("RELEASE_BAD %s: %s" % (relpath, exc))
            print("RELEASE_FILES_VERIFIED")
    inrel = os.path.join(repo, "dists/stable/InRelease")
    det = os.path.join(repo, "dists/stable/Release.gpg")
    signed = os.path.exists(det)
    has_inrelease = os.path.exists(inrel)
    print("SIGNED=%s (Release.gpg detached)" % signed)
    print("INRELEASE=%s (clearsign)" % has_inrelease)
    print("CHECKED=%d" % checked)
    print("FAILS=%s" % (fails or "NONE"))
    return 1 if fails else 0


if __name__ == "__main__":
    repo = sys.argv[1] if len(sys.argv) > 1 else "ziyan_apt_repo"
    sys.exit(main(repo))
