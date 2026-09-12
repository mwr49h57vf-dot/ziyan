#!/usr/bin/env python3
"""
在设备上启动子砚 App 并采集运行数据。
"""

import subprocess
import sys
import os
import time
import json
from pathlib import Path
from datetime import datetime

ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
PASS = os.environ.get("ZIYAN_SSH_PASS", "alpine")
LOG_DIR = ROOT / "logs" / "device_run"

# 设备配置
DEVICES = [
    {"id": "101", "ip": "192.168.31.101", "model": "iPhone 7", "ios": "13.x", "script": "ios7_副本.lua"},
    {"id": "112", "ip": "192.168.31.112", "model": "iPhone 7 Plus", "ios": "13.x", "script": "ios7_副本.lua"},
    {"id": "166", "ip": "192.168.31.166", "model": "iPhone 7", "ios": "13.1.2", "script": "ios7_副本.lua"},
    {"id": "53", "ip": "192.168.31.53", "model": "iPhone 8 Plus", "ios": "16.7.16", "script": "ios8p_副本.lua"},
]

# Registered in the project plan, but excluded from the active four-device
# acceptance loop until its rootless test contract is defined.
ADDITIONAL_DEVICES = [
    {
        "id": "61",
        "ip": "192.168.31.61",
        "model": "iPhone 7",
        "product_type": "iPhone9,1",
        "ios": "15.8.8",
        "env": "rootless",
        "ssh_user": "mobile",
        "script": "ios7_副本.lua",
        "acceptance": "REGISTERED_SSH_ONLY",
    },
]

