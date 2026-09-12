#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_repo.py 合同测试 —— 对齐 develop 的严格契约（2026-09-12 合并后重写）。

本文件原为 main 分支宽松契约的用例（要求 `SIGNED=True`/`INRELEASE=True`/`BAD_SIZE`
且不带 keyring 也要 exit 0）。合并 develop 的 #14 APT 校验后，verify_repo 改为
「要求包身份/数量/双架构/索引/Release 哈希，并用明确可信公钥环实际验签」的严格契约，
原用例已与新契约互斥，故按新契约逐条重写。

覆盖（真实最小仓库 fixture，不依赖大 deb / 不联网）：
  1. 结构健全 + 提供 keyring → 结构化校验全过，唯一失败项是签名（本机无 gpgv）
  2. Packages.gz 与 Packages 不一致 → COMPRESSED_INDEX_MISMATCH / exit 1
  3. 篡改 deb 字节 → PACKAGE_MISMATCH / exit 1
  4. Packages 里 Size 非数字（坏记录）→ INVALID_PACKAGE_SIZE / 无 traceback
  5. 删除 deb → exit 1 / 无 traceback
  6. 目录冒充 deb → exit 1 / 无 traceback
  7. 记录数与期望不符 → PACKAGE_COUNT / exit 1
  8. Release 记录的 Packages 哈希与实体不符 → RELEASE_MISMATCH / exit 1
  9. 完全缺 dists → exit 1 / 无 traceback
 10. 不给 --trusted-keyring → TRUST_MATERIAL_REQUIRED / exit 1

加密验签（SIGNATURE_VERIFIED / SIGNATURE_INVALID / INRELEASE_CONTENT_MISMATCH）
需要真实 gpgv，由 tools/test_build_install_repairs.py 在 gpgv 存在时覆盖，
本机无 gpgv 时那边同样显式 skipTest。本文件不重复造轮子，只显式记录 SKIP。

