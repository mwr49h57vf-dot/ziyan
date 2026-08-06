#!/usr/bin/env python3
"""
部署 ios7_副本.lua 和 ios8p_副本.lua 到目标设备，并启动子砚 App 运行。
"""

import subprocess
import sys
import os
from pathlib import Path

# 配置
ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
PASS = os.environ.get("ZIYAN_SSH_PASS", "alpine")
DEST_DIR = "/var/mobile/Media/ZiYan"

# 设备列表: (设备编号, IP, 脚本文件)
DEVICES = [
    ("101", "192.168.31.101", "ios7_副本.lua"),
    ("112", "192.168.31.112", "ios7_副本.lua"),
    ("166", "192.168.31.166", "ios7_副本.lua"),
    ("53", "192.168.31.53", "ios8p_副本.lua"),
]

def ssh_exec(ip: str, cmd: str, timeout: int = 60) -> str:
    """执行 SSH 命令并返回输出"""
    r = subprocess.run(
        [
            "sshpass", "-p", PASS,
            "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
            f"root@{ip}", cmd
        ],
        capture_output=True, text=True, timeout=timeout
    )
    return (r.stdout or "") + (r.stderr or "")

def scp_upload(ip: str, src: str, dst: str) -> bool:
    """通过 SCP 上传文件"""
    r = subprocess.run(
        [
            "sshpass", "-p", PASS,
            "scp", "-o", "StrictHostKeyChecking=no",
            src, f"root@{ip}:{dst}"
        ],
        capture_output=True, text=True, timeout=30
    )
    return r.returncode == 0

def check_device(ip: str) -> bool:
    """检查设备是否在线"""
    try:
        result = subprocess.run(
            ["ping", "-c", "2", "-W", "2", ip],
            capture_output=True, text=True, timeout=5
        )
        return result.returncode == 0
    except:
        return False

