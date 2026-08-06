# 子砚超越触动精灵 · 执行计划

**日期：** 2026-07-28  
**基线包：** 0.0.92-8-136（门禁）/ 8-134（功能机）  
**约束：** 四大硬锁；禁复用触动私有 so/Daemon/TSLib；Desktop ios7/ios8p 仅 scp  
**对照依据：** 公开手册 + .149/.171 TSDaemon 只读观察 + 四机自测（非同机装触动 A/B）

---

## 总目标（可证伪）

| # | 目标 | 通过线 |
|---|------|--------|
| G1 | SB 长稳 | .53+.166 连续 **8h** 无自发 `SB_RESTART`（部署 respring 除外） |
| G2 | 换屏找色跟手 | 业务脚本切画面后 **≤300ms** 内吃到新帧（门禁机计数器） |
| G3 | 锁帧吞吐 | keep 批内找色 last_ms **≤5ms**（.166）/ **≤30ms**（.53） |
| G4 | 点击 | 横屏 HID 角点回归 PASS；不改 LOCK_TOUCH |
| G5 | 停止 | 音量−停止后 **≤1s** 无 lua；无 zydaemon 误 revive |
| G6 | 宣称「超越」 | G1–G5 全 PASS **且** 公开对照报告发布后，才允许改总排序 |

**当前裁决（未达 G6）：** 长稳天花板仍触动；子砚追赶中。

**架构写死（2026-07-31）：** 综合性能须**完全超越触动**，验收时优先盯 **G1 SB 稳定性** 与 **业务执行效率（G2/G3/圈速）**；对照必须含 `.149`/`.171` 触动日志拉取（`tmp_shots/TS_OBS/`）；测试结论只允许来自 `.53/.101/.112/.166`。

---

## 阶段

### P0 · 对照与度量（已完成基线）
- Canvas / VERDICT / TS_LEARNING：触动 Daemon 隔离 vs 子砚半隔离
- 四机版本对齐入口

### P1 · 8-137「触动式 keep 语义」（本轮开工）
1. **显式 `keepScreen(true)`** → 真锁帧至 `false`（禁软 TTL 偷偷换帧）  
2. **自动 keep**（脚本未显式锁）→ **≤350ms** 批窗后释放再截（换屏跟手）  
3. tap 后仍 `keepScreen(false)`（手册对齐，已有）  
4. 四机装包自测：orient / stop / find_lat / 功能机冒烟  

**触及：** LOCK_FINDCOLOR 仅脉冲/TTL 层（变更申请写入 `已正常功能参考.txt`）

### P2 · 找色匹配迁出 SB（已完成 · 8-138/8-139）
- 抽 `ZiYanColorMatch` 共享库；`framecap` 在 shm 热时直接答 `color_req`
- SB `pollColor` 热帧让出，≥150ms 无认领才回退  
- 验收：四机 keep 批 `via=daemon` **10/10**（见 `VERDICT_SURPASS_TS_P2.md`）

### P3 · 截帧/脚本守护产品化（下一刀 · 见 `逆向学习/PROJECT_REPLAN_AND_OPTIMIZE.md`）
- ZyDaemon：Lua + 帧池同属 root KeepAlive；SB 只留音量/触控/图标硬锁  
- .53 iOS16 守护取帧成功率门禁  
- 并行候选：自研 findImage（framecap）、OCR 白名单、局域网 HTTP 启停（对标 AutoTouch **公开** API 面，禁止拷贝实现）  
- 学习语料：`逆向学习/corpus/`（doc-spider；触动仅公开文档） 

### P4 · 8h 门禁 + 公开对照报告
- `stability_gate_8h` 双机 PASS  
- 更新 `VERDICT_SURPASS_TS.md`：达 G6 才改「总排序」

---

## 四机分工

| 机 | 角色 | 本轮自测 |
|----|------|----------|
| .166 | 门禁 rootful | **跑项目** `ios7.lua` · orient · stop · find |
| .53 | 门禁 rootless | **跑项目** `ios8p.lua` · 同上 |
| .101 | 功能 rootful | **同跑用户项目脚本**（禁止只冒烟）；无脚本则先 scp 再启 |
| .112 | 功能 rootful | **同跑用户项目脚本**（禁止只冒烟）；无脚本则先 scp 再启 |

> **禁止**：把 .101/.112 验收写成「keep/find 冒烟 PASS」代替项目脚本。  
> 装包后默认：四机都要有 `/var/mobile/Media/ZiYan/<项目>.lua` 并真正 `ziyan_run` / 音量菜单运行。

---

## 非目标（本计划不做）
- 不改音量菜单文案/布局硬锁  
- 不改 HID 单路径、Toast preferScreenLand  
- 不拷贝触动私有实现  
- 未达 G1 前不启动 3h+ 以外的「宣称超越」对外话术  
