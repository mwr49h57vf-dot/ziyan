#!/usr/bin/env python3
"""
修复 rootless 设备 (iPhone 8 Plus) 的 Lua 库加载问题，并运行测试脚本。
"""

import subprocess
import os
import time
import json
from pathlib import Path
from datetime import datetime

PASS = os.environ.get("ZIYAN_SSH_PASS", "alpine")
LOG_DIR = Path("/Users/mac/Desktop/ZiYan_副本/logs/fix_and_run")
LOG_DIR.mkdir(parents=True, exist_ok=True)

DEVICE_53 = {"id": "53", "ip": "192.168.31.53", "env": "rootless", "script": "ios8p_副本.lua"}
DEVICE_166 = {"id": "166", "ip": "192.168.31.166", "env": "rootful", "script": "ios7_副本.lua"}
DEVICE_101 = {"id": "101", "ip": "192.168.31.101", "env": "rootful", "script": "ios7_副本.lua"}
DEVICE_112 = {"id": "112", "ip": "192.168.31.112", "env": "rootful", "script": "ios7_副本.lua"}

def ssh_exec(ip: str, cmd: str, timeout: int = 30, binary_mode=False) -> str:
    """执行 SSH 命令"""
    r = subprocess.run(
        ["sshpass", "-p", PASS, "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", f"root@{ip}", cmd],
        capture_output=True, timeout=timeout
    )
    if binary_mode:
        return r.stdout + r.stderr
    return (r.stdout or b"").decode('utf-8', errors='replace') + (r.stderr or b"").decode('utf-8', errors='replace')

def fix_rootless_libraries(ip: str):
    """修复 rootless 设备的库加载问题"""
    print("\n" + "=" * 60)
    print("修复 rootless 设备 (iPhone 8 Plus)")
    print("=" * 60)
    
    # 检查是否能写入 /usr/lib
    print("\n[1] 检查 /usr/lib 写入权限:")
    test_write = ssh_exec(ip, "touch /usr/lib/.ziyan_test 2>&1 && echo 'WRITABLE' || echo 'READONLY'; rm -f /usr/lib/.ziyan_test")
    print(f"  {test_write.strip()}")
    
    # 方案 A: 创建符号链接 (如果可写)
    print("\n[2] 尝试创建符号链接:")
    fix_cmd = """
    # 创建目录
    mkdir -p /usr/lib/ziyan/bin 2>/dev/null
    mkdir -p /usr/lib/ziyan/lib 2>/dev/null
    
    # 创建链接
    if [ -f /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib ]; then
        ln -sf /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib /usr/lib/ziyan/lib/liblua5.3.dylib 2>/dev/null
        echo "Created symlink for liblua5.3.dylib"
    fi
    
    if [ -f /var/jb/usr/lib/ziyan/bin/lua5.3 ]; then
        ln -sf /var/jb/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/bin/lua5.3 2>/dev/null
        echo "Created symlink for lua5.3"
    fi
    
    # 检查链接是否创建成功
    ls -la /usr/lib/ziyan/lib/liblua5.3.dylib 2>/dev/null || echo "Symlink failed or not writable"
    ls -la /usr/lib/ziyan/bin/lua5.3 2>/dev/null || echo "Symlink failed for bin"
    """
    out = ssh_exec(ip, fix_cmd)
    print(f"  {out}")
    
    # 方案 B: 使用环境变量 (无需写入权限)
    print("\n[3] 测试使用 DYLD_LIBRARY_PATH 环境变量:")
    test_env = ssh_exec(ip, "DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 -e 'print(\"Lua works!\")' 2>&1")
    print(f"  结果: {test_env.strip()}")
    
    if "Lua works" in test_env:
        print("  ✅ 环境变量方案可行！")
        return "ENV_VAR_OK"
    
    # 方案 C: 复制文件
    print("\n[4] 尝试复制文件:")
    copy_cmd = """
    if [ -w /usr/lib ]; then
        cp /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib /usr/lib/ziyan/lib/ 2>/dev/null
        cp /var/jb/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/bin/ 2>/dev/null
        chmod +x /usr/lib/ziyan/bin/lua5.3 2>/dev/null
        echo "Files copied"
    else
        echo "Cannot write to /usr/lib"
    fi
    
    # 验证
    /usr/lib/ziyan/bin/lua5.3 -e 'print(\"Lua from /usr/lib works!\")' 2>&1 || echo "Still failed"
    """
    out = ssh_exec(ip, copy_cmd)
    print(f"  {out}")
    
    return "FIX_ATTEMPTED"

