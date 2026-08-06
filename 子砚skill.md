---
name: ziyan-surpass-touchsprite
description: 子砚越狱自动化引擎 — 逆向分析触动精灵，抄袭模仿其架构，最终全面超越。
globs: ["**/*.lua", "**/*.m", "**/*.h", "**/*.mm", "**/*.c", "**/*.cpp", "**/Makefile", "**/DEBIAN/**"]
version: 3.0
alwaysApply: true
---

# 子砚超越触动精灵 — 完整逆向+抄袭+超越技能

## 核心目标

**用一切手段逆向触动精灵，把它的源码级实现全部还原出来，然后抄袭它的架构，在它的基础上做得更好。**

## 触动精灵目标文件清单

```
/Applications/TouchSprite.app/TSDaemon          # 主守护进程 (核心)
/Applications/TouchSprite.app/Hades              # 辅助进程
/Library/MobileSubstrate/DynamicLibraries/
  ├── TSTweak.dylib         # SpringBoard 注入 (截图/触摸/找色)
  ├── TSTweak.plist
  ├── TSEventTweak.dylib    # 事件注入
  ├── TSEventTweak.plist
  ├── TSTweakEx.dylib       # 扩展功能
  ├── TSActivator.dylib     # 激活器
  └── TSActivator.plist
/var/mobile/Media/TouchSprite/
  ├── lua/TSLib.lua          # Lua 标准库 (166KB, 核心)
  ├── lua/main.lua           # 用户脚本
  ├── config/                # 配置
  ├── log/                   # 日志
  ├── tmp/                   # 临时文件
  └── res/                   # 资源
```

## 全机型兼容矩阵（iPhone 7 / 7 Plus / 8 / 8 Plus × iOS 13 ～ 16.7.16）

子砚必须支持以上 4 款机型 × iOS 13 ～ **16.7.16**（上限写死，扩展待用户通知）。
所有代码必须设备无关，禁止硬编码机型/分辨率。

### 机型规格

| 参数 | iPhone 7 (A1660/A1778) | iPhone 7 Plus (A1661/A1784) | iPhone 8 (A1863/A1905) | iPhone 8 Plus (A1864/A1898) |
|------|:---:|:---:|:---:|:---:|
| 芯片 | A10 Fusion | A10 Fusion | **A11 Bionic** | **A11 Bionic** |
| CPU 核心 | 2+2 | 2+2 | 2+4 | 2+4 |
| 屏幕分辨率 | 750×1334 | 1080×1920 | 750×1334 | **1080×1920** |
| 逻辑分辨率 | 375×667 | 414×736 | 375×667 | **414×736** |
| 缩放倍率 | **@2x** | **@3x (downsample)** | **@2x** | **@3x** |
| 帧缓存大小 | ~4MB | ~8MB (downsample) | ~4MB | **~8MB** |
| 内存 | 2GB | 3GB | 2GB | 3GB |
| Tweak 路径 | rootful | rootful | rootful | rootful |

### iOS 版本兼容

| iOS | 越狱方式 | 根路径 | 截图 API | 触控 API | 注意事项 |
|-----|----------|--------|----------|----------|----------|
| **13.x** | unc0ver / checkra1n | rootful `/` | `_UICreateScreenUIImage` | `IOHIDEventCreateDigitizerEvent` | 最稳定，全部功能可用 |
| **14.x** | unc0ver / checkra1n | rootful `/` | `_UICreateScreenUIImage` | `IOHIDEventCreateDigitizerEvent` | 同 13.x，额外注意 Tweak 加载顺序 |
| **15.x** | Dopamine / XinaA15 | **rootless** `/var/jb/` | `_UICreateScreenUIImage` | `IOHIDEventCreateDigitizerEvent` | 路径前缀 `/var/jb/`，plist 在 `/var/jb/Library/MobileSubstrate/` |
| **16.x** | Dopamine | **rootless** `/var/jb/` | **`UIGraphicsImageRenderer`** | `IOHIDEventCreateDigitizerEvent` | `_UICreateScreenUIImage` 不可用！必须用 `UIGraphicsImageRenderer` |
| **17.x** | Dopamine | **rootless** `/var/jb/` | **`UIGraphicsImageRenderer`** | **IOHID 已废弃，替代方案** | IOHID 部分 API 被删除，需要 fallback 方案 |

### 关键差异处理

```
1. 路径适配（rootful vs rootless）:
   rootful:  /usr/lib/ziyan/  /Library/MobileSubstrate/DynamicLibraries/
   rootless: /var/jb/usr/lib/ziyan/  /var/jb/Library/MobileSubstrate/DynamicLibraries/

2. 截图 API（iOS 13-15 vs iOS 16-17）:
   iOS 13-15: _UICreateScreenUIImage()  ← 最快
   iOS 16-17: UIGraphicsImageRenderer   ← 必须用这个

3. 分辨率适配（@2x vs @3x）:
   @2x (750×1334): 帧缓存 4MB, 可安全 keepScreen
   @3x (1080×1920): 帧缓存 8MB, keepScreen 需限制 30s TTL, 内存压力大

4. A11 芯片优化（iPhone 8/8 Plus）:
   NCNN 模型必须 int8 量化，CPU 推理，禁止 ANE/MLX 加速
   A11 有 2 大核 + 4 小核，计算任务绑定大核

5. 内存管理:
   iPhone 7/8 (2GB): 帧缓存上限 4MB, 进程总内存 ≤80MB
   iPhone 7 Plus/8 Plus (3GB): 帧缓存上限 8MB, 进程总内存 ≤120MB
```

