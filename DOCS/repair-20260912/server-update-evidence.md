# 发布服务与热更新本地验收

日期：2026 年 9 月 12 日。范围：工单 #3、#4、#9、#10。
源码基线：`cfb4695bd83c8a11dbaf428b1bc0c9f58d39b090`。
当前结论：本地行为测试及隔离管理页验收通过。尚未进行真实 iOS 安装、运行探测或五机验收，不能标为 DEVICE_PASS。

## 已交付行为

工单 #3：安装命令退出码、dpkg 完整配置状态、准确版本和架构分别核对。
安装前校验并保存旧包、候选包及其 SHA256。单个 `state` 文件原子提交当前版本、前版本与健康标记。
安装失败、半配置、查询无结果、运行检查失败或状态保存失败均返回失败，并尝试安装旧包及核验其真实状态。
留下 `transaction` 的中断流程会阻止下一次安装，`rollback()` 提供明确恢复路径。
`install` 必须收到实际运行探测回调 `health_check(version)`。缺少回调返回 `runtime_health_required`，不会开始安装。
`run_once` 在缺少该回调时也会在下载前返回失败；`dry_run`、`verify_only` 保留独立语义。
搜索当前 `lua`、`objc`、`tools` 的直接调用，未发现生产侧启用 `install` 或 `run_once` 的调用方。
现有 `tools/test_hotupdate_contract.py` 仅覆盖检查、兼容判断、下载与校验，没有安装调用。

工单 #4：发布与上报凭证分离；未配置发布凭证时关闭发布。
默认监听回环地址，局域网需显式启用。同一数据目录只允许一个服务进程。
只读取导入目录内的 ZiYan deb，对照真实 control 身份及固件依赖校验声明，私有快照用于解析、哈希与最终保存。
支持 tar、gz、xz、bz2 与旧式 LZMA-alone 包归档。
下载名称包含内容哈希。同版本、架构、渠道的不同内容返回 409，相同内容重试返回实际已提交记录。
管理页可验证、清除凭证，明确显示缺少、无效、失效及权限不足。输入值不保存到浏览器持久存储。

工单 #9：正文、索引在进程内锁及可恢复事务记录下提交。
相同事件和相同内容幂等成功；同编号不同内容返回 409，保留原正文。
索引失败不回报成功。重启会利用已持久保存的事务恢复正文和索引。
索引损坏、正文缺失或哈希冲突保持错误，不默默覆盖。

工单 #10：服务端按 Debian 版本语义选择兼容候选。
客户端使用 `dpkg --compare-versions`，下载后准备包期间再次读取已装版本。
同版本和降级被普通更新拒绝；显式 `rollback()` 为独立恢复操作。

## 已执行验证

1. `python tools/ziyan_log_server/test_repairs.py`：14 项通过，退出码 0，10.129 秒。完整记录在 `server-http-tests.txt`。
   包括双架构发布、下载哈希、LZMA-alone、权限分离、凭证轮换、声明范围、伪造包、包身份、并发与版本回退选择。
2. `lua-fixed.exe tools/ziyan_log_server/test_hotupdate_repairs.lua`：32 项通过，退出码 0。完整记录在 `server-lua-tests.txt`。
   使用 Lua 5.3.5 解释器和独立的包命令、文件系统替身。覆盖退出非零却含进度文本、半配置、空查询、严格版本、回滚成功或失败、运行回调失败或异常、state 打开及写入、flush、close、rename 失败、中断恢复和准备期间版本变化。
3. `node tools/ziyan_log_server/test_admin_ui.mjs <Python路径>`：退出码 0。真实 Chrome 以鼠标点击验证缺少凭证、设备凭证拒绝、失效凭证发布拒绝、管理员授权、成功发布、读取清单及清除凭证。
   页面异常、console.error 及加载失败均为空；403 为预期拒绝响应。凭证未进入 localStorage 或 sessionStorage。
   记录为 `server-browser-tests.txt`、`admin-ui-result.json` 与 `admin-ui.png`，截图已人工查看。
4. `git diff --check -- tools/ziyan_log_server lua/modules/HotUpdate.lua`：退出码 0。

并发实测为 16 个请求、4 个 worker，0.265 秒完成，最终 9 个独立事件。
相同内容的 8 次重投中恰有 7 次幂等回执，所有索引哈希与实际正文一致。

进程中断测试使用真正独立的 Python 服务。在正文写盘后、索引提交前调用 `os._exit(73)`。
客户端未收到成功回执，进程退出码为 73。新进程从同一隔离目录恢复一条记录，正文哈希与索引一致，事务记录清除。
同时启动使用相同目录的第二个服务会退出失败并说明目录已被占用。

## 失败复现与复核修正

原日志竞态证据见 `event-race-baseline.json`。两个冲突请求都返回 200，但索引 SHA256 与最终正文不同。
发布幂等复核新增测试最初失败：返回值中的 notes 与清单中已提交 notes 不同。调整为返回原记录后，同一测试通过。
有效 LZMA-alone deb 在修复前的归档类型检查中被拒绝，证据见 `server-lzma-baseline.txt`。补充类型后真实 HTTP 发布与下载原字节比较通过。
缺少运行检查回调的新增 Lua 用例最初失败：默认路径仍安装并提交。现在明确拒绝，显式健康回调的升级路径仍通过。

## 环境与边界

Python：`C:/Users/Administrator/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe`。
Lua：`tmp_shots/repair-20260912/toolchain/lua-5.3.5/src/lua-fixed.exe`，官方 5.3.5 源码及 Windows 临时路径适配，工具链来源记录由集成验收统一保存。
Node 24.18.0；Chrome：`C:/Program Files/Google/Chrome/Application/chrome.exe`。
沙箱中的 Chrome GPU/渲染子进程无法启动。自动审核允许在沙箱外运行上述隔离浏览器脚本后，通过相同页面验收。
测试仅访问临时回环服务，全部数据为合成数据。脚本只关闭自己的服务和 Chrome 进程，并清理自己的临时目录。
浏览器 stderr 中存在机器已有扩展注册项文件缺失提示；它未形成页面异常。

尚未验证：真实 Theos 生成包、真实 dpkg 的维护脚本和设备故障恢复、设备业务运行探测回调、双方案及五机覆盖。
Lua 的 I/O 故障与 dpkg 状态由替身注入，不代表设备已通过，也不构成掉电持久性保证。
没有访问 SSH、安装设备包、重启系统界面、修改真实数据、提交、发布或关闭远端 Issue。
代码与测试 SHA256 见 `server-source-hashes.json`。

下一步：固定候选源码与真实双包后，在受控设备上接入实际运行探测，按 .101、.112、.166、.53、.61 顺序完成适用验收。