def ssh_exec(ip: str, cmd: str, timeout: int = 30) -> str:
    r = subprocess.run(
        ["sshpass", "-p", PASS, "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", f"root@{ip}", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return (r.stdout or "") + (r.stderr or "")

def get_device_info(device: dict) -> dict:
    """获取设备详细信息"""
    ip = device["ip"]
    info = {}
    
    # iOS 版本
    info["ios_version"] = ssh_exec(ip, "sw_vers -productVersion 2>/dev/null || echo 'unknown'").strip()
    
    # 内存
    mem_out = ssh_exec(ip, "vm_stat | head -3; sysctl hw.memsize 2>/dev/null").strip()
    info["memory_info"] = mem_out
    
    # CPU
    cpu_out = ssh_exec(ip, "sysctl -n hw.ncpu hw.cpuspeed 2>/dev/null").strip()
    info["cpu_info"] = cpu_out
    
    # 子砚进程状态
    ziyan_out = ssh_exec(ip, "ps aux | grep -i ziyan | grep -v grep | wc -l").strip()
    info["ziyan_procs"] = ziyan_out
    
    # Lua 进程
    lua_out = ssh_exec(ip, "ps aux | grep lua5.3 | grep -v grep | wc -l").strip()
    info["lua_procs"] = lua_out
    
    # 子砚 App 前端
    app_out = ssh_exec(ip, "ps aux | grep -i com.ziyan | grep -v grep").strip()
    info["app_running"] = "YES" if app_out else "NO"
    
    return info

def check_ziyan_logs(ip: str) -> list:
    """获取子砚日志"""
    logs = []
    # 检查日志目录
    log_paths = [
        "/var/mobile/Media/ZiYan/logs/",
        "/var/mobile/Media/ZiYan/ZYCV/logs/",
        "/tmp/ziyan_*.log",
    ]
    for path in log_paths:
        out = ssh_exec(ip, f"ls -la {path} 2>/dev/null | head -5")
        if out and "No such file" not in out:
            logs.append({"path": path, "content": out[:500]})
    return logs

def collect_performance_data(ip: str) -> dict:
    """采集性能数据"""
    perf = {}
    
    # 系统负载
    load_out = ssh_exec(ip, "uptime").strip()
    perf["load"] = load_out
    
    # 内存使用
    mem_out = ssh_exec(ip, "top -l 1 -n 0 | grep -E 'PhysMem|Networks' | head -3").strip()
    perf["memory"] = mem_out
    
    # 子砚相关进程
    procs_out = ssh_exec(ip, "ps aux | grep -E 'ziyan|lua5' | grep -v grep | awk '{print $1, $2, $3, $4, $11}'").strip()
    perf["processes"] = procs_out
    
    # 网络状态
    net_out = ssh_exec(ip, "netstat -an | grep -E 'LISTEN|ESTABLISHED' | head -10").strip()
    perf["network"] = net_out
    
    return perf

def trigger_script_via_ziyan(ip: str, script_name: str) -> dict:
    """尝试通过子砚接口运行脚本"""
    result = {"method": "", "success": False, "message": ""}
    
    # 方法 1: 检查子砚的控制 socket 或 API
    control_paths = [
        "/var/mobile/Media/ZiYan/.ziyan_control",
        "/tmp/.ziyan_socket",
        "/var/run/ziyan.sock",
    ]
    
    for path in control_paths:
        out = ssh_exec(ip, f"test -e {path} && echo 'EXISTS' || echo 'NOT_FOUND'")
        if "EXISTS" in out:
            result["method"] = f"Found control path: {path}"
            break
    
    # 方法 2: 检查子砚 App 是否有 URL scheme
    url_scheme = ssh_exec(ip, "defaults read /Applications/ZiYan.app/Info CFBundleURLSchemes 2>/dev/null").strip()
    if url_scheme:
        result["url_scheme"] = url_scheme
    
    # 方法 3: 使用 open 命令尝试
    # 这需要知道正确的 URL scheme
    
    # 方法 4: 检查子砚前端的脚本运行接口
    lua_runtime = ssh_exec(ip, "find / -name 'ziyan_run.lua' 2>/dev/null | head -3").strip()
    if lua_runtime:
        result["lua_runtime"] = lua_runtime
        # 尝试查看 ziyan_run.lua 的内容
        run_content = ssh_exec(ip, f"cat {lua_runtime.split(chr(10))[0]} 2>/dev/null | head -50").strip()
        result["run_content_preview"] = run_content[:500]
    
    # 方法 5: 尝试直接通过 lua5.3 运行（如果有正确的环境）
    # 子砚脚本通常依赖于 App 提供的 API，所以直接运行可能会失败
    
    result["success"] = True  # 只是表示检查完成
    return result

def monitor_device(device: dict, duration: int = 10):
    """监控设备一段时间"""
    ip = device["ip"]
    device_id = device["id"]
    
    print(f"\n{'='*60}")
    print(f"[监控] 设备 {device_id} ({ip})")
    print(f"{'='*60}")
    
    # 采集初始信息
    print(f"\n[1] 设备信息:")
    info = get_device_info(device)
    for key, val in info.items():
        print(f"  {key}: {val}")
    
    # 检查脚本部署
    print(f"\n[2] 检查脚本部署:")
    script_path = f"/var/mobile/Media/ZiYan/{device['script']}"
    out = ssh_exec(ip, f"ls -la {script_path} 2>/dev/null")
    print(f"  {script_path}: {'OK' if out else 'NOT FOUND'}")
    
    # 尝试触发脚本
    print(f"\n[3] 尝试触发脚本运行:")
    trigger_result = trigger_script_via_ziyan(ip, device["script"])
    print(f"  检查结果: {trigger_result['message']}")
    if trigger_result.get("method"):
        print(f"  找到控制路径: {trigger_result['method']}")
    if trigger_result.get("url_scheme"):
        print(f"  URL Scheme: {trigger_result['url_scheme']}")
    
    # 检查日志
    print(f"\n[4] 子砚日志:")
    logs = check_ziyan_logs(ip)
    if logs:
        for log in logs[:3]:
            print(f"  [{log['path']}]:")
            print(f"    {log['content'][:200]}")
    else:
        out = ssh_exec(ip, "find /var/mobile/Media/ZiYan -name '*.log' -o -name '*.txt' 2>/dev/null | head -10")
        print(f"  日志文件: {out[:300]}")
    
    # 采集性能快照
    print(f"\n[5] 性能快照:")
    perf = collect_performance_data(ip)
    for key, val in perf.items():
        print(f"  {key}:")
        for line in val.split('\n')[:5]:
            print(f"    {line[:100]}")
    
    # 保存数据
    data = {
        "device_id": device_id,
        "ip": ip,
        "model": device["model"],
        "ios": device["ios"],
        "timestamp": datetime.now().isoformat(),
        "info": info,
        "script_deployed": bool(out),
        "trigger_result": trigger_result,
        "logs": logs,
        "performance": perf,
    }
    
    return data

def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    
    print("=" * 60)
    print("子砚设备运行状态监控")
    print(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    
    all_data = []
    
    for device in DEVICES:
        try:
            data = monitor_device(device)
            all_data.append(data)
            
            # 保存单设备数据
            device_log = LOG_DIR / f"device_{device['id']}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
            with open(device_log, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            print(f"\n  [保存] {device_log}")
            
        except Exception as e:
            print(f"\n[ERROR] 设备 {device['id']} 监控失败: {e}")
            all_data.append({"device_id": device["id"], "error": str(e)})
    
    # 保存汇总数据
    summary_log = LOG_DIR / f"summary_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(summary_log, "w", encoding="utf-8") as f:
        json.dump(all_data, f, ensure_ascii=False, indent=2)
    
    print(f"\n{'='*60}")
    print(f"[汇总] 数据已保存到 {LOG_DIR}")
    print(f"{'='*60}")
    
    # 输出运行建议
    print("""
📱 手动启动脚本步骤:

1. 检查子砚 App 是否已安装并运行
   iPhone 7 (101/112/166): rootful 环境，子砚已通过 deb 安装
   iPhone 8 Plus (53): rootless 环境，子砚已通过 sideload 安装

2. 在设备上打开「子砚」App
   - 找到图标并点击打开
   - 等待 App 完全加载

3. 运行脚本
   - 进入「脚本」或「Scripts」目录
   - 找到 ios7_副本.lua 或 ios8p_副本.lua
   - 点击运行按钮 ▶️

4. 观察运行状态
   - 脚本会显示 toast 提示
   - 执行找色操作
   - 点击找到的目标位置

5. 如果 App 未运行:
   - 通过 SSH 手动启动:
     iPhone 7 系列 (rootful):
     ssh root@<ip> "open com.ziyan.ziyan"
     或
     ssh root@<ip> "launchctl load /Library/LaunchDaemons/com.ziyan.plist"
   
   - iPhone 8 Plus (rootless):
     ssh root@<ip> "open com.ziyan.ziyan"
""")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
