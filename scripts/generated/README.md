# AI 生成脚本输出目录

由 `Zy.AI.save` / `Zy.AI.loop` 写入。  
记录：`AI_GEN_DB.jsonl` · 优秀方案：`ai_best.lua`

功能测试约束：

- 生成脚本必须包含 `AI-GENERATED` 标记并只调用 `Zy.*` 模块。
- `Zy.AI.test` 默认要求 `real_device=true`。
- 本地 load-only/light-test 只能作为语法检查，不能形成业务 PASS。
- 业务功能 verdict 必须来自 `.101 → .112 → .166 → .53` 四台真机。
