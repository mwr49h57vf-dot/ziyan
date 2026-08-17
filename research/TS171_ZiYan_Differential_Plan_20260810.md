# .171 TouchSprite ↔ ZiYan 卡屏差分方案

日期：2026-08-10

## 结论先行

当前 ZiYan 的卡屏/黑屏主因不是单个找色函数，而是前台切换后的帧生产链不稳定：

```text
IOMFB unavailable
  → CARender black / UICreate fallback / SB relay
  → relay_timeout、relay_sb_fail、uicreate_* 或 black_backoff
  → shm stale / seq=0 / 旧帧续用
  → 业务层表现为卡屏、黑屏、找色停顿
```

只读 .171 对照显示：TSDaemon 300 秒 RSS 基线与末值均为 31856 KB，delta=0，重启=0；同窗采样 20/20 成功。ZiYan 的历史长窗证据则出现 3–20 秒帧龄、`relay_timeout`、`relay_sb_fail`、`uicreate_exc_NSInternalInconsistencyException` 和 `black_backoff`。

## 可复核证据

- .171 内存长窗：[TS_RSS_SLOPE.md](/Users/mac/Desktop/ZiYan_副本/tmp_shots/TS_OBS/20260809_134823/TS_RSS_SLOPE.md)
- .171/P2 同口径采样：[SUMMARY.txt](/Users/mac/Desktop/ZiYan_副本/tmp_shots/TS171_P2_COMPARE_COMPLETE_20260809_224327/SUMMARY.txt)
- 静态差分：[TOUCHSPRITE_STATIC_COMPARE_20260808.md](/Users/mac/Desktop/ZiYan_副本/research/ts_static_compare_20260808/TOUCHSPRITE_STATIC_COMPARE_20260808.md)
- ZiYan relay/黑帧证据：[remote.log](/Users/mac/Desktop/ZiYan_副本/tmp_shots/LIVE_MIN_COMPARE_20260809_043849/remote.log)

静态提取只能说明 TouchSprite 具备 `createScreenIOSurface/keepScreen/screenRenew`、锁与会话对象；不能证明其内部源码，也不把 TouchSprite 二进制、dylib 或私有代码放入 ZiYan。

## 新的实现边界

1. **FrameLeaseState 作为唯一像素所有权**：`active → suspended → reacquiring → active`。前台、锁屏、scene 变化立即使旧 lease 失效；找色只能读取已提交的不可变 lease。
2. **业务热路径单一生产者**：优先常驻 IOSurface/IOMFB；业务 find 禁止同步等待 SpringBoard relay、CARender 或 UICreate 子进程；UICreate 只保留 P6 诊断路径。
3. **失败不续命旧帧**：捕获失败返回明确 `reacquiring/unavailable`，不把 stale/black 帧交给找色，也不重复 fork 子进程。
4. **采集、Home、Toast、Touch 四条串行队列解耦**：任何一条队列不得通过同步调用阻塞其它队列；Toast 只消费稳定几何快照。
5. **只做差分验证，不做猜测式补丁**：每次改动必须同时记录 provider、seq、age、lease 状态、relay/UICreate 错误、CPU、RSS、重启和黑帧计数。

## 验收门禁

- 同一业务脚本、同一 Home/锁屏/最小化序列，.101/.112/.166 与只读 .171 同窗运行。
- 10 分钟定位窗：不得出现 `relay_timeout`、`relay_sb_fail`、`uicreate_exc`、持续 `seq=0` 或 black backoff。
- 30 分钟回归窗：App 帧龄 P50/P95、最大值、恢复时间、RSS/CPU 与 .171 同表；不得以一次短门禁 PASS 代替长窗结论。
- 3 小时长稳窗：SB 重启=0、framecap 单实例、停止后无残留、黑屏/卡屏人工观察与日志一致。

## 当前状态

- P2 `.112` settled 短窗已 PASS，但不代表三机长稳 PASS。
- P3 `.101/.112/.166` 中文标准答案仍 FAIL。
- P6 `.166` UICreate 仍 FAIL，禁止升级 C-65.11。
- `.53` 暂停；`.149/.171` 继续只读。

下一步应先完成上述差分采集和 FrameLeaseState 设计评审，再实施单一生产者改动；在此之前不再叠加 Home/Toast/relay 的局部补丁。
