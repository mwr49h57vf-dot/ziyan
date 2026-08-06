# SYSTEM_REGRESSION_REPORT — 阶段 7.6.3

**日期**：2026-07-23（初版审计）· **续更 2026-07-26 22:08（§15 Wave4 / 8-84）** · 前：§14 锁定 / 8-83 Wave3  
**性质**：审计 → Screen Mirror（§7）→ R8.4（§8）→ 业务脚本 OPEN（§9）→ **SECURITY_AI**（§13）→ **锁定快照**（§14）→ **Wave4**（§15）  
**仓库**：无可用 git commit 链（工作区阶段产物 / 热部署为主）→ 以 **阶段版本 + 文件 mtime + 设备现场 dump** 定位回归点。

---

## 1. 用户报告的问题（对照现场）

| # | 现象 | 现场 dump（审计时） | 解读 |
|---|------|---------------------|------|
| 1 | find 对、tap 偏 | `.166` tap_proof `logic=1044,346 hid=0.460,0.919`；Vision 与 tap **同逻辑点下发** | Lua tap 未二次转换；偏移在 **Oc HID/UITouch / AppTouch** 映射层 |
| 2 | Toast 横屏游戏仍像竖屏 | toast `toastOrient=1 rot=CCW(+90)`，但宿主仍为竖屏 `host=320×568` / `.53 raw` 常竖屏 | **数学上跟 init(1)**，视觉上依赖「竖屏 host + 旋转」；与 App 真实横屏可能仍不一致 |
| 3 | Volume 弹窗方向错 | R4 后 `menu_geom init=1 via=ScreenTransform`；R4 前为 **硬编码 init=0** | R4 试图修方向；若仍觉「竖屏」，属 **旋转矩阵/宿主与物理 raw 不一致**，非未改到文件 |
| 4 | SB 几分钟重启 | ScreenBridge 注释 jetsam；`.53` ExcResource；lua RSS=0 僵尸 | 长跑资源模型 vs TSDaemon 差距；非单点「音量键失效」 |

学习设备 `.149`/`.171`：TSDaemon 长跑（周～月级），只读采集见 `logs/device_behavior/`。

---

## 2. 污染模块（按风险）

### P0 — 直接相关回归面

| 模块 | 阶段/版本 | 污染说明 |
|------|-----------|----------|
| **ZiYanOrientMap.h** | 7.6.2-**R3.1** (≈07-22 23:05) | WindowNorm / MapLogicToNorm 调整；竖屏窗互逆 + HID 玻璃规范 |
| **ZiYanScreenBridge.m** | **R3.1** | HID 固定 `MapLogicToNorm`；去掉 forceLand 横屏恒等 HID |
| **ZiYanAppTouch.m** | **R3.1** | 由「横屏恒等 HID」改为 `ZiYanMapLogicToTap(..., preferPortraitHID=YES)` → **游戏内 tap 最可疑回归点** |
| **Tweak.m Volume** | 7.6.2-**R4** (≈07-23 12:44) | 废除验收态 `orient=0`，改 `ZiYanScreenXformCurrent()` |
| **ZiYanToastBridge.m** | **R4** | ToastPositionManager 锚点（公式与改前等价，主要是命名/经 ScreenTransform） |
| **ZiYanScreenTransform.h** | **R4 新增** | Volume/Toast 统一入口；不碰 tap Lua，但改变 Overlay 朝向策略 |

### P1 — 稳定性 / 旁路

| 模块 | 阶段 | 说明 |
|------|------|------|
| ScreenBridge 截屏/OCR 缓存 | R / R2 / R3 | jetsam 主因；死循环 find+toast 加压 |
| stability.lua / LearningObserver | R3.3–R4 | **观察/心跳**，非坐标执行核心；冻结期可保留不扩 |
| Optimization 2.0 | 7.6.2 | **未直接改 Touch 矩阵**；本阶段禁止继续开发 |

### 未污染（审计结论）

- **Lua `tap()` 本体**（R3.1/R4 均声明未改语义：逻辑原样 IPC）
- Device / Coordinate / Verify / StateMachine / ScriptRunner 核心管道（无证据显示 R4 改其执行语义）

