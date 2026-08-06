# ZiYan 架构总纲（写死）

**生效**：2026-07-31  
**Agent 强制规则**：`.cursor/rules/surpass-ts-four-pillar.mdc`（`alwaysApply: true`）  
**设备细则**：`DEVICE_RULES.md` · **目录**：`STRUCTURE.md` · **抄袭/整改**：`COPY_TS_REFORM_PLAN.md` · **五机门禁**：`FIVE_PHONE_SURPASS_PLAN.md`

---

## 0. 四条设备与目标铁律（写死）

| # | 铁律 | 内容 |
|---|------|------|
| **1** | 机型矩阵 | 必须兼容越狱 **iPhone 7 / 7P / 8 / 8P**，系统 **iOS 13～16.7.16**（后续扩展待告知） |
| **2** | TS 日志 | **`.149` / `.171`** 运行触动精灵的日志/状态须可记录；需要时**随时拉取**落盘 `tmp_shots/TS_OBS/` 与四机对照 |
| **3** | 测试机专用 | **`.53` / `.101` / `.112` / `.166` 只做 ZiYan 项目测试**（唯一可部署/验收机） |
| **4** | 全面超越 | 综合性能须**完全超越触动**，尤其 **SB 稳定性**、**业务脚本执行效率**（宣称须 G1–G6 + VERDICT + TS 日志对照） |

---

## 1. 战略：四支柱加速并超越触动精灵

子砚不是「另起炉灶忽略触动」，也不是「拷贝触动」。固定组合为：

```
模仿触动（体感/运行模型）
    + 借鉴触动（分层/语义/稳态，公开资料 + .149/.171 日志）
    + 自研（lua/ + objc/ + 自有 IPC/framecap）
    + 网络学习与 corpus（逆向学习/corpus + 免费开源）
    → 仅在 .53/.101/.112/.166 真测
    → 拉取 .149/.171 TS 日志对照 + VERDICT
    → SB 稳态 & 业务效率全面优于触动后，才可宣称超越
```

| 支柱 | 做什么 | 绝不做什么 |
|------|--------|------------|
| 模仿 | 常驻合帧、音量启停、找色/点/Toast 跟手、Home 后可点、冷启动可跑 | 观察机装 ZiYan；把 TS 结果当 ZiYan PASS |
| 可抄触动 | 允许抄 API/逻辑/算法进 `lua/`/`objc/`（手册、日志、逆向、open_code） | 把 TS so/Daemon **链进包当运行依赖** |
| 落点自有树 | 抄来的能力由 ZiYan 二进制/脚本自己跑 | Desktop ios7/ios8p 改内容（仅 scp） |
| corpus/网络 | 先查 `逆向学习/corpus/`，再 GitHub/HF 免费资源 | 无确认批量拉；付费闭源 |

---

## 2. 运行模型（对标 TSDaemon，自研落地）

```
[音量菜单 / App UI]
        │ menu_run / run_intent
        ▼
┌─────────────────── SpringBoard（薄）───────────────────┐
│ ZiYanVol：音量·Toast·Home·open_app 闸                  │
│ ZiYanFrameRelay：合帧中继 / 触控兜底（thin）            │
└────────────────────────┬──────────────────────────────┘
                         │ IPC: $JB/usr/lib/ziyan/var
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
  ziyan_framecap    lua5.3/ziyan_run   AppTouch(游戏)
  （常驻合帧·对标     （业务脚本）      （进程内点）
   TSDaemon 帧侧）
```

**铁律**：`menu_run` 启动脚本时必须 **EnsureFramecapAlive**（launchd load 或拉起 `serve`）。  
只起 lua、不起合帧守护 → 找色卡 `color_req` 无 `color_rep` → 用户看到「毫无反应」。  
助手测试若手动起了 framecap，产品路径也必须自动做同一件事。

---

## 3. 设备角色（不可混）

| 角色 | IP | 用途 |
|------|-----|------|
| TS 观察 + 日志 | `.171` / `.149` | 只读学触动；**随时拉 TS 日志** → `tmp_shots/TS_OBS/`；禁止部署 ZiYan |
| ZiYan 项目测试 | `.53` / `.101` / `.112` / `.166` | **只做本项目测试**；唯一部署与功能/稳态结论来源 |

兼容矩阵：**7 / 7P / 8 / 8P × iOS 13～16.7.16**（当前四机覆盖 7 + 8P 主路径，代码不得排斥 7P/8；后续扩展待用户告知）。

Desktop 业务脚本：`/Users/mac/Desktop/ios7.lua`、`ios8p.lua` → **只 scp，不改文件**。

---

## 4. 学习资源落点

| 来源 | 路径/方式 |
|------|-----------|
| 仓内语料 | `逆向学习/corpus/`（`repos/` `raw/` `text/` `priority/` `touchsprite_helpdoc/`） |
| 触动真机日志 | `.149`/`.171` 拉取 → `tmp_shots/TS_OBS/<timestamp>/` |
| 触动公开 | 手册/官网/开发者文档（原理学习）；实现必须自研重封装 |
| 开源逆向 | corpus 内 GitHub 镜像 + 联网检索时优先免费开源 |
| 模型 | Hugging Face 免费可用优先 |

---

## 5. 宣称「完全超越触动」门槛

见 `FIVE_PHONE_SURPASS_PLAN.md` **G0** 与历史门槛归档 `DOCS/_superseded_plans/SURPASS_TS_PLAN.md` **G1–G6**。  
硬指标优先：**SpringBoard 长稳**、**业务脚本执行效率**（找色/圈速/跟手）。  
缺四机 VERDICT、缺 `.149`/`.171` 日志对照、缺长稳数据 → **禁止宣称超越**。

---

## 6. 变更纪律

改启动链 / 合帧 / 找色 / 触控 / Toast / 守护时：

1. 对照四支柱 + §0 四条铁律  
2. 手动路径与助手路径是否同构  
3. 仅在测试四机验收；需要时拉取 `.149`/`.171` TS 日志  
4. 落下 `tmp_shots/.../VERDICT.md`（含 SB 稳态与业务效率对照）  
