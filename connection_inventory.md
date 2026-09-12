# E48 Windows 来源与非 Agent API 证据汇总

## 结论

本轮完成 E48 Windows 来源的固定只读清单、迁移候选汇总、静态 API 使用量、依赖边界和敏感排除记录。来源侧证据成立；迁移候选尚未复制或运行；非 Agent API 矩阵的目录静态事实成立，但四机功能证据仍全部为 `NOT_RUN`，不能写成设备通过。

## 采集范围

- Windows 来源根：`E:\传奇世界`
- 访问方式：本机固定 wrapper `windows-ssh` 调用 `powershell.exe -NoProfile -NonInteractive -EncodedCommand`
- 采集器：`tools/e48_legend_readonly_manifest.ps1`
- 本轮不连接、不操作 `.101`、`.112`、`.166`、`.53`
- 未安装、重签、替换动态库、解冻、恢复、重启或改变设备状态
- 生成清单：`e48_legend_manifest.json`
- 清单 SHA-256：`02933013d04c64f2a44b37277719224baa9c4be5ebe40a145f604436f2eac726`
- 采集时间：`2026-09-09T03:03:54.6675667Z`

## 来源 inventory

| 项目 | 数量 |
|---|---:|
| 来源文件总数 | 81 |
| 允许记录 | 40 |
| 迁移候选 | 22 |
| 仅 inventory 记录 | 18 |
| 敏感排除 | 41 |
| Lua | 21 |
| Luac | 9 |
| SO | 4 |
| TXT | 3 |
| DEB | 1 |
| JPG | 1 |
| ZIP | 1 |

允许记录中的每个文件均带来源侧大小、mtime、扩展名、SHA-256 和文本编码字段；敏感排除记录不含路径或 hash。

## 证据命令与原始输出

### 固定只读采集

命令：

```text
python3 tools/e48_readonly_ps.py --output e48_legend_manifest.json
```

原始 stdout：

```text
E48_READONLY_OK files=40 exclusions=41 output=e48_legend_manifest.json
```

### 只读 transport dry-run

命令：

```text
python3 tools/e48_readonly_ps.py --dry-run
```

原始 stdout：

```text
E48_READONLY_DRY_RUN
remote_root=E:\传奇世界
transport=windows-ssh powershell.exe -EncodedCommand
```

### 迁移复制 dry-run

命令：

```text
python3 tools/e48_collect_migration.py --manifest e48_legend_manifest.json --dry-run
```

原始 stdout：

```text
E48_MIGRATION_COLLECTION_OK samples=22 mode=dry_run
```

该命令没有调用 SCP，没有写入 `tests/touchsprite_migration/source`，没有产生 `sample_mapping.json`。

### 契约核验

命令：

```text
python3 -m unittest tools/test_e48_readonly_manifest_contract.py tools/test_e48_collect_migration_contract.py
```

原始 stdout：

```text
...........
----------------------------------------------------------------------
Ran 11 tests in 0.187s

OK
```

本轮保留的核验要点：

- 固定根为 `E:\传奇世界`
- collector 输出模式为 `read_only`
- 远端脚本不含写入、删除、移动、复制或启动进程的 mutator
- 迁移路径拒绝绝对路径、`..` 和空路径
- 迁移远端路径固定拼接到 `E:/传奇世界/`

### manifest 结构核验

命令：

```text
python3 -m json.tool e48_legend_manifest.json
```

核验结果：

```text
sourceRoot=E:\传奇世界
accessMode=read_only
files=40
exclusions.count=41
file sha256 valid=True
relative paths hidden in exclusions=False
source file total=81
```

其中 `relative paths hidden in exclusions=False` 表示排除记录没有携带路径字段；这是预期的敏感边界，不是失败。

### 本轮产物 hash

```text
02933013d04c64f2a44b37277719224baa9c4be5ebe40a145f604436f2eac726  e48_legend_manifest.json
```

基线引用：

```text
a79985e18fb4116749732c799c591396cd6b23ac3afaf9126a2991bafc0fc525  api_spec/catalog.json
209d933507349d3901f388e85b6e2fbf12e5dac9249c87bb413e1228d240a55d  api_spec/device_function_matrix.json
```

## 迁移样本

下表的 `source_hash_observed` 是 Windows 清单中的来源侧 `Get-FileHash` 结果；它不是本地复制后的 hash，也不是运行兼容性结论。

