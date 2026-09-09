# .53 动态库缺口只读静态分析报告

分析日期：2026-09-08  
工作目录：`/Users/mac/Desktop/ZiYan_副本`  
分析范围：

1. `/Users/mac/Desktop/触动精灵deb/拆解分析/触动16版/`
2. `/Users/mac/Desktop/ZiYan_副本/ZiYan学习/逆向学习/corpus/touchsprite_helpdoc/`

## 结论

现场错误基线：

```text
Lua: /var/jb/usr/lib/ziyan/bin/lua5.3
缺库: /usr/lib/ziyan/lib/liblua5.3.dylib
exit: 134
```

静态证据显示：

- `/var/jb/usr/lib/ziyan/bin/lua5.3` 的 arm64 Mach-O 直接加载绝对路径 `/usr/lib/ziyan/lib/liblua5.3.dylib`，同时加载 `/usr/lib/ziyan/lib/libreadline.8.dylib`。
- rootless 文件布局使用 `/var/jb/usr/lib/ziyan/...`，因此现场路径与 Mach-O 绝对 `LC_LOAD_DYLIB` 路径存在 rootless 前缀不一致。
- ZiYan 自有构建输入 `/Users/mac/Desktop/ZiYan_副本/vendor/lib/liblua5.3.dylib` 与 Theos staging 文件字节完全一致，均为 arm64，`LC_ID_DYLIB` 为 `/usr/lib/ziyan/lib/liblua5.3.dylib`，版本为 compatibility `5.3.0`、current `5.3.5`。
- Lua 5.3 导出 ABI 中包含 `_luaL_newstate`、`_luaL_openlibs`、`_lua_pcallk`、`_lua_resume`、`_lua_close`、`_lua_load`、`_lua_version`、`_lua_yieldk` 等。
- 以上证明 ZiYan 自有候选的来源、架构和 Lua 5.3 ABI 证据；尚未证明该绝对 install name 在 `.53` rootless 设备上已解析，也没有进行设备处理。

根因分类：**主因候选为 rootless 路径命名空间与 Mach-O 绝对加载路径不一致；exit 134 的具体 abort 点仍需人工批准后的运行态证据确认。**

判定：**STATIC_REVIEW_ONLY**。当前候选不进入设备处理。

## 文件盘点

目标一共盘点 178 个文件，筛出 13 个 Mach-O，2 个压缩包：

- Mach-O：`Hades`、`OcrPlugin.dylib`、`TSDaemon`、`TSInstaller`、`TSLn`、`TSUpdate`、`TouchSpritePe`、`libs/luasql.so`、`libs/sz.so`、`model.so`、`paddleocr.so`、`unzip`、`TSTweak.dylib`。
- 压缩包：`ts_control.tar.gz`、`ts_data.tar.gz`。
- 两个压缩包的清单已保存；内容属于 TouchSprite rootless 应用文件系统及控制信息，未发现 ZiYan `liblua5.3.dylib`。

目标二共盘点 37 个文件，全部为 `.txt`、`.html` 或 `.DS_Store`，筛出 0 个 Mach-O、0 个压缩包。该目录只有 TouchSprite 帮助文档和 HTML 原文，没有可作为动态库的文件。

清单与类型输出：

- `readonly_run_2026-09-08_v4/target1_file_list.txt`
- `readonly_run_2026-09-08_v4/target1_file_types.txt`
- `readonly_run_2026-09-08_v4/target1_archive_files.txt`
- `readonly_run_2026-09-08_v4/target1_archive_listing.txt`
- `readonly_run_2026-09-08_v4/target2_file_list.txt`
- `readonly_run_2026-09-08_v4/target2_file_types.txt`
- `readonly_run_2026-09-08_v4/target2_archive_files.txt`
- `readonly_run_2026-09-08_v4/target2_archive_listing.txt`

## Mach-O 依赖证据

下表为每个候选的摘要；每个候选的 `file`、架构、SHA-256、完整 `otool -L`、完整 `otool -l`、`otool -D`、`nm -gU` 和相关 `strings` 均在独立文件中保存。

