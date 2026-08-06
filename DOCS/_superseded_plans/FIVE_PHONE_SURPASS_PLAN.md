# 五机超越计划（2026-08-02 · Find/Home 数值门禁）

> **架构/抄袭总计划（权威）**：[`COPY_TS_REFORM_PLAN.md`](./COPY_TS_REFORM_PLAN.md)  
> **CPU/内存深入**：[`CPU_MEM_REFORM_PLAN.md`](./CPU_MEM_REFORM_PLAN.md)  
> 本文件只保留五机 **G0 指标与 H1–H8 测量刀**；怎么抄 Pe/3.x 以总计划为准。

**设备**：TS `.171`（对照）+ ZiYan `.53` `.101` `.112` `.166`  
**证据**：`tmp_shots/FIND_HOME_MEM_COMPARE_5PHONE.md`  
**兼容**：iPhone 7/7P/8/8P × iOS 13～16.7.16  
**规则**：可抄触动 API/逻辑/算法进 `lua/` `objc/`；禁链 TS dylib/TSDaemon；验收只出四机 ZiYan。

原则：**先对齐触动「常驻帧 + Home 零风暴 + 内存不爬」→ 再谈超越**；未过 G0 不宣称超越、不报人工审核。

---

## 0. 五机结论一句话

| 机 | 角色 | 相对触动的核心差距 |
|----|------|-------------------|
| **.171** | 触动对照 | IOSurface ~5.7MB 常驻；Home 只换内容；TINY/RSS≈不涨 |
| **.112** | rootful 主改机 | Home `force/relay` 风暴 + `carender_black` → TINY+1MB、wall 尖峰 233ms |
| **.166** | rootful 对照 | 同模式；TINY+1.4MB、RSS+4.2MB；常态 find 尚可 |
| **.101** | rootful 脆弱机 | FC 曾死、shm=0；单例不稳；shm_bid 滞后 |
| **.53** | rootless/@3 最重 | shm~10.5MB；RSS+11MB；find 秒级 |

共性：ZiYan 是「文件 shm + 切前台狂 force」，不是触动「常驻工作集」。

---

## 1. G0 对齐线（过线才谈超越）

同协议：业务找色循环 + 用户按 Home ≈100s。

| 指标 | 触动 .171 | 四机 ZiYan 目标 |
|------|-----------|-----------------|
| 帧模型 | IOSurface 常驻 Δ0 | running 期间 shm≥1 帧且尺寸稳定；找色不每圈重分配 |
| TINY Δ/100s | ≈0 | **≤64KB**（.53 放宽 ≤128KB） |
| RSS Δ/100s | ≈16KB | **≤0.5MB**（.53 放宽 ≤1MB） |
| Home 合帧 | 无 I/O 风暴 | 单次 bid 切换 ≤2 次有效合帧；200ms 内无 5+ `relay_req` |
| find wall | 稳态 | 窄 ROI p50≤40ms；Home 后 p99≤80ms |
| framecap | 单宿主 | **全程 FC_N=1**；shm 不为 0 |
| shm_bid | n/a | 与 `front_bid` 同步（滞后≤1 个采样周期） |

---

## 2. 分刀（按证据优先级）

### P0 · 冻帧失效（2026-08-02 夜 · **8-161-127**）

**状态**：已装 `.112`。切屏 → `shm_invalidate` + `shm_front_bid=stale`；禁 `home_force_settle`；embed 禁扫 released。  
**验收**：手切后**不必再按一次 Home** 也能正确找色（对标 .171）。

### H1 · Home/force 节流（最高优先 · 先改 · 先验 .112/.166）

**状态（2026-08-02）**：已落地 **8-161-126**；`.112` 复测见 `tmp_shots/ZY112_H1H2_126_20260802_213859/`。  
force/relay 风暴已明显下降（回游戏仅 1× force；relay≈2）。TINY 仍爬 → 未过 G0 内存线。

**抄触动点**：Home 只换缓冲内容，不连环 recap。  
**已做**：
1. bid 去抖 Home 2.0s / App 0.80s；静默窗 3.0s；serve pace 2.5/1.8s。  
2. 热帧已对齐 → `force_skip_hot_aligned`；黑帧退避不破静默。  
3. Home 连败软结算 `home_force_settle`（打断永久 bidMismatch）。  

