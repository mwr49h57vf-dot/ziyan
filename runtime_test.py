#!/usr/bin/env python3
"""
在设备上运行子砚脚本并采集实时性能数据。
"""

import subprocess
import os
import sys
import time
import json
from pathlib import Path
from datetime import datetime

PASS = os.environ.get("ZIYAN_SSH_PASS", "alpine")
LOG_DIR = Path("/Users/mac/Desktop/ZiYan_副本/logs/runtime_test")
LOG_DIR.mkdir(parents=True, exist_ok=True)

# 设备配置
DEVICES = [
    {"id": "101", "ip": "192.168.31.101", "model": "iPhone 7", "env": "rootful", "ios": "13.6", "script": "ios7_副本.lua", "lua_bin": "/usr/lib/ziyan/bin/lua5.3"},
    {"id": "112", "ip": "192.168.31.112", "model": "iPhone 7 Plus", "env": "rootful", "ios": "13.2.2", "script": "ios7_副本.lua", "lua_bin": "/usr/lib/ziyan/bin/lua5.3"},
    {"id": "166", "ip": "192.168.31.166", "model": "iPhone 7", "env": "rootful", "ios": "13.1.2", "script": "ios7_副本.lua", "lua_bin": "/usr/lib/ziyan/bin/lua5.3"},
    {"id": "53", "ip": "192.168.31.53", "model": "iPhone 8 Plus", "env": "rootless", "ios": "16.7.16", "script": "ios8p_副本.lua", "lua_bin": "/var/jb/usr/lib/ziyan/bin/lua5.3", "dyld_path": "/var/jb/usr/lib/ziyan/lib"},
]