---

## 3. 回归点判定（是否找到）

**是 — 可定位到阶段版本，而非单一 git SHA（仓库无稳定 commit 链）。**

| 症状 | 最可能引入点 | 依据 |
|------|--------------|------|
| **tap 偏移（App 内）** | **R3.1 AppTouch → 竖屏玻璃 HID** | find 在 logicBuf；游戏窗横屏时 UITouch/HID 不对称历史曾反复；mtime 07-22 23:13 |
| **tap 偏移（桌面/SB）** | R3.1 ScreenBridge HID=Norm | 角点曾 ok；业务色点仍可能与 App 路径分裂 |
| **Toast/Volume「竖屏感」** | Overlay 模型本身（竖屏 host+旋转）；**R4 改变 Volume 策略**；**R3.1 前 Volume 故意 init=0** | R3.3 诊断已记「Volume init=0 分裂」；R4 改为 init=1 后 dump 已变，视觉仍可能错旋 |
| **SB 重启** | ScreenBridge 内存峰值（长期） | 与 TSDaemon 模型差异；非 R4 独有，但脚本死循环放大 |

**次级嫌疑**：R4 `ScreenTransform` 与物理 `raw` 横竖不一致时（.166 `raw=568×320` vs host `320×568`）旋转方向/中心钉固导致 Overlay「看起来仍竖」。

---

## 4. 建议恢复方案（仅方案，本阶段不执行）

**原则**：以 TouchSprite 学习设备行为为基准；**不要重新设计**；优先回滚污染面。

### 方案 A — 最小回滚（推荐先做）

1. **Volume**：恢复 R4 前「会话中可跟 init，但验收硬规则需对照 TS」——若 TS 音量窗跟游戏朝向，则保留跟 init，但 **修正旋转符号/宿主** 以匹配物理 raw；若仍错，回滚到 snapshot_pre `Tweak.m` 再对比视觉。  
2. **AppTouch**：回滚到 R3.1 前「横屏窗恒等 HID + 竖屏窗 OrientMap」分支（**仅 App 注入路径**），ScreenBridge 桌面路径保持 Norm。  
3. **Toast**：回滚 ToastBridge 至 snapshot_pre；或冻结 ScreenTransform 仅给 Volume 用。  
4. **不回滚** Lua tap / Verify / Device / Coordinate。

### 方案 B — 冻结点回退

- Oc：以 `tmp_shots/PHASE762R4_MIRROR/snapshot_pre/` + **R3.1 前 AppTouch** 为组合基线。  
- 去掉或旁路 `ZiYanScreenTransform.h` 对新 Overlay 的强制。  

### 方案 C — 稳定性（与坐标分离）

- 降 find/toast 频率与截屏峰值（引擎侧节流，**不改用户脚本**）。  
- 清理僵尸 `ziyan_run`；SB 内禁止再堆大 PNG。  

### 验证门禁（恢复后）

- `.166` ios7.lua / `.53` ios8p.lua 同方案  
- 对照 Desktop 三图：App 区、toast、tap、volume 朝向  
- 学习设备仅 DEVICE_BEHAVIOR_LOG 只读对比，不部署子砚  

---

## 5. Optimization / 新功能

**冻结**：禁止新增 Optimization 功能、禁止新 Screen Mirror「增强」、禁止改核心执行逻辑，直至 7.6.3 恢复验收通过。

---

## 6. 证据索引

- 阶段报告：`PHASE762R31_TOUCH` / `PHASE762R33_MIRROR` / `PHASE762R4_MIRROR` / **`PHASE763_RECOVERY`**
- R4 前快照：`PHASE762R4_MIRROR/snapshot_pre/` · 恢复前：`PHASE763_RECOVERY/snapshot_pre/`
- 学习日志：`logs/touchsprite_learning/` · `logs/device_behavior/` · `logs/stability/`
- 图片：Desktop `9785…` / `be8f…` / `a2c9…`（R3.3 已解读）

---

## 7. 恢复结果（2026-07-23 已执行方案 A）

