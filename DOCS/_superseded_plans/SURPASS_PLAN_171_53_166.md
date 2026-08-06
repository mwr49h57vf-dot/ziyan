# 超越触动 · 修订计划（171 + 53 + 166 + 101 + 112）

> **当前权威排期**：[`FIVE_PHONE_SURPASS_PLAN.md`](./FIVE_PHONE_SURPASS_PLAN.md)（按 Find/Home 五机证据重排）  
> 证据总表：`tmp_shots/FIND_HOME_MEM_COMPARE_5PHONE.md`

**依据**：
- `.171` 触动 `main.lua` → `tmp_shots/TS171_OBS_20260802_033901/` + Find/Home `TS171_FIND_MEM_*`
- `.53` / `.166` / `.101` / `.112` Find/Home 采样（见五机计划 §6）

原则：**先对齐触动「内存锁死 + 热帧常驻 + 零风暴」再谈超越**；可抄触动逻辑进自有树；兼容 7/7P/8/8P × iOS 13～16.7.16；未过 G0 不宣称超越。

### Find/Home 五机结论（摘要）

| 机 | TINY Δ | RSS Δ | 备注 |
|----|--------|-------|------|
| TS .171 | ≈0 | ≈16KB | IOSurface 5744KB 常驻 |
| .112 | **+1040KB** | +896KB | home_force + carender_black；wall 尖峰 233ms |
| .166 | +1.4MB | +4.2MB | 同 rootful 模式 |
| .101 | +224KB | +0.7MB | FC 曾死；shm_bid 滞后 |
| .53 | +656KB | **+11MB** | @3 shm 最大；find 秒级 |

**下一刀**：**H1+H2**（见 `FIVE_PHONE_SURPASS_PLAN.md`）——节流 `home_force_recap`；黑帧退避复用旧帧；先验 `.112`。

---

## 0. 三机对照表（同节奏：窄 ROI find + mSleep500 + 乱动/切前台）

| 指标 | .171 触动 | .166 子砚(ios7/@2) | .53 子砚(ios8p/@3) | 结论 |
|------|-----------|--------------------|--------------------|------|
| 宿主 | TSDaemon 单进程 | framecap embed | framecap embed | 架构已对齐 |
| 帧存放 | **IOSurface 5.76MB 进程内** | **文件 shm 2.77MB** | **文件 shm 10.46MB** | 子砚无 IOSurface；@3 过大 |
| phys_footprint | ≈14–15MB 锁死 | **8.0MB 锁死** | 8.5→9.1MB **缓爬** | .166 稳态已够；.53 要治爬 |
| RSS Δ/100s | **304 KB** | **16 KB** | **496 KB** | .166 优；.53 贴边 |
| MALLOC_TINY | ≈2.1MB | **7.1MB 但不爬** | **缓爬 +39 pages/100s** | .166 基线偏肥；.53 泄漏/碎片 |
| CPU avg/max | **10.5% / 27%** | **2.85% / 7.6%** | **5.6% / 14.8%** | 子砚 CPU 已不差于触动 |
| find 脉冲 | ~1+/s | **1.81/s** | **1.84/s** | 节奏一致 |
| 切前台 | 换 IOSurface 内容 | **force_recap+relay 风暴** | 同左 | **共性痛点 #1** |
| find 耗时埋点 | hist≈30–40ms | color_perf **0.0** | 同左 | **共性痛点 #2** |
| 假命中/误 tap | 桌面看脚本 | 需业务门禁 | Dock「R」误命中+假登录曾现 | 语义门禁继续 |

**一句话**：CPU 与「running 时 shm 常驻」已大体追上；差距在 **(A) 切前台截帧风暴 (B) @3 帧过大 (C) .53 TINY 爬 / .166 TINY 基线肥 (D) 找不到真实 find_ms**。

---

## A. G0 对齐线（修订）

| 指标 | 触动基线 | 子砚目标（修订） |
|------|----------|------------------|
| 宿主 | 单进程 | embed 单宿主（已满足） |
| 帧 | IOSurface 常驻 | **running 期间 shm 始终 ≥1 帧且尺寸稳定**（.166/.53 本窗已满足） |
| RSS 抖动 | Δ≤0.5MB/100s | **四机业务 100s Δ≤0.5MB**（.166 已过；.53 贴边要压） |
| TINY | 不爬 | **100s TINY Δ≤64KB**；绝对值对标同分辨率机 |
| CPU | avg≤15% | avg≤**10%**（@3 放宽 15%）——实测已大多达标 |
| 切前台 | 无 I/O 风暴 | **单次 bid 切换 ≤2 次有效合帧**；日志无 200ms 内 5+ relay |
| find_ms | p50≤40ms | **埋点真实非 0**；窄 ROI p50≤40ms |
| 启停/假命中 | 起停两条；桌面不靠运气 | soft_kill 0 误杀；桌面 0 假「登录」；Dock 误色可复现则修 |

