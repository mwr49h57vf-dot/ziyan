# 子砚 ROADMAP · Z 路线图（唯一门禁真值源）

> 本文取代 `COPY_TS_REFORM_PLAN.md` / `FIVE_PHONE_SURPASS_PLAN.md` / `CPU_MEM_REFORM_PLAN.md`
> 以及历史 `G0` / `G1–G6` / `H1–H8` / `刀1–刀6` / `M-A~M-F` / `E1–E4` / `总门禁` / `7.6.x-R*`
> 全部编号。旧文档已迁入 `DOCS/_superseded_plans/`，仅作历史查阅，**不得再作为排期或判据依据**。

最后更新：2026-08-07

---

## 0. 目标

综合性能完全超越触动精灵，两个硬指标：

1. **SpringBoard 稳定性** —— 长跑无自发 SB / backboardd 重启环
2. **业务脚本执行效率** —— 找色 / 点击 / 圈速 / 跟手优于同语义触动脚本

未满足 Z2 全绿前，**禁止任何「超越触动」表述**。

---

## 1. 阶段模型

```
Z0 基线校准  →  Z1 对齐  →  Z2 长稳  →  Z3 超越
   触动真值       不劣于触动    30min/3h     优于触动
```

| 阶段 | 门禁 | 含义 |
|---|---|---|
| **Z0** | `Z0-GIT` `Z0-TS` `Z0-METRIC` | 回滚锚点、触动同协议真值、度量口径正确 |
| **Z1** | `Z1-MEM` `Z1-VIS` `Z1-TOUCH` `Z1-ASSET` | 四机在同协议下不劣于触动 |
| **Z2** | `Z2-30M` `Z2-3H` | 四机长稳，无 SB 重启环 |
| **Z3** | `Z3-SB` `Z3-PERF` | 稳定性与效率优于 `.171` |

阶段之间是**硬依赖**：Z0 未完成则 Z1 的阈值无效；Z1 未全绿禁开 Z2；Z2 未全绿禁谈 Z3。

---

## 2. 设备

| IP | 角色 | 用途 |
|---|---|---|
| `.53` | iPhone 8 Plus · rootless · @3x | ZiYan 验收 |
| `.101` `.112` `.166` | iPhone 7 · rootful · @2x | ZiYan 验收 |
| `.149` `.171` | TouchSprite 观察机 | **只读**；`.171` 为找色长跑参考机 |

- PASS 只出在 `.53/.101/.112/.166`；观察机不得部署 ZiYan、不得作为验收结论来源。
- 兼容矩阵：iPhone 7 / 7P / 8 / 8P × iOS 13 ～ **16.7.16**（上限写死，扩展待用户通知）。
- Desktop `ios7.lua` / `ios8p.lua` 仅 scp，**不改内容**。

---

## 3. 门禁定义与阈值

### 阈值纪律

**每个数字必须标注实测出处。无出处的数字不得作为 FAIL 依据。**

历史教训：旧计划把 `TINY ≤64KB/100s`、`RSS ≤0.5MB/100s`、`≤512KB` 当作硬预算，
其中 `≈0 / ≈16KB` 来自 `.171` 的 **100 秒 Find/Home 短协议**，被误当成长跑基线；
而 `512KB` 是发明值，且与「Δ/100s」单位不一致。据此判 FAIL 属于无效判据。

### Z0-GIT · 回滚锚点

工作树必须干净，每个主题独立成 commit，任一刀可单独 `git revert`。

### Z0-TS · 触动同协议真值

工具：`tools/zy_ts_obs_snapshot.sh`（`ZY_TS_MIN=5` 启用定时采样）

采样口径必须与 `tools/zy_e4_promo_gate.sh` 完全一致：
暖机 60s → 5 点中位数为 BASE → 每 2s 采样 → 末 5 点中位数为 END → `DELTA = END − BASE`，
并归一化为 `PER100 = DELTA × 100 / SEC`。

**采样必须按 `-server` 锁定 TSDaemon PID**：TSDaemon 会 fork 出同 argv、RSS 仅 2MB 量级的
短命子进程，按名字 `grep | head -1` 会随机抓到子进程，导致样本在 33408 与 2064 之间跳变。

**实测结果**（`tmp_shots/TS_OBS/20260807_022020/TS_RSS_SLOPE.md`，5min 窗口）：

| 观察机 | RSS BASE→END | DELTA | **PER100** | 重启 |
|---|---|---|---|---|
| `.171`（找色长跑） | 33408 → 33584 KB | +176 KB | **58 KB/100s** | 0 |
| `.149`（非找色，旁证） | 85424 → 85792 KB | +368 KB | **122 KB/100s** | 0 |

**结论：触动自身斜率不为零。**「趋近于零」是伪目标，Z1-MEM 按「不劣于触动」判定。

### Z0-METRIC · 度量口径

`tools/zy_e4_promo_gate.sh` 的斜率判据必须按 `KB/100s`，不得用整窗差值直接比预算
（否则 `ZY_E4_MIN=5` 与 `=30` 严格程度差 6 倍）。

### Z1-MEM · 内存

工具：`ZY_E4_MIN=5 bash tools/zy_e4_promo_gate.sh 101 53`

