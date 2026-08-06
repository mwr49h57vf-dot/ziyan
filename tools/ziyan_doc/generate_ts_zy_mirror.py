#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 TS 文档归档生成「一一对应」ZiYan 自研镜像表 + Lua 注册表。

硬约束：
- 仅镜像函数名/契约分层，实现走 ZiYan 自有后端
- 禁止嵌入触动/XXTouch 源码或私有调用
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path

ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
ARCHIVE = ROOT / "tmp_shots/PHASE763R8/ts_docs_archive/functions.jsonl"
OUT_JSON = ROOT / "tools/ziyan_doc/ts_zy_mirror_map.json"
OUT_LUA = ROOT / "lua/ziyan_engine/compat_registry.lua"
OUT_REPORT = ROOT / "tmp_shots/PHASE763R8/TS_ZY_MIRROR_REPORT.md"

# name → impl key in compat_impl.lua (IMPL.dispatch / helpers)
DIRECT = {
    # color
    "getColor": "color.getColor",
    "getColorRGB": "color.getColorRGB",
    "isColor": "color.isColor",
    "isColors": "color.isColors",
    "multiColor": "color.multiColor",
    "multiColTap": "color.multiColTap",
    "muColors": "color.muColors",
    "findColor": "color.findColor",
    "findColorUntil": "color.findColorUntil",
    "findColorInRegionFuzzy": "color.findColorInRegionFuzzy",
    "findMultiColor": "color.findMultiColor",
    "findMultiColorInRegionFuzzy": "color.findMultiColorInRegionFuzzy",
    "findMultiColorInRegionFuzzyExt": "color.findMultiColorInRegionFuzzyExt",
    "findMultiColorInRegionFuzzyByTable": "color.findMultiColorInRegionFuzzyByTable",
    "findColorsUntil": "color.findColorsUntil",
    "intToRgb": "color.intToRgb",
    "rgbToInt": "color.rgbToInt",
    "toTableType": "color.toTableType",
    "toStringType": "color.toStringType",
    "setColor": "color.setColor",
    "replaceColor": "color.replaceColor",
    # touch
    "tap": "touch.tap",
    "touchDown": "touch.touchDown",
    "touchMove": "touch.touchMove",
    "touchUp": "touch.touchUp",
    "swipe": "touch.swipe",
    "longTap": "touch.longTap",
    # screen
    "keepScreen": "screen.keepScreen",
    "snapshot": "screen.snapshot",
    "getScreenSize": "screen.getScreenSize",
    "init": "screen.init",
    "resetScreen": "screen.resetScreen",
    # time
    "mSleep": "time.mSleep",
    "msleep": "time.mSleep",
    "sleep": "time.sleep",
    # input
    "inputText": "input.inputText",
    "inputStr": "input.inputStr",
    "inputKey": "input.inputKey",
    "keyDown": "input.keyDown",
    "keyUp": "input.keyUp",
    "copyText": "input.copyText",
    "writePasteboard": "input.writePasteboard",
    "readPasteboard": "input.readPasteboard",
    "clearPasteboard": "input.clearPasteboard",
    # keycode.*
    "keycode.back": "keycode.back",
    "keycode.home": "keycode.home",
    "keycode.power": "keycode.power",
    "keycode.notification": "keycode.notification",
    "keycode.quickSetting": "keycode.quickSetting",
    "keycode.recent": "keycode.recent",
    "keycode.splitScreen": "keycode.splitScreen",
    "pressHomeKey": "keycode.home",
    # app
    "runApp": "app.runApp",
    "appRun": "app.runApp",
    "closeApp": "app.closeApp",
    "frontAppBid": "app.frontAppBid",
    "isAppInstalled": "app.isAppInstalled",
    "appIsRunning": "app.appIsRunning",
    # file / path
    "userPath": "file.userPath",
    "getList": "file.getList",
    "readFile": "file.readFile",
    "writeFile": "file.writeFile",
    "delFile": "file.delFile",
    "removeFile": "file.delFile",
    "isFileExist": "file.isFileExist",
    "fileExists": "file.isFileExist",
    "mkdir": "file.mkdir",
    # log / toast
    "toast": "log.toast",
    "notifyMessage": "log.notifyMessage",
    "sysLog": "log.sysLog",
    "nLog": "log.nLog",
    "log": "log.sysLog",
    "dialog": "log.dialog",
    # device
    "unlockDevice": "device.unlockDevice",
    "deviceUnlock": "device.unlockDevice",
    "deviceIsLock": "device.deviceIsLock",
    "getOSVer": "device.getOSVer",
    "getDeviceType": "device.getDeviceType",
    "getScreenScale": "device.getScreenScale",
    "getNetTime": "device.getNetTime",
    "getNetIP": "device.getNetIP",
    "getRndNum": "util.getRndNum",
    "lua_exit": "script.lua_exit",
    # image / ocr thin
    "findImage": "image.findImage",
    "ocrText": "ocr.ocrText",
    "ppOcrText": "ocr.ocrText",
}


