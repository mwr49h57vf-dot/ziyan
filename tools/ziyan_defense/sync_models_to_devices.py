#!/usr/bin/env python3
"""将 vendor/hf_models 三套权重同步到双机 Media/ZiYan/models/（阶段6）。"""
from __future__ import annotations
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
SRC = ROOT / "vendor" / "hf_models"
PASS = os.environ.get("ZIYAN_SSH_PASS", "alpine")
LOG = ROOT / "tmp_shots" / "PHASE763R8" / "hf_model_sync.log"

DEVICES = [
    ("166", "192.168.31.166"),
    ("53", "192.168.31.53"),
]

REPOS = [
    "ynyg__Unified_Prompt_Guard",
    "vincentoh__jailbreak-detector-v5",
    "llm-semantic-router__mmbert-jailbreak-detector-merged",
]


def run(cmd: list[str], t: int = 7200) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=t)


def ssh(ip: str, cmd: str, t: int = 60) -> str:
    r = run(
        [
            "sshpass",
            "-p",
            PASS,
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "ConnectTimeout=15",
            f"root@{ip}",
            cmd,
        ],
        t=t,
    )
    return (r.stdout or "") + (r.stderr or "")


def main() -> int:
    lines: list[str] = []
    if not SRC.is_dir():
        print("MISSING", SRC)
        return 2

    # 刷新本地清单
    man = []
    for repo in REPOS:
        d = SRC / repo
        total = 0
        files = []
        if d.is_dir():
            for p in sorted(d.rglob("*")):
                if p.is_file() and ".cache" not in p.parts:
                    sz = p.stat().st_size
                    total += sz
                    files.append(f"{p.relative_to(SRC)}\t{sz}")
        man.append(f"REPO {repo} bytes={total} files={len(files)}")
        print(man[-1], flush=True)
    (SRC / "MANIFEST.txt").write_text("\n".join(man + [""] + files) if False else "\n".join(man) + "\n", encoding="utf-8")
    # full manifest
    all_lines = list(man)
    for repo in REPOS:
        d = SRC / repo
        for p in sorted(d.rglob("*")):
            if p.is_file() and ".cache" not in p.parts:
                all_lines.append(f"{p.relative_to(SRC)}\t{p.stat().st_size}")
    (SRC / "MANIFEST.txt").write_text("\n".join(all_lines) + "\n", encoding="utf-8")

    ok_all = True
    for name, ip in DEVICES:
        dest = "/var/mobile/Media/ZiYan/models"
        print(f"==== SYNC .{name} {ip} → {dest} ====", flush=True)
        lines.append(f"SYNC .{name} begin")
        ssh(ip, f"mkdir -p {dest} && chown -R mobile:mobile /var/mobile/Media/ZiYan")
        # rsync 三目录 + MANIFEST（排除 .cache）
        # 真机无 rsync：用 tar 管道（排除 .cache）
        for repo in REPOS:
            src_path = SRC / repo
            if not src_path.is_dir():
                lines.append(f"FAIL .{name} missing {repo}")
                ok_all = False
                continue
            print(f"TAR .{name} {repo}", flush=True)
            tar = subprocess.Popen(
                ["tar", "cf", "-", "--exclude=.cache", "-C", str(SRC), repo],
                stdout=subprocess.PIPE,
            )
            r = subprocess.run(
                [
                    "sshpass",
                    "-p",
                    PASS,
                    "ssh",
                    "-o",
                    "StrictHostKeyChecking=no",
                    "-o",
                    "ConnectTimeout=20",
                    f"root@{ip}",
                    f"cd {dest} && tar xf - && chown -R mobile:mobile {repo}",
                ],
                stdin=tar.stdout,
                capture_output=True,
                text=True,
                timeout=7200,
            )
            if tar.stdout:
                tar.stdout.close()
            tar.wait()
            if r.returncode != 0:
                print((r.stderr or "")[-1500:], flush=True)
                lines.append(f"FAIL .{name} {repo} rc={r.returncode}")
                ok_all = False
            else:
                lines.append(f"OK .{name} {repo}")
                print(f"OK .{name} {repo}", flush=True)
        # MANIFEST
        man = SRC / "MANIFEST.txt"
        if man.exists():
            subprocess.run(
                [
                    "sshpass",
                    "-p",
                    PASS,
                    "scp",
                    "-o",
                    "StrictHostKeyChecking=no",
                    str(man),
                    f"root@{ip}:{dest}/MANIFEST.txt",
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )

        # 就绪标记 + 权限
        ready = (
            "stage=6\n"
            "models=3\n"
            "repos=ynyg__Unified_Prompt_Guard,vincentoh__jailbreak-detector-v5,"
            "llm-semantic-router__mmbert-jailbreak-detector-merged\n"
            "note=heuristic_runtime_plus_weight_presence\n"
        )
        ssh(
            ip,
            f"printf '%s' '{ready}' > {dest}/MODELS_READY.txt; "
            f"chown -R mobile:mobile {dest}; "
            f"du -sh {dest}/* 2>/dev/null; "
            f"test -f {dest}/ynyg__Unified_Prompt_Guard/model.safetensors && echo W1=OK; "
            f"test -f {dest}/vincentoh__jailbreak-detector-v5/adapter_model.safetensors && echo W2=OK; "
            f"test -f {dest}/llm-semantic-router__mmbert-jailbreak-detector-merged/model.safetensors && echo W3=OK",
            t=120,
        )
        verify = ssh(
            ip,
            f"du -sh {dest}; ls {dest}; "
            f"wc -c {dest}/ynyg__Unified_Prompt_Guard/model.safetensors "
            f"{dest}/vincentoh__jailbreak-detector-v5/adapter_model.safetensors "
            f"{dest}/llm-semantic-router__mmbert-jailbreak-detector-merged/model.safetensors 2>/dev/null",
            t=120,
        )
        print(verify, flush=True)
        lines.append(f"VERIFY .{name}\n{verify}")

    LOG.parent.mkdir(parents=True, exist_ok=True)
    LOG.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("wrote", LOG)
    return 0 if ok_all else 1


if __name__ == "__main__":
    raise SystemExit(main())