### 部署设备

```
触动精灵 (逆向目标):
149 root@192.168.31.149 alpine iPhone7      iOS13.3   rootful  @2x
171 root@192.168.31.171 alpine iPhone7      iOS13.5.1 rootful  @2x

子砚 (部署/测试目标):
53  root@192.168.31.53  alpine iPhone8Plus  iOS16.7.16 rootless @3x ← 最复杂
101 root@192.168.31.101 alpine iPhone7      iOS13.6    rootful  @2x
112 root@192.168.31.112 alpine iPhone7      iOS13.2.2  rootful  @2x
166 root@192.168.31.166 alpine iPhone7      iOS13.1.2  rootful  @2x
```

### 构建部署命令（兼容 rootful + rootless）

```bash
# 构建
cd /Users/mac/Desktop/ZiYan_副本

# rootful (iOS 13-14)
make clean-user-bins && make package

# rootless (iOS 15-17) — 必须先 rootful 再 rootless
make clean-user-bins && make package && THEOS_PACKAGE_SCHEME=rootless make package

# 部署 rootful (101/112/166)
sshpass -p alpine scp -o StrictHostKeyChecking=no \
  packages/com.ziyan.ziyan_*_iphoneos-arm.deb root@192.168.31.$IP:/tmp/ziyan.deb
sshpass -p alpine ssh root@192.168.31.$IP \
  'dpkg -i /tmp/ziyan.deb && killall -9 SpringBoard'

# 部署 rootless (53)
sshpass -p alpine scp -o StrictHostKeyChecking=no \
  packages/com.ziyan.ziyan_*_iphoneos-arm64.deb root@192.168.31.53:/tmp/ziyan.deb
sshpass -p alpine ssh root@192.168.31.53 \
  'dpkg -i /tmp/ziyan.deb && (sbreload || killall -9 SpringBoard)'

# 部署后必须等 10 秒
sleep 10
```

### 运行 Lua 脚本（兼容 rootful + rootless）

```bash
# rootful (101/112/166)
sshpass -p alpine ssh root@192.168.31.$IP \
  '/usr/lib/ziyan/bin/lua5.3 /usr/lib/ziyan/lib/lua/ziyan_run.lua /private/var/mobile/Media/ZiYan/脚本名.lua'

# rootless (53)
sshpass -p alpine ssh root@192.168.31.53 \
  'DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib /var/jb/usr/lib/ziyan/bin/lua5.3 /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua /private/var/mobile/Media/ZiYan/脚本名.lua'
```

### 健康检查（兼容 rootful + rootless）

```bash
sshpass -p alpine ssh root@192.168.31.$IP '
echo "=== 进程 ==="; ps aux | grep -iE "ziyan|springboard|lua5\.3|framecap" | grep -v grep
echo "=== 分辨率 ==="; sysctl hw.machine; echo "---"; cat /var/jb/usr/lib/ziyan/var/.ziyan_screen 2>/dev/null || cat /usr/lib/ziyan/var/.ziyan_screen 2>/dev/null
echo "=== 找色 ==="; cat /usr/lib/ziyan/var/.ziyan_color_perf 2>/dev/null || cat /var/jb/usr/lib/ziyan/var/.ziyan_color_perf 2>/dev/null
echo "=== 崩溃 ==="; ls /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -i springboard | wc -l
echo "=== 磁盘写入 ==="; cat /var/mobile/Library/Logs/CrashReporter/SpringBoard.diskwrites_resource*.ips 2>/dev/null | grep -A1 "Writes:" | tail -5
echo "=== 内存 ==="; ps aux | grep -iE "springboard|framecap" | grep -v grep | awk "{print \$6\" RSS\"}"
echo "=== 负载 ==="; uptime
'

---

## 第一阶段：文件提取（先把触动全家桶拖到本地）

### 1.1 提取所有二进制文件

```bash
# 从设备 149/171 拉取所有触动相关文件
for ip in 149 171; do
  mkdir -p /tmp/ts_dump/$ip
  sshpass -p alpine ssh root@192.168.31.$ip '
    # 打包所有触动文件
    tar czf /tmp/ts_full.tar.gz \
      /Applications/TouchSprite.app/ \
      /Library/MobileSubstrate/DynamicLibraries/TS* \
      /Library/MobileSubstrate/DynamicLibraries/TSTweak* \
      /var/mobile/Media/TouchSprite/ \
      /var/mobile/Library/Preferences/com.touchsprite* \
      /usr/lib/TweakInject/TS* \
      2>/dev/null
  '
  sshpass -p alpine scp root@192.168.31.$ip:/tmp/ts_full.tar.gz /tmp/ts_dump/$ip/