| 项 | 结果 |
|----|------|
| AppTouch 横屏 identity | `.166`/`.53` in-game `space=screen_landscape_identity` · center hid=0.5 |
| Overlay rawLand | 双机游戏横屏：`mode=rawLand_identity host=raw rot=0` |
| 角点 mapping | 双机 5/5 `err=ok` · `x1=x2=x3=yes` |
| tap Lua | **未改** |
| Volume− 人手 | 待物理键确认（与 Toast 共用 layout） |
| SB 30min | 采样中；部署后 etime 已数分钟无重启 |

**状态**：RECOVERY DONE · **等待确认** · 勿自动进入下一阶段。

---

## 8. R8.4 文档/兼容层回归结果（2026-07-25 17:20）

本节记录恢复后新增的 TS→Zy 兼容镜像与手册更新，**不改变**前文对 R3.1/R4 坐标与 Overlay 回归点的审计结论。

| 项 | 结果 |
|----|------|
| 包 / 引擎 | `0.0.92-8-29` · Engine `2.20.0`（Lua 热更） |
| HF 权重 | v5 / UPG / mmbert COMPLETE → `vendor/hf_models/` |
| TS 文档采集 | 573/573 完成 → `tmp_shots/PHASE763R8/ts_docs_archive/` |
| TS→Zy 镜像 | 476 个采集函数名已注册到 ZiYan 自研 compat 后端 |
| 实现状态 | `implemented=82` / `stub_generic=309` / `stub_planned=25` / `stub_unsupported=60` |
| HTML 手册 | `子砚触控函数说明.html`：174 Zy API + 476 TS→Zy 镜像条目；已回写双机 compat 摘要 |
| `.166` rootful | `compat_mirror_selftest.lua` → `pass=478 fail=0 skip=0 total=476` |
| `.53` rootless | `compat_mirror_selftest.lua` → `pass=478 fail=0 skip=0 total=476` |
| SB 监控 | 本轮 compat 双机跑通期间无 SB PID 变化记录 |

### 修复点（本轮）

| 问题 | 修复 |
|------|------|
| 同版本二次 `init` 早退不载 compat | `init.lua` 早退分支补载 `layers` / `compat_registry` |
| `Zy.Compat.count` 为空 | `compat_registry` 强制创建 `_G.Zy.Compat` |
| `pressHomeKey` ↔ `keycode.home` 递归卡死 | `__ZIYAN_NATIVE_*` / `__ZIYAN_COMPAT_WRAP_*` |
| `yolo` 命名空间与同名函数冲突 | 表+`__call` 元表共存注册 |
| 批量真机测试阻塞（输入/IO/触控等） | 注册契约检查 vs 纯函数/轻量图色真实调用 |

### 证据索引

- `tools/ziyan_doc/ts_zy_mirror_map.json`
- `lua/ziyan_engine/compat_impl.lua` · `compat_registry.lua` · `init.lua`
- `lua/modules/Input.lua` · `lua/ziyan_engine/layers.lua`
- `tmp_shots/PHASE763R8/api_selftest/compat_result_166.txt`
- `tmp_shots/PHASE763R8/api_selftest/compat_result_53.txt`
- `tmp_shots/PHASE763R8/TS_ZY_MIRROR_REPORT.md`
- `tmp_shots/PHASE763R8/HTML_HANDBOOK_R84.md`
- `tmp_shots/PHASE763R8/GATE_VERDICT.md`
- `GPT.txt` · `GPT_PROJECT_STATE.txt`

### 当前门禁结论

| 序 | 项 | 状态 |
|----|----|------|
| 串行1 | HTML + TS→Zy 镜像 + 双机 compat | **PASS** |
| 串行2 | SECURITY_AI 全量 + 双机实测 | **未闭环** |
| 串行3 | 3h 长稳 | **禁止启动** |

**总判定：门禁不通过 · 禁止下一阶段 · 禁止长稳采集。**

硬约束重申：触动/XXTouch 仅作章节/契约学习；全部实现须走 ZiYan 自研后端，禁止私有 API/源码复用。

---

## 9. R8.4 后业务脚本回归（2026-07-25 17:35）· OPEN

