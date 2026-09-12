# E48 来源依赖图

## 证据边界

- 来源根：`E:\传奇世界`
- 访问模式：`read_only`
- 清单：`e48_legend_manifest.json`
- 清单 SHA-256：`02933013d04c64f2a44b37277719224baa9c4be5ebe40a145f604436f2eac726`
- 采集器：`tools/e48_legend_readonly_manifest.ps1`
- 采集时间：`2026-09-09T03:03:54.6675667Z`
- 本图只表示固定采集器从允许输出中观察到的 Lua `require`、`dofile`、`loadfile` 和资源字符串。

## 文件层

- 允许记录：40
- 迁移候选：22
- 仅清单记录：18
- Lua 文件：21
- `fileDependencies` 匹配：0
- 图片资源字符串匹配：0

因此，当前证据没有建立 Lua 文件之间的显式 `dofile`/`loadfile` 边；模块名只表示源文本中的 `require` 结果，不等于本地工程中已经存在对应模块。

## `require` 模块到来源文件

| 模块 | 观察到的文件 |
|---|---|
| `ts` | `赤沙龙城/CSLCJH.lua`; `赤沙龙城加密/CSLCJH.lua`; `龙界争霸/LJZBQS.lua`; `怒剑传奇/NJCQJH.lua`; `圣戒信条/SJXTJH.lua`; `圣戒信条加密/SJXTJH.lua`; `新版血战加密/XBXZJH.lua`; `血战加密/XZTLJH.lua`; `血战屠龙/XZJH.lua`; `血战优化/XZTLJH.lua` |
| `TSLib` | `赤沙龙城/CSLCJH.lua`; `龙界争霸/LJZBQS.lua`; `怒剑传奇/NJCQJH.lua`; `圣戒信条/SJXTJH.lua`; `血战屠龙/ceshi.lua`; `血战屠龙/XZJH.lua`; `血战优化/XZTLJH.lua` |
| `sz` | `龙界争霸/LJZBQS.lua` |
| `posix` | `系统工具/ZYXiTongGongJu.lua` |
| `socket` | `血战屠龙/ceshi.lua` |
| `XZHS` | `血战屠龙/XZJH.lua` |
| `XZQS` | `血战屠龙/XZJH.lua` |
| `XZUI` | `血战屠龙/XZJH.lua` |

## 迁移样本边界

22 个迁移候选均只有来源侧 `Get-FileHash`、大小和静态文本事实。`e48_collect_migration.py --dry-run` 只产生计划，不发生 SCP、本地落盘校验或运行验证；因此本图不声明任何迁移样本已复制、可执行或行为兼容。

## 未证实项

- 模块文件的搜索路径、加载顺序和运行时分支未由本次清单证实。
- 加密目录中的 `.luac` 文件只进入 inventory-only 记录，未反编译、未执行。
- 被敏感排除策略命中的文件不进入本依赖图。
