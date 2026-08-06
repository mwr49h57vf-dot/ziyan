# ZiYan 设备规则（DEVICE_RULES）

**生效日期**：2026-08-07
**阶段**：Z1-MEM（包锚点 `0.0.92-8-161-205-A`）
**权威同步**：排期与门禁真值以 **`ROADMAP.md`（Z0–Z3）** 为准。
本文只保留设备角色与坐标/朝向管线规则；历史 `7.6.x-R*` / `总门禁` 编号已作废，
过时快照见 `DOCS/_superseded_plans/`。

> **第一类 `.149`/`.171` 只读**；第二类 `.53/.101/.112/.166` 双方案同构，禁止单机硬编码特判。
> **锁定**：音量 / 找色 / 点击（见已正常功能参考.txt）。
> **当前门禁状态见 `ROADMAP.md` 第 4 节**，不在本文重复维护。

> **架构铁律（2026-07-31 起写死）**  
> 1）兼容 **7/7P/8/8P × iOS 13～16.7.16**（后续扩展待告知） 
> 2）**.149/.171** 只读触动 + **日志随时可拉**对照（`tmp_shots/TS_OBS/`）  
> 3）**.53/.101/.112/.166 只做 ZiYan 项目测试**  
> 4）综合性能须**完全超越触动**（尤其 **SB 稳定性**、**业务执行效率**）  
> 5）**业务 API 可照搬照抄触动**；**CPU 越低越好**；**内存释放对照触动**（见下表 + `.cursor/rules/ziyan-api-cpu-mem.mdc`）  
> 另：支柱（模仿+可抄触动+落点自有树+corpus+CPU/内存）。Agent：`surpass-ts-four-pillar.mdc` · `ziyan-api-cpu-mem.mdc` · `ARCHITECTURE.md` · `ROADMAP.md`。  
> 手动 `menu_run` 与助手路径同构（EnsureFramecapAlive + 目标 App 前台）。
---

## 总则

| 规则 | 说明 |
|------|------|
| **自测前清机（铁律）** | 每次四机自测前必须：停脚本、杀业务/游戏进程、收僵尸、释帧压内存、保证 `FC_N=1`。脚本：`bash tools/zy_pretest_clean_4phone.sh`。不清不测。 |
| 机型矩阵 | 必须支持越狱 iPhone **7 / 7P / 8 / 8P**，系统 **iOS 13～16.7.16**；禁止单机死坐标；后续扩展待告知 |
| 业务 API | **允许照搬照抄触动** Lua 业务 API（名/参/语义/脚本）；实现落 ZiYan 自有树，禁链接触动运行时 |
| CPU | **全项目占用越低越好**；禁 toast/force/relay/空转风暴 |
| 内存释放 | **对照触动**：缓冲/Toast/截帧用完即释；停脚本清 keep；长跑不弱于 `.171` |
| 四支柱+ | 模仿 TS 体感 · 照搬业务 API · ZiYan 自研实现 · corpus · CPU↓/内存对照 |
| 分类强制 | 所有真机操作必须先判定设备类别 |
| TS 日志 | `.149`/`.171` 触动运行日志/状态须可记录；需要时随时拉取比较 |
| 测试机专用 | `.53`/`.101`/`.112`/`.166` **只做本项目测试**；唯一部署与验收结论来源 |
| 超越目标 | 综合性能完全超越触动，尤其 SB 稳定性与业务脚本执行效率 |
| 结论隔离 | TouchSprite 观察结果 ≠ 子砚功能验证结论 |
| 禁止混用 | 不得在观察设备上部署/验收子砚；不得把观察设备冒烟写成子砚 PASS |
| 双测同方案 | `.166` 与 `.53` 必须执行**完全相同**测试方案（禁止单设备特判代码） |
| 坐标 | 禁止固定物理像素；管道 Device→Screen→Coordinate→Vision→Touch→Verify |
| 冷启动 | 脚本进程与 framecap（合帧守护）必须同时存活；IPC 真路径在 `$JB/usr/lib/ziyan/var` |

---

## 第一类：TouchSprite 学习观察设备

### 192.168.31.149