| 编号 | 绝对路径末段 | 架构 | SHA-256 前 16 位 | LC_ID_DYLIB | LC_RPATH | 依赖/关键证据 |
|---|---|---|---|---|---|---|
| 01 | `.../TouchSpritePe.app/Hades` | arm64 | `69058be723573177` | 无 | 无 | Foundation、UIKit、objc、System、CoreFoundation |
| 02 | `.../TouchSpritePe.app/OcrPlugin.dylib` | arm64 | `39edd4cf95b5fbca` | `/usr/local/lib/OcrPlugin64.dylib` | 无 | OcrPlugin64、libc++、QuartzCore、CoreGraphics、UIKit、Foundation |
| 03 | `.../TouchSpritePe.app/TSDaemon` | arm64 | `4e89b9a34cd9a7a6d` | 无 | 无 | 系统框架、sqlite3、objc、libc++、System；strings 含 Lua、`ts.so`、`sz.so`、`LUA_PATH_5_2`、`rootless` |
| 04 | `.../TouchSpritePe.app/TSInstaller` | arm64 | `aacdf47219bb07bc` | 无 | `@executable_path/Frameworks` | UIKit、MobileInstallation、Foundation、objc、System、CoreFoundation |
| 05 | `.../TouchSpritePe.app/TSLn` | arm64 | `9859bd2a5df6fda0` | 无 | 无 | UIKit、Foundation、objc、System、CoreFoundation；strings 含 `DYLD_INSERT_LIBRARIES=/Library/MobileSubstrate/DynamicLibraries/TSTweakEx.dylib` |
| 06 | `.../TouchSpritePe.app/TSUpdate` | armv7、arm64 | `bb7c986049615a98` | 无 | 无 | Foundation、objc、System、CoreFoundation；strings 含 TSTweak 权限路径 |
| 07 | `.../TouchSpritePe.app/TouchSpritePe` | armv7、arm64 | `3f5b65129956e0d5b` | 无 | `@executable_path/Frameworks` | iOS 系统框架、libc++、sqlite3、z、WebKit/Twitter/JavaScriptCore 等；strings 含 `ts.so`、`overdrive.dylib` |
| 08 | `.../TouchSpritePe.app/libs/luasql.so` | armv7s、arm64 | `951940fe77cda1c8` | `/Users/Fish/Documents/MyFiles/触动精灵/luasql.so.openapi/build/luasql.so` | 无 | 自身构建机路径、系统框架、libc++；不是 ZiYan Lua 核心库 |
| 09 | `.../TouchSpritePe.app/libs/sz.so` | armv7、arm64 | `1abc6b40812896b4` | 无 | 无 | MobileGestalt、sqlite3、System、iconv、Foundation、libc++、CoreFoundation、objc；strings 含 `lua_exit`、lua-cjson、网络 socket |
| 10 | `.../TouchSpritePe.app/model.so` | arm64 | `84e45e7523ba94e8` | 无 | 无 | Vision、CoreML、UIKit、CoreImage、Foundation、objc、System、CoreFoundation |
| 11 | `.../TouchSpritePe.app/paddleocr.so` | arm64 | `c2e9f6e65741e79f` | 无 | 无 | libc++、CoreMedia、AssetsLibrary、AVFoundation、CoreGraphics、UIKit、Foundation |
| 12 | `.../TouchSpritePe.app/unzip` | arm | `3a5d2fa996d98d67` | 无 | 无 | libgcc_s、libSystem |
| 13 | `.../DynamicLibraries/TSTweak.dylib` | arm64、arm64e | `1c0e783e277ae76e` | `@rpath/TSTweakNoRoot.dylib` | `/var/jb/Library/Frameworks`、`/var/jb/usr/lib`、`@loader_path/.jbroot/Library/Frameworks`、`@loader_path/.jbroot/usr/lib` | TSTweakNoRoot、objc、Foundation、CoreFoundation、UIKit、CoreGraphics、AppSupport、WebKit、libc++、System |

独立证据目录：

`/Users/mac/Desktop/ZiYan_副本/DOCS/dylib_static_analysis_2026-09-08/readonly_run_2026-09-08_v4/candidates/`

命名规则示例：

- `03_TSDaemon_file.txt`
- `03_TSDaemon_arch.txt`
- `03_TSDaemon_sha256.txt`
- `03_TSDaemon_deps.txt`
- `03_TSDaemon_install_name.txt`
- `03_TSDaemon_load_commands.txt`
- `03_TSDaemon_symbols.txt`
- `03_TSDaemon_relevant_strings.txt`

全部 Mach-O 的 `LC_ID_DYLIB`、`LC_LOAD_DYLIB`、`LC_RPATH` 抽取汇总：

`readonly_run_2026-09-08_v4/candidates/path_load_extracts.txt`

## ZiYan 候选库证据

### 候选 A：vendor 输入

绝对路径：`/Users/mac/Desktop/ZiYan_副本/vendor/lib/liblua5.3.dylib`  
来源：ZiYan `vendor` 构建输入。  
类型/架构：Mach-O 64-bit dynamically linked shared library，arm64。  
SHA-256：`51ca786549e916d89a4b1264b1398c5abbe516dc3a501fc326ea4bb3f3003ae5`。  
install name：`/usr/lib/ziyan/lib/liblua5.3.dylib`。  
直接依赖：`/usr/lib/libSystem.B.dylib`。  
版本：compatibility `5.3.0`，current `5.3.5`。  
ABI 证据：导出 `_luaL_checkversion_`、`_luaL_newstate`、`_luaL_openlibs`、`_lua_close`、`_lua_load`、`_lua_newstate`、`_lua_pcallk`、`_lua_resume`、`_lua_version`、`_lua_yieldk`。