def norm_names(raw: str, title: str) -> list[str]:
    raw = (raw or "").strip()
    if not raw or raw in ("Android", "iOS", "脚本 UI", "触动精灵云打码"):
        return []
    if "、" in raw:
        return [
            p.strip()
            for p in raw.split("、")
            if re.match(r"^[A-Za-z_]", p.strip() or "")
        ]
    m = re.match(r"^([A-Za-z_][\w\.:]*)", raw)
    if m:
        return [m.group(1)]
    m = re.search(r"函数[：:]\s*([A-Za-z_][\w\.:]*)", title or "")
    return [m.group(1)] if m else []



# merge optional extras
_extra_path = Path(__file__).resolve().parent / "ts_zy_direct_extra.json"
if _extra_path.exists():
    DIRECT.update(json.loads(_extra_path.read_text(encoding="utf-8")))

def classify(name: str) -> str:

    rules = [
        ("color", r"(?i)color|rgb|findMulti|findColor|isColor|multiCol|muColors|replaceColor|intToRgb|toTableType|toStringType"),
        ("touch", r"(?i)^(tap|touch|swipe|longTap)"),
        ("screen", r"(?i)screen|snapshot|keepScreen|orient|rotate"),
        ("image", r"(?i)image|findImage|qr|album|binary"),
        ("ocr", r"(?i)ocr|ppOcr|tess"),
        ("app", r"(?i)^(runApp|app|closeApp|frontApp|isApp|launch)"),
        ("file", r"(?i)file|getList|unzip|zip|Path|readFile|writeFile|delFile|mkdir|isFile"),
        ("input", r"(?i)input|keyDown|keyUp|paste|Paste|clipboard|InputMethod"),
        ("keycode", r"(?i)^keycode\.|pressHome"),
        ("widget", r"(?i)^widget\.|Accessibility"),
        ("log", r"(?i)^(log|sysLog|nLog|dialog|toast|notify)"),
        ("device", r"(?i)device|unlock|lock|battery|brightness|wifi|udid|getOS|getDevice|getNet|getIP|getMemory"),
        ("net", r"(?i)http|ftp|url|download|upload"),
        ("thread", r"(?i)^thread\.|lua_exit|restartScript"),
        ("ui", r"(?i)^ui\."),
        ("time", r"(?i)time|Time|sleep|mSleep|msleep"),
        ("util", r"(?i)rnd|random|utf8|md5|base64|json"),
        ("ts_cloud", r"(?i)^ts\."),
    ]
    for b, rx in rules:
        if re.search(rx, name):
            return b
    return "other"