复测：`Desktop/ios7.lua` → `.166`；`Desktop/ios8p.lua` → `.53`。  
证据：`tmp_shots/PHASE763R8/REGRESS_IOS_SCRIPTS/`。

| 现象 | 判定 | 说明 |
|------|------|------|
| compat 劫持 find/toast | **否** | `wrap_find=nil`，原生 cv 路径 |
| 自命中找色 | **OK** | 双机邻域 self_hit 成功 |
| 业务找色 | **依赖前台** | `.166` 采样 `front=SpringBoard` → searching |
| Toast / 音量弹窗 | **回归 OPEN** | `.53` Toast=`portraitHost_rotate`，Volume=`rawLand_identity` |
| tap HID | **回归 OPEN** | `.53` 同点 `0.774,0.911` ↔ `0.911,0.226` 翻转 |
| Zy.Compat 丢失 | **已修 Lua** | `modules/init.lua` 保留 prev Compat（te_boot 后覆盖） |

### 根因对照（与 §2/§3 污染面衔接）

- Overlay：R8.2 Toast `preferScreenLandIdentity:NO` vs R8.3.4 Volume `YES` → scene 竖/屏横时模式分裂（延续 R4 Overlay 张力）。
- AppTouch：横屏 identity 与竖屏玻璃 HID 在 bounds 抖动时交替（延续 R3.1/恢复路径张力）。
- **非** TS→Zy 476 镜像直接破坏 find 全局（本轮未 wrap）。

### 门禁影响

- 串行1（HTML/镜像/compat）仍记 PASS。
- **新增阻塞**：业务脚本 Overlay/HID 回归未过 → 不得开 3h；建议 SECURITY_AI 串行2 让位于 Overlay/HID 修复。
- 总判定维持：**不通过**。

## 10. R8.3.5–R8.3.8 Volume 统一 + 「运行」最小化（2026-07-25 18:25）

包：`0.0.92-8-38`（双机已装）。证据：`tmp_shots/PHASE763R8/REGRESS_VOL_MIN/`。  
约束：未修改 Desktop `ios7.lua` / `ios8p.lua` 源内容（仅 scp）。

| 项 | 判定 | 说明 |
|----|------|------|
| Volume vs Toast | **PASS** | 均 `preferScreenLandIdentity:NO`；`.53` 游戏前台 `rawLand=1 sceneLand=0` → 同为 `portraitHost_rotate`（不再 `rawLand_identity`） |
| 仅音量弹窗 | **PASS** | App 进程保留，无 minimize 日志 |
| 点「运行」后最小化 | **PASS** | `.166` front→游戏/SB；`.53` front→`com.ljzbbadao.game`；lua 存活；ZiYan App SIGTERM |
| 找色 toast | **部分** | 会话 toast 方向正确；色点命中依赖游戏画面（searching≠引擎坏） |
| tap HID 翻转 | **仍 OPEN** | 本轮未闭环 AppTouch 单路径 |

根因纪要：
- Overlay：废除 Volume `preferScreenLand=YES`（R8.3.4）→ 与 Toast scene 安全路径对齐。
- 最小化：rootless App RunLoop 定时器不可靠；「运行」成功后 SB 侧 SIGTERM 仅 ZiYan（不杀 lua）。

## 11. R8.3.11 空闲竖屏居中 + .53 暂停链（2026-07-25 19:02）

包：`0.0.92-8-42`。证据：`tmp_shots/PHASE763R8/REGRESS_VOL_MIN/regress_842_dual.txt` · `VERDICT_842.md`。

| 项 | 判定 | 说明 |
|----|------|------|
| 空闲音量竖屏居中 | **PASS** | 双机 `init=0` `rot=0`（故意留下 armed+orient=1 仍强制竖屏） |
| .53 暂停/继续/停止 | **PASS** | RUN→暂停；PAUSE→继续；RESUME→暂停；STOP→运行 + init=0 |
| .166 同链 | **PASS** | 同上 |
| Toast/Volume 分流 | **保持** | Toast `preferScreenLand=NO`；Volume iOS13 identity / iOS15+ rotate |
| tap HID | **仍 OPEN** | 未本轮处理 |

