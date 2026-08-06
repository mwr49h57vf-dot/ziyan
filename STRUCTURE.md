# ZiYan 源码结构

设备安装路径由 `layout/` + Theos staging 决定。本文件说明**仓库**分类与真相源。

## 架构铁律（写死 · 四支柱）

> **权威 Agent 规则**：`.cursor/rules/surpass-ts-four-pillar.mdc`（`alwaysApply: true`）  
> **人类可读总纲**：`ARCHITECTURE.md`

开发必须同时走四支柱 + 四条设备/目标铁律，目标是**综合性能完全超越触动**（尤其 SB 稳定性、业务执行效率）：

| 支柱 | 一句话 |
|------|--------|
| 模仿触动 | 对齐 TS 体感与运行模型（常驻合帧、冷启动可跑、Home 后可点） |
| 可抄触动 | 允许抄 API/逻辑/算法进 `lua/`/`objc/`；仅禁链触动 dylib/TSDaemon 作运行依赖 |
| 自研 | 全部落 `lua/` + `objc/` + 自有 IPC / framecap |
| 网络+corpus | 优先 `逆向学习/corpus/` 与免费开源；禁止无确认批量拉取 |

| 铁律 | 一句话 |
|------|--------|
| 机型矩阵 | **7 / 7P / 8 / 8P × iOS 13～16.7.16** 必须可跑（后续扩展待告知） |
| TS 日志 | `.149`/`.171` 触动日志可记录，需要时随时拉 `tmp_shots/TS_OBS/` |
| 测试机 | `.53`/`.101`/`.112`/`.166` **只做 ZiYan 项目测试** |
| 超越目标 | SB 稳定性 + 业务效率全面优于触动；宣称须 G1–G6 + VERDICT + TS 对照 |

```
ZiYan_副本/
├── Makefile / control / *.plist     # Theos 入口（deployment 13.0）
├── README.md                        # 项目说明摘要
├── ARCHITECTURE.md                  # 四支柱架构总纲（写死）
├── STRUCTURE.md                     # 本文件
├── .cursor/rules/                   # Agent 铁律（含 surpass-ts-four-pillar）
├── 逆向学习/corpus/                 # 网络学习语料（TS 公开文档 + 开源逆向）
├── DOCS/
│   ├── PROJECT.md                   # 项目说明详版
│   ├── API.md                       # 函数说明（由 api_spec 生成）
│   └── CLEANUP_REPORT.md            # 整理报告
│
├── objc/                            # Objective-C
│   ├── app/                         # ZiYan.app UI
│   │   ├── ZiYanScriptGenerator.m   # R8.4.1 自动生成脚本（runApp/OCR/learn）
│   │   ├── ZiYanDumpManager.m       # R8.4.1 脱壳 IPA+分析+defense_feed
│   │   └── ZiYanLLMSidecarClient.m  # POST /v1/* + 文件回退
│   ├── tweak/
│   │   ├── springboard/             # ZiYanVol：音量 / Toast / 截屏找色 / 触控兜底
│   │   └── apptouch/                # 进程内触控 + MemHook（Filter 可配）
│   ├── shared/                      # Engine / ScriptRunner / Paths / OrientMap
│   └── _archive/                    # 未接入构建（E：默认保留）
│
├── lua/                             # Lua 引擎（脚本 API 唯一真相源）
│   ├── ziyan_engine/                # touch / cv / py_cv / orient / …
│   ├── ziyan_run.lua / ziyan_te_boot.lua
│   └── json.lua / inspect.lua
│   → 安装到 /usr/lib/ziyan/lib/lua/
│
├── Script/                          # 用户脚本 SDK（Template/Examples/Helper/Debug）
├── GPT.txt                          # AI 上下文同步（助手必读）
├── api_spec/                        # 契约 catalog / modules / compat / reports
├── layout/                          # 装机路径镜像
│   ├── private/.../Media/ZiYan/     # 用户脚本（smoke / api_test / login_*）
│   └── usr/lib/ziyan/               # tessdata / modules HTML / var 占位
│
├── tools/                           # device_smoke / gate / OCR / mem / 取色
│   └── ziyan_training_import/       # R8.4.2 Ai代码训练→knowledge 导入
├── media_seed/knowledge/            # 导入产物 index/KB/families
├── vendor/                          # 运行时二进制（H：慎删）
├── Resources/                       # App 资源
├── probes/                          # 本地探测（仅 README；图可删）
├── packages/                        # deb（保留最新 2 产品版+保底 arm64；bash tools/cleanup_packages.sh）
├── DOCS/_superseded_plans/          # 过时计划归档（排期以 FIVE_PHONE_SURPASS_PLAN.md 为准）
├── tmp_shots/                       # 真机日志（可再生；SURPASS_TS/TS_OBS/SELF_ITERATE）
├── vendor/ref/                      # 学习参考 zip（如 TSColorPicker）
└── .theos/                          # 构建中间产物（可 clean）
```

## 真相源

| 角色 | 路径 |
|------|------|
| 脚本 API | `lua/` |
| Native | `objc/` |
| 契约 | `api_spec/` |
| 装机副本 | `layout/`（用户脚本装机源） |

`.theos/_/` 是 staging 副本，**不是**真相源。

## 核心脚本 API → 实现

| API | 实现 | IPC / 依赖 |
|-----|------|------------|
| `init(1)` | `orient.lua` | `.ziyan_orient` |
| `findMultiColorInRegionFuzzy` | `cv.lua` → ScreenBridge | `.ziyan_color_req` |
| `tap` / `touchDown` | `touch.lua` → AppTouch / SB | `.ziyan_touch_req`；默认随机手指 |
| `getText` | `py_cv.lua` + `ziyan_ocr` | `.ziyan_cv_shot.png` |
| `NetTime` | `py_cv.lua` | curl |
| `toast` | `toast.lua` | `.ziyan_cmd` |

## 找色 / 方向数据流

1. `init(1)` → `orient.lua` 写 `.ziyan_orient`
2. 找色 → `cv.lua` → `.ziyan_color_req`
3. `ZiYanScreenBridge` + `ZiYanOrientMap.h` 逻辑坐标取样
4. 触控同一套 OrientMap（AppTouch / SB）

### TS 找色工作流

```bash
bash tools/pull_ts_shot.sh
python3 tools/ts_color_pick_gui.py layout/private/var/mobile/Media/ZiYan/ts_shot.png --logic 1136x640
```

## 构建

```bash
make package   # → packages/com.ziyan.ziyan_*.deb
```

根目录保留 `ZiYanVol.plist` / `ZiYanAppTouch.plist`（Theos 约定）。

完整说明见 [DOCS/PROJECT.md](DOCS/PROJECT.md)，函数表见 [DOCS/API.md](DOCS/API.md)。

## Rootless / rootful 打包
见 [DOCS/ROOTLESS.md](DOCS/ROOTLESS.md)。交付 USB rootless 机请用 `make package-rootless`（`iphoneos-arm64`）。

## P0 自检
见 [DOCS/P0_CHECKLIST.md](DOCS/P0_CHECKLIST.md)。  
装机脚本：`Media/ZiYan/_orient_selftest.lua` → 报告 `ZYCV/_orient_selftest.txt`。