未过 G0 → 不做「超越」对外话术。

---

## B. 分阶段（按证据重排优先级）

### Phase R1 · 掐断 `front_bid` 合帧风暴（新 · 最高优先）

**状态（2026-08-02）**：已落地 **8-161-117**；自测 `tmp_shots/R1_GATE_117_20260802_041442/`（.166/.53 PASS）。待人工手切确认。

**证据**：.166/.53 日志在 `springboard↔game` 时 `home_force_recap` + 连续 `relay_req`（同秒多次）。触动只换缓冲内容。  
**做**：

1. bid 变化 **去抖**（≥300–500ms 合并为一次 force）。  
2. 一次切换只允许 **一条有效 relay**；ack 未归前禁止连环 nonce。  
3. 找色热路径：若热帧 age≤阈值阈值，**跳过** force（仅标记 dirty）。  

**门禁**：手切 App 10 次，framecap 日志 `relay_req` **≤20**；CPU 尖峰不高于本机基线 +5pp；shm 尺寸不变。

### Phase R2 · 帧预算按分辨率封顶（修订原 T1）

**证据**：触动固定 ~5.76MB IOSurface；.166 shm 2.77MB 健康；.53 @3 **10.46MB** 偏肥。  
**做**：

1. running 保留热帧（已有）；**禁止**业务中 idle clear。  
2. @3：评估 **逻辑分辨率缓冲 / 降采样找色面**（仍用 ZiYan 自有 API），目标热帧 dirty **≤6MB** 或与触动同量级。  
3. 仅 `user_stop` 或冷闲 >N 秒才 clear。  

**门禁**：.53 running `shm_bytes` 稳定且 phys 峰不因切前台台阶上涨；冷启首包 0 `empty_shm`。

### Phase R3 · TINY 肥 / 爬（.166 基线 + .53 爬）

**证据**：.166 TINY≈7.1MB 平台阶；.53 100s +39 pages。  
**做**：

1. 长跑前后 `footprint` 差分：toast/Verify/日志路径是否每圈 `alloc`。  
2. Verify.jsonl / 调试字符串：业务热路径改为环形缓冲或降频。  
3. embed Lua 分配审计：禁每圈新建大表/大字符串。  

**门禁**：四机业务 10min：TINY Δ≤**256KB**；.53 100s 复测 Δ≤64KB。

### Phase R4 · 真实 find_ms + 语义门禁（原 T3）

**证据**：`color_perf` wall/cpu 恒 0.0，无法对标触动 30–40ms；.53 曾 Dock 误命中。  
**做**：

1. embed/daemon 找色写 **真实 wall_ms**（每 50 次聚合，禁每圈刷盘）。  
2. 保留 mono+3；`/biztest` + 桌面禁止假 login。  
3. FIND1 命中坐标落在 Dock/图标区时记告警（可选前台门闩，默认关）。  

**门禁**：`find_ms_p50≤40`（同机窄 ROI）；`p1r_picker_biz` 绿；桌面 0 假登录。

### Phase R5 · 启停稳态（原 T2，保持）

空闲不写 kill；音量只报「已启动」；20 次启停 pid 不变。

### Phase R6 · SB 极薄（原 T4）

Toast/合帧不挡找色；业务时 find_ms 不随 SB CPU 线性恶化。

### Phase R7 · 超越项（G0–R6 全绿后）

| 点 | 做法 | 验收 |
|----|------|------|
| 闲时更省 | 停脚本后释帧（触动常驻 5.8MB） | 闲 CPU≤2.5%、shm≤128KB |
| 前台门闩 | 脚本显式开才限 bid | 桌面 0 假 tap |
| 可观测 | 四机一键 CPU/RSS/TINY/find_ms/relay 报告 | 对得上本表 |
| 双架构 | rootful@.166 + rootless@.53 同判据 | 同门禁脚本 |

---

## C. 近期排期（修订）

| 日 | 产出 |
|----|------|
| D1 | **R1** bid/relay 去抖 + 门禁（.166/.53 手切 App） |
| D2 | **R2** .53 帧预算评估/落地 + 冷启 empty 门禁 |
| D3 | **R3** TINY 差分修复 + 10min 复测 |
| D4 | **R4** find_ms 埋点 + 假命中四机 |
| D5 | R5/R6 复测；与 .171 同脚本节奏对照表更新 |
| D6+ | 仅对照表全面不差于触动 → R7 |

---

## D. 明确不做 / 可做

- **允许抄触动**：API、逻辑、算法、架构模型可对照移植进 ZiYan（见 `.cursor/rules/ziyan-api-cpu-mem.mdc`）  
- **仍不做**：把触动 dylib / TSDaemon 链进包当运行依赖；用观察机冒充 ZiYan 验收  
- 不靠再叠旗修竞态  
- 未过 G0 不说「已超越触动」
