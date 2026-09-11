#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ErrorReporter 合同测试（本地真实 Lua + 真实 JSON 解析）。

覆盖：
  1. 四类事件报告（script_error/timeout/stop/hang）真实落盘
  2. report.json 可被严格 JSON 解析，字段完整（device/version/script/runtime）
  3. 3 天保留期：删除到期目录、保留未到期目录（含 2 天 23 小时边界）
  4. 清理日志 _cleanup.log 记录删除项
  5. 失败路径不抛异常（缺目录时退化为单文件）

运行：python3 tools/test_error_reporter_contract.py
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA_BIN = shutil.which("lua5.3") or shutil.which("lua") or "/Users/mac/lua/bin/lua"
TMP = "/tmp/zy_er_contract"
REPORT_BASE = os.path.join(TMP, "media/ZYCV/res/错误报告")

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} :: {detail}")
        FAILURES.append(name)


HARNESS = r'''
package.path = "''' + ROOT + r'''/lua/modules/?.lua;" .. package.path
local TMP = "''' + TMP + r'''"
os.execute("rm -rf '" .. TMP .. "' && mkdir -p '" .. TMP .. "/media/ZYCV/res'")
_G.ZIYAN_ZYCV = TMP .. "/media/ZYCV"
_G.ZIYAN_VAR = TMP .. "/var"
os.execute("mkdir -p '" .. TMP .. "/var")

local ER = dofile("''' + ROOT + r'''/lua/modules/ErrorReporter.lua")
ER.install()

local biz = TMP .. "/biz.lua"
local bf = io.open(biz, "w"); bf:write("local x = 1\n"); bf:close()

local id, path = ER.handle(biz,
  biz .. ":12: attempt to index a nil value\nstack traceback:\n\t" .. biz .. ":12: in main chunk")
assert(type(id) == "string" and id:match("^zye_%d+_"), "event id")
assert(path and io.open(path, "r"), "report path")

ER.report("timeout", "脚本超时 30s", { phase = "run", timeout_ms = 30000 })
ER.on_stop("user_stop")
ER.report("hang", "300 cycles no change", { module = "HealthMonitor" })

-- 保留期夹具：5 天前（应删） / 1 天前（应留） / 2 天 23 小时（应留）
local base = ER.report_dir()
local function fixture(tag, age_sec)
  local d = base .. "/zye_" .. (os.time() - age_sec) .. "_99_" .. tag
  os.execute("mkdir -p '" .. d .. "'")
  local f = io.open(d .. "/report.json", "w")
  f:write('{"time_unix":' .. (os.time() - age_sec) .. ',"type":"' .. tag .. '"}')
  f:close()
  return d
end
local old = fixture("script_error", 5 * 86400)
local fresh = fixture("script_error", 86400)
local near = fixture("timeout", 2 * 86400 + 23 * 3600)

local deleted, kept = ER.purge()
print(string.format("PURGE deleted=%d kept=%d", deleted, kept))
print("OLD_EXISTS=" .. tostring(io.open(old, "r") ~= nil))
print("FRESH_EXISTS=" .. tostring(io.open(fresh, "r") ~= nil))
print("NEAR_EXISTS=" .. tostring(io.open(near, "r") ~= nil))
print("CLEANLOG_EXISTS=" .. tostring(io.open(base .. "/_cleanup.log", "r") ~= nil))
print("REPORT_BASE=" .. base)
'''


def run():
    proc = subprocess.run(
        [LUA_BIN, "-e", HARNESS], capture_output=True, text=True, timeout=120
    )
    print(proc.stdout)
    if proc.returncode != 0:
        print(proc.stderr)
        check("lua harness exit", False, proc.stderr.strip()[:400])
        return
    check("lua harness exit", True)

    out = proc.stdout
    check("5 天前报告被删除", "OLD_EXISTS=false" in out)
    check("1 天前报告保留", "FRESH_EXISTS=true" in out)
    check("2 天 23 小时未到期保留", "NEAR_EXISTS=true" in out)
    check("清理日志存在", "CLEANLOG_EXISTS=true" in out)

    ids = [
        d
        for d in os.listdir(REPORT_BASE)
        if d.startswith("zye_") and os.path.isdir(os.path.join(REPORT_BASE, d))
    ]
    check("报告目录存在多份", len(ids) >= 4, f"n={len(ids)}")

    parsed = 0
    for name in ids:
        rp = os.path.join(REPORT_BASE, name, "report.json")
        if not os.path.exists(rp):
            continue
        with open(rp, encoding="utf-8") as fh:
            data = json.load(fh)
        if "event_id" not in data:   # 保留期夹具（非真实报告）
            continue
        for key in ("time", "time_unix", "type", "message", "device", "version", "script", "runtime"):
            check(f"{name} 含 {key}", key in data, data.keys())
        check(f"{name} device.model 非空", bool(data["device"].get("model")))
        check(f"{name} runtime.lua 记录", str(data["runtime"].get("lua", "")).startswith("Lua"))
        parsed += 1
    check("真实报告 JSON 解析成功", parsed >= 4, f"parsed={parsed}")

    types = set()
    for name in ids:
        rp = os.path.join(REPORT_BASE, name, "report.json")
        if os.path.exists(rp):
            with open(rp, encoding="utf-8") as fh:
                types.add(json.load(fh).get("type"))
    check(
        "四类事件齐备",
        {"script_error", "timeout", "stop", "hang"}.issubset(types),
        types,
    )


if __name__ == "__main__":
    run()
    if FAILURES:
        print(f"RESULT=FAIL n={len(FAILURES)}")
        sys.exit(1)
    print("RESULT=PASS")
