# CPU / 内存管理 · 深入整改计划（抄触动）

**权威关系**：本文件是 [`COPY_TS_REFORM_PLAN.md`](./COPY_TS_REFORM_PLAN.md) 的 **CPU·内存专章**；五机数值门禁见 [`FIVE_PHONE_SURPASS_PLAN.md`](./FIVE_PHONE_SURPASS_PLAN.md)。  
**证据**：`tmp_shots/FIND_HOME_MEM_COMPARE_5PHONE.md` + 各机 `*_FIND_MEMORY_CONCLUSION.md` + Pe `keepScreen`/`createScreenIOSurface`。  
**铁律**：`.cursor/rules/ziyan-api-cpu-mem.mdc`（CPU 越低越好；内存对照触动；可抄逻辑禁链 so）。  
**自测前清机（铁律）**：每次四机自测前必须 `bash tools/zy_pretest_clean_4phone.sh`（杀进程/僵尸/释帧）；不清不测。

---

## 0. 触动模型（要抄成什么样）

```
┌─────────────────────────────────────────────────────────┐
│ TSDaemon（单进程）                                        │
│  ┌──────────────────┐   find/tap/toast 同进程读写        │
│  │ IOSurface ~5.7MB │←── keepScreen：常驻，只换像素     │
│  │ Δ size = 0       │   Home/切 App：不 realloc、不风暴 │
│  └──────────────────┘   TINY/RSS：平台阶（Δ≈0 / ~16KB） │
│  HID 事件在 Daemon 内；SB 只做悬浮/音量（几乎 0 找色 CPU） │
└─────────────────────────────────────────────────────────┘
```

| 维度 | 触动行为 | 子砚现状（五机） | 后果 |
|------|----------|-----------------|------|
| 帧工作集 | IOSurface 定容常驻 | 文件 shm + 旁路小 IOSurface | Home 时堆爬、wall 尖峰 |
| 切前台 | 换内容 | force/relay/carender 重试 | TINY+、CPU 脉冲 |
| keep | 一块 surface 吃到底 | `embed_find`↔`false` 抖动 | 生命周期不稳 |
| 找色 CPU | 同进程扫已挂帧 | 偶发慢路径/IPC/重抓 | .53 秒级尖峰 |
| SB CPU | 薄 | Vol 轮询 + 可能截屏兜底 | SB 风险 / jetsam |

**优化哲学（写死）**：  
1. **基线可略高，斜率必须为零**（允许常驻 5～6MB 帧，禁止 100s 内 TINY/RSS 台阶）。  
2. **CPU 看尖峰与占空比**，不只看 avg；Home 窗禁止连环 force。  
3. **用完即释的是「临时物」**（OCR 大图、日志、失败重试缓冲），不是热帧本身。

---

## 1. 预算表（G0 对齐线 · 业务 Find/Home ≈100s）

协议：业务找色循环 + 用户按 Home；采 framecap（或 TSDaemon）TINY / RSS / IOSurface或shm / CPU% / `relay_req` / `force_*` / `find wall_ms`。

### 1.1 内存预算

| 指标 | 触动 .171 | rootful 目标 (.112/.166/.101) | rootless @3 (.53) |
|------|-----------|-------------------------------|-------------------|
| 主帧尺寸 | IOSurface **5744KB Δ0** | 定容工作集 **Δ0**（shm 或 IOSurface） | 脏帧预算 **≤6MB**，尺寸 Δ0 |
| TINY Δ/100s | ≈0 | **≤64KB** | **≤128KB** |
| RSS Δ/100s | ≈16KB | **≤0.5MB** | **≤1MB** |
| 停脚本后 | 可释工作集 | **1.2s 内**清 keep/可延迟清 shm（已有 pressure_relief 方向） | 同左 |
| Toast | 单窗复用 | **禁止**每圈新建 UIWindow/大图 | 同左 |
| OCR | 用完释 | 懒加载；禁 find 循环常驻模型 | 同左 |

### 1.2 CPU 预算

