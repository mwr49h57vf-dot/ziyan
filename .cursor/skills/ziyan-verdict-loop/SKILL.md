---
name: ziyan-verdict-loop
description: 为 ZiYan 越狱 iOS 自动化项目执行快速、证据优先的交付闭环。适用于任何 ZiYan 缺陷修复、兼容工作、打包部署、真机测试、API 补齐、守护/framecap/Lua/视觉/触控/Toast 工作、进度交接或 TouchSprite 对照。它选择最小有效下一步，保护四机证据模型，并要求取得可回收的设备端结论后才允许推进项目状态。
---

# ZiYan 证据闭环

执行小范围、可归因的交付闭环；禁止大范围重构或反复依赖人工猜测排障。

## 每次任务开始时

0. 若本回合是 Codex 压缩摘要：停手，按仓库根目录 `AGENTS.md` 与 `.codex/skills/ziyan-compact-handoff/SKILL.md` 执行 `create_thread` 迁出；禁止在压缩对话里继续 `nextAction`。
1. 在仓库根目录执行：`bash .cursor/skills/ziyan-verdict-loop/scripts/preflight.sh`。
2. 按顺序读取：`今日项目进度.txt`、`ROADMAP.md`、`ARCHITECTURE.md`、`完整超越触动精灵方案.txt` 的当前执行章节。
3. 只读取当前症状所需的源码、最新 `VERDICT.md` 与相关 `.149/.171` 只读观察证据。
4. 将 `ROADMAP.md` 视为阶段、门禁和完成宣称的唯一真值源。当前 Z2 为四机 **30 分钟**稳定性；三小时长稳不是门禁。
5. 若预检真机事实与 `今日项目进度.txt` 冲突，记录 `STATE_MISMATCH`，用观察证据更新交接，再改产品代码。

## 每次只选择一个下一步

按以下顺序决策，禁止跳级。

| 观察状态 | 必须执行的下一步 |
|---|---|
| SSH、包、服务、脚本哈希或测试记录不可用 | 修复或验证测试通道。记录 `TRANSPORT_BLOCKED` 或 `INVALID_RUN`；不得改产品代码。 |
| 一次运行没有设备端最终结果 | 回收设备端结果或干净停止测试。它既不是 PASS，也不是产品 FAIL。 |
| 有效门禁出现一个已分类失败 | 只改一个归属层：采集、lease/前台、匹配、触控、生命周期或 API 契约。 |
| 同一已分类症状经两次 ZiYan 修改仍存在 | 只读观察 `.149/.171` 并写明行为差异，之后才可进行第三次修改。 |
| 当前所有 Z1 门禁为绿 | 运行四机 30 分钟门禁，不做猜测性优化。 |
| API 为 partial/planned | 先补契约测试；再实现一个 API 家族，并在 rootful 与 rootless 各至少一台验证。 |

## 不可违背的项目模型

- `.149/.171` 仅为 TouchSprite 观察机。不得部署 ZiYan，也不得用于 ZiYan PASS。
- `.53/.101/.112/.166` 是唯一允许部署 ZiYan 与产出结论的设备。
- 保持单一 `ziyan_framecap`、`FC_N=1`、Lua/embed 热路径和固定 `init` 坐标语义。
- 不得因 safe area、SpringBoard 或前台 Bundle 改变而重写脚本找色/触控坐标。
- 不得让常规 find/getColor/keepScreen 退回 HTTP、同步截图或 `color_req` 热路径。
- 不得新增竞争型 supervisor、通过杀 SpringBoard 掩盖缺陷，或修改桌面 `ios7.lua` / `ios8p.lua`。
- 网络、FTP、云 OCR、更新、账号等可选功能不得进入本地 find/touch 生命周期；应作为隔离 API 测试。

## 执行一次交付闭环

1. 写出一句话假设、归属层、回滚点和预期指标。
2. 只做一个内聚且可回滚的改动；不得混合 UI、坐标、内存和生命周期修改。
3. 构建并验证包的 install name。仅当任务明确授权部署，或已接受的测试计划要求部署时，才部署。
4. 仅用现有预清机工具清理指定 ZiYan 测试机；永远不得清理 `.149/.171`。
5. 运行最小匹配门禁。设备端结果必须含 `run_id`、包/版本、脚本 SHA、会话状态、最终类别、`FC_N`、`SB_CHG` 与停止清理状态。
6. 使用 `references/evidence-contract.md` 的分类。不得将传输丢失或输出缺失写成 `VISION_MISS`。
7. 用事实结果与证据路径更新 `今日项目进度.txt`。仅当有效 VERDICT 支持时，才更新 `ROADMAP.md` 门禁状态。

## 快速路径

- **兼容/rootless：**先验证 `.53` 的包、路径、服务和 IPC；rootless 部署链有效前，不得改视觉算法。
- **视觉：**先检查帧新鲜度及 `front_bid`/`shm_bid`/lease，再调整 fuzzy、ROI、点序或坐标。
- **触控：**区分视觉命中与 `TOUCH_SENT_NO_UI_CHANGE`；不得调整 find 去掩盖触控缺陷。
- **久跑/卡顿：**先检查 `frame_seq`、`frame_age_ms`、`lock_wait_ms`、`pixel_match_ms`、GC/autoreleasepool、workset、停止残留，再改节流。
- **API：**先测 L0 核心自动化，再测 L1 应用/图像/OCR/文件，最后测试隔离的 L2 网络/FTP/云功能。

## 证据标准

创建新门禁或 VERDICT 前，先读取 `references/evidence-contract.md`。每次运行在 `tmp_shots/<GATE>_<timestamp>/` 建立独立证据目录；保留原始日志并写简洁的 `VERDICT.md`。

## 闭环结束条件

仅在取得有效设备端 VERDICT、干净停止状态并完成进度交接后，才结束一次闭环。在 `ROADMAP.md` 要求的四机门禁全绿前，不得宣称完全兼容或超越。