def test_lua_execution(ip: str, env: str):
    """测试 Lua 执行"""
    print(f"\n[测试] 设备 (env={env}):")
    
    # 测试 1: 基本 Lua 运行
    test1 = ssh_exec(ip, "lua5.3 -e 'print(\"test1\")' 2>&1 || /usr/bin/lua5.3 -e 'print(\"test2\")' 2>&1")
    print(f"  基本 Lua: {test1.strip()}")
    
    # 测试 2: ziYan Lua 运行
    test2 = ssh_exec(ip, "/usr/lib/ziyan/bin/lua5.3 -e 'print(\"ziyan lua\")' 2>&1")
    print(f"  ziYan Lua (/usr/lib): {test2.strip()}")
    
    # 测试 3: jb 路径 Lua 运行
    test3 = ssh_exec(ip, "/var/jb/usr/lib/ziyan/bin/lua5.3 -e 'print(\"jb lua\")' 2>&1")
    print(f"  ziYan Lua (/var/jb): {test3.strip()}")
    
    # 测试 4: 使用 DYLD_LIBRARY_PATH
    test4 = ssh_exec(ip, "DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 -e 'print(\"env lua\")' 2>&1")
    print(f"  ziYan Lua (with env): {test4.strip()}")
    
    return {
        "basic": "test1" in test1 or "test2" in test1,
        "ziyan_usr": "ziyan lua" in test2,
        "ziyan_jb": "jb lua" in test3,
        "ziyan_env": "env lua" in test4,
    }

def run_script_on_device(ip: str, script_name: str, env: str):
    """在设备上运行 Lua 脚本"""
    print(f"\n{'='*60}")
    print(f"运行脚本: {script_name}")
    print(f"{'='*60}")
    
    script_path = f"/var/mobile/Media/ZiYan/{script_name}"
    
    # 检查脚本是否存在
    check = ssh_exec(ip, f"ls -la {script_path}")
    print(f"\n[1] 脚本检查: {check.strip()}")
    
    # 方法 1: 通过 ziYan Lua 直接运行
    print("\n[2] 尝试通过 ziYan Lua 运行:")
    
    # 准备运行命令 - 需要正确的 Lua 环境
    # 子砚脚本通常需要在 App 环境中运行（有 package.path 等）
    # 这里先尝试简单运行看看是否有错误
    
    run_cmd = f"""
    cd /var/mobile/Media/ZiYan
    DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 "{script_path}" 2>&1 &
    echo "Started Lua script, PID: $!"
    sleep 2
    ps aux | grep lua5.3 | grep -v grep
    """
    
    out = ssh_exec(ip, run_cmd)
    print(f"  结果: {out}")
    
    # 方法 2: 使用 ziYan_run.lua 引导
    print("\n[3] 尝试通过 ziYan_run.lua 引导:")
    
    # 先查看 ziYan_run.lua 的启动方式
    check_runner = ssh_exec(ip, "head -50 /usr/lib/ziyan/lib/lua/ziyan_run.lua 2>/dev/null || head -50 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua 2>/dev/null")
    print(f"  ziYan_run.lua 预览: {check_runner[:500]}")
    
    # 尝试使用 ziYan_run.lua
    run_with_runner = f"""
    cd /var/mobile/Media/ZiYan
    DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua "{script_path}" 2>&1 &
    echo "Started with ziYan_run.lua"
    sleep 3
    """
    out2 = ssh_exec(ip, run_with_runner)
    print(f"  结果: {out2}")
    
    # 检查运行状态
    print("\n[4] 检查运行状态:")
    ps = ssh_exec(ip, "ps aux | grep -E 'lua5|ziyan' | grep -v grep | head -10")
    print(f"  进程列表:\n{ps}")
    
    # 检查日志
    print("\n[5] 检查日志:")
    logs = ssh_exec(ip, f"ls -la /tmp/ziyan_*.log 2>/dev/null && echo '---' && cat /tmp/ziyan_run_*.log 2>/dev/null | tail -20")
    print(f"  日志:\n{logs[:1000]}")
    
    return True

