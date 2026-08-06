# 整改 · 抄袭借鉴触动精灵 · 总计划（权威）

**生效**：2026-08-02 22:57  
**取代**：根目录旧 SURPASS 多稿（已迁 `DOCS/_superseded_plans/`）；五机数值门禁见 `FIVE_PHONE_SURPASS_PLAN.md`；**CPU/内存深入**见 [`CPU_MEM_REFORM_PLAN.md`](./CPU_MEM_REFORM_PLAN.md)。  
本文件管**怎么抄/怎么改架构**。  
**对照源**：  
- TS 3.x `.171`：`tmp_shots/TS171_FULL_ARCH_20260802_223916/`  
- TS Pe 4.1.1：`tmp_shots/TSPE411_ARCH_20260802_224413/ARCH_COMPARE_3WAY_COPY_PLAN.md`（deb 在桌面 `触动精灵deb/`）  
- 五机 Find/Home：`tmp_shots/FIND_HOME_MEM_COMPARE_5PHONE.md`  

**硬约束**：可抄 API / 逻辑 / 算法进 `lua/` `objc/`；**禁**链 `TSDaemon` / `TSTweak*` / `sz.so` / `paddleocr.so` / 任意触动 dylib；`.171` 只读；验收只出 `.53/.101/.112/.166`；兼容 7/7P/8/8P × iOS 13～16.7.16。

---

## 0. 目标态（抄 Pe 为主、3.x 为辅）

```
触动 Pe 4.1.1                          子砚目标
─────────────────                      ─────────────────
TouchSpritePe.app (UI)                 ZiYan.app (UI)
TSDaemon = 脚本+IOSurface+找色+HID     ziyan_framecap = 脚本+常驻帧+找色+HID
Hades (轻旁路)                         zydaemon 仅拉起，不仲裁停杀
TSTweak → SB（仅体验）                 ZiYanVol → SB（仅音量/Toast/悬浮）
（无业务 LaunchDaemon）                热路径无 engine/scripthub/fscloak 仲裁
```

一句话：**把 ZiYan 从「多守护 + 文件 shm + Relay 风暴」收成「单核常驻帧 + 薄 SB」**，行为对齐触动后再谈超越。

---

## 1. 现状（包线 128）

| 项 | 状态 |
|----|------|
| 宿主意图 | embed-in-framecap ✅ |
| Home force 节流 / 黑帧退避 | 126 H1/H2 ✅（TINY 仍未过 G0） |
| 切屏冻帧失效 | 127 P0 ✅（待游戏手验） |
| Toast 跟可见屏 | 128 ✅（待游戏横屏手验） |
| 帧模型 | 仍文件 shm + FrameRelay ❌ 相对 Pe |
| Substrate | Vol+AppTouch+FrameRelay+Defense+FsCloak（Pe 仅 1）❌ |
| LaunchDaemon | 4+ KeepAlive（Pe 0）❌ |

当前包：`0.0.92-8-161-130`（arm + arm64）。  
130：对标 main.lua——`force` 不堵 find；常驻帧热扫（见 `tmp_shots/TS171_RUN_STACK_*/ANALYSIS_MAIN_LUA_STACK.md`）。

---

## 2. 抄什么 / 不抄什么

### 必抄（模型与热路径）

| # | 触动做法（Pe 证据） | ZiYan 落点 |
|---|-------------------|------------|
| C1 | `createScreenIOSurface` + `keepScreen` + 常驻 `screenshotSurface` | framecap 定容 IOSurface/CVPixelBuffer 或定长 mmap；running 不拆 |
| C2 | 切屏只换像素 + orient/bid | 巩固 invalidate/stale；单次切换 ≤1 次有效合帧 |
| C3 | `ioHidEventSystem` 在 Daemon | 触控主路径进 framecap/HID；SB 不跑找色截屏 |
| C4 | 仅 `TSTweak`→SB | 热路径只留 Vol(+AppTouch)；FrameRelay 冷备或可卸 |
| C5 | 无业务 LD | zydaemon=Hades；engine/fscloak/scripthub 退出启停仲裁 |
| C6 | `findMultiColor*` 同进程扫帧 | embed 直读热帧；禁独立 lua 热路径 |
| C7 | `initOrient` / `convertSearchOrient` / Toast 跟屏 | OrientMap + ToastBridge 同一套屏坐标 |

### 可后置

| # | 触动 | ZiYan |
|---|------|-------|
| C8 | Paddle-Lite + ppocr | 免费权重**自编译**进自有树；不打包 Pe so |
| C9 | 悬浮条 / WebServer 体感 | 对齐交互，不抄资源版权素材 |

### 严禁抄

