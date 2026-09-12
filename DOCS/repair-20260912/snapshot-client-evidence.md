# 截图与取色客户端修复证据

日期：2026 年 9 月 12 日。工单：#5、#11、#12、#18。

基线：`cfb4695bd83c8a11dbaf428b1bc0c9f58d39b090`。本轮没有提交、发布、SSH 或设备写操作。状态为本地契约验证通过，设备验收未执行。

## 最终行为

默认监听回环地址。本机 `POST /pairing/start` 生成 120 秒有效的一次性配对码。客户端用 `POST /pair` 换取 900 秒有效的随机凭证，凭证关联客户端 IP。截图、状态、健康查询、找色和业务测试入口统一校验。帧令牌继续用于帧一致性，不参与身份认证。新配对、撤销和过期使旧凭证失效。关闭后恢复回环监听，等待发送期间也检查撤销状态。浏览器 Origin 请求被拒绝。

HTTP 请求头最多 8192 字节，正文最多 65536 字节。完整请求共享 5 秒单调时钟期限。缺正文、重复或错误 Content-Length、超长、截断、超时和不支持的传输编码被拒绝。收齐正文后才进入业务处理。完整响应共享 8 秒期限。连接使用非阻塞 I/O；设置失败则关闭连接。超时、错误和异常统一关闭连接并清除截图忙碌文件。

取色器支持配对、附带凭证、失效提示、重新配对和撤销。回调经主线程队列处理。截图请求绑定请求编号、设备、方向和目标图像窗口。关闭目标、切设备、切方向和停止实时会作废旧请求。实时模式固定目标窗口。撤销后设备状态标签同步变为未配对。

加密载荷加入 paired_http，并在启动入口先加载依赖模块。原本未随仓库提供的 _collect_imports 改为可追踪的 picker_imports。源码隔离测试证明启动入口可以载入配对客户端。

## 验证

Python：`C:/Users/Administrator/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe`。

C 编译器：`C:/Strawberry/c/bin/gcc.exe`。沿用现有 Tk 和 Pillow。

1. 从基线提取原取色器到独立临时目录，运行 `SnapshotWindows.test_switching_tabs_does_not_redirect_delayed_snapshot`。退出码 1。A 仍为红色，预期为响应的绿色，复现等待期间切页后目标错误。临时目录已自动清理。
2. `python -B -m unittest discover -s tools/ziyan_colorpicker -p 'test_snapshot_*.py' -v`，退出码 0，18 项通过。完整输出见 `snapshot-client-tests.txt`。包含真实 HTTP 客户端配对、状态、PNG、找色、撤销、错误凭证和过期；真实 Tk 按钮完成配对、截屏、撤销；真实 Tk 多图切页、关页、设备/方向切换、停止实时和连续刷新；源码隔离发行入口；生产 C 传输层的真实 Windows socket 测试。
3. 真实 socket 将超过 5 KB 的同一 POST 一次发送和分段发送，响应正文完全一致。截断、缺正文、超长、错误长度、chunked 和超时分别被拒绝，业务响应为空。正常 2 MiB 响应逐字节一致。
4. 慢读 socket 使用缩短至 0.2 秒的测试期限，实际在约 0.219 秒退出发送。后续健康请求在断言的 1.5 秒内完成。此测试不能证明设备上 8 秒期限的性能。
5. `gcc -std=c11 -Wall -Wextra -Werror tools/ziyan_framecap/test_snapshot_http_contract.c -o tools/ziyan_framecap/test_snapshot_http_contract.exe` 后运行产物，退出码 0，输出 `SNAPSHOT_TRANSPORT_CONTRACT=PASS`。包含持续 EAGAIN/EINTR、断连、发送错误、部分发送、撤销中止、收包限制、凭证错误/过期/复用/来源地址和回环访问。
6. GUI 撤销标签测试曾退出码 1，修复后同一测试通过。源码隔离发行测试曾因缺依赖退出码 1，修复后通过。发行自测使用不读取源码的 `--smoke` 入口。
7. `ZiYanColorPicker.py --smoke` 通过七种格式；`test_picker_panel_bugs.py` 输出 `PICKER_PANEL_BUGS=PASS`；本组 `git diff --check` 退出码 0。

测试记录保留现有图标读取产生的 ResourceWarning。该警告不涉及截图请求或凭证。

## 当前源码 SHA256

* ZiYanSnapshotHttp.m：`80E681ED5F61F8296D6C8CCE9237A00F233A6E380EA8FDB056DC7FE07A22E15E`
* ZiYanSnapshotTransport.h：`1295C7E674161641BCC60A96E43D3EF2BAEB51F6A2253757E3ECAFAA6C27C0E0`
* ZiYanColorPicker.py：`7B6CDD12DE67A5A959505D8109D6BF99BC4F97F2684F42C34161A1687BEA3FFA`
* paired_http.py：`97A6E13AAF9194312C1E99C3391F60074A4D9927C5D2A1FEAFB19221D87F699A`

## 使用与边界

操作命令及客户端步骤见 `tools/ziyan_colorpicker/USAGE.txt`。按主任务确认，本轮设备本机命令是启用和撤销入口，设备设置 UI 尚未接入。配对码只向操作者显示，凭证不落盘、不写日志。HTTP 本身未加密，仅适用于可信局域网。

CodeGraph、iOS SDK 未就绪。未编译 Objective-C 服务、未重新打包 Windows exe，也未验证 iOS 文件协调器或设备监听重绑。本地测试直接运行生产的可移植传输层；Foundation 路由接线仅完成源码检查。旧 ZiYan.zip 保持原状，不能作为本轮候选。

`.101 → .112 → .166 → .53 → .61` 验收尚未执行。FC_N、SB_CHG、设备停止清理和 `.61` 最终结果均未取得。#5/#11 的原生路由与资源清理、#12 的设备找色等价性仍待实际设备验证，不据此关闭最终验收。

回退时先由设备本机撤销配对并关闭远程入口。代码回退不触碰用户图像或设备数据。下一步由主任务独立复核本组 diff，再在具备 iOS 构建条件和授权设备通道时验证候选包。
