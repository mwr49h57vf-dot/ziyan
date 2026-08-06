# ZiYan 打包：rootful vs rootless

## 设备与架构

| 方案 | dpkg Architecture | 典型路径前缀 | 适用 |
|------|-------------------|--------------|------|
| rootful | `iphoneos-arm` | `/`（如 `/usr/lib/ziyan`） | checkra1n 等 rootful |
| rootless | `iphoneos-arm64` | `/var/jb`（如 `/var/jb/usr/lib/ziyan`） | palera1n / Dopamine |

## 构建

```bash
# rootless（USB rootless arm64 交付）
make package-rootless
# 等价：THEOS_PACKAGE_SCHEME=rootless make clean package

# rootful（旧机）
make package-rootful
```

产物：
- `packages/com.ziyan.ziyan_*_iphoneos-arm64.deb` ← rootless 交付
- `packages/com.ziyan.ziyan_*_iphoneos-arm.deb` ← rootful

`stage-runtime` 必须写入 **未加 jb 前缀** 的 `$THEOS_STAGING_DIR/usr/...`；Theos 会 remap 到 `/var/jb/...`。勿在 staging 写绝对 `/var/jb` symlink（会变成 `var/jb/var/jb`）。

## 运行时路径

| 用途 | rootful | rootless |
|------|---------|----------|
| 运行时库 | `/usr/lib/ziyan` | `/var/jb/usr/lib/ziyan` |
| Tweak | `/Library/MobileSubstrate/DynamicLibraries` | `/var/jb/Library/MobileSubstrate/DynamicLibraries` |
| App | `/Applications/ZiYan.app` | `/var/jb/Applications/ZiYan.app` |
| 用户脚本 | `/private/var/mobile/Media/ZiYan` | 同左（非 jb 前缀） |

ObjC：`ZiYanPaths.h` 运行时探测 `/var/jb`。Lua：`ziyan_paths.lua` / `_G.ZIYAN_*`。

## USB 安装（仅本机数据线）

```bash
UDID=$(idevice_id -l | head -1)
iproxy -u "$UDID" 2222:22 &
# 打印：USB-iproxy → 127.0.0.1:2222 → UDID=...
sshpass -p alpine scp -P 2222 packages/*iphoneos-arm64.deb mobile@127.0.0.1:/var/mobile/Media/
sshpass -p alpine ssh -p 2222 mobile@127.0.0.1 'echo alpine | sudo -S dpkg -i /var/mobile/Media/*.deb'
```

安装后建议 `killall SpringBoard`。冒烟：`lua5.3 …/ziyan_run.lua _ziyan_usb_smoke.lua` → `$JB/usr/lib/ziyan/var/.ziyan_usb_smoke.txt` 含 `round=1`。
