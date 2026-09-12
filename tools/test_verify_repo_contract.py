#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_repo.py 合同测试（真实最小仓库 fixture，不依赖大 deb / 不联网）。

覆盖：
  1. 健康 repo → exit 0 / CHECKED=1 / FAILS=NONE / RELEASE_FILES_VERIFIED
  2. 篡改 deb 字节（SHA/Size 不再匹配）→ 一行式 MISMATCH / exit 1
  3. 删除 deb → 一行式 MISSING / exit 1
  4. Packages 里 Size 非数字（坏记录）→ 一行式 BAD_SIZE / 无 traceback / exit 1
  5. 目录冒充 deb → 一行式 MISSING / 无 traceback / exit 1
  6. Release 记录的 Packages 哈希与实体不符 → RELEASE_MISMATCH / exit 1
  7. 完全缺 dists（缺文件）→ 一行式 missing / 无 traceback / exit 1

运行：python3 tools/test_verify_repo_contract.py
（本仓合同脚本均为直跑脚本形式，非 unittest.TestCase）
"""
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(ROOT, "tools", "ziyan_apt", "verify_repo.py")
TMP = "/tmp/zy_verify_repo_contract"
REPO = os.path.join(TMP, "repo")

FAILURES = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else " :: " + str(detail)))
    if not cond:
        FAILURES.append(name)


def write(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if isinstance(body, bytes):
        with open(path, "wb") as fh:
            fh.write(body)
    else:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)


def sha256_bytes(body):
    return hashlib.sha256(body).hexdigest()


DEB_REL = "pool/main/z/ziyan/pkg_iphoneos-arm.deb"
DEB_BODY = b"!<arch>\n" + b"\x00" * 512


def build_repo(size_field=None):
    """重建最小 repo；size_field 可覆盖 Packages 里的 Size 行（坏记录用例）。"""
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(REPO, exist_ok=True)
    write(os.path.join(REPO, DEB_REL), DEB_BODY)
    size_line = "Size: %s" % (size_field if size_field is not None else len(DEB_BODY))
    pkg = (
        "Package: com.ziyan.ziyan\n"
        "Version: 0.0.92-verify-contract\n"
        "Architecture: iphoneos-arm\n"
        "Maintainer: ZiYan\n"
        "Depends: firmware (>= 13.0)\n"
        "Section: Utilities\n"
        "Filename: %s\n"
        "%s\n"
        "SHA256: %s\n"
        "Description: verify_repo contract fixture\n"
    ) % (DEB_REL, size_line, sha256_bytes(DEB_BODY))
    arm_pkgs = os.path.join(REPO, "dists/stable/main/binary-iphoneos-arm/Packages")
    arm64_pkgs = os.path.join(REPO, "dists/stable/main/binary-iphoneos-arm64/Packages")
    write(arm_pkgs, pkg + "\n")
    write(arm64_pkgs, "")
    lines = []
    for rel, p in (("main/binary-iphoneos-arm/Packages", arm_pkgs),
                   ("main/binary-iphoneos-arm64/Packages", arm64_pkgs)):
        body = open(p, "rb").read()
        lines.append(" %s %d %s" % (hashlib.sha256(body).hexdigest(), len(body), rel))
    release = (
        "Origin: ZiYan\nLabel: ZiYan\nSuite: stable\nCodename: stable\n"
        "Architectures: iphoneos-arm iphoneos-arm64\nComponents: main\n"
        "Date: fixture\nSHA256:\n" + "\n".join(lines) + "\n"
    )
    write(os.path.join(REPO, "dists/stable/Release"), release)
    write(os.path.join(REPO, "dists/stable/InRelease"), "fixture clearsign placeholder\n")
    write(os.path.join(REPO, "dists/stable/Release.gpg"), b"\x00fixture")


def run_verify(repo=REPO):
    proc = subprocess.run([sys.executable, VERIFY, repo],
                          capture_output=True, text=True, timeout=60)
    return proc.returncode, proc.stdout, proc.stderr


def main():
    # 1) 健康 repo
    build_repo()
    rc, out, err = run_verify()
    check("健康 repo exit=0", rc == 0, "rc=%s err=%s" % (rc, err[-200:]))
    check("健康 repo CHECKED=1", "CHECKED=1" in out, out)
    check("健康 repo FAILS=NONE", "FAILS=NONE" in out, out)
    check("健康 repo RELEASE_FILES_VERIFIED", "RELEASE_FILES_VERIFIED" in out, out)
    check("健康 repo SIGNED=True/INRELEASE=True",
          "SIGNED=True" in out and "INRELEASE=True" in out, out)

    # 2) 篡改 deb → MISMATCH
    build_repo()
    with open(os.path.join(REPO, DEB_REL), "ab") as fh:
        fh.write(b"x")
    rc, out, err = run_verify()
    check("篡改 deb exit=1", rc == 1, "rc=%s" % rc)
    check("篡改 deb MISMATCH", "MISMATCH %s" % DEB_REL in out, out)

    # 3) 删除 deb → MISSING
    build_repo()
    os.remove(os.path.join(REPO, DEB_REL))
    rc, out, err = run_verify()
    check("删除 deb exit=1", rc == 1, "rc=%s" % rc)
    check("删除 deb MISSING", "MISSING %s" % DEB_REL in out, out)

    # 4) 坏记录（Size 非数字）→ 一行式 BAD_SIZE，无 traceback
    build_repo(size_field="abc")
    rc, out, err = run_verify()
    check("坏记录 exit=1", rc == 1, "rc=%s" % rc)
    check("坏记录 BAD_SIZE 一行式", "BAD_SIZE %s: 'abc'" % DEB_REL in out, out)
    check("坏记录 无 traceback", "Traceback" not in err and "Traceback" not in out, err[-300:])

    # 5) 目录冒充 deb → MISSING，无 traceback
    build_repo()
    os.remove(os.path.join(REPO, DEB_REL))
    os.makedirs(os.path.join(REPO, DEB_REL))
    rc, out, err = run_verify()
    check("目录冒充 deb exit=1", rc == 1, "rc=%s" % rc)
    check("目录冒充 deb MISSING", "MISSING %s" % DEB_REL in out, out)
    check("目录冒充 deb 无 traceback", "Traceback" not in err, err[-300:])

    # 6) Release 哈希与实际不符 → RELEASE_MISMATCH
    build_repo()
    with open(os.path.join(REPO, "dists/stable/main/binary-iphoneos-arm64/Packages"), "w") as fh:
        fh.write("tampered\n")
    rc, out, err = run_verify()
    check("Release 哈希失配 exit=1", rc == 1, "rc=%s" % rc)
    check("Release 哈希失配 RELEASE_MISMATCH",
          "RELEASE_MISMATCH main/binary-iphoneos-arm64/Packages" in out, out)

    # 7) 完全缺 dists → 一行式 missing / 无 traceback
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(REPO, exist_ok=True)
    rc, out, err = run_verify()
    check("缺 dists exit=1", rc == 1, "rc=%s" % rc)
    check("缺 dists 一行式 missing", "missing Release" in out and "missing " in out, out)
    check("缺 dists 无 traceback", "Traceback" not in err, err[-300:])

    if FAILURES:
        print("RESULT=FAIL n=" + str(len(FAILURES)))
        return 1
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