| 指标 | 触动参考 | ZiYan 目标 |
|------|----------|------------|
| framecap/TSDaemon avg | ~8–11%（业务窗） | **≤10%**（@3 放宽 **≤15%**） |
| framecap max（Home 窗） | ~27–30% 短脉冲 | **≤35%**；禁止 >50% 持续 ≥2s |
| SpringBoard avg（脚本跑） | 低（薄钩子） | **≤5%** 额外；禁找色进 SB |
| 单次 bid 切换 | 无 I/O 风暴 | **≤2** 次有效合帧；200ms 内 **无 5+** `relay_req` |
| find wall p50 / p99 | ~30–40ms 稳态 | **p50≤40ms**；Home 后 **p99≤80ms**（.53 过渡 p99≤200ms） |
| toast 路径 | 轻 | 同文案节流；轮询间隔与 bump 事件驱动并存，禁 1ms 空转 |

### 1.3 过程计数（日志门禁）

| 计数器 | 100s / 手切 10 次窗口 | FAIL 条件 |
|--------|----------------------|-----------|
| `home_force_recap` + `force_recap` | ≤ 切换次数 ×2 | 同秒 ≥5 次 force |
| `relay_req` | ≤20 / 10 次手切 | 200ms 内 ≥5 |
| `carender_kr_or_black` 忙等 | 连续 ≤2 后必须 backoff | 连续 ≥3 无 `black_backoff_keep` |
| `FC_N`（framecap 实例） | **恒 =1** | ≥2 或 shm_bytes=0 超 3s |
| keep 态抖动 | running 期保持「持帧」 | 每秒 `embed_find`↔`false` 翻转 ≥3 |

---

## 2. 根因 → 对策矩阵（按证据）

| ID | 根因（证据机） | CPU 影响 | 内存影响 | 对策（落点） | 刀 |
|----|---------------|----------|----------|--------------|----|
| M1 | 文件 shm + Home force 风暴 (.112/.166) | 合帧/CPU 脉冲 | TINY+1MB 级 | 定容常驻；bid 去抖已有→再压到「只覆写」 | M-A |
| M2 | `carender_black` 忙等重试 (.112) | wall 233ms | 失败路径堆碎片 | 指数退避+复用旧帧（126 已开）巩固 | M-A |
| M3 | keep 在 embed_find↔false 抖动 | 多余 clear/alloc | TINY 台阶 | running 期 keep 粘住；仅停脚本/显式 keepScreen(false) 释放 | M-A |
| M4 | @3 shm ~10.5MB (.53) | 扫帧缓存 miss | RSS+11MB | 找色降采样面 ≤6MB；逻辑分辨率封顶 | M-B |
| M5 | FC 死 / shm=0 (.101) | 重启尖峰 | 短暂 0 帧 | 单例 + 自愈；禁叠 serve | M-C |
| M6 | shm_bid 滞后 front | 假 force | 多余合帧 | bid 与帧原子写；stale 拒绝热扫（127） | M-A |
| M7 | SB 内 Toast 50ms 轮询 + 可能截屏 | SB CPU | 窗/图层 | bump 事件为主；同文案 gap；禁 SB 找色 | M-D |
| M8 | 多 LD / 多 dylib | 后台唤醒 | 驻留集偏大 | 热路径只 framecap+Vol(+AppTouch) | M-D |
| M9 | Lua 每圈大表/字符串/日志 | framecap CPU | TINY 爬 | 环形缓冲；禁热路径 NSLog 风暴 | M-E |
| M10 | OCR/py 大缓冲 | 尖峰 | RSS 台阶 | 懒加载；用完 `pressure_relief` | M-E |

---

## 3. 分阶段实施（CPU / 内存专用刀）

### M-A · 常驻工作集 + 零风暴（最高优先 · 对应总计划第 2 刀）

**目标**：行为对齐 `keepScreen` + IOSurface Δ0。