根因纪要：
- 空闲：`volumeMenuOrient` 与 `uiOrient` 解耦，无跑/未暂停强制 0。
- `.53`：无 `/bin/sh` 致 `popen` 失败 → jb-shell + `/bin/ps`；无 cmdline 勿盲信 kill（防 PID 复用粘「暂停」）。

## 12. R8.3.12 HID 锁定（2026-07-25 19:13）

包：`0.0.92-8-43`。证据：`hid_lock_843.txt` · `VERDICT_843.md`。

| 项 | 判定 | 说明 |
|----|------|------|
| .166 同点 HID 稳定 | **PASS** | `land=1` 仍 `portrait_glass`；`0.688,0.793`×10 = EXPECT |
| 路径翻转 | **已消除** | 不再出现 identity HID |
| 人手游戏点色 | **待签** | 建议用户确认视觉后再开长稳 |

根因：AppTouch/SB 随窗口横竖切换 HID 路径。修复：数字化仪永远 `MapLogicToNorm`。

## 13. SECURITY_AI（串行2）· 2026-07-26

| 包 | 要点 | 手测 |
|----|------|------|
| 8-54～8-66 | 曾用 rename/hook afc2d → 爱思错误13 / 转圈 / afc2d 崩溃 | FAIL |
| 8-67 | FsCloak 零注入；图标 SB Hook 仍弱 | 部分 |
| 8-68 | 桌面 App 改名隐藏 + 指纹 Alert Window；AFC 不碰 | **A–D PASS**（用户） |
| **8-69** | Defense **去掉写死游戏包名**；Hook 对齐 Shadow essential；仍不碰 AFC | **待复测** |

学习结论：
- FlyJB/Shadow/Liberty/tsProtector/KernBypass ≠ 桌面隐藏；桌面对标 Libhide 改名思路。
- 游戏不能像爱思走 AFC；防游戏靠进程内 Hook（`ZiYanDefense`）。
- Filter：仅 `com.apple.UIKit` + `com.ziyan.ziyan`（见 `ZiYanDefense.plist`）。
- 说明文档：`子砚工程防御/项目防御说明.txt`。

总判定：门禁仍 **不通过**，待 8-69 SECURITY_AI 复测签核。

## 14. 锁定上下文同步 · 分工2 Wave1–3 · 包 8-83（2026-07-26 21:50）

**性质**：状态锁定归档（非新回归审计）。权威快照：`GPT_PROJECT_STATE.txt` · `已正常功能参考.txt`。

| 项 | 状态 |
|----|------|
| 真机包 | **0.0.92-8-83** signed 双机 |
| Engine / Modules | **2.23.0** / **1.12.0** |
| TS mirror | **implemented=144**/476 |
| 手册 | `子砚触控函数说明.html` 已同步 Wave2+3 + Engine 标头 |
| 门禁 | **不通过**（长稳/人手未全签） |

### 硬锁（禁止擅自改）

| 标记 | 锚点 | 要点 |
|------|------|------|
| LOCK_VOLUME_OVERLAY | 8-42 | 空闲竖屏居中；运行暂停链 |
| Toast preferScreenLand=NO | **8-80** | 禁止再改 Toast 主路径 |
| LOCK_FINDCOLOR | 内核语义 | 匹配算法禁改；**8-82/8-85** 仅脉冲/TTL/峰值释压已合入 |
| LOCK_TOUCH_BASE | 8-46 | HID 永远 MapLogicToNorm；ALLOW 已用尽 |
| LOCK_ICON_HIDE | **8-81** | 仅 `.ziyan_app_session` 粘性；fscloakd v881 |

### 分工2

| Wave | 内容 | implemented |
|------|------|-------------|
| 1 | String/Clipboard/Timer/Dialog + 扩展 | ~98 |
| 2 | HTTP/FTP/JSON/findFile/appBundlePath；cloud 诚实 unsupported | 131 |
| 3 | P2 Device 13 API + `pollDeviceControl`；connectToWifi=`no_hotspot_api` | **144** |
| 4 | **未启** | — |