| 项 | 内容 |
|----|------|
| 设备 IP | 192.168.31.149 |
| 设备角色 | TouchSprite 学习观察设备 |
| 允许用途 | 1. 观察真实 TouchSprite IDE 运行方式<br>2. 学习 Lua 脚本结构<br>3. 分析函数调用方式<br>4. 分析运行流程<br>5. 分析音量键触发机制<br>6. 分析日志显示方式<br>7. **记录/拉取触动运行日志**，需要时与四机 ZiYan 对照（落盘 `tmp_shots/TS_OBS/`） |
| 禁止用途 | - 不修改原有脚本<br>- 不部署子砚代码<br>- 不作为子砚测试设备<br>- 不产生子砚功能验证结论 |
| 测试记录 | 历史（7.4/7.5）曾误作子砚测试机部署/冒烟 — **自 7.6.1-A 起作废为子砚验收依据**，仅可作观察对照。后续仅允许 TS 架构观察与日志拉取。 |

### 192.168.31.171

| 项 | 内容 |
|----|------|
| 设备 IP | 192.168.31.171 |
| 设备角色 | TouchSprite 学习观察设备 |
| 允许用途 | 同 .149（含 **随时拉取 TSDaemon/脚本/系统侧触动运行日志** 做对照） |
| 禁止用途 | 同 .149（不改 TS 脚本、不部署子砚、不作子砚测试、不产生子砚结论） |
| 测试记录 | 历史曾装 ZiYan 包做 7.4/7.5 冒烟 — **自 7.6.1-A 起不作子砚验收依据**。后续仅允许 TS 观察与日志拉取。 |

---

## 第二类：子砚自动化测试设备

### 192.168.31.53（兼容基准）

| 项 | 内容 |
|----|------|
| 设备 IP | 192.168.31.53 |
| 机型 | **iPhone 8 Plus**（ProductType `iPhone10,2`） |
| 系统 | iOS **16.7.16** |
| CPU | Apple A11 · ncpu≈6 |
| 屏幕 | native 1242×2208 @3 · logic(init1) 2208×1242 · DPI≈460 |
| 环境 | rootless（`/var/jb/usr/lib/ziyan`） |
| 设备角色 | **子砚兼容基准测试设备** |
| 允许用途 | 1. 测试子砚自动化引擎<br>2. 测试 Script SDK<br>3. 测试 AI 脚本生成<br>4. 测试 StateMachine<br>5. 测试函数调用<br>6. **双机兼容同方案验收（与 .166）** |
| 禁止用途 | 不得用于拷贝/反编译 TouchSprite；进角/登录 PASS 须有本机证据；禁止为本机写特殊坐标分支 |
| 测试记录 | 7.5+ 冒烟；**7.6.2-R3** 双机兼容 probe + ios8p.lua |

### 192.168.31.166

| 项 | 内容 |
|----|------|
| 设备 IP | 192.168.31.166 |
| 机型 | **iPhone 7**（ProductType `iPhone9,3`） |
| 系统 | iOS **13.1.2** |
| CPU | Apple A10 · ncpu=2 |
| 屏幕 | native 640×1136 @2 · logic(init1) 1136×640 · DPI≈326 |
| 环境 | rootful（`/usr/lib/ziyan`） |
| 设备角色 | 子砚自动化测试设备（兼容对照） |
| 允许用途 | 同第二类；**双机兼容同方案验收（与 .53）** |
| 禁止用途 | 同 .53；无凭证不得宣称进角 PASS；禁止为本机写特殊坐标分支 |
| 测试记录 | 7.5+ 冒烟；**7.6.2-R3** 双机兼容 probe + ios7.lua |

### 192.168.31.101 / 192.168.31.112（功能机 · 须跑项目）

| 项 | 内容 |
|----|------|
| 设备 IP | 192.168.31.101 · 192.168.31.112 |
| 环境 | rootful（`/usr/lib/ziyan`） |
| 设备角色 | 子砚功能验证机（与门禁机同包） |
| 允许用途 | 部署同版本包；**运行用户项目 Lua**；回归 keep/find/停止 |
| 禁止用途 | **禁止仅用临时 find 冒烟代替项目验收**；无 Media/ZiYan 脚本时须先 scp 再测 |
| 脚本目录 | `/var/mobile/Media/ZiYan/`（用户项目）；引擎在 `/usr/lib/ziyan` |

---

## 双设备兼容测试规则（7.6.2-R3）

