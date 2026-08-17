# 子砚 ROADMAP · Z 路线图（唯一门禁真值源）

> 本文取代 `COPY_TS_REFORM_PLAN.md` / `FIVE_PHONE_SURPASS_PLAN.md` / `CPU_MEM_REFORM_PLAN.md`
> 以及历史 `G0` / `G1–G6` / `H1–H8` / `刀1–刀6` / `M-A~M-F` / `E1–E4` / `总门禁` / `7.6.x-R*`
> 全部编号。旧文档已迁入 `DOCS/_superseded_plans/`，仅作历史查阅，**不得再作为排期或判据依据**。

最后更新：2026-08-15（CLOCK_SKEW：工作区/设备常显示 2026-08-16，不是额外进度日）

---

## 0. 目标

综合性能完全超越触动精灵，两个硬指标：

1. **SpringBoard 稳定性** —— 长跑无自发 SB / backboardd 重启环
2. **业务脚本执行效率** —— 找色 / 点击 / 圈速 / 跟手优于同语义触动脚本

未满足 Z2 全绿前，**禁止任何「超越触动」表述**。

---

## 1. 阶段模型

```
Z0 基线校准  →  Z1 对齐  →  Z2-30M 长稳  →  Z3 超越
   触动真值       不劣于触动       30min        优于触动
```

| 阶段 | 门禁 | 含义 |
|---|---|---|
| **Z0** | `Z0-GIT` `Z0-TS` `Z0-METRIC` | 回滚锚点、触动同协议真值、度量口径正确 |
| **Z1** | `Z1-MEM` `Z1-VIS` `Z1-TOUCH` `Z1-ASSET` | 四机在同协议下不劣于触动 |
| **Z2** | `Z2-30M` | 四机 30 分钟长稳，无 SB 重启环 |
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

**实测结果**（`tools/zy_rss_slope_analyze.py` 统一重算）：

| 观察机 | 窗口 | median/100s | **OLS/100s** | 摆幅 |
|---|---|---|---|---|
| `.171` 找色长跑 | **1235s** | +0.0 | **−1.6** | 3184 KB |
| `.149` 旁证 | 1255s | −255.3 | **−370.4** | 6064 KB |
| `.171` 短轮 | 296s | +99.4 | +141.2 | 3168 KB |

出处：`tmp_shots/TS_OBS/20260807_030815/TS_RSS_SLOPE.md`（长窗口，权威）
与 `tmp_shots/TS_OBS/20260807_022020/`（短轮，已判为噪声）。

**结论：触动 TSDaemon 的 RSS 在长窗口上是平的**（`.171` 20.6min 窗口
`base = end = 33408 KB`，OLS −1.6）。5min 轮测出的 +176KB 不是趋势，
是周期约 60s、摆幅约 3.2MB 的锯齿相位噪声。

由此确立三条：

1. **长窗口（≥20min）才是有效判据**，目标 ≈0 KB/100s，与触动持平。
2. **5min 窗口不足以判内存趋势**，触动自己在该窗口都测出 +141，只能当冒烟。
3. **约 3MB 锯齿摆幅是正常行为**，子砚与触动同量级，不得当缺陷追。

### Z0-METRIC · 度量口径

两条口径要求：

1. 斜率判据必须按 `KB/100s`，不得用整窗差值直接比预算
   （否则 `ZY_E4_MIN=5` 与 `=30` 严格程度差 6 倍）。
2. 首/末窗口必须足够宽以覆盖锯齿（现为 15 点约 30s），且**斜率结论以
   `tools/zy_rss_slope_analyze.py` 的 OLS 为准**，设备端中位数法只作现场快速判读。

### Z1-MEM · 内存

工具：`ZY_E4_MIN=5 bash tools/zy_e4_promo_gate.sh 101 53`

| 判据 | 阈值 | 出处 |
|---|---|---|
| `fc_rss_slope_per100` rootful | **≤120 KB/100s** | 现场快判用；短窗口噪声大，**不作 FAIL 唯一依据** |
| `fc_rss_slope_per100` rootless `.53` | **≤240 KB/100s** | 同上 |
| **OLS 斜率（≥30min 窗口）** | **≈0，不劣于触动** | `.171` 长窗口实测 −1.6 KB/100s |
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

### Z2-30M · 长稳

`ZY_E4_MIN=30` 四机全绿，`SB_CHG=0` 且无重启环。三小时长稳不再是当前门禁。

### Z3 · 超越

需同时具备：四机 VERDICT + `.149/.171` 同窗对照 + Z2 全绿。

---

## 4. 当前状态