### SB / 图标近况（摘要）

- `.53` 慢性 ~12min `sb_up` ↔ hiRes keep ~11MP → **8-82** 释压；短窗脚本跑未见新自发重启（长稳待观察）。
- 图标：8-78 script_session 乱动已由 **8-81** 撤回；桌面改名隐藏保留。
- Toast：8-79 误改已 **8-80** 回退；`.166` 横屏 Toast 用户确认恢复。

### 约束

- Desktop `ios7.lua` / `ios8p.lua` **禁止改内容**；勿自动 `menu_run` / 覆盖脚本。
- Wave4 / 新锁定例外须用户明示 + 变更申请模板。
- 证据：`tmp_shots/PHASE763R8/DIVISION2_WAVE3.md` · `SB_EXTRACT_20260726_2104_DUAL/` · `HTML_HANDBOOK_R84.md`

**总判定维持：门禁不通过。**

## 15. Division2 Wave4 ship · 包 8-84（2026-07-26 22:08）

**性质**：分工2 Wave4 交付 + 锁定快照刷新（非新回归审计）。权威：`GPT_PROJECT_STATE.txt`。

| 项 | 状态 |
|----|------|
| 真机包 | **0.0.92-8-84** signed 双机（.166 arm / .53 arm64） |
| Engine / Modules | **2.24.0** / **1.13.0** |
| TS mirror | **implemented=169**/476（+25 vs Wave3 144） |
| 手册 | `子砚触控函数说明.html` 含 **Engine 2.24.0 / Modules 1.13.0** |
| SB pid（部署后） | .166 **94513** · .53 **13420** |
| 门禁 | **不通过** |

### Wave4 范围与诚实限制

| 面 | 实现 | 限制 |
|----|------|------|
| Thread.* | `Zy.Thread` coroutine | **协作式**非 OS 真线程；无 yield 会死循环饿死 |
| Widget.* | OCR + Touch | **非 Accessibility**；`isAccessibilityOn` 诚实 false |
| ftp.init/+ | curl FTP | 依赖 curl；凭据可进进程列表 |
| zip/unzip | 系统 zip CLI | 大包勿 tight-loop |
| http.get / getNetworkIP | 别名到已有后端 | optional 计入 169 |

### 硬锁（未改）

VOLUME(8-42) · Toast preferScreenLand=NO(8-80) · FINDCOLOR(+8-82) · TOUCH(8-46) · ICON(8-81)

### 约束

- Desktop `ios7.lua` / `ios8p.lua` **未改内容**；未主动 menu_run（SB 后若脚本自恢复属引擎既有行为）
- 证据：`tmp_shots/PHASE763R8/DIVISION2_WAVE4.md` · `HTML_HANDBOOK_R84.md`

**总判定维持：门禁不通过。**

## 16. LOOP_ROUND1 · 8-85 SB 脉冲加固（2026-07-26 ~22:35）

**性质**：阶段循环修复专项 · SB 稳定主线（非 Wave）。权威：`GPT_PROJECT_STATE.txt`。

| 项 | 状态 |
|----|------|
| control / 真机 | **0.0.92-8-85** signed 双机 |
| ROUND | `sb_incidents/LOOP_ROUND1_20260726_2216/` |
| 8-84 窗判定 | **RESTART_DETECTED**（.166 ~22:29 自发 sb_up；.53 未重启） |
| 8-85 短窗 | **STABLE_20MIN**（22:48–23:08；SB 未变；.53 mem_warn + 60s_hiRes_abs 生效） |
| gate | pid **61752** · start **22:43:19** · 8h 时钟续跑 |
| 门禁 | **不通过**（须连续 8h 双机无 sb_up） |

### 8-85 变更（仅 ScreenBridge 脉冲/缓存 · 避四大硬锁）

1. `UIApplicationDidReceiveMemoryWarningNotification` → keepScreen=0 + `clearCachedPixelsForce` + throttle + lifecycle `mem_warn_clear`
2. hiRes 绝对 keep 释放 **90s→60s**（idleFind 15s；lifecycle `60s_hiRes_abs`）
3. `CGContextDrawImage` 后 `img=nil` 降 UIImage 叠峰