哈希改名 Daemon、支付/云控 SDK、`killall SpringBoard backboardd` 当常规恢复、dlopen 触动任何 so/dylib、观察机装 ZiYan。

---

## 3. 整改刀序（执行板）

### 第 1 刀 · 验收已改（本周内手验收口）

1. `.112` 游戏横屏：Toast 贴底（128）  
2. `.112` 手切 App/Home：一刀找色正确、不必二次 Home（127）  
3. 四机推 128（或下一包）：`.166/.101` arm；`.53` 需先打 arm64  

### 第 2 刀 · C1 伪 IOSurface（最高优先 · 过 G0 内存）

> **深入步骤 / 预算 / 状态机**：见 [`CPU_MEM_REFORM_PLAN.md`](./CPU_MEM_REFORM_PLAN.md) **M-A～M-E**。

**改**：`tools/ziyan_framecap` + `ZiYanFrameShm`  
**做**：
- running 期固定工作集；禁止 unlink/重映射风暴  
- bid 变 → 覆盖像素 + stale；热路径零/少 Relay  
- @3（.53）找色面降采样，脏帧预算 ≤~6MB  
- keep 粘性：禁 `embed_find`↔`false` 热抖动  

**门禁**（同 `FIVE_PHONE` G0 + CPU_MEM 预算表）：TINY/RSS；relay≤2/次切换；FC_N=1；framecap avg CPU≤10%  

### 第 3 刀 · C3+C4 路径收束（对齐 Pe 钩子量）

**改**：AppTouch / Vol / FrameRelay Filter  
**做**：
- 默认：Vol + AppTouch；FrameRelay 仅合帧失败冷路径  
- 统计 SB 内截屏/找色调用 → 目标 0  
- `.53` 试「Vol+AppTouch only」业务 100s  

### 第 4 刀 · C5 守护瘦身

**改**：LaunchDaemons + zydaemon  
**做**：运行中 `ps` ≈ `framecap` + 可选 1 watchdog；停杀单一会话状态机  
**门禁**：音量停后无 launchd 连环拉起误杀  

### 第 5 刀 · C6+C7 语义对齐

embed 零文件找色；find_ms 真值 p50≤40；横竖屏/Toast/坐标一门禁  

### 第 6 刀 · 超越（仅 G0 全绿）

闲时更省、四机一键对照、OCR 自研加速；**此时才允许「超越触动」话术**。

---

## 4. 与五机门禁的映射

| 本计划 | 五机计划 | 主验机 |
|--------|----------|--------|
| 第 1 刀 | P0 / Toast / H1 验收 | .112 |
| 第 2 刀 | H1 巩固 + H4 + H5 | .112 → .53 |
| 第 3 刀 | —（架构） | .53 / .112 |
| 第 4 刀 | H3 | .101 |
| 第 5 刀 | H6 / H7 | 四机 |
| 第 6 刀 | H8 | 四机 |

详细数值表：`FIVE_PHONE_SURPASS_PLAN.md`。

---

## 5. 每日节奏（建议）

| 日 | 产出 |
|----|------|
| D0 | 本清理 + 本计划生效；`.112` 手验 127/128 |
| D1–D2 | 第 2 刀伪 IOSurface；`.112` Find/Home 100s |
| D3 | 推包 `.166/.101`；H3 单例 |
| D4 | `.53` arm64 包 + 帧预算 |
| D5 | 第 3–4 刀瘦钩子/LD；四机 TINY |
| D6 | R1 UI 四机；全绿再报人工 |

---

## 6. 仓库卫生（已做 / 规则）

| 项 | 状态 |
|----|------|
| `packages/` 仅 126/127/128 | ✅ ~207M |
| 过时计划 → `DOCS/_superseded_plans/` | ✅ |
| `tmp_shots` 去重/去大包提取物 | ✅ ~1M 级证据保留 |
| `bash tools/cleanup_packages.sh` | ✅ 已修，勿用 zsh 直跑旧逻辑 |
| 排期权威 | **本文件** + `FIVE_PHONE_SURPASS_PLAN.md` |

---

## 7. 风险备忘

- IOSurface 常驻抬高 footprint 基线，换「不爬、无风暴」  
- 合帧等 ack 必须超时+复用旧帧，禁忙等  
- `.53` 上 Pe 与 ZiYan 共存时采基线先停一方  
- `.171` 若残留 ZiYan dylib 须卸净后再采 TS 基线  

---

## 8. 下一动作（立刻）

1. 人工：`.112` 开游戏验 Toast + 手切验冻帧  
2. 工程：开工第 2 刀（framecap 常驻帧，Pe `keepScreen` 语义）  
3. 构建：补打 **128 arm64** 供 `.53`，避免 rootless 停在 126  
