# device_difference_report.md

**阶段**：7.6.3-R2  
**日期**：2026-07-23  
**设备**：192.168.31.166（iPhone7） vs 192.168.31.53（iPhone8 Plus）  
**原则**：同方案对比；禁止单设备特判坐标；学习设备仅对照  

---

## 1. 摘要

| 维度 | .166 iPhone7 | .53 iPhone8 Plus | 差异影响 |
|------|--------------|------------------|----------|
| iOS | 13.1.2 rootful | **16.7.16 rootless** | 注入/jetsam/场景生命周期不同 |
| 原生像素 | 640×1136 @**2** | **1242×2208 @3** | 截图像素数比 ≈ **3.77×** |
| 逻辑缓冲 logicBuf | 1136×640 | **2208×1242** | 单帧 RGBA ≈ 2.9MB vs **11.0MB** |
| 点阵 UIScreen | 320×568 / raw 常横屏 568×320 | 414×736 / 横屏 736×414 | Overlay host 尺寸不同 |
| 期望「1920×1080」？ | 否 | **否** — 真机是 Retina 1242×2208→横屏逻辑 **2208×1242**（大于 1080p） | 非 scale 算错成 1080p |
| Touch | AppTouch land identity | 同路径 land identity | 角点曾双机 ok |
| Overlay | rawLand_identity 稳定（游戏横屏） | rawLand **随 raw 翻转**（回桌面→portraitHost_rotate） | 体感「仍异常」主因之一 |
| SB jetsam | highwater；rpages≈55950 | highwater；**rpages≈111488（≈2×）** | .53 更容易几分钟重启 |
| Lua 运行时 | lua5.3 正常 | **缺 DYLD 时 Abort**（liblua 装在 /var/jb） | 脚本偶发中断 |

**结论**：.53「异常」不是找色坐标公式单独坏掉，而是 **更大缓冲 + iOS16 jetsam + Overlay 随物理 raw/会话翻转 + rootless Lua 装载** 叠加。Capture 尺寸正确，**不是**误用 1920×1080。  
补充（14:56 现场）：`.166` 坐标仍 OK，但 **SB 在会话内多次重启**（etime 回零）——双机同属 jetsam 风险，不能因「点得准」视为稳定性已解决。

---

## 2. 分项对比

### 2.1 屏幕 / 像素 / scale

| | .166 | .53 |
|--|------|-----|
| native | 640×1136 @2 | 1242×2208 @3 |
| logicBuf(init1) | 1136×640 | 2208×1242 |
| img(points) | 320×568 | 414×736 |
| scale factor | 2 | 3 |

### 2.2 截图 buffer

双方 ScreenBridge：`src=竖屏原生 → rotate → logicBuf`。  
.53 单缓冲约 11MB，旋转过程峰值可达约 2×；注释已有 iOS16 丢弃竖屏 capture，但峰值仍显著高于 .166。

### 2.3 Coordinate / Touch

双方：`transform_count=1`，`x1=x2=x3`，横屏窗 `space=screen_landscape_identity`。  
.166 业务点例：`logic=1044,346 hid=0.460,0.919 error_type=ok`。  
.53 中心：`logic=1104,621 hid=0.500,0.500 via=app`。

### 2.4 Memory / iOS

- Jetsam `largestProcess=SpringBoard`，reason=`highwater`（.166 明确；.53 同为最大进程）。  
- .53 lifetimeMax rpages 约为 .166 的 2 倍。  
- .53 另有 `lua5.3-*.ips` / `timeout-*.ips`（今日 14:03）→ 进程崩溃而非仅坐标。

### 2.5 TouchSprite 学习机对照

.149 / .171：TSDaemon 长跑（天～周）；只读 `logs/touchsprite_learning/`。  
对照含义：TS 不把全分辨率双缓冲长期压在 SpringBoard 同进程模型上（架构差异），子砚 Vol 注入 SB 是 jetsam 高危面。

---

## 3. .53 重点：Screen Capture 是否错误？

| 检查项 | 结果 |
|--------|------|
| 是否应为 1920×1080 | **否**。8 Plus 原生 1242×2208@3；横屏逻辑 **2208×1242** |
| Retina scale | scale=3 与 native 一致 |
| rotation | init=1 → rot=1，logicBuf 已横置 |
| framebuffer | screen_info 与 native_wh 一致，未见 1080p 错绑 |

异常来自 **内存压力 / Overlay 宿主随 raw / Lua 装载**，不是「截成了错误的 1080p」。

---

## 4. 建议（待确认，本阶段未改 Oc 核心）

1. **通用**降低 ScreenBridge 峰值（双机同一策略；禁止 .53 特判坐标）。  
2. rootless 包装保证 `lua5.3` 的 `@rpath`/`install_name` 指向 `/var/jb/usr/lib/ziyan/lib`。  
3. Overlay：游戏前台时强制刷新 rawLand（已有逻辑；避免在桌面竖屏 raw 下误判「横屏坏了」）。  
4. 继续 30min endurance 门禁（采样已启动）。

---

## 5. 证据

- `logs/screen_mirror/mirror_20260723.jsonl`  
- `logs/sb_restart/sb_20260723.jsonl`  
- `tmp_shots/PHASE763R2_DIAG/deep_*.txt` · `jetsam_*.txt`  
- snapshot：`tmp_shots/PHASE763R2_DIAG/snapshot_pre/`