1. 同一测试脚本/同一 probe 在两台各跑一遍
2. 比较 Device / Screen / Coordinate(ratio) / Vision / Touch / Volume
3. 差异只记录为**适配结果**，不得用 if(ip==…) 特判
4. Media/ZiYan 仅用户脚本（`.lua/.py/.c/.oc`）；设备库在 `var/device_db.json`
5. **触控映射（7.6.2-R3.1）**：find 与 tap 共用 init(0/1/2) 逻辑坐标；系统 HID 一律竖屏玻璃 `MapLogicToNorm`（与 find 旋转互逆）；禁止单设备镜像/固定像素补偿
6. **Screen Mirror（7.6.2-R4）**：Volume/Toast 经 `ZiYanScreenTransform` 跟当前脚本 `uiOrient`；禁止 Volume 硬编码 init(0)。目标：App镜像=Screen=Vision=Coordinate=tap输入=Volume=Toast。
7. **LearningObserver / StabilityAnalyzer**：`.149`/`.171` → `logs/touchsprite_learning/*.jsonl`；测试机稳定性 → `logs/stability/*.jsonl`
8. **架构冻结（7.6.3）**：停止新功能与 Optimization 开发；坐标/朝向/SB 问题以 `SYSTEM_REGRESSION_REPORT.md` 为准做回滚分析；学习设备行为见 `logs/device_behavior/`

---

## 验证 App（仅第二类设备）

- `com.ljzbbadao.game`
- `com.xztl.ios`

凭证未通时：只记相位/失败原因，不宣称进角 PASS。

---

## 变更日志

| 日期 | 说明 |
|------|------|
| 2026-07-22 | 7.6.1-A：.149/.171 划为 TS 观察；.53/.166 划为子砚测试；.53 定为兼容基准 |
| 2026-07-22 | 7.6.2-R3：明确 .166=iPhone7 / .53=iPhone8Plus；双机同方案兼容规则 |
| 2026-07-23 | 7.6.2-R3.3：Screen Mirror 诊断；Volume init(0) 分裂记录；LearningObserver 只读日志 |
| 2026-07-23 | 7.6.2-R4：ScreenTransform；Volume/Toast 统一；StabilityAnalyzer；双机 menu init=1 验证 |
| 2026-07-23 | 7.6.3：架构冻结；SYSTEM_REGRESSION_REPORT；DEVICE_BEHAVIOR_LOG；禁止新功能 |
| 2026-07-23 | 7.6.3 恢复：rawLand_identity Overlay；AppTouch 横屏 identity；双机角点 ok；等待确认 |
| 2026-07-23 | 7.6.3-R2：DeviceDifference / ScreenMirror / SBStability 诊断；jetsam=SB highwater；.53 非 1080p 错绑 |
| 2026-07-23 | 7.6.3-R3：通用降载 capture 丢弃+找色缓存；会话 Overlay；CloseApp 释缓冲；ScreenWake |
| 2026-07-23 | 7.6.3-R3 门禁：部分通过；设备分类规则不变；关闭程序须杀 App；待人手 30min/2h+Volume |
| 2026-07-23 | 7.6.3-R4.1：Overlay followScreen；CloseApp zombie 收割；front_bid 刷帧；第一类仍只读 |
| 2026-07-23 | 7.6.3-R5：vol_disarmed 关闭后音量归系统；找色邻域回写；第一类仍只读 |
| 2026-07-23 | 7.6.3-R6：Overlay 合成器跟屏；暂停菜单不预冻；继续不退出；第一类仍只读 |
| 2026-07-23 | 7.6.3-R7：Overlay 物理 UIScreen 横优先；scriptSessionActive 存活判定；找色强制重截；解锁=会话 |
| 2026-07-23 | 7.6.3-R8：.53 找色性能（keepScreen 缓存）；Toast 位置统一（safeBottom）；SB 稳定性增强（脉冲间隔+日志轮转）；第一类仍只读 |
| 2026-07-24 | 7.6.3-R8.1：纠正误标 PASS；ToastBridge 禁误清 session；keepScreen IPC 失败仍锁帧；双机短时 keepScreen=1+Toast rawLand；avg 差距与 30min 门禁未过；禁止下一阶段 |
| 2026-07-24 | 7.6.3-R8.3.2：包8-23；HTML全量生成；API46双机PASS；.166 reboot迟到补采；.53软冷启；过夜23:00调度；总门禁仍不通过 |
