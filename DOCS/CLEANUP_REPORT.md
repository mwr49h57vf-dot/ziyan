# ZiYan 仓库整理报告

## 2026-08-02 22:58（续 · 再清 + 新总计划）

| 路径 | 结果 |
|------|------|
| `tmp_shots` 大包/重复门禁/forever 日志 | 已删；留五机 Find/Home + TS/Pe 架构对照 ≈1.7M |
| Pe deb `extract/data` | 已删（分析 md 保留；deb 仍在桌面可重解） |
| `函数测试优化建议.txt` | 迁入 `_superseded_plans/` |
| **新权威** | 根目录 `COPY_TS_REFORM_PLAN.md` |

---

## 2026-08-02 22:50（清历史冲突）

### 已执行

| 路径 | 结果 | 理由 |
|------|------|------|
| `packages/` 旧 deb ×90 | **已删** | 策略保留 126/127/128（含 .53 用 arm64 `126-3`）；3.7G→**207M** |
| 根目录过时计划 10 份 | **迁入** `DOCS/_superseded_plans/` | 与 `FIVE_PHONE_SURPASS_PLAN.md` 冲突，易误导排期 |
| `tools/cleanup_packages.sh` | **重写** | 旧 sed 解析会误删最新包；现按产品版本保留 + 保底 arm64 |

### 保留的 packages

- `0.0.92-8-161-128-1` arm（当前 .112）
- `0.0.92-8-161-127-1` arm（回滚）
- `0.0.92-8-161-126-{1,2}` arm + `126-3` arm64（rootless 最近包）

### 迁入 `_superseded_plans/`（非删除）

`SURPASS_TS_PLAN.md` · `SURPASS_PLAN_171_53_166.md` · `TS512_DEB_SURPASS_PLAN.md` · `PHASE1_RESET.md` · `GPT_PROJECT_STATE.txt` · `SYSTEM_REGRESSION_REPORT.md` · `forever_status.txt` · `device_difference_report.md` · `iPhone7_vs_iPhone8Plus_report.md` · `EMAIL_TO_MUSK.txt`

### 索引已改指

`README.md` · `ARCHITECTURE.md` · `DEVICE_RULES.md` · `脚本生成提示词.txt` · `.cursor/rules/surpass-ts-four-pillar.mdc` → 权威改为 `FIVE_PHONE_SURPASS_PLAN.md`。

### 未动（慎删）

| 路径 | 理由 |
|------|------|
| `tmp_shots/`（含今日 TS/Pe 架构对照） | 证据；勿再整目录清空 |
| `vendor/` · `.theos/` · `objc/` · `lua/` · `layout/` | 构建/源码 |
| `GPT.txt` · `历史问题全归档.txt` · `已正常功能参考.txt` | 仍在用 |

### 安全命令

```bash
bash tools/cleanup_packages.sh
```

---

## 2026-08-01（上次）

磁盘：**11G → 2.7G**（旧 deb）。`tmp_shots` 曾误删重建——详见该节事故说明（已归档于 git 历史；本文件旧节略）。