### 候选 B：Theos staging

绝对路径：`/Users/mac/Desktop/ZiYan_副本/.theos/_/var/jb/usr/lib/ziyan/lib/liblua5.3.dylib`  
来源：ZiYan Theos staging，由 `vendor/lib` 进入 staging。  
类型/架构：Mach-O 64-bit dynamically linked shared library，arm64。  
SHA-256：同为 `51ca786549e916d89a4b1264b1398c5abbe516dc3a501fc326ea4bb3f3003ae5`。  
`cmp`：`liblua_vendor_vs_staged=0`。  
install name、版本、直接依赖和 ABI 导出与候选 A 一致。

### Lua 解释器和依赖闭包

`/Users/mac/Desktop/ZiYan_副本/vendor/bin/lua5.3` 与 staging 的
`/Users/mac/Desktop/ZiYan_副本/.theos/_/var/jb/usr/lib/ziyan/bin/lua5.3`
均为 arm64，SHA-256：

`7f73822f9fb7461e1b0e7b73911ba05210e070a19a4f51504b527f41e6fa049e`

解释器直接加载：

```text
/usr/lib/ziyan/lib/liblua5.3.dylib
/usr/lib/libSystem.B.dylib
/usr/lib/ziyan/lib/libreadline.8.dylib
```

解释器的 `LC_RPATH`：

```text
/usr/lib/ziyan/lib
```

`vendor/lib/libreadline.8.0.dylib` 为 arm64，SHA-256：
`e7e5375f077da88f6165313175b6ba51b4db81f77fc7763fe1ca3ddf1e1e8560`，
install name 为 `/usr/lib/ziyan/lib/libreadline.8.0.dylib`，直接依赖
`/usr/lib/libncurses.6.dylib` 与 `/usr/lib/libSystem.B.dylib`。

完整闭包输出：

`readonly_run_2026-09-08_v4/ziyan_dependency_closure.txt`

来源和字节一致性：

`readonly_run_2026-09-08_v4/ziyan_candidate_provenance.txt`

当前未在 `packages/*.deb` 中找到包含 `lua5.3` 或
`liblua5.3.dylib` 的精确条目；因此 package archive 层面的安装内容仍需后续人工确认。

## 路径、配置和脚本搜索

目标目录内的精确结果：

- TouchSprite 控制信息声明 `TouchSpritePe-rootless`，并注明该包由 live `.53` 重打包用于 ZiYan 架构研究。
- `tsdebug.lua` 读取 `DYLD_LIBRARY_PATH`。
- 目标二只命中 TouchSprite 文档中的 `ts.so`、`sz.so`、iOS/Android 插件说明，没有命中 `/usr/lib/ziyan`、`/var/jb/usr/lib/ziyan` 或 `liblua5.3.dylib`。

目标目录搜索输出：

`readonly_run_2026-09-08_v4/requested_token_search.txt`

ZiYan 构建和脚本侧静态结果：

- `Makefile` 的 staging 目标为 `$DEST/usr/lib/ziyan/...`，Theos remap 后形成 `.theos/_/var/jb/usr/lib/ziyan/...`。
- `Makefile` 同时将 `vendor/bin/lua5.3`、`vendor/lib/` 放入 runtime。
- rootless 脚本使用 `/var/jb/usr/lib/ziyan/bin/lua5.3` 和
  `/var/jb/usr/lib/ziyan/lib`，并在若干入口导出
  `DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib`。
- rootful 脚本使用 `/usr/lib/ziyan/bin/lua5.3` 和 `/usr/lib/ziyan/lib`。
- 构建产物的 Lua Mach-O 仍将 `LC_LOAD_DYLIB` 和 `LC_RPATH` 写成
  `/usr/lib/ziyan/...`，未见 `/var/jb/usr/lib/ziyan/...` 的 Lua 核心库加载命令。

## 根因分类

1. **路径命名空间不一致，优先级最高。** 实际 rootless Lua 位于
   `/var/jb/usr/lib/ziyan/bin/lua5.3`，但核心库的绝对加载名为
   `/usr/lib/ziyan/lib/liblua5.3.dylib`。
2. **依赖闭包仍有第二个路径点。** 即使核心 Lua 库解析，解释器还需要
   `/usr/lib/ziyan/lib/libreadline.8.dylib`，其 install name 同样是 rootful 绝对路径，并继续依赖 `/usr/lib/libncurses.6.dylib`。
