# #8 真实磁盘、重启与 HTTP 验证

2026 年 9 月 12 日。本次只新增测试与证据，未修改产品代码。

测试：`tests/repair_20260912/test_queue_disk_restart.py`。

命令：`python -X utf8 -B -m unittest discover -s tests/repair_20260912 -p test_queue_disk_restart.py -v`。

退出码 0，1 条集成用例通过，耗时 3.169 秒。完整输出见 `queue-disk-restart-tests.txt`。

执行过程中读取的 OfflineQueue.lua SHA256 始终为 `0a97feb0c8634bd54a755b511bb862b53fe733ffb5def0008c6f7999bedd1e87`。测试在开始和结束比较源码哈希，拒绝在六次进程启动间切换版本。

## 实际验证

六次运行使用不同的 Lua 5.3.5 进程，运行时为 `tmp_shots/repair-20260912/toolchain/lua-5.3.5/src/lua-fixed.exe`。

1. PID 62812：普通报告入队成功。另一报告已提交到 spool，但注入 state 临时文件打开失败后，enqueue 明确返回 false。磁盘上有完整报告而无 state。原始报告与 spool 副本 SHA256 相同。
2. PID 38168：新进程恢复 orphan state。在本机端口已绑定但未监听时，两次真实 HTTP 连接均被拒绝。flush 返回 tried=2、sent=0、pending=2。磁盘 state 为 pending，attempts=1，next_retry 晚于更新时间。
3. PID 48692：再启进程，退避期间 tried=0、pending=2，未再次发送 HTTP。
4. PID 21512：同一端口启用受控 HTTP 接收服务，两份报告均被服务真实接收。flush 返回 tried=2、sent=2、pending=0。
5. PID 51516：同一 event_id 重投，服务器返回真实 dedup 回执。磁盘记录 dedup=true，sent=1。
6. PID 62104：再启进程读取磁盘，total=2、sent=2、pending=0。普通报告 attempts=3，原 orphan 报告 attempts=2。两份原报告均保持原内容。没有本轮临时文件残留。

服务器共收到三份完整 JSON：普通事件两次，orphan 事件一次。客户端记录两次连接失败、三次成功回执。测试逐项核对内容、次数、状态和原始文件。

## 替身与宿主适配边界

报告及 state 的打开、读取、写入、关闭使用真实 Lua 文件 I/O。只对 orphan 的 state 临时文件打开注入一次明确失败。测试没有使用内存字典模拟存储。

宿主桥替代 Windows 不支持的 POSIX shell：仅把 mkdir 和 ls 转成 Python 的真实目录操作，且所有路径必须位于本轮新建的工作区临时目录。其他 shell 命令一律不执行。curl/wget 回退被标为不可用，不模拟成功。

Windows CRT rename 不能覆盖已有文件。测试桥把生产 POSIX rename 映射为 Python os.replace，实际执行同目录原子磁盘替换。首次直接使用 Windows rename 的试跑发现该宿主差异，未把它归因于 iOS 产品。

Zy.Network.httpPost 的宿主桥使用 Python HTTP 客户端发出真实回环请求。没有替代 HTTP 回执。该测试验证队列读取这些回执后的行为，不验证 iOS 原生网络实现。报告根目录替换为 ASCII 测试路径，避免 Windows C 文件 API 的代码页影响中文路径。

每次测试创建 `tmp_shots/repair-20260912/queue-disk-*` 独立目录。Lua 的 TMP/TEMP 也指向其中，所有临时文件与清理均限制在该目录。未调用实际 rm，未读取或修改用户报告。测试结束后目录自动清理。

这证明跨 Lua 进程重启、真实磁盘提交和真实 HTTP 断开/恢复的行为。尚未模拟断电、文件系统崩溃，也未证明 fsync 持久性。rootful/rootless 设备、系统停止清理与实际设备网络验收仍未执行。