done
```

### 1.2 脱壳 IPA（如果加密）

```bash
# 使用 frida-ios-dump 脱壳
python3 dump.py TouchSprite
# 或直接用 clutch
clutch -i  # 列出已安装应用
clutch -d TouchSprite
```

### 1.3 提取 TSLib.lua（最重要的文件）

```bash
sshpass -p alpine scp root@192.168.31.149:/var/mobile/Media/TouchSprite/lua/TSLib.lua /tmp/ts_dump/
# 166KB 的 Lua 文件包含触动全部 API 实现，逐行分析
```

---

## 第二阶段：静态分析（把二进制翻个底朝天）

### 2.1 基础信息采集

```bash
# 文件类型识别
file /Applications/TouchSprite.app/TSDaemon
file /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib

# 架构信息
lipo -info /Applications/TouchSprite.app/TSDaemon
lipo -info /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib

# 加密状态
otool -l /Applications/TouchSprite.app/TSDaemon | grep -A4 LC_ENCRYPTION_INFO

# 代码签名
codesign -dvvv /Applications/TouchSprite.app/TSDaemon 2>&1

# UUID
dwarfdump --uuid /Applications/TouchSprite.app/TSDaemon
dwarfdump --uuid /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib
```

### 2.2 符号表深度分析

```bash
# 导出全部符号
nm -gU /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib > /tmp/ts_symbols.txt
nm -gU /Applications/TouchSprite.app/TSDaemon >> /tmp/ts_symbols.txt

# 按类别分组搜索
# 截图相关
nm -gU /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib | grep -iE "screen|image|render|capture|display|IOSurface|CGImage|pixel|buffer|frame"

# 找色相关
nm -gU /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib | grep -iE "color|find|match|search|scan|pixel|rgb|hsv"

# 触摸相关
nm -gU /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib | grep -iE "touch|tap|swipe|finger|press|iohid|digitizer|event"

# 内存相关
nm -gU /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib | grep -iE "mmap|shm|malloc|free|cache|pool|retain|release"

# 通信相关
nm -gU /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib | grep -iE "xpc|mach|port|msg|socket|pipe|notify|cfnotify|darwin"

# 启动/守护
nm -gU /Applications/TouchSprite.app/TSDaemon | grep -iE "init|start|stop|boot|launch|daemon|keep|alive|watchdog|monitor"
```

### 2.3 ObjC 类结构完整导出

```bash
# class-dump 导出所有头文件
class-dump -H -o /tmp/ts_headers_tsdaemon /Applications/TouchSprite.app/TSDaemon
class-dump -H -o /tmp/ts_headers_tweak /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib
class-dump -H -o /tmp/ts_headers_event /Library/MobileSubstrate/DynamicLibraries/TSEventTweak.dylib
class-dump -H -o /tmp/ts_headers_ex /Library/MobileSubstrate/DynamicLibraries/TSTweakEx.dylib
class-dump -H -o /tmp/ts_headers_activator /Library/MobileSubstrate/DynamicLibraries/TSActivator.dylib

