#!/usr/bin/env python3
"""
诊断设备 53 (rootless) 的 Lua 库加载问题，并尝试修复。
"""

import subprocess
import os
from pathlib import Path

PASS = os.environ.get("ZIYAN_SSH_PASS", "alpine")

# 设备配置
DEVICE_53 = {"id": "53", "ip": "192.168.31.53", "env": "rootless"}
DEVICE_166 = {"id": "166", "ip": "192.168.31.166", "env": "rootful"}

def ssh_exec(ip: str, cmd: str, timeout: int = 30) -> str:
    r = subprocess.run(
        ["sshpass", "-p", PASS, "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", f"root@{ip}", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return (r.stdout or "") + (r.stderr or "")

def diagnose_rootless_device():
    """诊断 rootless 设备的库加载问题"""
    print("=" * 60)
    print("诊断 iPhone 8 Plus (设备 53, rootless)")
    print("=" * 60)
    
    ip = DEVICE_53["ip"]
    
    # 1. 检查 liblua5.3.dylib 的实际位置
    print("\n[1] 查找 liblua5.3.dylib:")
    search_cmd = """
    echo "=== 搜索 liblua5.3.dylib ==="
    find /var/jb -name 'liblua5.3.dylib' 2>/dev/null
    find /usr/lib -name 'liblua5.3.dylib' 2>/dev/null
    ls -la /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib 2>/dev/null || echo "NOT in /var/jb/usr/lib/ziyan/lib/"
    ls -la /usr/lib/ziyan/lib/liblua5.3.dylib 2>/dev/null || echo "NOT in /usr/lib/ziyan/lib/"
    """
    out = ssh_exec(ip, search_cmd)
    print(out)
    
    # 2. 检查 lua5.3 二进制文件
    print("\n[2] 检查 lua5.3 二进制:")
    lua_cmd = """
    echo "=== lua5.3 路径 ==="
    which lua5.3 2>/dev/null
    ls -la /var/jb/usr/lib/ziyan/bin/lua5.3 2>/dev/null
    ls -la /usr/lib/ziyan/bin/lua5.3 2>/dev/null
    
    echo "=== 使用 file 命令检查 lua5.3 ==="
    file /var/jb/usr/lib/ziyan/bin/lua5.3 2>/dev/null
    file /usr/lib/ziyan/bin/lua5.3 2>/dev/null
    
    echo "=== otool 检查依赖库 ==="
    otool -L /var/jb/usr/lib/ziyan/bin/lua5.3 2>/dev/null
    otool -L /usr/lib/ziyan/bin/lua5.3 2>/dev/null
    """
    out = ssh_exec(ip, lua_cmd)
    print(out)
    
    # 3. 检查 rootless 环境的路径映射
    print("\n[3] 检查 rootless 路径映射:")
    path_cmd = """
    echo "=== /var/jb vs /usr/lib ==="
    ls -la /var/jb/usr/lib/ 2>/dev/null | head -10
    ls -la /var/jb/usr/lib/ziyan/ 2>/dev/null | head -10
    ls -la /var/jb/usr/lib/ziyan/lib/ 2>/dev/null | head -20
    
    echo "=== /usr/lib (系统原始) ==="
    ls -la /usr/lib/ziyan/ 2>/dev/null || echo "No /usr/lib/ziyan"
    """
    out = ssh_exec(ip, path_cmd)
    print(out)
    
    # 4. 检查 DYLD 环境变量
    print("\n[4] 检查 DYLD 配置:")
    dyld_cmd = """
    echo "=== 检查 DYLD_LIBRARY_PATH ==="
    echo $DYLD_LIBRARY_PATH
    echo $DYLD_FALLBACK_LIBRARY_PATH
    
    echo "=== 检查 /etc/ld.so.conf 或类似配置 ==="
    cat /etc/dylib.conf 2>/dev/null || echo "No /etc/dylib.conf"
    
    echo "=== 检查 procursus/dopamine 配置 ==="
    find /var/jb -name '*.plist' -path '*/procursus/*' 2>/dev/null | head -5
    defaults read /var/jb/Library/Preferences/org.procursus.daemon 2>/dev/null || echo "No procursus defaults"
    """
    out = ssh_exec(ip, dyld_cmd)
    print(out)
    
    # 5. 查看 ziyan_framecap 如何成功运行
    print("\n[5] 检查 ziyan_framecap 的库加载方式:")
    framecap_cmd = """
    echo "=== ziyan_framecap 路径 ==="
    ls -la /var/jb/usr/lib/ziyan/bin/ziyan_framecap 2>/dev/null
    ls -la /usr/lib/ziyan/bin/ziyan_framecap 2>/dev/null
    
    echo "=== otool 检查 ziyan_framecap ==="
    otool -L /var/jb/usr/lib/ziyan/bin/ziyan_framecap 2>/dev/null | head -20
    
    echo "=== 检查 ziyan_framecap 的启动脚本 ==="
    cat /var/jb/usr/lib/ziyan/bin/ziyan_framecap 2>/dev/null | head -30
    cat /usr/lib/ziyan/bin/ziyan_framecap 2>/dev/null | head -30
    """
    out = ssh_exec(ip, framecap_cmd)
    print(out)

def diagnose_rootful_device():
    """诊断 rootful 设备的库加载情况作为对比"""
    print("\n" + "=" * 60)
    print("诊断 iPhone 7 (设备 166, rootful) - 作为对比")
    print("=" * 60)
    
    ip = DEVICE_166["ip"]
    
    check_cmd = """
    echo "=== liblua5.3.dylib 位置 ==="
    find /usr -name 'liblua5.3.dylib' 2>/dev/null
    
    echo "=== lua5.3 路径 ==="
    which lua5.3 2>/dev/null
    ls -la /usr/lib/ziyan/bin/lua5.3
    
    echo "=== otool 检查 ==="
    otool -L /usr/lib/ziyan/bin/lua5.3 2>/dev/null
    """
    out = ssh_exec(ip, check_cmd)
    print(out)

def fix_rootless_device():
    """尝试修复 rootless 设备的库加载问题"""
    print("\n" + "=" * 60)
    print("尝试修复 iPhone 8 Plus (设备 53)")
    print("=" * 60)
    
    ip = DEVICE_53["ip"]
    
    # 方案 1: 创建符号链接
    print("\n[方案 1] 创建符号链接:")
    fix_cmd1 = """
    echo "=== 创建 /usr/lib/ziyan/lib 目录 ==="
    mkdir -p /usr/lib/ziyan/lib 2>/dev/null
    
    echo "=== 检查 /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib ==="
    if [ -f /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib ]; then
        echo "存在，创建链接"
        ln -sf /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib /usr/lib/ziyan/lib/liblua5.3.dylib 2>/dev/null
        echo "链接已创建"
        ls -la /usr/lib/ziyan/lib/liblua5.3.dylib
    else
        echo "不存在，需要复制或重建"
    fi
    """
    out = ssh_exec(ip, fix_cmd1)
    print(out)
    
    # 方案 2: 复制库文件
    print("\n[方案 2] 复制库文件:")
    fix_cmd2 = """
    echo "=== 复制 liblua5.3.dylib ==="
    if [ -f /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib ]; then
        cp /var/jb/usr/lib/ziyan/lib/liblua5.3.dylib /usr/lib/ziyan/lib/ 2>/dev/null
        echo "复制成功"
        ls -la /usr/lib/ziyan/lib/liblua5.3.dylib
    fi
    
    echo "=== 也检查 lua5.3 二进制是否需要修复 ==="
    if [ -f /var/jb/usr/lib/ziyan/bin/lua5.3 ]; then
        cp /var/jb/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/bin/ 2>/dev/null
        chmod +x /usr/lib/ziyan/bin/lua5.3
        echo "二进制已复制"
    fi
    """
    out = ssh_exec(ip, fix_cmd2)
    print(out)
    
    # 方案 3: 设置环境变量
    print("\n[方案 3] 设置 DYLD 环境变量:")
    fix_cmd3 = """
    echo "=== 测试通过 DYLD_LIBRARY_PATH ==="
    DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 -e 'print("Hello from Lua!")' 2>&1
    
    echo "=== 或使用 /usr/lib ==="
    /usr/lib/ziyan/bin/lua5.3 -e 'print("Hello from Lua!")' 2>&1
    """
    out = ssh_exec(ip, fix_cmd3)
    print(out)
    
    # 方案 4: 检查 Cydia/Substrate 是否注入了环境
    print("\n[方案 4] 检查 Substrate/Substitute 环境:")
    fix_cmd4 = """
    echo "=== 检查 Substrate ==="
    ls -la /Library/Frameworks/CydiaSubstrate.framework/ 2>/dev/null || echo "No CydiaSubstrate"
    ls -la /Library/Frameworks/Substrate.framework/ 2>/dev/null || echo "No Substrate"
    ls -la /var/jb/Library/Frameworks/CydiaSubstrate.framework/ 2>/dev/null || echo "No jb/CydiaSubstrate"
    
    echo "=== 检查 Substitute ==="
    find / -name 'substitute*' -o -name 'Substitute*' 2>/dev/null | head -5
    
    echo "=== 检查 ElleKit (rootless) ==="
    find /var/jb -name 'ellekit*' -o -name 'ElleKit*' 2>/dev/null | head -5
    ls -la /var/jb/usr/lib/ellekit* 2>/dev/null || echo "No ElleKit"
    """
    out = ssh_exec(ip, fix_cmd4)
    print(out)
    
    return True

def test_lua_on_device(ip: str):
    """在设备上测试 Lua 运行"""
    print("\n[测试] 在设备上运行 Lua:")
    test_cmd = """
    echo "=== 测试 Lua ==="
    # 尝试多种路径
    /usr/lib/ziyan/bin/lua5.3 -e 'print("OK: /usr/lib/ziyan/bin/lua5.3 works!")' 2>&1 || \
    /var/jb/usr/lib/ziyan/bin/lua5.3 -e 'print("OK: /var/jb/usr/lib/ziyan/bin/lua5.3 works!")' 2>&1 || \
    lua5.3 -e 'print("OK: lua5.3 from PATH works!")' 2>&1 || \
    echo "FAILED: All paths failed"
    """
    out = ssh_exec(ip, test_cmd)
    print(out)

def main():
    # 诊断两台设备
    diagnose_rootful_device()
    diagnose_rootless_device()
    
    # 尝试修复
    fix_rootless_device()
    
    # 测试修复结果
    print("\n" + "=" * 60)
    print("测试修复结果")
    print("=" * 60)
    
    print("\n[设备 166 (rootful)]:")
    test_lua_on_device(DEVICE_166["ip"])
    
    print("\n[设备 53 (rootless)]:")
    test_lua_on_device(DEVICE_53["ip"])
    
    return 0

if __name__ == "__main__":
    import sys
    sys.exit(main())
