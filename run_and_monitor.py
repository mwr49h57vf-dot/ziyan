#!/usr/bin/env python3
"""
在设备上运行子砚脚本并采集运行数据。
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
LOG_DIR = ROOT / "logs" / "live_run"

# 设备配置
DEVICES = [
    {"id": "101", "ip": "192.168.31.101", "model": "iPhone 7", "ios": "13.6", "script": "ios7_副本.lua"},
    {"id": "112", "ip": "192.168.31.112", "model": "iPhone 7 Plus", "ios": "13.2.2", "script": "ios7_副本.lua"},
    {"id": "166", "ip": "192.168.31.166", "model": "iPhone 7", "ios": "13.1.2", "script": "ios7_副本.lua"},
    {"id": "53", "ip": "192.168.31.53", "model": "iPhone 8 Plus", "ios": "16.7.16", "script": "ios8p_副本.lua"},
]

def ssh_exec(ip: str, cmd: str, timeout: int = 30) -> str:
    r = subprocess.run(
        ["sshpass", "-p", PASS, "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", f"root@{ip}", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return (r.stdout or "") + (r.stderr or "")

def read_log_file(ip: str, log_path: str) -> str:
    """读取日志文件"""
    return ssh_exec(ip, f"cat {log_path} 2>/dev/null")

def get_process_list(ip: str) -> str:
    """获取进程列表"""
    return ssh_exec(ip, "ps aux | grep -E 'ziyan|lua5|springboard' | grep -v grep")

def get_memory_usage(ip: str) -> dict:
    """获取内存使用情况"""
    result = {}
    
    # 系统内存
    vm_stat = ssh_exec(ip, "vm_stat").strip()
    result["vm_stat"] = vm_stat
    
    # 子砚相关进程内存
    mem_info = ssh_exec(ip, "ps aux | grep -E 'ziyan|lua5' | grep -v grep | awk '{print $11, $4, $6}'")
    result["process_mem"] = mem_info
    
    return result

def monitor_running_script(device: dict, duration: int = 60):
    """监控正在运行的脚本"""
    ip = device["ip"]
    device_id = device["id"]
    
    print(f"\n{'='*60}")
    print(f"[实时监控] 设备 {device_id} ({ip})")
    print(f"{'='*60}")
    
    # 读取历史日志
    log_files = {
        "ios7": "/tmp/ziyan_run_ios7.lua.log",
        "ios8p": "/tmp/ziyan_run_ios8p.lua.log",
        "general": "/tmp/ziyan_ios7.log" if device_id != "53" else "/tmp/ziyan_ios8p.log",
    }
    
    print(f"\n[1] 读取历史日志:")
    for key, path in log_files.items():
        log_content = read_log_file(ip, path)
        if log_content.strip():
            print(f"\n  {path}:")
            for line in log_content.strip().split('\n')[-10:]:
                print(f"    {line[:120]}")
        else:
            print(f"\n  {path}: (空)")
    
    # 检查当前进程
    print(f"\n[2] 当前进程状态:")
    procs = get_process_list(ip)
    if procs.strip():
        print(f"  {procs}")
    else:
        print(f"  无子砚相关进程运行")
    
    # 检查 SpringBoard 状态
    print(f"\n[3] SpringBoard 状态:")
    sb_procs = ssh_exec(ip, "ps aux | grep SpringBoard | grep -v grep")
    if sb_procs.strip():
        print(f"  SpringBoard 正在运行")
        # 获取 SpringBoard 内存
        sb_mem = ssh_exec(ip, "ps aux | grep SpringBoard | grep -v grep | awk '{print $4, $6}'")
        print(f"  SB 内存: {sb_mem.strip()}")
    else:
        print(f"  ⚠️ SpringBoard 未运行!")
    
    # 尝试通过子砚 App 方式运行脚本
    print(f"\n[4] 检查子砚 App 脚本目录:")
    scripts_dir = ssh_exec(ip, "ls -la /var/mobile/Media/ZiYan/Scripts/ 2>/dev/null")
    print(f"  {scripts_dir[:300]}")
    
    # 检查 ziYan_run.lua 如何启动用户脚本
    print(f"\n[5] 查看 ziYan_run.lua 启动方式:")
    run_script = ssh_exec(ip, "cat /usr/lib/ziyan/lib/lua/ziyan_run.lua 2>/dev/null | head -100")
    if run_script:
        print(f"  ziYan_run.lua 内容预览:")
        for line in run_script.split('\n')[:30]:
            print(f"    {line[:120]}")
    
    # 尝试在设备上手动触发脚本运行
    print(f"\n[6] 尝试通过 ziYan_run.lua 运行脚本:")
    # 方式: 创建一个命令脚本来触发运行
    cmd_script = f"""
    # 检查子砚前端是否在前台
    frontmost=$(ssh root@192.168.31.{device_id} "defaults read com.apple.springboard SBFrontmostApplicationDisplayIdentifier 2>/dev/null || echo 'unknown'")
    echo "当前前台应用: $frontmost"
    """
    print(f"  (需要在设备上操作子砚 App 界面来运行脚本)")
    
    # 采集系统性能
    print(f"\n[7] 系统性能快照:")
    mem_data = get_memory_usage(ip)
    print(f"  VM Stat:")
    for line in mem_data["vm_stat"].split('\n')[:5]:
        print(f"    {line}")
    print(f"  进程内存:")
    if mem_data["process_mem"].strip():
        for line in mem_data["process_mem"].split('\n')[:5]:
            print(f"    {line}")
    
    return {
        "device_id": device_id,
        "timestamp": datetime.now().isoformat(),
        "logs": {k: read_log_file(ip, v)[:1000] for k, v in log_files.items()},
        "processes": get_process_list(ip),
        "springboard": sb_procs,
        "memory": mem_data,
    }

def generate_analysis_report(all_data: list):
    """生成分析报告"""
    report_lines = []
    report_lines.append("=" * 60)
    report_lines.append("子砚设备实时运行分析报告")
    report_lines.append(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    report_lines.append("=" * 60)
    
    for data in all_data:
        device_id = data["device_id"]
        report_lines.append(f"\n{'='*60}")
        report_lines.append(f"设备 {device_id}")
        report_lines.append(f"{'='*60}")
        
        # 日志分析
        report_lines.append("\n[运行日志分析]:")
        for log_key, log_content in data.get("logs", {}).items():
            if log_content.strip():
                report_lines.append(f"  {log_key}: {len(log_content)} 字节")
                # 提取关键信息
                if "findColor" in log_content or "tap" in log_content:
                    report_lines.append(f"    → 包含找色/触控操作记录")
                if "error" in log_content.lower() or "fail" in log_content.lower():
                    report_lines.append(f"    ⚠️  可能包含错误信息")
        
        # 进程分析
        report_lines.append("\n[进程状态]:")
        procs = data.get("processes", "")
        if procs and "ziyan" in procs.lower():
            lua_count = procs.count("lua5")
            report_lines.append(f"  子砚进程: 存在")
            report_lines.append(f"  Lua 进程数: {lua_count}")
        else:
            report_lines.append(f"  ⚠️  无子砚相关进程运行")
        
        # SpringBoard 状态
        report_lines.append("\n[SpringBoard]:")
        sb = data.get("springboard", "")
        if sb and sb.strip():
            report_lines.append(f"  ✅ SpringBoard 正常运行")
        else:
            report_lines.append(f"  ⚠️ SpringBoard 可能异常")
        
        # 内存状态
        mem = data.get("memory", {})
        vm = mem.get("vm_stat", "")
        if vm:
            try:
                for line in vm.split('\n'):
                    if "Pages free" in line:
                        free_pages = line.split(':')[1].strip()
                        report_lines.append(f"\n[内存状态]:")
                        report_lines.append(f"  空闲页: {free_pages}")
            except:
                pass
    
    # 总结
    report_lines.append(f"\n{'='*60}")
    report_lines.append("总结")
    report_lines.append(f"{'='*60}")
    report_lines.append("""