3. **`DYLD_LIBRARY_PATH` 证据不足以证明绝对 install name 已被改写。** 脚本侧存在 rootless 环境变量，但现场仍报告缺失 rootful 路径；静态证据不能把环境变量当作已完成修复。
4. **exit 134 仅能作为 abort 结果记录。** 现有静态材料支持缺库与路径问题相关，但不定位具体 abort 调用点。

## TouchSprite 与 ZiYan 边界

- 目标一的 13 个 Mach-O 全部来自 TouchSprite `.53` 重打包目录。
- `TSDaemon` 的 strings 含 `ts.so`、`sz.so`、Lua 5.2 环境变量和 TouchSprite 扩展版本提示；这属于 TouchSprite 运行时证据。
- `luasql.so` 的 install name 含 `/Users/Fish/.../触动精灵/...`，不是 ZiYan 构建路径。
- `OcrPlugin.dylib`、`TSTweak.dylib` 等均有 TouchSprite 自身 install name、依赖或注入边界。
- TouchSprite 动态库、`ts.so`、`sz.so`、`TSTweak.dylib`、`luasql.so`、`OcrPlugin.dylib` 均排除为 ZiYan 补库来源。
- 帮助文档只作为 TouchSprite API/插件命名和路径背景，不作为 ZiYan ABI 或库来源证明。

## 安装资格与设备处理

| 候选 | 来源 | 架构 | ABI | 路径匹配 | 后续资格 |
|---|---|---|---|---|---|
| `vendor/lib/liblua5.3.dylib` | ZiYan vendor，已证实 | arm64，已证实 | Lua 5.3 导出面，已证实 | rootful `/usr/lib/ziyan` 匹配；rootless `/var/jb/...` 未证实 | 仅人工审核候选 |
| Theos staged `liblua5.3.dylib` | ZiYan staging，和 vendor `cmp=0` | arm64，已证实 | 与 vendor 相同 | 文件位于 rootless staging，但 Mach-O install name 仍为 rootful 绝对路径 | 仅人工审核候选 |
| `vendor/bin/lua5.3` | ZiYan vendor，已证实 | arm64，已证实 | 解释器依赖 Lua 5.3，已证实 | `/var/jb` 现场路径与其 `/usr/lib` load name 不一致 | 仅人工审核候选 |
| TouchSprite 13 项 | ZiYan 来源未成立 | 多种 arm/arm64/arm64e | 非 ZiYan Lua ABI 证据 | 不匹配 ZiYan 目标库 | `DYLIB_SOURCE_OR_ABI_UNPROVEN`，排除 |

在人工审核前不执行复制、重签、install name 修改、安装、设备写入或运行态验证。

## 未解决问题

- `.53` 的 dyld 实际搜索顺序、rootless loader remap 状态和触发 abort 的精确调用点尚未取得运行态证据。
- package archive 未呈现 `lua5.3`/`liblua5.3.dylib` 精确条目，需人工确认最终 deb 是否包含 staging runtime。
- `libreadline.8.dylib` 及 `libncurses.6.dylib` 在 `.53` 目标路径上的实际存在性未读取。
- 当前没有证明仅设置 `DYLD_LIBRARY_PATH` 即可满足绝对 `/usr/lib/ziyan/...` 依赖。
- 未进行设备处理，因此没有 `.53` 端到端成功 chat/tool response 或加载成功证据。

## 只读命令和输出位置

本轮首先执行：

```text
python3 tools/ziyan_codex_checkpoint.py show
git status --short
```

完整只读命令类别：

```text
find
file
tar -tvf / tar -tzvf
dpkg-deb -c
lipo -info
otool -L
otool -D
otool -l
nm -gU
strings -a
rg
shasum -a 256
stat
cmp -s
```

命令清单：

`/Users/mac/Desktop/ZiYan_副本/DOCS/dylib_static_analysis_2026-09-08/readonly_run_2026-09-08_v4/commands.txt`

全部 v4 输出根目录：

`/Users/mac/Desktop/ZiYan_副本/DOCS/dylib_static_analysis_2026-09-08/readonly_run_2026-09-08_v4/`

旧证据文件 `otool_L.txt` 与 `otool_l.txt` 因 macOS 大小写不敏感文件系统发生过覆盖，本报告不采用该冲突文件；本报告采用 v4 独立的 `*_deps.txt`、`*_load_commands.txt` 和 `path_load_extracts.txt`。

## 操作声明

本轮仅读取目标和 ZiYan 本地构建产物并写入本地分析报告/证据目录：

- 未安装动态库。
- 未复制动态库到设备。
- 未重签动态库。
- 未 SSH 写设备。
- 未解冻 `.53`。
- 未安装 deb。
- 未恢复系统。
- 未重启进程。
- 未修改业务代码、兼容 stub、冻结证据、rollover seam 或 manifest。
- 未使用 TouchSprite/TSDaemon 动态库作为 ZiYan 补库来源。
- 当前报告提交后等待人工审核。