| 门禁 | 状态 | 证据 |
|---|---|---|
| `Z0-GIT` | **绿** | 5 个主题 commit，工作树干净 |
| `Z0-TS` | **绿** | `tmp_shots/TS_OBS/20260807_022020/TS_RSS_SLOPE.md` |
| `Z0-METRIC` | **绿** | `zy_e4_promo_gate.sh` 已归一化并绑定出处 |
| `Z1-MEM` | **绿（本包四机 30min）** | 配对包 rootful `debug-10-24-5` / rootless `debug-10-24-6`。30min `tmp_shots/Z1_MEM_C98_20260815_134508/REPORT.md` 四机 PASS：FC_N=1 SB_CHG=0 embed_find>0 color_req=0。OLS/100s：`.53 -20.7` `.101 -7.1` `.112 -11.5` `.166 -2.7`。5min 通道检 `tmp_shots/Z1_MEM_C98_20260815_133703`。旧 C98 三机报告保留不删。不是 Z2。禁宣称超越 |
| `Z1-VIS` | **绿（本包四机 RUN1）** | 同一次 `zy_dual_package.sh`：rootful `debug-10-24-5`、rootless `debug-10-24-6`。`RUN1_GATE_20260815_121431_all_72725` 四机 `TYPED=BUSINESS_PASS`，设备端 final 可回收。ios7 `(1010,294)` → `com.xztl.ios`；ios8p `(2011,284)` → `com.ljzbbadao.game`。`FC_N=1` `SB_CHG=0` 停后 ACTIVE=0。禁宣称超越 |
| `Z1-TOUCH` | **绿（本包四机）** | `tmp_shots/Z1_TOUCH_20260815_144118`。rootful `(1080,320)`→Preferences；rootless `(2011,284)`→`com.ljzbbadao.game`。`FC_N=1` `ACTIVE=0` `KEEP=0` `SB_CHG=0`。设备端 final 可回收。未改找色坐标。禁宣称超越 |
| `Z1-ASSET` | **绿（本包四机找图）** | `tmp_shots/Z1_ASSET_20260815_144305`。keep+shm 自证：rootful `454,256`；rootless `884,496`。`via_color_req_find=0` `FC_N=1`。lease 独立文件本包不存在（记 NOTE，未改 FrameLease）。禁宣称超越 |
| `Z1-OCR` | **结论明确：准确率未齐（非稳定）** | 复验 `tmp_shots/Z1_OCR_20260815_155443_16691`；旧跑 `144523`/`144555`/`151708` 保留。中文/空结果可用；数字四机同错 `它？方还j5`；多行不稳。`.53` getText 超时。热更 ocr 二进制 iOS13 被杀已回滚。不得把门禁 VERDICT=PASS 写成 OCR 稳定。未阻断 find/touch |
| `Z1-NET` | **绿（Lua Ftp* 四机）** | 复验 `tmp_shots/Z1_NET_20260815_153933`。旧 curl 夹具 `144633` 保留。`.53` via=curl；rootful via=python_ftplib。upload/download/read/delete 四机通。错误账号/超时/断网按预期失败。rootful `FtpIsUpdate` SIZE 未齐（记 NOTE，未伪造）。本地 `FC_N=1`。热更 `py_cv.lua` 去掉 embed `io.popen` |
| `Z2-10M-PRELIM` | **四机 PASS（非最终 Z2）** | `tmp_shots/Z1_MEM_C98_20260815_144705`。`FC_N=1` `SB_CHG=0` embed>0 color_req=0。OLS 不上升。**不得写成最终 Z2 PASS**。已有 30min MEM 报告未删 |
| `Z2-30M` | **绿（debug-10-25 四机正式 30min）** | `tmp_shots/P2_30M_C98_20260815_212152` 四机 30/30 PASS，SB/BB PID 不变，`via_color_req_find=0`，无空 open_app→ZiYan。设备 final 可回收。上次场景 FAIL `203524` 与更旧 `171114`/`161226`/`160605` 保留。debug-10-24 `175901` 仍有效但不能替代 10-25。未打最终包。禁宣称超越 |
| `OPEN_APP_SKIP` | **绿（debug-10-25 四机定向）** | 空/空白 `.ziyan_open_app` 已改为 skip，不再默认 `com.ziyan.ziyan`。任意明确合法 Bundle ID 按原逻辑打开。测试游戏只是夹具。证据 `tmp_shots/OPEN_APP_SKIP_20260815_193315`（`.166` 同包 `192312`）。配对包 rootful `debug-10-25-1` / rootless `debug-10-25-2`。尚未完成最终发布包人工验收。禁宣称完全兼容或超越触动 |
| `Z3-*` | **禁止宣称** | `.149/.171` 本窗密钥可达，只读。不可达时标 `OBSERVER_UNREACHABLE`，不得写成 ZiYan FAIL。`usb_play/lan_play=ERR` 是已停 forever 夹具 |
| `AGENT_MVP` | **PARTIAL，未四机 PASS** | 证据 `tmp_shots/AGENT_MVP_4PHONE_20260815_1/VERDICT.md`。.112 续修 `tmp_shots/SB_RECOVERY_112_20260815/VERDICT.md`：10-31 约每 275s 换 PID；10-32-2 一次 sbreload 后 360s 稳定。现 .101/.112/.166=10-32-2，.53 仍 10-31-2。BB 合帧仍 deferred。禁宣称四机完成或超越 |

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
