# Lua 与原生直接模块修复证据

本记录对应 #6、#7、#8、#13、#15、#17、#19。
本地最终命令为 tools/run_repair_regressions.py --lua tmp_shots/repair-20260912/toolchain/lua-5.3.5/src/lua-fixed.exe。
命令退出码 0。完整输出已保存为 lua-native-local-results.json。

## 工具来源

Python 使用本机 Codex 随附运行时。C 编译器使用原有 Strawberry GCC。
Lua 使用 https://www.lua.org/ftp/lua-5.3.5.tar.gz 官方源码，SHA256 为 0c2eed3f960446e1a3e4b9a1ca2f3ff893b6ce41942cf54d5dd59ab4b3b058ac，下载后核对一致。
源码与本地编译产物位于 tmp_shots/repair-20260912/toolchain，仅用于测试。

原样编译的 Windows Lua 在调用 CRT tmpnam 时出现 access violation。测试版本通过 tests/repair_20260912/windows_lua_temp.h 将临时文件名映射为 Windows GetTempPath/GetTempFileName；Lua VM、协程、I/O 和语法解析代码未改。
编译方式是 GCC -O1，include 上述 Windows helper，将 Lua src 的 C 文件合并编译，排除 luac.c。该适配未进入 iOS 产品。

## 失败与通过证据

1. #15 原始 Thread.wait 在主线程第一次 wait(0) 抛出 attempt to yield from outside a coroutine。修正 coroutine.running 第二返回值后，主线程、协程、兼容入口与定时任务测试通过。没有新增忙等。
2. #13 原始返回 false 的 runner 被 AI.test 判为 true。现分开记录 runner、execution_success、business_success、status 与 reason。nil 永远保留未验证；明确返回 true 才可进入成功，独立能力证据要求继续生效。旧全局 main 不会被复用。矩阵漏传 require_capability_evidence 的独立回归先失败，透传后通过。四个既有 AI/能力/矩阵合同也通过。
3. #7 合成 A 成功、B 损坏并残留旧转换 JSON 时，原代码返回了 A 的值。现统一调用原生 PlistRead 接口，失败返回明确错误，后续写入不遮蔽原 plist。列键、扫描、导出同样失败。真实 Lua 测了既有 JSON、缺失缓存、损坏输入、原子提交失败。原生 plist 调用用接口替身隔离；没有假装执行了 iOS helper。
4. #8 原代码在 report.json 打开失败时仍返回入队成功。写入、关闭、rename、state 提交各阶段故障现向上传播，失败保留原报告。网络失败同时 state 提交失败，以及网络成功但 state 提交失败都计入 storage_errors。ErrorReporter 对成功/失败回执保持一致，保留期只删除已可靠接管的源报告。故障测试使用受控 I/O 替身，真实磁盘与六进程补验证见 queue-disk-restart-evidence.md。
5. #6 已复核原代码先删除目标再忽略复制结果的路径。现协调读取、同目录唯一临时副本、内容比对、同步和原子 rename，失败保留旧目标并逐项提示。Foundation 行为测试为 tests/repair_20260912/script_import.m，覆盖部分复制失败、成功覆盖、同源和临时文件清理。当前没有 Foundation/UIKit SDK，未运行该原生测试，不能宣布导入行为验收完成。
6. #19 原全屏负角点返回整图却被标为 cropped，跳过全屏缩小。现使用同一 C 几何函数区分实际裁剪，全屏不同写法均得到 900 像素最长边，小区域保留放大并遵守上限。GCC 对生产几何代码的运行断言通过。UIKit 和 OCR 识别、峰值内存、耗时尚未测量。
7. #17 原 emit_full_lua 固定注释与原生整段禁词冲突，普通字符串提及也被错误拒绝。C/Python 共享样例覆盖注释、字符串、真实库调用、转义、动态加载、长参数、and/or/拼接表达式和阶段函数声明。实际生成函数输出送入原生 C checker 后通过，再由 Lua 5.3.5 编译。受控 HTTP 验证正常输出 ok/from_sidecar=true，坏语法或动态依赖为 false。
8. #17 新原生语法 helper 的生产 checker 常量由独立测试读出，使用实际 Lua 的 -E 和文本 loadfile 编译。四个 CLI 用例通过，顶层业务哨兵和 LUA_INIT/LUA_INIT_5_3 哨兵均未执行。macOS Foundation helper 集成测试明确跳过。

主任务 Python 测试发现 11 项，10 项通过，1 项原生 Foundation 检查因平台跳过。另有四份 Lua 行为脚本、实际 C 几何/依赖编译与四个既有静态合同。不同验证类别没有合并成设备通过数量。

## 审查结论

独立审查提出的矩阵证据参数、状态提交错误、动态依赖、长参数截断、坏语法和阶段入口误接受均有对应修正和回归。
C 和 Python 依赖检查用于约束生成契约，不声称可隔离任意恶意 Lua 程序。
当前没有发现仍未处理的本轮本地回归失败。原生编译和设备验收缺口保留，详见 STATUS.md。