def deploy_and_run(device_id: str, ip: str, script_file: str) -> bool:
    """部署脚本并启动子砚 App"""
    
    src_path = ROOT / script_file
    if not src_path.exists():
        print(f"[ERROR] 脚本文件不存在: {src_path}")
        return False
    
    print(f"\n{'='*60}")
    print(f"[设备 {device_id}] IP: {ip}")
    print(f"{'='*60}")
    
    # 1. 检查设备连通性
    print(f"\n[1] 检查设备连通性...")
    if not check_device(ip):
        print(f"  [WARN] 设备 {ip} 不在线，尝试 SSH 连接...")
    else:
        print(f"  [OK] 设备在线")
    
    # 2. 检查 SSH 连接
    print(f"\n[2] 检查 SSH 连接...")
    try:
        ssh_out = ssh_exec(ip, "echo 'SSH OK' && uname -a && cat /etc/os-release 2>/dev/null | head -3")
        print(f"  [OK] SSH 连接成功")
        print(f"  {ssh_out.split(chr(10))[0:3]}")
    except Exception as e:
        print(f"  [ERROR] SSH 连接失败: {e}")
        return False
    
    # 3. 检查子砚目录
    print(f"\n[3] 检查子砚目录...")
    ssh_exec(ip, f"mkdir -p {DEST_DIR} && chown -R mobile:mobile {DEST_DIR} 2>/dev/null")
    ssh_out = ssh_exec(ip, f"ls -la {DEST_DIR}/ | head -10")
    print(f"  [OK] {DEST_DIR}:")
    for line in ssh_out.strip().split('\n')[:8]:
        print(f"    {line}")
    
    # 4. 上传脚本
    dst_path = f"{DEST_DIR}/{script_file}"
    print(f"\n[4] 上传脚本 {script_file} -> {dst_path}")
    if scp_upload(ip, str(src_path), dst_path):
        print(f"  [OK] 上传成功")
        ssh_exec(ip, f"chown mobile:mobile {dst_path} && chmod 644 {dst_path}")
    else:
        print(f"  [ERROR] 上传失败")
        return False
    
    # 5. 确认上传
    print(f"\n[5] 确认文件上传...")
    ssh_out = ssh_exec(ip, f"ls -la {dst_path} && wc -l {dst_path}")
    print(f"  {ssh_out.strip()}")
    
    # 6. 准备运行脚本 (通过子砚 App 的方式)
    # 方式: 复制脚本到 Scripts 目录并触发运行
    scripts_dir = f"{DEST_DIR}/Scripts"
    print(f"\n[6] 准备脚本目录 {scripts_dir}...")
    ssh_exec(ip, f"mkdir -p {scripts_dir} && cp {dst_path} {scripts_dir}/ && chown -R mobile:mobile {scripts_dir}")
    
    # 7. 检查子砚 App 是否运行
    print(f"\n[7] 检查子砚 App 运行状态...")
    ssh_out = ssh_exec(ip, "ps aux | grep -i ziyan | grep -v grep")
    if ssh_out.strip():
        print(f"  [OK] 子砚 App 正在运行:")
        for line in ssh_out.strip().split('\n'):
            print(f"    {line}")
    else:
        print(f"  [WARN] 子砚 App 未运行")
    
    # 8. 尝试启动 Lua 脚本
    # 子砚通常通过 ziYan_run.lua 来运行脚本
    # 我们可以检查 ziYan_run.lua 的内容，了解如何运行用户脚本
    print(f"\n[8] 准备运行脚本...")
    print(f"  脚本已部署到 {scripts_dir}/{script_file}")
    print(f"  请在子砚 App 中手动运行此脚本，或通过子砚的控制接口触发")
    
    # 检查 ziYan 运行器
    print(f"\n[9] 检查 ziYan 运行器...")
    ssh_out = ssh_exec(ip, "find / -name 'ziYan_run.lua' -o -name 'lua5.3' 2>/dev/null | head -5")
    print(f"  {ssh_out.strip()}")
    
    # 10. 尝试通过命令行直接运行 Lua 脚本
    # 这需要子砚的 Lua 环境
    print(f"\n[10] 尝试直接运行 Lua 脚本...")
    lua_paths = [
        "/var/jb/usr/lib/ziyan/bin/lua5.3",
        "/usr/lib/ziyan/bin/lua5.3",
    ]
    lua_bin = None
    for path in lua_paths:
        ssh_out = ssh_exec(ip, f"test -f {path} && echo 'EXISTS' || echo 'NOT_FOUND'")
        if "EXISTS" in ssh_out:
            lua_bin = path
            break
    
    if lua_bin:
        print(f"  [OK] 找到 Lua: {lua_bin}")
        # 尝试运行脚本（需要正确的环境）
        # 实际上子砚脚本需要在 App 环境中运行
        print(f"  [INFO] 子砚脚本需要在 App 环境中运行，已将脚本部署到 Scripts 目录")
    else:
        print(f"  [WARN] 未找到 Lua 二进制文件")
    
    return True

def main():
    print("=" * 60)
    print("子砚脚本部署工具")
    print("=" * 60)
    print(f"\n目标设备数: {len(DEVICES)}")
    print(f"目标路径: {DEST_DIR}")
    print(f"SSH 密码: {'*' * len(PASS)}")
    
    results = {}
    for device_id, ip, script_file in DEVICES:
        try:
            success = deploy_and_run(device_id, ip, script_file)
            results[device_id] = success
        except Exception as e:
            print(f"\n[ERROR] 设备 {device_id} 部署失败: {e}")
            results[device_id] = False
    
    print("\n" + "=" * 60)
    print("部署结果汇总")
    print("=" * 60)
    for device_id, success in results.items():
        status = "✅ 成功" if success else "❌ 失败"
        print(f"  设备 {device_id}: {status}")
    
    success_count = sum(1 for v in results.values() if v)
    print(f"\n总计: {success_count}/{len(DEVICES)} 台设备部署成功")
    
    # 输出后续操作提示
    print("\n" + "=" * 60)
    print("后续操作")
    print("=" * 60)
    print("""
1. 在每台设备上打开「子砚」App
2. 进入「脚本」或「Scripts」目录
3. 找到已部署的脚本:
   - 设备 101/112/166: ios7_副本.lua
   - 设备 53: ios8p_副本.lua
4. 点击运行按钮启动脚本
5. 脚本运行后会:
   - 显示 toast 提示
   - 执行找色操作
   - 点击找到的目标
6. 观察运行日志和性能数据
""")
    
    return 0 if success_count == len(DEVICES) else 1

if __name__ == "__main__":
    sys.exit(main())
