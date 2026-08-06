#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ZiYan R8.4.2 — 从 Ai代码训练 提取业务流程色参（禁止拷贝 TSLib/ts.so）
输出：media_seed/knowledge/{index.json,KB.jsonl,families/*.json}
仅作结构/色参学习，生成脚本用 ZiYan 自有 API。
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRAIN = ROOT / "Ai代码训练"
OUT = ROOT / "media_seed" / "knowledge"

FAM = {
    "赤沙龙城": "cslc",
    "血战屠龙": "xztl",
    "新版血战": "xbxz",
    "圣戒信条": "sjxt",
    "怒剑传奇": "njcq",
    "龙界争霸": "ljzb",
}

PHASE_KW = {
    "login": ["登录", "账号", "密码", "免密", "游客", "隐私", "协议", "验证码", "公告", "维护", "掉线"],
    "server": ["区服", "服务器", "选服", "新开"],
    "role": ["角色", "选角", "创建角色", "角色选择", "角色界面"],
    "enter": ["进入游戏", "开始", "进游戏", "进入", "启动"],
    "battle": ["挂机", "挂图", "自动", "攻击", "技能", "战斗", "小助手", "大陆石", "安全区"],
    "popup": ["奖励", "升级", "活动", "关闭", "确定", "取消", "弹窗"],
}

OCR_HINTS = {
    "login": ["登录", "账号", "密码", "免密登录", "游客登录", "隐私", "同意"],
    "server": ["区服", "选择区服", "服务器"],
    "role": ["角色", "选择角色", "创建角色"],
    "enter": ["进入游戏", "开始", "进入"],
    "battle": ["挂机", "自动战斗", "攻击", "技能", "小助手"],
}

LABEL_PAT = re.compile(r'\["([^"]+)"\]\s*=\s*\{')
# {0xRGB, "off", x1,y1,x2,y2}
TUPLE_PAT = re.compile(
    r'\{(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\}'
)
# m_模糊多色 / findMultiColorInRegionFuzzy(0x, "off", deg, x1,y1,x2,y2)
CALL_PAT = re.compile(
    r'(?:m_模糊多色|findMultiColorInRegionFuzzy|d_多色坐标|d_多色)\s*\(\s*'
    r'(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)'
)
FN_PAT = re.compile(r'function\s+([A-Za-z_\u4e00-\u9fff]+)\s*\(')


def phase_of(label: str) -> str:
    for ph, kws in PHASE_KW.items():
        if any(k in label for k in kws):
            return ph
    return "main"


def extract_file(path: Path) -> list[dict]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    # 禁止解析/引用 TSLib.lua / ts.so 内容；只读业务 *.lua
    if path.name in ("TSLib.lua", "ts.so"):
        return []
    rows: list[dict] = []
    # table style
    for m in TUPLE_PAT.finditer(text):
        first, off, x1, y1, x2, y2 = m.groups()
        before = text[: m.start()]
        labs = list(LABEL_PAT.finditer(before))
        lab = labs[-1].group(1) if labs else "unknown"
        rows.append(
            {
                "label": lab,
                "phase": phase_of(lab),
                "first": first.lower(),
                "off": off,
                "degree": 85,
                "x1": int(x1),
                "y1": int(y1),
                "x2": int(x2),
                "y2": int(y2),
                "src": path.name,
                "via": "table",
            }
        )
    # call style (血战屠龙等)
    for m in CALL_PAT.finditer(text):
        first, off, deg, x1, y1, x2, y2 = m.groups()
        before = text[: m.start()]
        fns = list(FN_PAT.finditer(before))
        fn = fns[-1].group(1) if fns else "call"
        lab = fn
        # normalize common fn names
        if "进入" in fn:
            lab = "进入游戏"
        elif "大陆" in fn:
            lab = "大陆石"
        elif "安全" in fn:
            lab = "安全区"
        rows.append(
            {
                "label": lab,
                "phase": phase_of(lab + fn),
                "first": first.lower(),
                "off": off,
                "degree": int(deg),
                "x1": int(x1),
                "y1": int(y1),
                "x2": int(x2),
                "y2": int(y2),
                "src": path.name,
                "via": "call",
            }
        )
    return rows


def slim_colors(rows: list[dict], limit: int = 64) -> list[dict]:
    by: dict[str, list] = {}
    for r in rows:
        by.setdefault(r["label"], []).append(r)
    out = []
    # prefer phase-critical labels first
    priority = []
    rest = []
    for lab, arr in by.items():
        ph = arr[0]["phase"]
        (priority if ph in ("login", "server", "role", "enter", "battle") else rest).append(
            (lab, arr)
        )
    for lab, arr in priority + rest:
        out.extend(arr[:2])
        if len(out) >= limit:
            break
    return out[:limit]


def build_phases(colors: list[dict]) -> dict:
    phases = {k: [] for k in ("login", "server", "role", "enter", "battle", "popup", "main")}
    for c in colors:
        phases.setdefault(c["phase"], []).append(c)
    # ensure minimum stubs if empty (generic)
    stubs = {
        "server": {
            "label": "选择区服",
            "phase": "server",
            "first": "0x9b9a9b",
            "off": "1|0|0x9c9c9c",
            "degree": 85,
            "x1": 200,
            "y1": 540,
            "x2": 380,
            "y2": 580,
            "src": "stub",
            "via": "stub",
        },
        "login": {
            "label": "登录",
            "phase": "login",
            "first": "0xcda059",
            "off": "0|1|0xcda059",
            "degree": 85,
            "x1": 400,
            "y1": 350,
            "x2": 700,
            "y2": 500,
            "src": "stub",
            "via": "stub",
        },
        "enter": {
            "label": "进入游戏",
            "phase": "enter",
            "first": "0xf0e2c5",
            "off": "0|1|0xf0e2c5",
            "degree": 85,
            "x1": 500,
            "y1": 390,
            "x2": 620,
            "y2": 430,
            "src": "stub",
            "via": "stub",
        },
        "role": {
            "label": "角色选择",
            "phase": "role",
            "first": "0x917050",
            "off": "0|1|0x947250",
            "degree": 85,
            "x1": 220,
            "y1": 480,
            "x2": 280,
            "y2": 520,
            "src": "stub",
            "via": "stub",
        },
        "battle": {
            "label": "挂机",
            "phase": "battle",
            "first": "0xe6bf30",
            "off": "0|1|0xe6bf30",
            "degree": 85,
            "x1": 940,
            "y1": 60,
            "x2": 980,
            "y2": 100,
            "src": "stub",
            "via": "stub",
        },
    }
    for k, stub in stubs.items():
        if not phases.get(k):
            phases[k] = [stub]
    return phases


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    fam_dir = OUT / "families"
    fam_dir.mkdir(parents=True, exist_ok=True)
    index = {
        "phase": "7.6.3-R8.4.2",
        "ts": int(time.time() * 1000),
        "games": {},
        "note": "imported from Ai代码训练; no TSLib/ts.so",
    }
    kb_lines = []
    for folder, fam in FAM.items():
        d = TRAIN / folder
        if not d.is_dir():
            continue
        rows = []
        for f in sorted(d.glob("*.lua")):
            if f.name in ("TSLib.lua",):
                continue
            rows.extend(extract_file(f))
        colors = slim_colors(rows)
        phases = build_phases(colors)
        doc = {
            "family": fam,
            "game": folder,
            "imported": True,
            "status": "已导入",
            "api": "ZiYan",
            "ocr_hints": OCR_HINTS,
            "COLOR_PARAMS": colors,
            "phases": {k: v[:12] for k, v in phases.items()},
            "flows": ["boot", "login", "server", "role_select", "entering", "main", "task", "battle"],
            "sleep_ms_min": 300,
            "ocr_interval_ms": 350,
            "find_interval_ms": 200,
        }
        (fam_dir / f"{fam}.json").write_text(
            json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        index["games"][fam] = {
            "game": folder,
            "status": "已导入",
            "color_count": len(colors),
            "path": f"families/{fam}.json",
        }
        kb_lines.append(
            json.dumps(
                {
                    "ts": int(time.time()),
                    "event": "training_import",
                    "family": fam,
                    "game": folder,
                    "ok": True,
                    "color_count": len(colors),
                    "status": "已导入",
                },
                ensure_ascii=False,
            )
        )
        print(f"[ok] {fam} {folder} colors={len(colors)}")

    (OUT / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")
    with (OUT / "KB.jsonl").open("w", encoding="utf-8") as f:
        f.write("\n".join(kb_lines) + "\n")
    print(f"[done] → {OUT}")


if __name__ == "__main__":
    main()