| 判据 | 阈值 | 出处 |
|---|---|---|
| `fc_rss_slope_per100` rootful | **≤120 KB/100s** | `.171` 实测 58 × 2 容差 |
| `fc_rss_slope_per100` rootless `.53` | **≤240 KB/100s** | 同上，@3x 像素量更大再放宽一倍 |
| `WORKSET` | ≤6 MB | 常驻帧预算 |
| `FC_N_MAX` | =1 | 单宿主 |
| `SB_CHG` | =0 | 无 SB 重启 |
| `KEEP_AFTER_STOP` / `ACTIVE` | =0 | 停脚本必须清干净 |
| `via_color_req_find` | =0 | 热路径必须走 embed |
| `via_embed_find` | >10 | 证明确实在跑业务 |
| `TOAST` | =0 | 无 toast 风暴 |
| `FORCE` | ≤ `MIN×2+5` | 无合帧风暴 |

### Z1-VIS · 视觉命中

工具：`bash tools/zy_run1_script_logic_gate.sh`
四机均须 `TYPED=BUSINESS_PASS`。`VISION_MISS` 与 `TOUCH_SENT_NO_UI_CHANGE` 是不同故障，
**不得用改找色坐标掩盖触控问题**。

### Z1-TOUCH · 触控链

工具：`bash tools/zy_embed_native_hid_gate.sh <tag> <x> <y>`
命中后必须 `kind=tap ok=1` 且 SB 前台发生变化。

### Z1-ASSET · 图文识别

工具：`bash tools/zy_vision_asset_gate.sh 101 53`，配合 `tests/vision_assets/`。

### Z2-30M / Z2-3H · 长稳

`ZY_E4_MIN=30`（后续 180）四机全绿，`SB_CHG=0` 且无重启环。

### Z3 · 超越

需同时具备：四机 VERDICT + `.149/.171` 同窗对照 + Z2 全绿。

---

## 4. 当前状态

| 门禁 | 状态 | 证据 |
|---|---|---|
| `Z0-GIT` | **绿** | 5 个主题 commit，工作树干净 |
| `Z0-TS` | **绿** | `tmp_shots/TS_OBS/20260807_022020/TS_RSS_SLOPE.md` |
| `Z0-METRIC` | **绿** | `zy_e4_promo_gate.sh` 已归一化并绑定出处 |
| `Z1-MEM` | **进行中** | 刀 A/B/C 逐刀验证中 |
| `Z1-VIS` | **红 1/4** | 仅 `.53` PASS；`.112/.166` 待用户更新 Desktop 色点 |
| `Z1-TOUCH` | **红** | `.101` 命中 `(396,195)` 但 `TOUCH_REP_OK=0` |
| `Z1-ASSET` | **红** | `.53` `img=-1,-1`、`FC_N=2` |
| `Z2-30M` / `Z2-3H` | **未跑** | 被 Z1 阻塞 |
| `Z3-*` | **禁止宣称** | — |

已绿并需保持：RF 最小化+方向契约、找色契约 T1–T4、`FC_N=1`、`WORKSET≤6MB`、
`SB_CHG=0`、前台永远跟帧（`lua/ziyan_engine/fg_gate.lua`）。

---

## 5. Z1-MEM 刀序

嫌疑来自 `ziyan_framecap` 长跑堆增长排查：帧缓冲、模板 LRU、keep、日志、
CF/CG/IOSurface 释放路径均已有界，增长来自**回收节拍**而非未释放对象。

| 刀 | 位置 | 问题 |
|---|---|---|
| **A** | `tools/ziyan_framecap/main.m` ServeLoop relief | `hasColor` 在 embed 运行期恒真，`!hasColor` 守卫让整段业务长跑一次都不回收 |
| **B** | `tools/ziyan_framecap/ZiYanLuaEmbed.m` GC | 按 64 次 find 计数触发，脚本节奏变化时兜底间隔漂移 |
| **C** | `ZiYanLuaEmbed.m` 原生入口 | 会话级单 autoreleasepool；`l_get_color` / `l_keep_screen` / `l_touch_*` 无内层池 |

**一刀一验**：每刀单独改、单独打包、单独部署、单独跑 5min E4，记录 `PER100` 变化。
禁止叠改后归因。

---

## 6. 纪律

1. 阈值必须标注实测出处，无出处的数字不得作为 FAIL 依据。
2. 同一症状自研改动 ≥2 轮仍 FAIL → 下一动作强制 `.171` 采证，不得开第三轮纯猜改。
3. 一刀一验，禁止叠改后归因。
4. 观察机 `.149/.171` 只读；PASS 只出在 `.53/.101/.112/.166`。
5. Z2 未全绿前禁止任何「超越触动」表述。
6. 自测前必须 `bash tools/zy_pretest_clean_4phone.sh`，不清不测。
7. 允许抄触动的 API 名/参/语义与找色/合帧/keep/Home 等逻辑算法，实现落 `lua/`/`objc/`；
   仅禁止把触动 dylib / TSDaemon 链进包作运行依赖。

---

## 7. 索引

- 规则：`.cursor/rules/surpass-ts-four-pillar.mdc` · `ziyan-api-cpu-mem.mdc` ·
  `fg-always-vision.mdc` · `ts-observe-before-blind-fix.mdc`
- 架构：`ARCHITECTURE.md` · `STRUCTURE.md` · `DEVICE_RULES.md`
- 证据：`tmp_shots/TS_OBS/`（触动对照）· `tmp_shots/E4_PROMO_*`（资源）·
  `tmp_shots/RUN1_GATE_*`（业务）
- 历史计划（作废）：`DOCS/_superseded_plans/`