运行：python3 tools/test_verify_repo_contract.py
（本仓合同脚本均为直跑脚本形式，非 unittest.TestCase）
"""
import ast
import gzip
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(ROOT, "tools", "ziyan_apt", "verify_repo.py")
TMP = "/tmp/zy_verify_repo_contract"
REPO = os.path.join(TMP, "repo")
KEYRING = os.path.join(TMP, "operator-selected.gpg")

ARCHITECTURES = ("iphoneos-arm", "iphoneos-arm64")
DEB_REL = {arch: "pool/main/z/ziyan/pkg_%s.deb" % arch for arch in ARCHITECTURES}
DEB_BODY = {arch: b"!<arch>\n" + bytes([i]) * 512 for i, arch in enumerate(ARCHITECTURES, 1)}

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
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)


def sha256_bytes(body):
    return hashlib.sha256(body).hexdigest()


def build_repo(size_field=None):
    """重建最小 repo；size_field 可覆盖 Packages 里的 Size 行（坏记录用例）。

    严格契约要求：每个架构记录数 == expected_count_per_arch、同时存在 Packages 与
    Packages.gz 且内容一致、Release 覆盖两个索引的哈希、Date 必须带时区。
    """
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(REPO, exist_ok=True)
    hashes = []
    for arch in ARCHITECTURES:
        body = DEB_BODY[arch]
        write(os.path.join(REPO, DEB_REL[arch]), body)
        size = size_field if size_field is not None else len(body)
        record = (
            "Package: com.ziyan.ziyan\n"
            "Version: 0.0.92-verify-contract\n"
            "Architecture: %s\n"
            "Maintainer: ZiYan\n"
            "Depends: firmware (>= 13.0)\n"
            "Section: Utilities\n"
            "Filename: %s\n"
            "Size: %s\n"
            "SHA256: %s\n"
            "Description: verify_repo contract fixture\n"
        ) % (arch, DEB_REL[arch], size, sha256_bytes(body))
        directory = os.path.join(REPO, "dists/stable/main/binary-" + arch)
        index = os.path.join(directory, "Packages")
        write(index, record + "\n")
        write(index + ".gz", gzip.compress(open(index, "rb").read()))
        for name in ("Packages", "Packages.gz"):
            path = os.path.join(directory, name)
            payload = open(path, "rb").read()
            hashes.append(" %s %d main/binary-%s/%s"
                          % (sha256_bytes(payload), len(payload), arch, name))
    write(os.path.join(REPO, "dists/stable/Release"),
          "Origin: ZiYan\nLabel: ZiYan\nSuite: stable\nCodename: stable\n"
          "Architectures: %s\nComponents: main\n"
          "Date: Sat, 12 Sep 2026 14:00:00 +0800\nSHA256:\n%s\n"
          % (" ".join(ARCHITECTURES), "\n".join(hashes)))
    # 真实签名无法在本机生成（Mac 无 gpg，真签名走 .101 的 sign_native.sh）。
    # 这里只满足「签名文件存在」这一结构前提；内容是否可验由 gpgv 用例负责。
    write(os.path.join(REPO, "dists/stable/InRelease"), "fixture clearsign placeholder\n")
    write(os.path.join(REPO, "dists/stable/Release.gpg"), b"\x00fixture")
    # keyring 只需存在且非空：本机无 gpgv 时验签必失败，用哪把钥匙都不改变结论。
    write(KEYRING, b"\x00fixture-operator-keyring")


def run_verify(*extra):
    proc = subprocess.run([sys.executable, VERIFY, REPO, "--trusted-keyring", KEYRING, *extra],
                          capture_output=True, text=True, timeout=60)
    return proc.returncode, proc.stdout, proc.stderr


def recorded_fails(out):
    """取回 verify_repo 打印的 FAILS 列表（ast 安全求值，不做 eval）。"""
    if "FAILS=NONE" in out:
        return []
    tail = out.split("FAILS=", 1)[1].strip().splitlines()[0]
    return ast.literal_eval(tail)


def main():
    gpgv = shutil.which("gpgv")

    # 1) 结构健全：结构化校验必须全过，唯一失败项只能是签名（本机缺 gpgv）
    build_repo()
    rc, out, err = run_verify()
    check("健全 repo CHECKED=2", "CHECKED=2" in out, out)
    check("健全 repo RELEASE_FILES_VERIFIED=4", "RELEASE_FILES_VERIFIED=4" in out, out)
    fails = recorded_fails(out)
    if gpgv:
        check("健全 repo exit=0", rc == 0, "rc=%s fails=%s" % (rc, fails))
    else:
        check("健全 repo 唯一失败项是签名(缺 gpgv)", rc == 1 and len(fails) == 1
              and "gpgv" in fails[0].lower(), "rc=%s fails=%s" % (rc, fails))
        print("SKIP 加密验签：本机无 gpgv；由 tools/test_build_install_repairs.py "
              "在 gpgv 存在时覆盖（那边无 gpgv 同样 skipTest）")
    check("健全 repo 无 traceback", "Traceback" not in err and "Traceback" not in out,
          err[-300:])

    # 2) Packages.gz 与 Packages 不一致 → COMPRESSED_INDEX_MISMATCH
    build_repo()
    with open(os.path.join(REPO, "dists/stable/main/binary-iphoneos-arm/Packages.gz"), "wb") as fh:
        fh.write(gzip.compress(b"different index"))
    rc, out, err = run_verify()
    check("压索引不一致 exit=1", rc == 1, "rc=%s" % rc)
    check("压索引不一致 COMPRESSED_INDEX_MISMATCH", "COMPRESSED_INDEX_MISMATCH" in out, out)

    # 3) 篡改 deb → PACKAGE_MISMATCH
    build_repo()
    with open(os.path.join(REPO, DEB_REL["iphoneos-arm"]), "ab") as fh:
        fh.write(b"x")
    rc, out, err = run_verify()
    check("篡改 deb exit=1", rc == 1, "rc=%s" % rc)
    check("篡改 deb PACKAGE_MISMATCH", "PACKAGE_MISMATCH %s" % DEB_REL["iphoneos-arm"] in out, out)

    # 4) 坏记录（Size 非数字）→ INVALID_PACKAGE_SIZE，无 traceback
    build_repo(size_field="abc")
    rc, out, err = run_verify()
    check("坏记录 exit=1", rc == 1, "rc=%s" % rc)
    check("坏记录 INVALID_PACKAGE_SIZE", "INVALID_PACKAGE_SIZE" in out, out)
    check("坏记录 无 traceback", "Traceback" not in err and "Traceback" not in out, err[-300:])

    # 5) 删除 deb → exit 1，无 traceback
    build_repo()
    os.remove(os.path.join(REPO, DEB_REL["iphoneos-arm"]))
    rc, out, err = run_verify()
    check("删除 deb exit=1", rc == 1, "rc=%s" % rc)
    check("删除 deb 报出缺失路径", DEB_REL["iphoneos-arm"] in out, out)
    check("删除 deb 无 traceback", "Traceback" not in err, err[-300:])

    # 6) 目录冒充 deb → exit 1，无 traceback
    build_repo()
    os.remove(os.path.join(REPO, DEB_REL["iphoneos-arm"]))
    os.makedirs(os.path.join(REPO, DEB_REL["iphoneos-arm"]))
    rc, out, err = run_verify()
    check("目录冒充 deb exit=1", rc == 1, "rc=%s" % rc)
    check("目录冒充 deb 无 traceback", "Traceback" not in err, err[-300:])

    # 7) 记录数与期望不符 → PACKAGE_COUNT
    build_repo()
    rc, out, err = run_verify("--expected-count-per-arch", "2")
    check("记录数不符 exit=1", rc == 1, "rc=%s" % rc)
    check("记录数不符 PACKAGE_COUNT", "PACKAGE_COUNT" in out, out)

    # 8) Release 哈希与实际不符 → RELEASE_MISMATCH
    build_repo()
    with open(os.path.join(REPO, "dists/stable/main/binary-iphoneos-arm64/Packages"), "wb") as fh:
        fh.write(b"tampered\n")
    rc, out, err = run_verify()
    check("Release 哈希失配 exit=1", rc == 1, "rc=%s" % rc)
    check("Release 哈希失配 RELEASE_MISMATCH",
          "RELEASE_MISMATCH main/binary-iphoneos-arm64/Packages" in out, out)

    # 9) 完全缺 dists → exit 1，无 traceback
    # 严格契约对缺失索引抛的是 errno 文本（定位到缺失的 dists 前缀），
    # 不再是 main 宽松版的 `missing Release` 一行式。
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(REPO, exist_ok=True)
    write(KEYRING, b"\x00fixture-operator-keyring")
    rc, out, err = run_verify()
    check("缺 dists exit=1", rc == 1, "rc=%s" % rc)
    check("缺 dists 报出缺失的 dists 路径", "repo/dists" in out, out)
    check("缺 dists SIGNATURE_MISSING", "SIGNATURE_MISSING" in out, out)
    check("缺 dists 无 traceback", "Traceback" not in err, err[-300:])

    # 10) 不给 --trusted-keyring → TRUST_MATERIAL_REQUIRED
    build_repo()
    proc = subprocess.run([sys.executable, VERIFY, REPO], capture_output=True, text=True, timeout=60)
    check("无 keyring exit=1", proc.returncode == 1, "rc=%s" % proc.returncode)
    check("无 keyring TRUST_MATERIAL_REQUIRED", "TRUST_MATERIAL_REQUIRED" in proc.stdout,
          proc.stdout)

    if FAILURES:
        print("RESULT=FAIL n=" + str(len(FAILURES)))
        return 1
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