def collect_performance_metrics(ip: str, device_id: str):
    """采集性能指标"""
    metrics = {"device_id": device_id, "timestamp": datetime.now().isoformat()}
    
    # 系统负载
    metrics["load"] = ssh_exec(ip, "uptime").strip()
    
    # 内存
    mem = ssh_exec(ip, "vm_stat | head -5").strip()
    metrics["vm_stat"] = mem
    
    # 子砚进程
    procs = ssh_exec(ip, "ps aux | grep -E 'ziyan|lua5' | grep -v grep").strip()
    metrics["processes"] = procs.split('\n')[:10] if procs else []
    
    # SpringBoard
    sb = ssh_exec(ip, "ps aux | grep SpringBoard | grep -v grep").strip()
    metrics["springboard"] = "RUNNING" if sb else "NOT_RUNNING"
    
    return metrics

def main():
    print("=" * 60)
    print("修复和运行子砚脚本")
    print(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    
    results = []
    
    # 1. 修复 rootless 设备
    print("\n" + "#" * 60)
    print("# 步骤 1: 修复 rootless 设备库加载")
    print("#" * 60)
    fix_rootless_libraries(DEVICE_53["ip"])
    
    # 2. 测试所有设备的 Lua 执行
    print("\n" + "#" * 60)
    print("# 步骤 2: 测试 Lua 执行")
    print("#" * 60)
    
    devices = [DEVICE_101, DEVICE_112, DEVICE_166, DEVICE_53]
    for dev in devices:
        print(f"\n--- 设备 {dev['id']} ({dev['ip']}, {dev['env']}) ---")
        test_result = test_lua_execution(dev["ip"], dev["env"])
        results.append({"device": dev["id"], "test": test_result})
    
    # 3. 在设备上运行脚本
    print("\n" + "#" * 60)
    print("# 步骤 3: 运行测试脚本")
    print("#" * 60)
    
    for dev in devices:
        print(f"\n{'*'*60}")
        print(f"设备 {dev['id']} ({dev['ip']}): 运行 {dev['script']}")
        print(f"{'*'*60}")
        run_script_on_device(dev["ip"], dev["script"], dev["env"])
        time.sleep(3)  # 等待脚本启动
    
    # 4. 采集性能指标
    print("\n" + "#" * 60)
    print("# 步骤 4: 采集性能指标")
    print("#" * 60)
    
    all_metrics = []
    for dev in devices:
        metrics = collect_performance_metrics(dev["ip"], dev["id"])
        all_metrics.append(metrics)
        
        print(f"\n设备 {dev['id']}:")
        print(f"  负载: {metrics['load']}")
        print(f"  SpringBoard: {metrics['springboard']}")
        print(f"  子砚进程数: {len(metrics['processes'])}")
    
    # 5. 保存数据
    print("\n" + "#" * 60)
    print("# 步骤 5: 保存数据")
    print("#" * 60)
    
    output = {
        "timestamp": datetime.now().isoformat(),
        "lua_test_results": results,
        "performance_metrics": all_metrics,
        "notes": """
关键发现:
1. iPhone 7 系列 (rootful): Lua 可正常通过 /usr/lib/ziyan/bin/lua5.3 运行
2. iPhone 8 Plus (rootless): 需要使用 DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib 
   来确保 dyld 能找到 liblua5.3.dylib
3. 子砚脚本需要在 App 环境中才能使用完整的 API (findColor, tap 等)
4. 直接运行 lua5.3 只能测试基本 Lua 功能
        """.strip()
    }
    
    output_file = LOG_DIR / f"fix_and_run_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    
    print(f"\n数据已保存: {output_file}")
    
    # 6. 给出操作建议
    print("\n" + "#" * 60)
    print("# 操作建议")
    print("#" * 60)
    print("""
📱 在设备上手动启动子砚 App:

1. iPhone 7 系列 (设备 101/112/166):
   - 子砚已作为越狱 tweak 安装
   - 打开子砚 App → 进入脚本列表 → 运行 ios7_副本.lua

2. iPhone 8 Plus (设备 53):
   - 子砚已通过 sideload 安装
   - 打开子砚 App → 进入脚本列表 → 运行 ios8p_副本.lua

🔧 Rootless 环境修复 (如果需要):
   在 SSH 中执行:
   mkdir -p /usr/lib/ziyan/{bin,lib}
   ln -sf /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib /usr/lib/ziyan/lib/
   ln -sf /var/jb/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/bin/

或在运行时设置环境变量:
   DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib lua5.3 script.lua
""")
    
    return 0

if __name__ == "__main__":
    import sys
    sys.exit(main())