| 来源相对路径 | 字节数 | 来源 SHA-256 |
|---|---:|---|
| `2015528121953696.jpg` | 85135 | `faf66c042308edfefabd4824d3c994d1af8364af55add1b3e9fb99bf871ab5ab` |
| `赤沙龙城/CSLCJH.lua` | 7024 | `c042938d9caba91e5d53d9982013f4e6bdf8a12fc81e9d72bcebf8485c2270a3` |
| `赤沙龙城/TSLib.lua` | 166211 | `ae28c9dab4679abd64ac76a23f99ecc970a6786c8cfda75905cddb5e0a165d16` |
| `赤沙龙城加密/BBH.lua` | 7 | `9d170e826af271cb30ebbf1e2b8fbc97d0c57b3fd7b81fbdebad3fb654e326d0` |
| `赤沙龙城加密/CSLCJH.lua` | 17230 | `a393acba77825fb2e444ef345f83e0853fafa8990cf33e74c820ec4baaf42393` |
| `龙界争霸/LJZBQS.lua` | 14637 | `679a6cd8442d37cb3482c4ff820694b97cad75ccb460023889dd91ee32d03f59` |
| `怒剑传奇/NJCQJH.lua` | 5666 | `c3b06e1ecc237b680878ba42d0eef8beee784225ac80f9c415c1f5566e850d93` |
| `圣戒信条/SJXTJH.lua` | 5268 | `6bcaa8eb8801250981cb79c067cce7e2797c96c1b0fdb458d097ea086afd91a7` |
| `圣戒信条/TSLib.lua` | 166211 | `ae28c9dab4679abd64ac76a23f99ecc970a6786c8cfda75905cddb5e0a165d16` |
| `圣戒信条加密/BBH.lua` | 7 | `3928de9805210b5cc2eb75d5f05f908f0b700459d9417eab65f449f87a9c97d3` |
| `圣戒信条加密/SJXTJH.lua` | 17364 | `567c850e32ce5fd67dfff64901bc8ef82730d7cbeaa53b61ba2c5dbb9ecb99e1` |
| `系统工具/main.lua` | 585 | `184ff3a890e2dcac587464507e1362199f086859f44ab065774beb3e56f6fc4e` |
| `系统工具/ZYXiTongGongJu.lua` | 3587 | `f274546569e125ae785cdae2863068a6535875c41c90ed4d0abfb4d5933822e8` |
| `新版血战加密/BBH.lua` | 7 | `a82f4b4e61507c50beb86252439f4f6f23c2ace9f72b128097ca03322f5aad2f` |
| `新版血战加密/XBXZJH.lua` | 17109 | `e453ad0698cbe9d1a1a2b2fcc3955c853ce54010a5e6d11b0e211f6d1f761bdd` |
| `血战加密/BBH.lua` | 6 | `c646138cd87adccb736ed6b63feefec3530869669dca4c1122ba2ddbacbbcaf0` |
| `血战加密/XZTLJH.lua` | 17147 | `6b14e43a1d1f85b8d1c0f77350be074b6d12e49f11eec03b4d210e2e2af6b449` |
| `血战屠龙/BBH.lua` | 7 | `d65043ff255a5f90cbcaa21ef5affc2ed03592d2cc5f63f92e2c1b0c8890d26e` |
| `血战屠龙/ceshi.lua` | 2409 | `1f8a12fcfbafc2c8ef6e1734267bdbdc06b7930d9cce7eb3e99d7b3ed94a8b21` |
| `血战屠龙/TSLib.lua` | 166211 | `ae28c9dab4679abd64ac76a23f99ecc970a6786c8cfda75905cddb5e0a165d16` |
| `血战屠龙/XZJH.lua` | 8048 | `5a2d547aa43676bad079b560dce2b53a437cd4ecc8bd11689fdba74bb87294cf` |
| `血战优化/XZTLJH.lua` | 4989 | `e354e4cfe62260a6571f261131a83a2234cab20818c8421fb7cc10a5e1eceea8` |

迁移状态：22 个候选已由来源清单证实，0 个已复制，0 个已运行，0 个已在设备上验收。

## 静态 API 使用与非 Agent API 矩阵

### 来源侧静态 API

`e48_legend_api_usage.json` 汇总了 21 个允许 Lua 文件的静态匹配：

| 来源名称 | 次数 | ZiYan catalog 映射 |
|---|---:|---|
| `mSleep` | 199 | `sys.mSleep` |
| `getColor` | 19 | `screen.getColor` |
| `closeApp` | 9 | `app.appKill` legacy alias |
| `runApp` | 2 | `app.appRun` legacy alias |
| `touchDown` | 1 | `touch.touchDown` |
| `touchUp` | 1 | `touch.touchUp` |

这些是静态文本事实，不是 Agent API 的运行时调用证明。

### 矩阵事实

证据文件：

- `api_spec/catalog.json`
- `api_spec/device_function_matrix.json`
- `tmp_shots/E48_AUDIT_20260909_092718/api_baseline.json`

当前目录事实：

- catalog total：101
- status：done 55、partial 27、planned 19
- active total：101
- excluded total：0
- `local_functional_pass` 为 true 的项目：0
- 四机 device verdict：101 × 4 = 404，全部 `NOT_RUN`
- 有设备 evidence 字段的项目：0
- 四项 required capability 均未在 case 中建立 capability link

因此，当前只能确认“非 Agent 迁移接口目录和来源静态调用存在”，不能确认：

- Chat 文本输入、多轮复制粘贴
- 游戏规则状态、回合、计分、胜负和阶段迁移
- 自动决策 trace、重放、重试、降级、暂停和恢复
- 剪贴板、手势、硬件按键和 App 生命周期的真实设备行为

## 工具表示缺口

本轮生成的 manifest 保留 collector 原样。PowerShell 空数组在 JSON 输出及 Python 归一化后表现为 `[{}]`，本报告按“空集合”解释并在 `e48_legend_api_usage.json`、依赖图中显式记录。没有据此推导依赖或 API。

## 未证实项与下一步边界

- 未证实任何候选文件已复制到本地。
- 未证实任何候选文件可在 ZiYan 引擎执行。
- 未证实任何 API 在 `.101`、`.112`、`.166`、`.53` 上通过。
- 未证实被敏感规则排除的文件是否包含真实凭据。
- 未执行设备动作、历史 Chat、`BIZ11 publish_ms` 或业务代码修改。

本轮报告产物已齐；checkpoint 应更新为 `unfinished=false`、`nextAction=等待人工最终审核`。