### 根因与检索摘要

- `.53` ~11MP keep → 静默 jetsam/回收（无当日 SB `.ips`）
- 开源参考：overb0ard/jetsamctl(MIT·勿先抬限额)、XNU memorystatus、ScreenMirror hiRes OOM 笔记
- 详见 `STEP2_ROOTCAUSE_SEARCH.md`

### 硬锁（未改）

VOLUME(8-42) · Toast preferScreenLand=NO(8-80) · FINDCOLOR(+8-82/8-85 脉冲) · TOUCH(8-46) · ICON(8-81)

**总判定维持：门禁不通过。**

## 17. LOOP_ROUND2 · 8-86 学架构不抄实现（2026-07-27 ~01:05）

**性质**：SB 稳定主线 · 触动架构思想自研落地（非私有 API）。权威：`GPT_PROJECT_STATE.txt`。

| 项 | 状态 |
|----|------|
| 包 / 真机 | **0.0.92-8-86** signed 双机 |
| ROUND | `sb_incidents/LOOP_ROUND2_20260727_0103/` |
| SB / lua | .166 48923+51712 · .53 56158+56498（color_perf 上涨） |
| gate | pid **93066** · start **01:12:26** |
| 前序 | 8-85 后 .53 仍 4× 自发 sb_up；.166 脚本曾挂死 |
| 门禁 | **不通过** |

### 8-86 变更（脉冲/缓存/运维 · 避硬锁）

1. hiRes 绝对 keep **30s** + idleFind 10s；释帧后 throttle  
2. 废除 hiRes `dataWithData` 二次全帧拷贝（单缓冲）  
3. 缓冲/预清阈值 **4MB**；mem_warn lifecycle **20s 冷却**  
4. `color_perf` 卡住 120s → `.ziyan_lua_hung`  
5. `gate_8h_tick.sh`：心跳挂死重拉 + SB 重启后 revive + preempt≥6MP  

### 架构对照（思想）

| TS 观察 | Zy 本轮 |
|---------|---------|
| TSDaemon 隔离重活 | 仍在 SB；中长期 Daemon 化见 ROUND2_PLAN |
| 脚本可死可拉 | gate revive + hung 旗 |
| 缓存可丢 | keep 30s / 单缓冲 |

**总判定维持：门禁不通过。**

## 18. 0.0.92-8-87 ScriptHub 启用（2026-07-27 ~02:50）

| 项 | 状态 |
|----|------|
| 真机包 | **0.0.92-8-87** signed 双机 |
| ScriptHub | launchctl OK（.166 56023 / .53 49098）；intent 已写 |
| 自愈 | kill lua → ≤5s 拉起；color_perf PASS |
| SB | .166 **56103** · .53 **49156** |
| gate | pid **24996** · start **02:46:34** · pre887 已归档 |
| 门禁 | **不通过**（须满 8h） |

硬锁未改。证据：`STEP_887_DEPLOY.md`。

**总判定维持：门禁不通过。**


---

## §16 · R8.4.1 自动生成脚本 / 脱壳（2026-07-27）

**包**：`0.0.92-8-105`  
**污染面评估**：仅 `objc/app/*` + `lua/ziyan_engine/{game,learning}.lua` + sidecar；**未触** ScreenBridge 匹配核 / Toast preferScreenLand / AppTouch HID / IconShield。

| 回归点 | 判定 | 说明 |
|--------|------|------|
| LOCK_* 四硬锁 | PASS | 源码未改硬锁文件；抽检记录见 .autotest_last.json |
| 作者脚本覆盖 | PASS | sanitize 禁止 ios7/ios8p/_zy_auto |
| SB 整包 Mach-O | PASS | 仅 64KB 分片字符串抽样 |
| 单机写死坐标 | PASS | res_profile + 逻辑坐标状态表 |

**回滚**：`tmp_shots/PHASE763R8/BACKUP_20260727_2113_scriptgen_dump_r841/files/` → 覆盖对应源文件后 `make package`；或 dpkg 回退 8-104。