def main() -> None:
    items = [json.loads(l) for l in ARCHIVE.open(encoding="utf-8")]
    uniq: dict[str, dict] = {}
    for it in items:
        for n in norm_names(it.get("name", ""), it.get("page_title", "")):
            if n not in uniq:
                uniq[n] = it

    mirror = {}
    stats = defaultdict(int)
    for name, it in sorted(uniq.items()):
        bucket = classify(name)
        impl = DIRECT.get(name)
        if impl:
            status = "implemented"
        elif bucket in ("ts_cloud",) or name.startswith("ts."):
            status = "stub_unsupported"  # 触动云/私有生态不镜像实现
            impl = "stub.unsupported"
        elif bucket in ("widget",) or name.startswith("widget."):
            status = "stub_planned"  # iOS 无障碍控件：规划
            impl = "stub.planned"
        elif name.startswith("ui."):
            status = "stub_planned"
            impl = "stub.planned"
        elif name.startswith("ftp.") or name.startswith("thread."):
            status = "stub_planned"
            impl = "stub.planned"
        else:
            status = "stub_generic"
            impl = f"stub.generic:{bucket}"
        mirror[name] = {
            "ts_name": name,
            "ts_title": it.get("page_title", ""),
            "ts_url": it.get("url", ""),
            "bucket": bucket,
            "zy_impl": impl,
            "status": status,
            "global": "." not in name,
            "table": name.split(".")[0] if "." in name else None,
            "method": name.split(".", 1)[1] if "." in name else name,
        }
        stats[status] += 1

    OUT_JSON.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(),
                "disclaimer": "Name/contract mirror only; ZiYan self-implemented backends; no TS private API",
                "count": len(mirror),
                "stats": dict(stats),
                "functions": mirror,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    # Lua registry
    lines = [
        "--[[ AUTO-GENERATED by tools/ziyan_doc/generate_ts_zy_mirror.py",
        "  TS 文档函数名 → ZiYan compat_impl 一一注册。禁止手改；请改生成器/impl。",
        f"  generated: {datetime.now().isoformat()} count={len(mirror)}",
        "]]",
        "local M = { name = 'compat_registry', version = '1.0.0' }",
        "local function load_impl()",
        "  local root = (_G.ZIYAN_LUA or '/usr/lib/ziyan/lib/lua') .. '/ziyan_engine'",
        "  local ok, mod = pcall(dofile, root .. '/compat_impl.lua')",
        "  if ok and type(mod) == 'table' then return mod end",
        "  return nil",
        "end",
        "",
        "function M.install()",
        "  local IMPL = load_impl()",
        "  if not IMPL then return false, 'no_compat_impl' end",
        "  local call = IMPL.call  -- call(impl_key, ...)",
        "  local function bind(name, key)",
        "    if name:find('.', 1, true) then",
        "      local parts = {}",
        "      for p in string.gmatch(name, '[^%.]+') do parts[#parts+1]=p end",
        "      local node = _G",
        "      for i = 1, #parts-1 do",
        "        local k = parts[i]",
        "        if type(node[k]) ~= 'table' then",
        "          local prev = node[k]",
        "          node[k] = {}",
        "          if type(prev) == 'function' then",
        "            setmetatable(node[k], { __call = function(_, ...) return prev(...) end })",
        "          end",
        "        end",
        "        node = node[k]",
        "      end",
        "      local leaf = parts[#parts]",
        "      if type(node[leaf]) ~= 'function' then",
        "        node[leaf] = function(...)",
        "          return call(key, ...)",
        "        end",
        "      end",
        "    else",
        "      local cur = rawget(_G, name)",
        "      if type(cur) == 'function' and rawget(_G, '__ZIYAN_NATIVE_' .. name) == nil then",
        "        rawset(_G, '__ZIYAN_NATIVE_' .. name, cur)",
        "      end",
        "      if type(cur) == 'table' then",
        "        local mt = getmetatable(cur) or {}",
        "        if type(mt.__call) ~= 'function' then",
        "          mt.__call = function(_, ...) return call(key, ...) end",
        "          setmetatable(cur, mt)",
        "        end",
        "      end",
        "      if type(cur) ~= 'function' and type(cur) ~= 'table' then",
        "        _G[name] = function(...)",
        "          return call(key, ...)",
        "        end",
        "        rawset(_G, '__ZIYAN_COMPAT_WRAP_' .. name, true)",
        "      end",
        "    end",
        "  end",
        "",
    ]
    for name, meta in sorted(mirror.items()):
        key = meta["zy_impl"].replace("\\", "\\\\").replace("'", "\\'")
        n = name.replace("\\", "\\\\").replace("'", "\\'")
        lines.append(f"  bind('{n}', '{key}')")
    lines += [
        "",
        "  -- expose mirror table",
        "  if type(_G.Zy) ~= 'table' then _G.Zy = {} end",
        "  _G.Zy.Compat = _G.Zy.Compat or {}",
        "  _G.Zy.Compat.count = " + str(len(mirror)),
        "  _G.Zy.Compat.impl = IMPL",
        "  return true",
        "end",
        "",
        "return M",
        "",
    ]
    OUT_LUA.write_text("\n".join(lines), encoding="utf-8")

    # report
    by_bucket = defaultdict(int)
    for m in mirror.values():
        by_bucket[m["bucket"]] += 1
    OUT_REPORT.write_text(
        "\n".join(
            [
                "# TS → ZiYan 一一镜像报告",
                "",
                f"- 生成：{datetime.now().isoformat()}",
                f"- 归档唯一函数名：{len(mirror)}",
                f"- 状态统计：{json.dumps(stats, ensure_ascii=False)}",
                f"- 映射表：`tools/ziyan_doc/ts_zy_mirror_map.json`",
                f"- 注册表：`lua/ziyan_engine/compat_registry.lua`",
                f"- 实现：`lua/ziyan_engine/compat_impl.lua`",
                "",
                "## 分桶",
                "",
                *[f"- {k}: {v}" for k, v in sorted(by_bucket.items(), key=lambda x: -x[1])],
                "",
                "## 说明",
                "",
                "- `implemented`：已接到 ZiYan 自有后端",
                "- `stub_planned`：契约已挂名，待补全（控件/UI/线程/FTP 等）",
                "- `stub_unsupported`：触动云等私有生态，明确不实现",
                "- `stub_generic`：已挂名，返回 false/`not_implemented`",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(
        f"mirror={len(mirror)} stats={dict(stats)} lua={OUT_LUA} json={OUT_JSON}"
    )


if __name__ == "__main__":
    main()