📌 下一步操作:

1. 在每台设备上打开「子砚」App
2. 进入脚本列表，选择已部署的脚本
3. 点击运行按钮开始执行
4. 观察脚本运行日志和 Toast 提示
5. 运行 5-10 分钟后再次采集数据

如果子砚 App 未在前台:
- 禁止通过 SSH 执行 killall SpringBoard（BLOCKED_AUTO_SB_RESTART）
- 或在设备上手动点击子砚图标
""")
    
    return "\n".join(report_lines)

def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    
    print("=" * 60)
    print("子砚设备实时监控与分析")
    print(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    
    all_data = []
    
    for device in DEVICES:
        try:
            data = monitor_running_script(device)
            all_data.append(data)
            
            # 保存设备数据
            device_log = LOG_DIR / f"live_{device['id']}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
            with open(device_log, "w", encoding="utf-8") as f:
                # 简化 JSON 序列化
                json.dump(data, f, ensure_ascii=False, indent=2, default=str)
            print(f"\n  [保存] {device_log}")
            
        except Exception as e:
            print(f"\n[ERROR] 设备 {device['id']} 监控失败: {e}")
            import traceback
            traceback.print_exc()
            all_data.append({"device_id": device["id"], "error": str(e)})
    
    # 生成分析报告
    print("\n" + "=" * 60)
    print("生成分析报告...")
    print("=" * 60)
    
    report = generate_analysis_report(all_data)
    
    # 保存报告
    report_file = LOG_DIR / f"analysis_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.md"
    with open(report_file, "w", encoding="utf-8") as f:
        f.write(report)
    
    print(f"\n报告已保存: {report_file}")
    print(f"\n{'='*60}")
    print("请在设备上手动启动子砚 App 并运行脚本!")
    print(f"{'='*60}")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