| 步骤 | 改哪里 | 做什么 |
|------|--------|--------|
| A1 | `ZiYanFrameShm` | 固定容量 mmap/IOSurface；`Invalidate` **只标 dirty/stale**，禁 unlink |
| A2 | `ziyan_framecap/main.m` | bid 变 → 覆写像素；force 仅在 age 超时/黑帧；巩固 H1 去抖 |
| A3 | `ZiYanLuaEmbed.m` | running 找色：拒绝 `released`/`stale`；持帧时不写 keep=false |
| A4 | 黑帧路径 | 已有 `black_backoff_keep`：保证不破静默窗、不堆 TINY |
| A5 | 释放点 | `keepScreen(false)` / 停脚本 → 延迟 clear + `malloc_zone_pressure_relief`（已有骨架） |

**验收**：`.112` Find/Home 100s：TINY≤64KB、RSS≤0.5MB、relay 门禁绿、find p99≤80ms。

**风险**：常驻抬高 footprint 基线——**接受**；回滚点：保留文件 shm 冷路径开关。

---

### M-B · @3 帧预算（.53 · 对应 H4）

| 步骤 | 做什么 |
|------|--------|
| B1 | 逻辑分辨率/降采样找色面；热帧 dirty ≤**6MB** |
| B2 | 业务中禁 idle 全清；与 M-A 同一 keep 粘性 |
| B3 | Pe 同机采基线时停一方，避免双产品干扰 |

**验收**：shm 尺寸稳态；RSS Δ≤1MB；find 尖峰 ＜200ms（再压到 80ms）。

---

### M-C · 单例与自愈（.101 · 对应 H3）

| 步骤 | 做什么 |
|------|--------|
| C1 | launchd/wrap 保证单 `ziyan_framecap serve` |
| C2 | shm=0 → 快拉起；超时才重启；禁双实例 |
| C3 | `shm_front_bid` 与 front 同写 |

**验收**：100s `FC_N=1`；无长时间 shm=0。

---

### M-D · CPU 占空比：SB / 钩子 / 轮询

| 步骤 | 改哪里 | 做什么 |
|------|--------|--------|
| D1 | `ZiYanToastBridge` | bump/事件唤醒优先；空闲拉长 poll；同文案 minGap |
| D2 | FrameRelay | 热路径默认关；仅合帧失败冷启 |
| D3 | AppTouch | 触控主路径；SB 触控兜底计数→0 |
| D4 | Defense/FsCloak/engine LD | 不进找色/启停热路径 |
| D5 | framecap serve 循环 | 有事件才干活；禁无 force 时 tight loop |

**验收**：脚本跑时 SB avg≤5% 额外；framecap avg≤10%（@3≤15%）。

---

### M-E · 堆与临时物（TINY 长跑 · 对应 H5）

| 步骤 | 做什么 |
|------|--------|
| E1 | 审计 toast/Verify/每圈 Lua table：改为复用或池 |
| E2 | 日志：环形文件；热路径禁明文大 dump |
| E3 | OCR：首次用加载；结束 `pressure_relief` |
| E4 | 10min 业务：TINY Δ≤256KB |

**验收**：四机 10min TINY 门禁；无 jetsam。

---

### M-F · 超越（仅 G0 全绿后）

- 闲时 framecap 更深睡（对标触动停脚本后）  
- 四机一键 `tools/` 采样脚本出 CPU/MEM 对照表  
- 争取同脚本 **avg CPU < 触动**，且 TINY 斜率仍为 0  

---

## 4. 生命周期状态机（内存）

```
[idle] 无脚本
   │ menu_run / 音量+
   ▼
[warm] framecap 起；可预分配定容帧（未 keep）
   │ 脚本 start / keepScreen(true) / 首次 find
   ▼
[hot]  常驻工作集；只覆写；bid→stale→单次合帧
   │ 脚本 stop / keepScreen(false)
   ▼
[cool] 延迟 1.2s clear + pressure_relief → [idle]
```

**禁止转换**：
- `[hot]` 内每 find 一次 full realloc  
- `[hot]` 内 `embed_find`↔`false` 高频翻转  
- `[cool]` 未完成又叠第二个 framecap  

