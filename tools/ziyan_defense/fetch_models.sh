#!/bin/bash
# 用户授权后拉取 HF 模型
exec python3 "$(dirname "$0")/fetch_hf_models.py" "$@"
