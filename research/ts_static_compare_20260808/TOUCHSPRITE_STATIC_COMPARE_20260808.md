# TouchSprite 静态对比（只读）

## 范围与约束

- `.53`：只读提取 `TouchSpritePe` 的核心二进制和 Lua 库；没有启动、停止、注入或修改其进程。
- `.149/.171`：始终只读；没有部署、修改或写入任何文件。
- 结论只用于 ZiYan 的自研设计。不得把任何 TouchSprite 二进制、dylib、OCR 插件或私有源码作为 ZiYan 的运行依赖。

## 可复核样本

本地副本位于同目录下的 `53/`、`149/`、`171/`。关键结论由 SHA-256 确认：

| 组件 | `.149` 与 `.171` | 结论 |
|---|---|---|
| `TSDaemon` | 相同 | 不是版本差异 |
| `TouchSprite` | 相同 | 不是版本差异 |
| `TSTweak.dylib` | 相同 | 不是版本差异 |
| `OcrPlugin.dylib` | 相同 | 不是版本差异 |
| `TSLib.lua` | 相同 | 不是 API 库版本差异 |
| `Info.plist` | 相同 | 不是包配置版本差异 |

因此 `.149/.171` 的可观测差异必须按**运行态**解释，而不是按二进制版本解释：本次快照中 `.149` 为 `TSDaemon -server -b`，`.171` 为 `TSDaemon -run … -now -server`。不能将两者一次采样的 CPU/RSS 差值写成产品版本差异或性能胜负。

`.53` 是 rootless `TouchSpritePe`，核心 `TSDaemon` 为 arm64；它与 rootful 样本不是同一二进制。`.53` 的 daemon 比旧版多约 334 KB，OCR 插件也有小幅变化。

## 静态行为线索

`.53` daemon 与旧版都链接 IOSurface、IOMobileFramebuffer、SpringBoardServices、GraphicsServices、CoreGraphics 和 UIKit，说明二者都有常驻帧/系统帧能力。`.53` 还可见直接构造和分发 IOHID digitizer 事件的导入符号；旧版 rootful 的触控职责主要分散在 `TSTweak.dylib`/BackBoard 侧。

`.53` 的静态字符串明确包含下列状态对象或能力：

- `createScreenIOSurface`、`keepScreen`、`screenRenew`、`screenshotSurface`
- `NSLock`、`sslock`、`runSession`、`localServerQueue`
- `com.apple.springboard.lockstate`、`deviceIsLock`
- `isHideFloatInRun`、`showRunToast`、`showSysToast`

这只能证明其设计包含“帧资源 + 锁 + 会话 + 锁屏状态”的组合；不能据此推导其内部实现细节。

## 对 ZiYan 当前故障的直接启发

### 1. Toast 必须有独立的生命周期门禁（P0）

当前 `ZiYanToastBridge` 在一次 `showToast` 中会先按当下的 `UIScreen/scene` 几何布局，然后再异步重排一次。源码注释已承认场景切换会先把 Toast 放到中上部，下一次刷新才回到底部。锁屏或前台切换期间，第一次读取到的 `scene`、`UIScreen` 和脚本朝向可能并不属于同一几何 epoch，这与四机人工复现完全一致。

应实现自研 `ToastLifecycleGate`：

1. `willResignActive`、锁屏通知、scene 失活时进入 `unstable`，立即隐藏现有 Toast，禁止新建窗口和禁止单独更新 `label.center`。
2. Toast 请求仅保存“最后一条 + 到期时间”，不得在 `unstable` 期间做布局。
3. 解锁/激活后等待主线程上的稳定几何快照（同一 host/scene/orientation 连续确认）后，在一个禁动画事务中原子设置 window、root transform、label bounds 和 anchor。
4. 只有 epoch 未改变且请求未过期时才显示队列中的最后一条。

验收标准：锁屏、解锁、最小化前台 App、回到 App 的每个转换中，Toast 只能“保持正确位置”或“暂不显示”，不得出现一次错误坐标再回正。

### 2. 帧采集必须先做状态切换，再做重获帧（P0）

当前 framecap 的热路径仍会落入 SB relay / UICreate 冷备。`RequestSbRelay` 可等待约 1.6 秒，失败后又进入 black backoff；在这个窗口共享帧会变 stale，而 find 侧继续受旧帧/退避节拍影响。长窗已观测到 3–20 秒帧龄，这正是卡屏、黑屏和找色停顿的可见根因。

应改为单一 `FrameLeaseState`：`active → suspended/blocked → reacquiring → active`。

- 锁屏、非活动、前台 bundle 切换时，立即使旧帧 lease 失效；find/tap 返回明确的“重获中/不可用”结果，绝不把黑帧或过期帧伪装为可找色数据。
- 正常热路径只允许单一串行的 IOSurface/本地采集生产者；find 只读取不可变版本化 lease，永不等待 UI 创建或 SB relay。
- UICreate 子进程仅保留在受控诊断路径，不得在业务 find 热路径被重复 fork；P6 的 stderr、退出码、超时和 dump 应继续保留。
- 每次前台切换只启动一次有上限的 `reacquire`，失败后上报可诊断状态，而不是黑帧退避 + 旧帧续用。

验收标准：前后台/锁屏转换后不得出现 `write_black`、`relay_sb_fail`、`relay_timeout` 触发的多秒 stale；P2 对四机报告 P50/P95、最大帧龄与恢复时长。

### 3. 复用“常驻 IOSurface + 明确锁”的原则，而非复制二进制（P1）

TouchSprite 的可见静态接口表明它将截图 surface、会话和锁作为一组资源管理。ZiYan 已有 `ZiYanFrameResident`，但 fallback 体系绕开这一收敛点。应让 resident lease 成为唯一的像素所有权：生产者写入后提交序号，消费者按序号读取，回收只在 lease 不再被引用时进行。这样既避免 relay/UICreate 与找色并发抢帧，也避免长跑积压。

### 4. 触控执行器需与帧/Toast 解耦（P1）

`.53` 的 daemon 存在直接 IOHID digitizer 事件线索。ZiYan 可自研单一串行的 `TouchExecutor`，独占 IOHID client、按提交顺序派发触控，并与 `FrameLeaseState` 通过状态契约连接；不能让捕获失败、Toast 重排或 SB relay 阻塞触控队列。此项只能作为自研实现，不能复用任何 TouchSprite 代码或 dylib。

### 5. OCR 仅借鉴验收方式（P1）

两代均有私有 OCR 插件，且 `.53` 版本不同。它不能进入 ZiYan 包，也不能将“有返回字符串”当成识别正确。ZiYan 应继续 P3 的标准答案集：中文、英文、数字，逐样本记录正确/错误/误报与 P50/P95；在此基础上选择自研或合规第三方 OCR 适配器。

## 时钟风险

在本次只读检查中，`.53/.149/.171` 都显示 `2026-08-09`，而当前基准日期为 `2026-08-08`。设备时钟至少与采集基准不一致；P2/P7 的跨机比较必须记录采集机的单调时间和 UTC 偏移，不能直接按设备文件 mtime、设备日志墙钟排序或计算时长。

## 本轮未做的事

- 未对任何设备部署或修改 ZiYan/TouchSprite。
- 未启动 Frida、dump、hook 或运行任何 TouchSprite 脚本。
- 未将此次静态观察写成 ZiYan 通过或“超越触动”的结论。