**门禁**：手切 App/Home 10 次；`.112` 日志 `relay_req`≤20；TINY Δ≤64KB（TINY 仍待 H5）。

### H2 · 黑帧退避（与 H1 同包 · .112/.101）

**状态**：与 H1 同包 126；见 `black_backoff` / `need_fresh_keep`。  
**做**：`carender_kr_or_black` → 复用上一帧 + 指数退避；禁忙等重抓。  
**门禁**：同窗口无连续 ≥3 次 black 忙等；wall p99≤80ms（本窗尖峰 54.9ms，改善）。

### H3 · 单例 framecap + shm 自愈（.101 主验）

**做**：保证单 `ziyan_framecap serve`；shm=0 快拉起且不叠多实例；`shm_front_bid` 与 front 同步写。  
**门禁**：100s `FC_N` 恒=1；shm_bytes>0；无长时间 shm_bid 错位。

### H4 · @3 帧预算（.53 主验）

**抄触动点**：固定量级工作集（触动 ~5.7MB）。  
**做**：@3 逻辑分辨率/降采样找色面；热帧 dirty 目标 ≤6MB 量级；业务中禁 idle clear。  
**门禁**：`.53` shm 稳态；RSS Δ≤1MB；find 尖峰从 2s+ 压到 ＜200ms。

### H5 · TINY/长跑审计（四机）

**做**：差分 toast/Verify/每圈 Lua 大表；热路径环形缓冲；停脚本清 keep。  
**门禁**：业务 10min TINY Δ≤256KB。

### H6 · 真实 find_ms + 语义门禁

**做**：埋点真实 wall_ms（聚合写盘）；桌面 0 假登录；Dock 误色可复现则修。  
**门禁**：`find_ms_p50≤40`；`p1r_picker_biz` 绿。

### H7 · R1 UI 真门禁（并行，不挡 H1–H4）

锁屏/Home/切画面：`tools/r1_real_ui_gate.sh`；四机 OVERALL=PASS 才报人工审核。  
禁 `uiopen prefs` 冒充 Home。

### H8 · 超越项（G0 全绿后）

闲时更省、前台门闩、四机一键对照报告、rootful+rootless 同判据。

---

## 3. 机型验收矩阵

| 刀 | .112 | .166 | .101 | .53 | .171 |
|----|------|------|------|-----|------|
| H1/H2 | **主验** | 复测 | 复测 | 复测 | 对照 |
| H3 | — | — | **主验** | — | — |
| H4 | — | — | — | **主验** | 对照 |
| H5/H6 | 四机 | 四机 | 四机 | 四机 | 对照 |
| H7 R1 | 必过 | 必过 | 必过 | 必过 | 不部署 ZiYan |

---

## 4. 排期

| 日 | 产出 |
|----|------|
| **D1** | H1+H2 改 framecap/合帧 → `.112` 再跑 Find/Home 100s |
| **D2** | `.166` 复测；修回归后打一包 |
| **D3** | H3 → `.101` 单例/shm 自愈门禁 |
| **D4** | H4 → `.53` 帧预算 + Home 复测 |
| **D5** | H5/H6 + 五机对照表更新；对标 .171 |
| **D6** | H7 四机 R1 UI；全绿才报人工审核 |
| **D7+** | 仅 G0 全绿 → H8 超越项 |

---

## 5. 明确不做

- 不链触动 dylib / TSDaemon 进包  
- 不拿 `.171` 当 ZiYan 验收  
- 不靠叠旗糊竞态  
- 未告知前不扩兼容到 iOS 17+ 或 7/8 系以外机型  
- 未过 G0 不说「已超越触动」

---

## 6. 证据索引

| 机 | 目录 |
|----|------|
| TS .171 | `tmp_shots/TS171_FIND_MEM_20260802_203238/` |
| .53 | `tmp_shots/ZY53_FIND_MEM_20260802_203834/` |
| .166 | `tmp_shots/ZY166_FIND_MEM_20260802_204207/` |
| .101 | `tmp_shots/ZY101_FIND_MEM_20260802_204546/` |
| .112 | `tmp_shots/ZY112_FIND_MEM_20260802_205131/` |
| 总表 | `tmp_shots/FIND_HOME_MEM_COMPARE_5PHONE.md` |
