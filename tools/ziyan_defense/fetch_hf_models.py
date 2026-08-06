#!/usr/bin/env python3
"""经用户授权：拉取 SECURITY_AI 指定的 3 个 HF 模型到本地 vendor/hf_models/。"""
from __future__ import annotations
import os
import sys
from pathlib import Path

ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
OUT = ROOT / "vendor" / "hf_models"
OUT.mkdir(parents=True, exist_ok=True)
LOG = ROOT / "tmp_shots" / "PHASE763R8" / "hf_model_fetch.log"

MODELS = [
    "ynyg/Unified_Prompt_Guard",
    "vincentoh/jailbreak-detector-v5",
    "llm-semantic-router/mmbert-jailbreak-detector-merged",
]

def main() -> int:
    import os
    # 国内镜像（用户已授权联网）
    os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        os.system(f"{sys.executable} -m pip install -q huggingface_hub")
        from huggingface_hub import snapshot_download

    lines = []
    for repo in MODELS:
        dest = OUT / repo.replace("/", "__")
        lines.append(f"FETCH {repo} → {dest}")
        print(lines[-1], flush=True)
        try:
            path = snapshot_download(
                repo_id=repo,
                local_dir=str(dest),
                local_dir_use_symlinks=False,
                resume_download=True,
            )
            # size
            total = 0
            for p in Path(path).rglob("*"):
                if p.is_file():
                    total += p.stat().st_size
            lines.append(f"OK {repo} bytes={total} path={path}")
            print(lines[-1], flush=True)
        except Exception as e:
            lines.append(f"FAIL {repo} err={e}")
            print(lines[-1], flush=True)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    LOG.write_text("\n".join(lines) + "\n", encoding="utf-8")
    # symlink/copy manifest for device sync
    manifest = OUT / "MANIFEST.txt"
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("wrote", LOG)
    return 0 if all(l.startswith("OK") or l.startswith("FETCH") for l in lines if l.startswith("OK") or l.startswith("FAIL")) and not any(l.startswith("FAIL") for l in lines) else 1

if __name__ == "__main__":
    raise SystemExit(main())