# 合并并搜索关键类
cat /tmp/ts_headers_*/*.h > /tmp/ts_all_headers.h
grep -E "@interface|@property|[-+].*\(" /tmp/ts_all_headers.h | grep -iE "color|find|tap|touch|screen|image|match|buffer|frame|cache|keep"
```

### 2.4 Mach-O 段分析

```bash
# 查看所有段和节
otool -l /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib | grep -E "segname|sectname|size|addr"

# __TEXT 段（代码）
otool -tV /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib > /tmp/ts_disasm.txt

# __DATA 段（数据）
otool -dV /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib

# __OBJC 段（类信息）
otool -oV /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib > /tmp/ts_objc.txt

# 字符串段
otool -v -s __TEXT __cstring /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib
otool -v -s __TEXT __objc_methname /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib
otool -v -s __DATA __objc_classname /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib
```

### 2.5 字符串深度挖掘（最直接的信息源）

```bash
# 全量提取所有字符串
strings /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib > /tmp/ts_strings_tweak.txt
strings /Applications/TouchSprite.app/TSDaemon > /tmp/ts_strings_daemon.txt
strings /Library/MobileSubstrate/DynamicLibraries/TSEventTweak.dylib > /tmp/ts_strings_event.txt

# API 调用线索
grep -iE "UICreate|UIGraphics|CGImage|IOSurface|IOService|IOHID|mach_msg|xpc_|bootstrap|notify" /tmp/ts_strings_tweak.txt

# 文件路径
grep -E "^/" /tmp/ts_strings_tweak.txt
grep -E "^/" /tmp/ts_strings_daemon.txt

# 偏好设置键名
grep -iE "pref|config|setting|default|key|value" /tmp/ts_strings_tweak.txt

# 错误消息
grep -iE "error|fail|warn|debug|log|trace" /tmp/ts_strings_tweak.txt

# 函数名残留
grep -E "^_?[A-Z][a-z]+" /tmp/ts_strings_tweak.txt | head -100

# 版本号
grep -E "[0-9]+\.[0-9]+\.[0-9]+" /tmp/ts_strings_tweak.txt
```

### 2.6 jtool 深度解析

```bash
# 反汇编
jtool -d /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib > /tmp/ts_jtool_disasm.txt

# 导出 ObjC 类信息
jtool -d objc /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib

# 导出符号
jtool --sig /Applications/TouchSprite.app/TSDaemon

# 查找特定函数
jtool -d /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib | grep -A20 "findColor\|findMultiColor\|screenShot\|touchDown\|touchUp"
```

---

## 第三阶段：反汇编/反编译（还原伪代码）

### 3.1 Hopper Disassembler

```bash
# 在 macOS 上使用 Hopper 命令行
# 安装: https://www.hopperapp.com
# 导出伪代码
/Applications/Hopper\ Disassembler\ v4.app/Contents/MacOS/hopper \
  -e /tmp/ts_pseudocode.c \
  /Users/mac/Desktop/ZiYan_副本/逆向学习/ts_binaries/TSTweak.dylib

# 搜索关键函数
# 在 Hopper GUI 中搜索:
# _UICreateScreenUIImage
# CGImageGetDataProvider
# CGDataProviderCopyData
# IOSurfaceCreate
# IOHIDEventCreateDigitizerEvent
# findMultiColorInRegionFuzzy
# touchDown / touchUp
```

### 3.2 Ghidra（NSA 开源反编译器）

```bash
# 安装: brew install ghidra
# 创建项目 → 导入 TSTweak.dylib → 自动分析 → 导出 C 代码
# 关键搜索:
# 1. Filter → "findColor" → 所有找色函数
# 2. Filter → "screen" → 截图函数
# 3. Filter → "touch" → 触控函数
# 4. Filter → "mmap" → 共享内存
# 5. Filter → "xpc" → 进程间通信
```

### 3.3 Binary Ninja（商业反编译器，伪代码质量最高）

```bash
# 如果有 Binary Ninja 许可证
# 优先使用，伪代码最接近原始源码
# 重点分析:
# 1. TSTweak.dylib 中所有 Hook 函数
# 2. TSDaemon 中所有 Lua 桥接函数
# 3. 找色算法实现（逐像素扫描逻辑）
```

### 3.4 radare2 / rizin（命令行反汇编）

```bash
# 安装: brew install radare2
# 分析 TSTweak.dylib
r2 -A /Library/MobileSubstrate/DynamicLibraries/TSTweak.dylib

# 进入后执行:
# aaa          # 完整分析
# afl          # 列出所有函数
# afl~find     # 搜索找色函数
# afl~color    # 搜索颜色函数
# afl~touch    # 搜索触控函数
# afl~screen   # 搜索截图函数
# pdf @ sym._findMultiColorInRegionFuzzy  # 反汇编特定函数
# pdc @ sym._findMultiColorInRegionFuzzy  # 伪代码
# izz~find     # 搜索字符串
```

---

## 第四阶段：动态分析（运行时抓取一切）

### 4.1 Frida — 全量 Hook 框架

```bash
# 安装
pip3 install frida-tools objection

# 基础连接
frida-ps -U  # 列出 USB 设备进程
frida -U -n TSDaemon  # 附加到 TSDaemon
```

### 4.2 Frida 脚本：全类枚举 + 方法 Hook

```javascript
// dump_all_ts_classes.js — 枚举触动所有类和方法
// 用法: frida -U -n TSDaemon -l dump_all_ts_classes.js

// 枚举所有 ObjC 类
var classes = ObjC.enumerateLoadedClassesSync();
classes.forEach(function(cls) {
  if (cls.indexOf("TS") === 0 || cls.indexOf("TouchSprite") !== -1) {
    console.log("\n=== " + cls + " ===");
    var methods = ObjC.classes[cls].$ownMethods;
    methods.forEach(function(method) {
      console.log("  " + method);
      // 自动 Hook 每个方法
      try {
        var impl = ObjC.classes[cls][method];
        if (impl && impl.implementation) {
          Interceptor.attach(impl.implementation, {
            onEnter: function(args) {
              var msg = "[CALL] " + cls + " " + method;
              if (this.argCount > 2) {
                for (var i = 2; i < Math.min(this.argCount, 6); i++) {
                  try { msg += " arg" + (i-2) + "=" + args[i]; } catch(e) {}
                }
              }
              this._start = Date.now();
            },
            onLeave: function(retval) {
              var dt = Date.now() - this._start;
              if (dt > 1) {  // 只记录 >1ms 的调用
                console.log("[RET] " + cls + " " + method + " time=" + dt + "ms");
              }
            }
          });
        }
      } catch(e) {}
    });
  }
});

console.log("=== Hook 完成，开始监控 ===");
```

### 4.3 Frida 脚本：截图 API 追踪

```javascript
// trace_screenshot.js — 追踪触动截图调用链
// 用法: frida -U -n TSDaemon -l trace_screenshot.js

var screenshotAPIs = [
  "_UICreateScreenUIImage",
  "UIGraphicsGetImageFromCurrentImageContext",
  "UIGraphicsBeginImageContextWithOptions",
  "UIGraphicsEndImageContext",
  "CGDisplayCreateImage",
  "IOSurfaceCreate",
  "IOSurfaceLock",
  "IOSurfaceGetBaseAddress",
  "CARenderServerRenderDisplay",
  "CGImageCreate",
  "CGImageGetDataProvider",
  "CGDataProviderCopyData",
  "CGImageGetWidth",
  "CGImageGetHeight",
  "CGImageGetBytesPerRow",
  "CGImageGetBitsPerPixel",
  "CGImageGetBitmapInfo",
  "CGBitmapContextCreate",
  "CGBitmapContextGetData",
  "vImageBuffer_InitWithCGImage",
  "CGContextDrawImage"
];

screenshotAPIs.forEach(function(name) {
  var addr = Module.findExportByName(null, name);
  if (addr) {
    Interceptor.attach(addr, {
      onEnter: function(args) {
        console.log("[SCREENSHOT] " + name + " called from:\n" +
          Thread.backtrace(this.context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress).join("\n"));
      }
    });
    console.log("[TRACE] hooked " + name);
  }
});
```

### 4.4 Frida 脚本：IPC 通信追踪

```javascript
// trace_ipc.js — 追踪触动进程间通信方式
// 用法: frida -U -n TSDaemon -l trace_ipc.js

// Mach 消息
var mach_msg = Module.findExportByName(null, "mach_msg");
if (mach_msg) {
  Interceptor.attach(mach_msg, {
    onEnter: function(args) { console.log("[MACH] mach_msg called"); }
  });
}

// XPC 通信
var xpc_connection_send_message = Module.findExportByName(null, "xpc_connection_send_message");
if (xpc_connection_send_message) {
  Interceptor.attach(xpc_connection_send_message, {
    onEnter: function(args) { console.log("[XPC] xpc_connection_send_message"); }
  });
}

// 文件操作
["open", "write", "read", "close", "mmap", "shm_open", "shm_unlink"].forEach(function(name) {
  var addr = Module.findExportByName(null, name);
  if (addr) {
    Interceptor.attach(addr, {
      onEnter: function(args) {
        if (name === "open" || name === "shm_open") {
          var path = Memory.readUtf8String(args[0]);
          if (path && (path.indexOf("TouchSprite") !== -1 || path.indexOf("tmp") !== -1 || path.indexOf("ziyan") !== -1)) {
            console.log("[IPC] " + name + " " + path);
          }
        }
        if (name === "write") {
          var fd = args[0].toInt32();
          var size = args[2].toInt32();
          if (size > 1024) console.log("[IPC] write fd=" + fd + " size=" + size);
        }
        if (name === "mmap") {
          var size = args[1].toInt32();
          if (size > 1024*1024) console.log("[IPC] mmap size=" + (size/1024/1024).toFixed(1) + "MB");
        }
      }
    });
  }
});

// Darwin Notification
var CFNotificationCenterPostNotification = Module.findExportByName("CoreFoundation", "CFNotificationCenterPostNotification");
if (CFNotificationCenterPostNotification) {
  Interceptor.attach(CFNotificationCenterPostNotification, {
    onEnter: function(args) {
      var name = Memory.readUtf8String(ObjC.Object(args[2]).UTF8String());
      if (name) console.log("[NOTIFY] " + name);
    }
  });
}
```

### 4.5 Frida 脚本：找色算法还原

```javascript
// trace_find_color.js — 还原触动找色完整流程
// 用法: frida -U -n TSDaemon -l trace_find_color.js

// Hook 找色入口
var hooks = {};

// 1. 先找到所有找色相关函数
var modules = Process.enumerateModules();
modules.forEach(function(m) {
  if (m.name.indexOf("TSTweak") !== -1 || m.name.indexOf("TouchSprite") !== -1) {
    Module.enumerateExports(m.name).forEach(function(e) {
      if (e.name.match(/find|color|match|search|scan|pixel|cmp/i)) {
        console.log("[FIND] " + m.name + " -> " + e.name + " @ " + e.address);
      }
    });
  }
});

// 2. Hook 内存分配（看找色是否分配临时缓冲区）
Interceptor.attach(Module.findExportByName(null, "malloc"), {
  onEnter: function(args) {
    this.size = args[0].toInt32();
    this.bt = Thread.backtrace(this.context, Backtracer.ACCURATE)
      .map(DebugSymbol.fromAddress).join(" -> ");
  },
  onLeave: function(retval) {
    if (this.size > 100 * 100 * 4) {  // 大于 100x100 像素缓冲区
      console.log("[MALLOC] " + this.size + " bytes for pixel buffer\n  " + this.bt);
    }
  }
});

// 3. Hook vImage/vDSP（加速框架，可能用于找色加速）
["vImageConvert", "vDSP"].forEach(function(prefix) {
  Module.enumerateExports("Accelerate").forEach(function(e) {
    if (e.name.indexOf(prefix) === 0) {
      Interceptor.attach(e.address, {
        onEnter: function(args) {
          console.log("[ACCELERATE] " + e.name);
        }
      });
    }
  });
});
```

### 4.6 Frida 脚本：内存快照对比

```javascript
// memory_snapshot.js — 抓取找色前后的内存快照
// 用法: frida -U -n TSDaemon -l memory_snapshot.js

var snapshots = [];
function takeSnapshot(label) {
  var total = 0;
  Process.enumerateMallocRanges().forEach(function(r) {
    total += r.size;
  });
  snapshots.push({label: label, time: Date.now(), total: total});
  console.log("[SNAP] " + label + ": " + (total/1024/1024).toFixed(1) + "MB");
}

// 每 5 秒对比
var lastTotal = 0;
setInterval(function() {
  var total = 0;
  Process.enumerateMallocRanges().forEach(function(r) { total += r.size; });
  var diff = total - lastTotal;
  if (Math.abs(diff) > 1024*1024) {
    console.log("[MEM] delta=" + (diff/1024/1024).toFixed(2) + "MB total=" + (total/1024/1024).toFixed(1) + "MB");
  }
  lastTotal = total;
}, 5000);
```

### 4.7 objection — 快速运行时探索

```bash
# 启动 objection
objection -g TouchSprite explore

# 进入后执行:
ios hooking list classes                   # 列出所有类
ios hooking search classes find            # 搜索找色类
ios hooking search classes color           # 搜索颜色类
ios hooking search classes touch           # 搜索触控类
ios hooking search classes screen          # 搜索截图类
ios hooking watch class TSDaemon           # 监控类调用
ios hooking list class_methods TSDaemon    # 列出方法
ios hooking watch method "-[TSDaemon findColor:]" --dump-args --dump-return

# 搜索所有类的所有方法
ios hooking list class_methods "*Color*"
ios hooking list class_methods "*Find*"
ios hooking list class_methods "*Tap*"
ios hooking list class_methods "*Touch*"
ios hooking list class_methods "*Screen*"

# 内存搜索
ios memory search "0x00000000" --string    # 搜索空字节

# 文件系统监控
ios monitor files /var/mobile/Media/TouchSprite/
```

### 4.8 Cycript — 实时 ObjC 运行时交互

```bash
cycript -p TSDaemon
# 或
cycript -p SpringBoard

# 进入后:
// 查看所有窗口
[[UIApp keyWindow] recursiveDescription]

// 查看 TSDaemon 实例
choose(TSDaemon)

// 查看所有触动相关的类
[objc_getClassList()]  // 这个需要脚本

// 查看视图层级
[[[UIApp keyWindow] rootViewController] _printHierarchy]
```

### 4.9 dtrace — 系统调用追踪

```bash
# 追踪 TSDaemon 的所有系统调用
sudo dtruss -p $(pgrep TSDaemon) 2>&1 | grep -vE "kevent|workq|select"

# 只追踪文件操作
sudo dtruss -p $(pgrep TSDaemon) -t open -t open_nocancel -t write -t write_nocancel -t mmap

# 追踪 SpringBoard 中触动相关的调用
sudo dtruss -n SpringBoard 2>&1 | grep -iE "TS|touch|sprite"
```

### 4.10 malloc_history — 内存分配回溯

```bash
# 开启 malloc 日志
# 需要先设置环境变量重启 App
# 在 TSDaemon 运行时:
malloc_history $(pgrep TSDaemon) -all_by_size | head -50
malloc_history $(pgrep TSDaemon) -callTree | grep -iE "TS|touch|sprite"
```

---

## 第五阶段：通信协议分析

### 5.1 网络流量抓取

```bash
# 在 Mac 上创建虚拟网卡
rvictl -s $(idevice_id -l)

# 抓包
sudo tcpdump -i rvi0 -w /tmp/ts_network.pcap -s 0

# 分析
# 用 Wireshark 打开 /tmp/ts_network.pcap
# 过滤: http || tls
# 看触动有没有心跳上报、远程控制、版本检查
```

### 5.2 进程间通信分析

```bash
# 查看 Mach 端口
lsmp -p $(pgrep TSDaemon)

# 查看 XPC 服务
launchctl print system
launchctl print gui/501

# 查看文件描述符
lsof -p $(pgrep TSDaemon)
```

---

## 第六阶段：TSLib.lua 逐行分析

### 6.1 关键 API 实现提取

```bash
# 提取 TSLib.lua 中所有函数定义
grep -n "function" /tmp/ts_dump/TSLib.lua

# 找色相关
grep -n -i "find.*color\|keepScreen\|keep.*screen\|snapshot\|screenShot\|getColor\|getPixel" /tmp/ts_dump/TSLib.lua

# 触控相关
grep -n -i "touch\|tap\|swipe\|move\|finger\|press" /tmp/ts_dump/TSLib.lua

# 应用控制
grep -n -i "runApp\|closeApp\|frontApp\|activeApp\|bundleID" /tmp/ts_dump/TSLib.lua

# 脚本控制
grep -n -i "init\|mSleep\|msleep\|delay\|wait\|while\|loop" /tmp/ts_dump/TSLib.lua

# 日志/调试
grep -n -i "toast\|dialog\|alert\|log\|print\|debug\|notify" /tmp/ts_dump/TSLib.lua
```

---

## 第七阶段：竞品对比分析

### 7.1 触动精灵 vs 子砚 API 对照表

必须逐一对比的 API：

| 触动 API | 子砚对应 | 触动实现方式 | 子砚实现方式 | 需要抄袭的点 |
|----------|----------|-------------|-------------|-------------|
| init("0",1) | init(1) | ? | ? | 启动流程 |
| keepScreen(b) | keepScreen(b) | ? | ? | 缓存策略 |
| findMultiColorInRegionFuzzy | findMultiColorInRegionFuzzy | ? | ? | 找色算法 |
| touchDown(x,y) | tap(x,y) | ? | ? | 触控注入 |
| touchUp(x,y) | tap(x,y) | ? | ? | 触控注入 |
| mSleep(ms) | mSleep(ms) | ? | ? | 睡眠实现 |
| toast(msg,t) | toast(msg,t) | ? | ? | UI 显示 |
| runApp(bid) | — | ? | — | 应用启动 |
| closeApp(bid) | — | ? | — | 应用关闭 |
| frontAppBid() | — | ? | — | 前台检测 |

### 7.2 必须抄袭的触动架构特性

1. **单进程架构**：找色/触控/脚本都在一个进程内，零 IPC 开销
2. **截图策略（keep 消歧）**：无 `keepScreen` 时即用即弃；脚本显式 `keepScreen(true)` 时锁**当前前台**缓冲复用（Frida：keep 后少 create）。禁止会话暗补锁 / hasColor→KeepEnable（190 教训）
3. **零文件 IPC**：所有通信都在进程内部
4. **内存上限**：TSDaemon 内存峰值可控；2GB≤80MB / 3GB≤120MB
5. **Lua 直接调用 C 函数**：无中间层，最快路径

---

## 第八阶段：还原触动源码结构

### 8.1 推测的触动源码结构（基于逆向）

```
TSTweak/
├── TSTweak.m              # 主入口，%ctor 初始化
├── TSScreenCapture.m      # 截图模块 (_UICreateScreenUIImage)
├── TSColorFinder.m        # 找色模块 (逐像素扫描)
├── TSTouchInjector.m      # 触控模块 (IOHIDEvent)
├── TSLuaBridge.m          # Lua 桥接 (注册 C 函数到 Lua)
├── TSAppManager.m         # 应用管理 (runApp/closeApp)
├── TSUIOverlay.m          # UI 覆盖层 (toast/dialog)
├── TSConfigManager.m      # 配置管理
└── TSNetworkHook.m        # 网络 Hook (如有)

TSDaemon/
├── main.m                 # 主入口
├── TSDaemonCore.m         # 守护核心
├── TSLuaEngine.m          # Lua 引擎封装
├── TSScriptManager.m      # 脚本管理
├── TSHeartbeat.m          # 心跳/保活
└── TSUpdateChecker.m      # 版本更新检查
```

### 8.2 子砚需要抄袭后重写的模块

```
采用触动架构，但用子砚的代码重写：

ZiYan/                          # 新架构：单进程
├── ZiYanDaemon/                # 合并 framecap + lua5.3 + daemon
│   ├── main.m                  # 唯一入口
│   ├── ZYScreenCapture.m       # 抄袭触动截图方式
│   ├── ZYColorFinder.m         # 抄袭触动找色算法（再加 NCNN 加速）
│   ├── ZYTouchInjector.m       # 抄袭触动触控方式（再加 HID 预构造）
│   ├── ZYLuaBridge.m           # 抄袭触动 Lua 桥接方式
│   ├── ZYAppManager.m          # 抄袭触动应用管理
│   ├── ZYUIManager.m           # 抄袭触动 UI 覆盖层
│   └── ZYHealthMonitor.m       # 子砚新增：健康监控
├── ZiYanTweak/                 # SB 最小注入（只保留必要的）
│   ├── ZiYanVol.m              # 音量键 Hook
│   └── ZiYanFrameRelay.m       # 零拷贝帧中继（IOSurface）
└── lua/
    └── modules/                # 子砚 Lua 模块
```

---

## 第九阶段：子砚工程操作

### 9.1 项目目录

```
objc/tweak/springboard/     # SB Tweak
objc/shared/                 # 共享代码
objc/app/                    # ZiYan.app
tools/ziyadaemond/           # ObjC daemon
tools/ziyan_framecap/        # 帧捕获
tools/ziyan_ncnn_findcolor/  # NCNN 找色
lua/modules/                 # Lua 核心模块
layout/DEBIAN/               # 打包
Makefile                     # 构建
```

### 9.2 构建

```bash
cd /Users/mac/Desktop/ZiYan_副本
# rootful
make clean-user-bins && make package
# rootless
make clean-user-bins && make package && THEOS_PACKAGE_SCHEME=rootless make package
```

### 9.3 部署

```bash
# rootful
sshpass -p alpine scp -o StrictHostKeyChecking=no packages/com.ziyan.ziyan_*_iphoneos-arm.deb root@192.168.31.$IP:/tmp/ziyan.deb
sshpass -p alpine ssh root@192.168.31.$IP 'dpkg -i /tmp/ziyan.deb && killall -9 SpringBoard'
# rootless (53)
sshpass -p alpine scp -o StrictHostKeyChecking=no packages/com.ziyan.ziyan_*_iphoneos-arm64.deb root@192.168.31.53:/tmp/ziyan.deb
sshpass -p alpine ssh root@192.168.31.53 'dpkg -i /tmp/ziyan.deb && (sbreload || killall -9 SpringBoard)'
sleep 10
```

### 9.4 健康检查

```bash
sshpass -p alpine ssh root@192.168.31.$IP '
echo "=== 进程 ==="; ps aux | grep -iE "ziyan|springboard|lua5\.3|framecap" | grep -v grep
echo "=== 找色 ==="; cat /usr/lib/ziyan/var/.ziyan_color_perf 2>/dev/null || cat /var/jb/usr/lib/ziyan/var/.ziyan_color_perf 2>/dev/null
echo "=== 崩溃 ==="; ls /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -i springboard | wc -l
echo "=== 磁盘写入 ==="; cat /var/mobile/Library/Logs/CrashReporter/SpringBoard.diskwrites_resource*.ips 2>/dev/null | grep -A1 "Writes:" | tail -5
echo "=== 负载 ==="; uptime
'
```

---

## 硬约束

### 代码约束
1. 禁止硬编码物理像素坐标，必须用 ScreenTransform 比例坐标
2. 禁止修改 ios7.lua / ios8p.lua 用户脚本
3. 禁止覆盖其他业务代码
4. SB 重启后必须 mSleep(3000)
5. 禁止 ANE/MLX 硬件加速，A11 只用 CPU int8
6. OCR 间隔 ≥350ms
7. 学习/AI 代码在 daemon 进程，不在 SB
8. 允许抄触动的 API 名/参/语义与找色/合帧/keep/Home 等逻辑算法，实现落 `lua/`/`objc/`；仅禁止把触动 dylib / TSDaemon 链进包作运行依赖
9. 热路径 IPC 优先共享内存；文件 IPC 仅用于低频控制位
10. framecap 帧数据必须写内存不写文件

### 兼容性约束
11. 所有代码必须设备无关，禁止 `if (device == "iPhone8,2")` 等硬编码
12. 路径必须同时支持 rootful (`/usr/lib/ziyan/`) 和 rootless (`/var/jb/usr/lib/ziyan/`)
13. 截图 API 必须同时支持 iOS 13-15 (`_UICreateScreenUIImage`) 和 iOS 16.x (`UIGraphicsImageRenderer`)
14. keepScreen 缓存必须区分 @2x (4MB/可缓存) 和 @3x (8MB/30s TTL)
14b. **找色永远跟前台；keep 仅显式（191）**：像素=当前前台。`keepScreen(true)` 或 `.ziyan_auto_keep` 才锁帧。**禁止**会话默认 auto-keep / framecap hasColor 暗补锁（190 导致内存暴涨 SB 重启）。停脚本必拆 keep。
15. 内存上限必须区分 2GB 设备 (≤80MB) 和 3GB 设备 (≤120MB)
16. 部署包必须同时构建 rootful (`_iphoneos-arm.deb`) 和 rootless (`_iphoneos-arm64.deb`)
17. 每次修改必须至少在 2 种设备上验证（1 台 @2x + 1 台 @3x，1 台 rootful + 1 台 rootless）
18. iOS 16.x 触控必须保留 IOHID fallback 方案（部分 API 已废弃）

---

## 迭代工作流

```
提取触动二进制 → 静态分析(class-dump/otool/nm/strings/radare2/Ghidra) →
动态分析(Frida/objection/Cycript/dtrace/fs_usage) →
还原源码结构 → 对比 API 差异 →
抄袭触动架构(单进程/零IPC/即用即弃) → 改子砚代码 →
构建 → 部署4设备 → 健康检查 → 对比触动数据 → 下一轮
```

## 输出规范

每次分析必须输出：
1. 发现了触动什么实现细节（截图用哪个 API？IPC 用什么？）
2. 子砚对应模块的差距
3. 抄袭方案（改哪个文件，怎么改）
4. 预期效果（具体数值）

---

## 当前最高优先级（2026-08-05 加速收窄）

已完成（勿重复开史诗）：188 TSDaemon keep/find 静态；189 Frida `UIWindow createScreenIOSurface` + 去 MS_SYNC；191 回滚暗 keep。

**P0（可验收，默认双机 `.101`+`.53`）：**
1. **SB 稳态**：禁暗 keep / 禁 hasColor→KeepEnable；禁 embed 启动 `ZiYanFrameKeepEnable`；停脚本必拆 keep；miss 熔断；长跑无 SB 环（对标 `.171`）
2. **找色内存模型**：显式 `keepScreen(true)`=锁当前前台缓冲；默认不 keep；@3x TTL；进程预算见上
3. **色点与引擎解耦**：引擎 PASS=HOT20+keep 态+无 SB 重启；业务 PASS=同屏 getColor 对链后再跑 Desktop 脚本（`tools/zy_color_chain_probe.sh`）

**整改冻结（禁再改）：** 会话 auto-keep、framecap `hasColor→KeepEnable`、无假设的 relay/toast 连改。

**P1 架构（整改第 2 期，一刀一假设）：**
- **E1（193）**：业务强制 embed；热路径 `via_color_req_*=0`（`.ziyan_path_stats`）；`tools/zy_e1_embed_hotpath_gate.sh`
- **E2（194）**：@3x keep TTL=30s；Relock 不续命；停脚本 `KeepRecycle`；`tools/zy_e2_mem_budget_gate.sh`
- **E3（195）**：去切前台 `toast_bump`；force 节流加钝；CapLog `front_bid_chg` 节流；`tools/zy_e3_storm_gate.sh`
- **S53B（197）**：iomfb_nil@3x force≥12s；`.53` 30min PASS；下一刀 E4R2 四机晋级  
未完成 E1 前禁止新开 OCR/NCNN/UI 大刀。

**P2：** 控制面全量 shm；NCNN 等加速（E4 后）

**加速工作流：** 一刀一假设 → 双机门禁 → 色不对只走取色专线 → 晋级才四机+`.171` 对照。