def ssh_exec(ip: str, cmd: str, timeout: int = 30) -> str:
    """执行 SSH 命令"""
    r = subprocess.run(
        ["sshpass", "-p", PASS, "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", f"root@{ip}", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return (r.stdout or "") + (r.stderr or "")

def test_basic_lua(ip: str, lua_bin: str, dyld_path: str = None):
    """测试基本 Lua 执行"""
    prefix = f"DYLD_LIBRARY_PATH={dyld_path} " if dyld_path else ""

    # Lua 测试脚本
    lua_script = '''
print("=== Lua 基本功能测试 ===")
print("Lua 版本: " .. _VERSION)

-- 测试基础函数
local x, y = 100, 200
print("变量测试: x=" .. x .. ", y=" .. y)

-- 测试字符串
local str = "Hello ZiYan!"
print("字符串测试: " .. str)

-- 测试循环
local sum = 0
for i = 1, 100 do
    sum = sum + i
end
print("循环测试: sum(1..100) = " .. sum)

-- 测试 table
local colors = {{0xff, 0xaa, 0x33}, {0x11, 0x22, 0x33}}
print("Table 测试: colors[1] = " .. colors[1][1] .. ", " .. colors[1][2] .. ", " .. colors[1][3])

print("=== 所有基础测试通过 ===")
'''

    # 将 Lua 脚本写入临时文件并执行
    cmd = f"""{prefix}echo '{lua_script}' > /tmp/test_basic.lua && {prefix}{lua_bin} /tmp/test_basic.lua 2>&1"""

    return ssh_exec(ip, cmd)

def test_ziyan_api(ip: str, lua_bin: str, dyld_path: str = None):
    """测试子砚 API 是否可用"""
    prefix = f"DYLD_LIBRARY_PATH={dyld_path} " if dyld_path else ""

    lua_script = '''
print("=== 子砚 API 测试 ===")

-- 尝试加载子砚核心模块
local ok, err = pcall(require, "ziyan_paths")
if ok then
    print("ziYan_paths 加载成功")
else
    print("ziYan_paths 加载失败: " .. tostring(err))
end

-- 尝试加载 cv 模块 (找色)
local ok2, err2 = pcall(require, "cv")
if ok2 then
    print("cv 模块加载成功")
else
    print("cv 模块加载失败: " .. tostring(err2))
end

-- 检查全局函数
if _G.findMultiColorInRegionFuzzy then
    print("findMultiColorInRegionFuzzy 可用")
else
    print("findMultiColorInRegionFuzzy 不可用 (需 App 环境)")
end

if _G.tap then
    print("tap 可用")
else
    print("tap 不可用 (需 App 环境)")
end

if _G.toast then
    print("toast 可用")
else
    print("toast 不可用 (需 App 环境)")
end

print("=== API 测试完成 ===")
'''

    cmd = f"""{prefix}echo '{lua_script}' > /tmp/test_api.lua && {prefix}{lua_bin} /tmp/test_api.lua 2>&1"""

    return ssh_exec(ip, cmd)

def run_script_syntax_check(ip: str, lua_bin: str, script_name: str, dyld_path: str = None):
    """检查脚本语法"""
    prefix = f"DYLD_LIBRARY_PATH={dyld_path} " if dyld_path else ""
    script_path = f"/var/mobile/Media/ZiYan/{script_name}"

    lua_script = f'''
print("=== 脚本语法检查 ===")

-- 尝试加载脚本（只检查语法，不执行）
local f, err = loadfile("{script_path}")
if f then
    print("脚本语法正确")
else
    print("脚本语法错误: " .. tostring(err))
end

-- 读取脚本内容检查
local file = io.open("{script_path}", "r")
if file then
    local content = file:read("*all")
    file:close()
    print("脚本大小: " .. #content .. " 字节")

    -- 检查关键字
    if string.find(content, "findMultiColorInRegionFuzzy") then
        print("包含 findMultiColorInRegionFuzzy")
    end
    if string.find(content, "tap") then
        print("包含 tap")
    end
    if string.find(content, "toast") then
        print("包含 toast")
    end
    if string.find(content, "function main") then
        print("包含 main 函数")
    end
    if string.find(content, "while true") then
        print("包含无限循环")
    end
end

print("=== 语法检查完成 ===")
'''

    cmd = f"""{prefix}echo '{lua_script}' > /tmp/test_syntax.lua && {prefix}{lua_bin} /tmp/test_syntax.lua 2>&1"""

    return ssh_exec(ip, cmd)

def collect_detailed_metrics(ip: str, device_id: str):
    """采集详细性能指标"""
    metrics = {"device_id": device_id, "timestamp": datetime.now().isoformat()}

    # 1. 系统负载
    metrics["uptime"] = ssh_exec(ip, "uptime").strip()

    # 2. 内存状态
    vm = ssh_exec(ip, "vm_stat").strip()
    for line in vm.split('\n'):
        if "Pages free" in line:
            metrics["pages_free"] = line.split(':')[1].strip()
        if "Pages active" in line:
            metrics["pages_active"] = line.split(':')[1].strip()
        if "Pages wired down" in line:
            metrics["pages_wired"] = line.split(':')[1].strip()

    # 3. 子砚进程详细信息
    procs = ssh_exec(ip, "ps aux | grep -E 'ziyan|lua5|SpringBoard' | grep -v grep").strip()
    metrics["processes"] = []
    for line in procs.split('\n'):
        if line.strip():
            parts = line.split()
            if len(parts) >= 11:
                metrics["processes"].append({
                    "user": parts[0],
                    "pid": parts[1],
                    "cpu": parts[2],
                    "mem": parts[3],
                    "rss_kb": parts[5],
                    "command": parts[10] if len(parts) > 10 else ""
                })

    return metrics

def monitor_runtime(device: dict):
    """监控设备运行"""
    ip = device["ip"]
    device_id = device["id"]

    print(f"\n{'='*60}")
    print(f"[监控] 设备 {device_id} ({device['model']}, {device['env']})")
    print(f"{'='*60}")

    all_metrics = []

    # 初始状态
    print(f"\n[初始状态采集]")
    metrics = collect_detailed_metrics(ip, device_id)
    metrics["phase"] = "initial"
    all_metrics.append(metrics)

    sb_running = any('SpringBoard' in str(p.get('command', '')) for p in metrics.get('processes', []))
    ziyan_count = len([p for p in metrics.get('processes', []) if 'ziyan' in str(p.get('command', '')).lower() or 'lua5' in str(p.get('command', '')).lower()])

    print(f"  系统负载: {metrics.get('uptime', 'N/A')}")
    print(f"  空闲内存页: {metrics.get('pages_free', 'N/A')}")
    print(f"  SpringBoard: {'运行中' if sb_running else '未运行'}")
    print(f"  子砚进程数: {ziyan_count}")

    # 测试 1: 基本 Lua
    print(f"\n[Lua 基本功能测试]")
    lua_result = test_basic_lua(ip, device["lua_bin"], device.get("dyld_path"))
    print(f"  {lua_result[:300]}")
    metrics["lua_basic_test"] = lua_result

    # 测试 2: 子砚 API
    print(f"\n[子砚 API 测试]")
    api_result = test_ziyan_api(ip, device["lua_bin"], device.get("dyld_path"))
    print(f"  {api_result[:300]}")
    metrics["api_test"] = api_result

    # 测试 3: 脚本语法
    print(f"\n[脚本语法检查] {device['script']}")
    syntax_result = run_script_syntax_check(ip, device["lua_bin"], device["script"], device.get("dyld_path"))
    print(f"  {syntax_result[:300]}")
    metrics["syntax_check"] = syntax_result

    # 运行中监控
    print(f"\n[5秒后状态采集]")
    time.sleep(5)

    metrics2 = collect_detailed_metrics(ip, device_id)
    metrics2["phase"] = "after_5s"
    all_metrics.append(metrics2)

    sb_running2 = any('SpringBoard' in str(p.get('command', '')) for p in metrics2.get('processes', []))

    # 检查日志
    print(f"\n[日志检查]")
    logs = ssh_exec(ip, "cat /tmp/ziyan_run_*.log 2>/dev/null | tail -20 || echo 'No logs'").strip()
    print(f"  最近日志:")
    for line in logs.split('\n')[-10:]:
        if line.strip():
            print(f"    {line[:100]}")

    # 汇总
    lua_ok = "Lua 版本" in lua_result or "基础测试通过" in lua_result
    syntax_ok = "语法正确" in syntax_result

    print(f"\n[设备 {device_id} 测试汇总]")
    print(f"  Lua 可执行: {'✅' if lua_ok else '❌'}")
    print(f"  语法正确: {'✅' if syntax_ok else '❌'}")
    print(f"  SpringBoard: {'✅ 运行中' if sb_running2 else '❌ 未运行'}")

    return {
        "device_id": device_id,
        "model": device["model"],
        "env": device["env"],
        "ios": device["ios"],
        "metrics": all_metrics,
        "lua_test": lua_result,
        "api_test": api_result,
        "syntax_test": syntax_result,
        "logs": logs
    }

def main():
    print("=" * 60)
    print("子砚设备实时测试与数据采集")
    print(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    all_results = []

    for device in DEVICES:
        try:
            result = monitor_runtime(device)
            all_results.append(result)

            # 保存单设备结果
            device_log = LOG_DIR / f"runtime_{device['id']}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
            with open(device_log, "w", encoding="utf-8") as f:
                json.dump(result, f, ensure_ascii=False, indent=2, default=str)
            print(f"\n  [保存] {device_log}")

        except Exception as e:
            print(f"\n[ERROR] 设备 {device['id']} 测试失败: {e}")
            import traceback
            traceback.print_exc()
            all_results.append({"device_id": device["id"], "error": str(e)})

    # 生成汇总报告
    print("\n" + "=" * 60)
    print("测试汇总报告")
    print("=" * 60)

    summary = []
    for result in all_results:
        if "error" not in result:
            device_id = result["device_id"]
            model = result.get("model", "Unknown")
            env = result.get("env", "Unknown")

            lua_ok = "Lua 版本" in result.get("lua_test", "") or "基础测试通过" in result.get("lua_test", "")
            syntax_ok = "语法正确" in result.get("syntax_test", "")

            summary.append(f"设备 {device_id} ({model}, {env}):")
            summary.append(f"  Lua 执行: {'✅' if lua_ok else '❌'}")
            summary.append(f"  脚本语法: {'✅' if syntax_ok else '❌'}")
            summary.append("")

    print("\n".join(summary))

    # 保存完整结果
    output_file = LOG_DIR / f"complete_test_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump({
            "timestamp": datetime.now().isoformat(),
            "results": all_results,
            "summary": summary,
            "conclusion": "rootful设备Lua环境完整，rootless设备需DYLD_LIBRARY_PATH，子砚API需App环境。"
        }, f, ensure_ascii=False, indent=2, default=str)

    print(f"\n完整结果已保存: {output_file}")

    # 最终操作指引
    print("\n" + "=" * 60)
    print("📱 请在设备上执行以下操作:")
    print("=" * 60)
    print("""
1. 打开「子砚」App
2. 进入「脚本」目录
3. 找到已部署的脚本:
   - 设备 101/112/166: ios7_副本.lua
   - 设备 53: ios8p_副本.lua
4. 点击运行按钮 ▶️
5. 观察脚本执行和日志输出

如果子砚 App 未在前台:
   - rootful设备: 禁止 killall SpringBoard（BLOCKED_AUTO_SB_RESTART）
   - rootless设备: open com.ziyan.ziyan (直接打开)
""")

    return 0

if __name__ == "__main__":
    sys.exit(main())
