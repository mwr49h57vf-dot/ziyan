# SB 注入回归 · 安全定位方案（只规划，不执行）

日期：2026-08-15  
状态：**未执行**。本文是静态计划。当前禁止连接写入真机、禁止恢复 plist、禁止打开 ZiYan、禁止重启 SB/BB。

---

## 0. 冻结条件（写死）

- `.101` / `.166` 已人工禁用 6 个注入 plist，ZiYan 守护 / framecap 已停，**系统已稳定**。
- **当前禁止操作这两台机器。** 不得恢复任一 plist，不得启动守护，不得打开 App。
- `.53` / `.112` **不得触碰**，不得当作本次定位对象。
- `.149` / `.171` 只读观察机，绝不部署 ZiYan，也不是本次定位对象。
- 不改 `/Users/mac/Desktop/ios7.lua`、`/Users/mac/Desktop/ios8p.lua`。
- 禁止 `sbreload` / `ldrestart` / `killall SpringBoard` / `killall backboardd` / `launchctl reboot`。
- 一旦将来某次恢复后 SB/BB PID 连续变化：**立即停止**，保持该模块禁用，不得用重启 SB 掩盖。

将来只有用户写出明确授权（机号 + 唯一模块名 + 允许观察 10 分钟）后，才允许 **一次只恢复一个模块**。不允许同时恢复多个模块。

---

## 1. 六个已禁用模块的 Filter / 进程范围

源文件以仓库根目录 plist 为准（与 Substrate Filter 一致）。

| 模块 | Filter | 进程类 | 范围 |
|---|---|---|---|
| **ZiYanFsCloak** | Bundles: `com.ziyan.fscloak.disabled` | 无有效注入 | 哨兵 Bundle，不进真实进程 |
| **ZiYanDefense** | Bundles: `com.ziyan.ziyan` | App 前台（仅子砚） | 不进 SB / BB |
| **ZiYanAppTouch** | Bundles: `com.xztl.ios` `com.ychj.hlhjlygr` `com.zsyxs180.game` `com.ljzbbadao.game` | App 前台（游戏） | 不进 SB / BB |
| **ZiYanFrameRelay** | Bundles: `com.apple.springboard`；Executables: `SpringBoard` | SpringBoard 注入 | 只进 SB |
| **ZiYanVol** | Bundles: `com.apple.springboard`；Executables: `SpringBoard` | SpringBoard 注入 | 只进 SB；负责 open_app / 音量 / Home 桥 |
| **ZiYanBBFrame** | Bundles: `com.apple.backboardd`；Executables: `backboardd` | backboardd 注入 | 只进 BB；BB 死通常拖死 SB |

未列入本次 6 项、本次也不得恢复：

| 模块 | Filter | 说明 |
|---|---|---|
| ZiYanBBTouch | backboardd | 默认不链；不在本次禁用清单，禁止顺带恢复 |
| ZiYanTEHook | SpringBoard | layout 内 TE 钩子；不在本次清单 |

分类摘要：

- **SpringBoard 注入：** ZiYanVol、ZiYanFrameRelay（以及未授权的 ZiYanTEHook）
- **backboardd 注入：** ZiYanBBFrame（以及未授权的 ZiYanBBTouch）
- **App 前台注入：** ZiYanDefense（子砚）、ZiYanAppTouch（游戏）
- **全局注入：** 无。六个模块都不是 `Executables=*` / 无 Filter 的全局注入。
- **无效注入：** ZiYanFsCloak（disabled 哨兵）

---

## 2. 将来的唯一恢复顺序（风险最低、范围最窄 → 最高）

一次只恢复一个。上一项 10 分钟 PID 稳定并经用户确认后，才允许谈下一项。

| 序 | 模块 | 理由 |
|---|---|---|
| 1 | **ZiYanFsCloak** | 不进真实进程，风险最低，用于验证“只动 plist、不加载代码”的操作本身不搅 SB |
| 2 | **ZiYanDefense** | 只进 `com.ziyan.ziyan`，不进 SB/BB。空闲 10 分钟不应加载；若要验证加载，必须另写授权“只打开子砚、不点运行” |
| 3 | **ZiYanAppTouch** | 只进 4 个游戏 Bundle，不进 SB/BB。空闲不应加载；禁止顺带开游戏，除非另写授权 |
| 4 | **ZiYanFrameRelay** | 进 SpringBoard，但职责比 Vol 窄（合帧中继）。plist 恢复后，**未重载 SB 则尚未注入** |
| 5 | **ZiYanVol** | 进 SpringBoard，且是 open_app / 音量 / Home 热路径。打开 ZiYan 页面后的重启环，它是优先嫌疑，因此放后 |
| 6 | **ZiYanBBFrame** | 进 backboardd。BB 崩溃会连带 SB 换 PID，影响面最大，最后做 |

禁止把 4/5/6 提前到 App 模块之前。禁止跳级同时恢复。

---

## 3. 单次授权后的观察合同（将来才执行）

1. 用户授权文本必须包含：设备（只许 `.101` 或 `.166` 之一）、唯一模块名、允许观察 10 分钟。
2. 只恢复那一个 plist。不启动 framecap / zydaemon，不打开 ZiYan，不触发运行 / 人工学习 / 演练 / 自动运行，除非授权里单独写了“允许打开某 App”。
3. 记录恢复前 SB/BB PID 与 etime。
4. 只观察 10 分钟：PID、etime、有无新 CrashReporter。不写其他文件，不杀进程。
5. PID 连续变化 → **立即停止**，把该模块重新禁用，写入 FAIL 证据。不得 `sbreload` / `killall SpringBoard` 掩盖。
6. 10 分钟 PID 不变 → 记 PASS（本模块、本观察窗口）。不得自动开始下一模块。
7. SpringBoard / backboardd 模块的限制：恢复 plist **不会**让已在跑的 SB/BB 立刻装上 dylib。因此：
   - 第一次 10 分钟只证明“plist 存在且空闲稳定”；
   - “模块已加载”需要另一次用户明确授权的加载步骤；
   - 加载步骤也不得用重启 SB 当故障恢复手段。若加载后 PID 连跳，停，保持禁用。

---

## 4. 本轮明确未做

- 未部署、未连接写入真机。
- 未恢复 `.101` / `.166` 任何一个注入 plist。
- 未启动 ZiYan，未跑 Z2，未构建最终包。