---

## 5. CPU 时间线（单次 Home）

触动：

```
Home 按下 → 短 CPU 脉冲（合成/前台切换）→ IOSurface 内容更新 → find 继续（无 I/O 风暴）
```

子砚目标：

```
Home → bid debounce (≥300–500ms 合并) → 至多 1× force/relay
     → 黑则 backoff 复用旧帧 → stale 清除后下一 find 用新帧
     → 禁止：同秒 5+ relay / 无退避 carender 重试
```

---

## 6. 埋点与验收工具（必须有真值）

| 埋点 | 用途 | 要求 |
|------|------|------|
| `find_wall_ms` | p50/p99 | **非 0**；聚合落盘 |
| `force_*` / `relay_req` 计数 | 风暴门禁 | framecap 日志可 grep |
| `shm_bytes` / `shm_front_bid` | 帧生命 | 与 front 同步 |
| `keep` 态 | 抖动检测 | 采样脚本打点 |
| `vmmap` / footprint TINY·RSS | G0 | 与五机同协议 |
| SB/FC `%cpu` | CPU 预算 | `ps`/`top` 窗采样 |

建议脚本（实现或加固）：`tools/zy_find_home_mem_sample.sh`（四机同一套），输出对齐 `FIND_HOME_MEM_COMPARE_5PHONE.md` 表头。

---

## 7. 代码热点清单（改之前先读）

| 区域 | 文件 | CPU/内存角色 |
|------|------|----------------|
| 合帧/force | `tools/ziyan_framecap/main.m` | Home 风暴、black backoff、keep clear |
| embed 找色 | `tools/ziyan_framecap/ZiYanLuaEmbed.m` | keep 抖动、force_recap 触发 |
| 帧 shm | `objc/shared/ZiYanFrameShm.*` | 定容/invalidate |
| Toast | `objc/tweak/springboard/ZiYanToastBridge.m` | SB 轮询 CPU、窗复用 |
| Relay | `ZiYanFrameRelay.dylib` | 跨进程合帧税 |
| 脚本 API | `lua/ziyan_engine/cv.lua` 等 | 文件 IPC 税（应降为冷路径） |

---

## 8. 排期（嵌入总计划）

| 日 | CPU/内存产出 | 主验 |
|----|--------------|------|
| D1–D2 | **M-A** 定容常驻 + keep 粘性；`.112` 100s 过 TINY/RSS | .112 |
| D3 | M-C 单例；推包 .166/.101 | .101 |
| D4 | **M-B** @3 预算；128 arm64 | .53 |
| D5 | **M-D/E** 钩子/堆；四机 CPU avg | 四机 |
| D6 | 全量 G0 复测表；未绿禁 M-F 话术 | 四机 |

---

## 9. 明确不做（防「越优化越炸」）

1. 用「更勤 force」换「画面更新」——禁止（抬 CPU+TINY）。  
2. 为降 footprint 基线而每圈 free 热帧——禁止（触动反模式）。  
3. 在 SB 里做找色/重截屏「省 IPC」——禁止（毁 SB 稳定性）。  
4. `killall backboardd/SpringBoard` 当内存回收——禁止。  
5. 未过 G0 宣称 CPU/内存已超越触动——禁止。

---

## 10. 一页验收清单（发版前）

- [ ] `.112` Find/Home：TINY≤64KB、RSS≤0.5MB、relay≤20/10 切  
- [ ] `.166` 同协议复测绿  
- [ ] `.101` FC_N=1、shm>0  
- [ ] `.53` RSS Δ≤1MB、find 尖峰＜200ms  
- [ ] 四机 framecap avg CPU 达标；SB 无找色截屏  
- [ ] 停脚本后 keep 清、无泄漏窗  
- [ ] 对照 `.171` 同脚本：子砚斜率不差于触动  

全绿 → 才进入 `COPY_TS_REFORM_PLAN` 第 6 刀（超越项）。
