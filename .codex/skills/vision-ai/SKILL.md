---
name: vision-ai
description: "Analyze a local image or screenshot (describe, OCR, objects). Use when the user asks to 看图, 识别图片, 描述截图, OCR a PNG/JPG, or vision-ai. Script is vision_ai.py. Do not pip install torch or download local models unless the user explicitly asks."
metadata:
  source: "/Users/mac/Desktop/skills/03"
---

# Vision AI

Desktop source: `/Users/mac/Desktop/skills/03`.

1. Confirm the image absolute path.
2. Try:

```bash
python3 /Users/mac/.codex/skills/vision-ai/vision_ai.py
```

3. The script imports `llm_config` from the parent of the `03` folder. That file is currently missing at `/Users/mac/Desktop/skills/llm_config.py`. If import fails, stop and report the missing file. Do not download Hugging Face weights or `pip install torch`.
